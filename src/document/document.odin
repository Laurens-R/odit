package document

import "core:strings"
import "core:bytes"

import "../collections"

DocumentBufferKind :: enum {
	Source,
	Edit,
}

DocumentBuffer :: struct {
	kind:   DocumentBufferKind,
	buffer: bytes.Buffer,
}

// --- Edit operations for undo/redo ---

EditKind :: enum {
	Insert,
	Delete,
	Compound, // children form an atomic group — undo/redo replays them as one
}

EditOperation :: struct {
	kind:     EditKind,
	offset:   u32,
	length:   u32,    // length of the inserted or deleted text
	text:     string, // for Delete: the deleted text (needed to redo insert on undo)
	                  // for Insert: the inserted text (needed to redo delete on undo)
	children: []EditOperation, // populated only for Compound; nil otherwise
}

UndoStack :: struct {
	operations:    [dynamic]EditOperation,
	current_position: int, // current position in the stack (for undo/redo)
}

// --- Document ---

Document :: struct {
	piece_tree:        PieceTree,
	undo_stack:        UndoStack,
	has_unsaved_changes: bool, // true if modified since last save
}

// --- DocumentBuffer procs (used internally by PieceTree) ---

document_buffer_init :: proc(document_buffer: ^DocumentBuffer, kind: DocumentBufferKind, initial_text: string) {
	document_buffer.kind = kind
	if len(initial_text) > 0 {
		bytes.buffer_init_string(&document_buffer.buffer, initial_text)
	}
}

document_buffer_destroy :: proc(document_buffer: ^DocumentBuffer) {
	bytes.buffer_destroy(&document_buffer.buffer)
	// bytes.buffer_destroy frees the underlying memory but leaves the dynamic
	// array header pointing at the now-freed region (delete takes [dynamic]
	// by value, so it can't null out our copy of `.data`/`.cap`). If we then
	// reused this buffer, the next `resize` would realloc a dangling pointer
	// and corrupt the heap. Reset to a clean, empty Buffer.
	document_buffer.buffer = bytes.Buffer{}
}

document_buffer_append :: proc(document_buffer: ^DocumentBuffer, text_to_append: string) {
	bytes.buffer_write_string(&document_buffer.buffer, text_to_append)
}

// --- Document lifecycle ---

document_init :: proc(document: ^Document, initial_text: string) {
	piecetree_init(&document.piece_tree, initial_text)
	document.undo_stack.operations = make([dynamic]EditOperation)
	document.undo_stack.current_position = 0
	document.has_unsaved_changes = false
}

document_destroy :: proc(document: ^Document) {
	piecetree_destroy(&document.piece_tree)
	for &edit_operation in document.undo_stack.operations {
		edit_operation_destroy(&edit_operation)
	}
	delete(document.undo_stack.operations)
}

// Recursively free an EditOperation's owned memory (the `text` string and any
// Compound `children`). Safe to call on a zero-value EditOperation.
@(private="file")
edit_operation_destroy :: proc(edit_operation: ^EditOperation) {
	if len(edit_operation.text) > 0 {
		delete(edit_operation.text)
		edit_operation.text = ""
	}
	if edit_operation.children != nil {
		for &child in edit_operation.children {
			edit_operation_destroy(&child)
		}
		delete(edit_operation.children)
		edit_operation.children = nil
	}
}

// --- Document editing API ---

// Insert text at offset. Records an undo operation.
document_insert :: proc(document: ^Document, offset: u32, text_to_insert: string) {
	if len(text_to_insert) == 0 {
		return
	}

	piecetree_insert(&document.piece_tree, offset, text_to_insert)

	// Truncate any redo history beyond current position
	undo_truncate_redo(document)

	// Record the operation
	edit_operation := EditOperation{
		kind   = .Insert,
		offset = offset,
		length = u32(len(text_to_insert)),
		text   = strings.clone(text_to_insert),
	}
	append(&document.undo_stack.operations, edit_operation)
	document.undo_stack.current_position += 1
	document.has_unsaved_changes = true
}

// Delete `length_to_delete` bytes at offset. Records an undo operation.
document_delete :: proc(document: ^Document, offset: u32, length_to_delete: u32) {
	if length_to_delete == 0 {
		return
	}

	// Capture the text being deleted (needed for undo)
	deleted_text := piecetree_get_slice(&document.piece_tree, offset, length_to_delete)

	piecetree_delete(&document.piece_tree, offset, length_to_delete)

	// Truncate any redo history
	undo_truncate_redo(document)

	edit_operation := EditOperation{
		kind   = .Delete,
		offset = offset,
		length = length_to_delete,
		text   = deleted_text, // already allocated by get_slice
	}
	append(&document.undo_stack.operations, edit_operation)
	document.undo_stack.current_position += 1
	document.has_unsaved_changes = true
}

// --- Undo / Redo ---

// Undo the last operation. Returns the cursor offset after the undo and whether
// an operation was undone.
document_undo :: proc(document: ^Document) -> (cursor_offset: u32, success: bool) {
	if document.undo_stack.current_position <= 0 {
		return 0, false
	}

	document.undo_stack.current_position -= 1
	edit_operation := &document.undo_stack.operations[document.undo_stack.current_position]
	cursor_offset = apply_undo_operation(document, edit_operation)
	document.has_unsaved_changes = true
	success = true
	return
}

// Redo the last undone operation. Returns the cursor offset after the redo and
// whether an operation was redone.
document_redo :: proc(document: ^Document) -> (cursor_offset: u32, success: bool) {
	if document.undo_stack.current_position >= len(document.undo_stack.operations) {
		return 0, false
	}

	edit_operation := &document.undo_stack.operations[document.undo_stack.current_position]
	document.undo_stack.current_position += 1
	cursor_offset = apply_redo_operation(document, edit_operation)
	document.has_unsaved_changes = true
	success = true
	return
}

// Replay `edit_operation` in reverse so the doc returns to its pre-op state.
// Compound entries recurse into their children in reverse order so the partial
// piecetree state seen at each step matches the order edits were originally
// applied (last child first).
@(private="file")
apply_undo_operation :: proc(document: ^Document, edit_operation: ^EditOperation) -> (cursor_offset: u32) {
	switch edit_operation.kind {
	case .Insert:
		piecetree_delete(&document.piece_tree, edit_operation.offset, edit_operation.length)
		cursor_offset = edit_operation.offset
	case .Delete:
		piecetree_insert(&document.piece_tree, edit_operation.offset, edit_operation.text)
		cursor_offset = edit_operation.offset + edit_operation.length
	case .Compound:
		for child_index := len(edit_operation.children) - 1; child_index >= 0; child_index -= 1 {
			cursor_offset = apply_undo_operation(document, &edit_operation.children[child_index])
		}
	}
	return
}

@(private="file")
apply_redo_operation :: proc(document: ^Document, edit_operation: ^EditOperation) -> (cursor_offset: u32) {
	switch edit_operation.kind {
	case .Insert:
		piecetree_insert(&document.piece_tree, edit_operation.offset, edit_operation.text)
		cursor_offset = edit_operation.offset + edit_operation.length
	case .Delete:
		piecetree_delete(&document.piece_tree, edit_operation.offset, edit_operation.length)
		cursor_offset = edit_operation.offset
	case .Compound:
		for child_index in 0..<len(edit_operation.children) {
			cursor_offset = apply_redo_operation(document, &edit_operation.children[child_index])
		}
	}
	return
}

// --- Compound edits (transactions) ----------------------------------------

// Snapshot the current undo position. Pair with `document_end_compound` to
// collapse every Insert/Delete recorded between the two calls into a single
// Compound undo entry, so the user's Ctrl+Z reverts the whole transaction at
// once. The interactive Replace bar uses this for its live-preview flow.
document_begin_compound :: proc(document: ^Document) -> (snapshot_position: int) {
	return document.undo_stack.current_position
}

// Coalesce all entries recorded between `snapshot_position` and the current
// position into one Compound EditOperation. Caller is responsible for not
// rewinding `current_position` (via undo) between begin/end — that would leave
// the snapshot pointing inside live entries.
document_end_compound :: proc(document: ^Document, snapshot_position: int) {
	current_position := document.undo_stack.current_position
	if snapshot_position < 0 || snapshot_position >= current_position { return }
	operation_count := current_position - snapshot_position
	if operation_count == 0 { return }
	if operation_count == 1 {
		// Single op — wrapping it in a Compound would just add memory churn
		// for no behavior change. Leave the stack alone.
		return
	}

	// Move the existing entries into a `children` slice owned by the new
	// Compound entry. Their `text` allocations move with them; we must not
	// double-free, so we resize down before pushing the Compound.
	children := make([]EditOperation, operation_count)
	for child_index in 0..<operation_count {
		children[child_index] = document.undo_stack.operations[snapshot_position + child_index]
	}
	resize(&document.undo_stack.operations, snapshot_position)

	compound := EditOperation{
		kind     = .Compound,
		children = children,
	}
	append(&document.undo_stack.operations, compound)
	document.undo_stack.current_position = snapshot_position + 1
}

// Rewind the doc back to `target_position` AND drop the rolled-back entries
// from the stack (so they can't be redone). Used by the Replace bar's cancel
// path to throw away the in-progress preview.
document_pop_to_position :: proc(document: ^Document, target_position: int) {
	if target_position < 0 { return }
	for document.undo_stack.current_position > target_position {
		document.undo_stack.current_position -= 1
		edit_operation := &document.undo_stack.operations[document.undo_stack.current_position]
		_ = apply_undo_operation(document, edit_operation)
	}
	for operation_index := target_position; operation_index < len(document.undo_stack.operations); operation_index += 1 {
		edit_operation_destroy(&document.undo_stack.operations[operation_index])
	}
	resize(&document.undo_stack.operations, target_position)
}

// --- Document query API (delegates to PieceTree) ---

// Get the full document text.
document_get_text :: proc(document: ^Document, allocator := context.allocator) -> string {
	return piecetree_get_text(&document.piece_tree, allocator)
}

// Get a slice of document text.
document_get_slice :: proc(document: ^Document, offset: u32, length: u32, allocator := context.allocator) -> string {
	return piecetree_get_slice(&document.piece_tree, offset, length, allocator)
}

// Total byte length of the document.
document_length :: proc(document: ^Document) -> u32 {
	return piecetree_length(&document.piece_tree)
}

// Total number of lines.
document_line_count :: proc(document: ^Document) -> u32 {
	return piecetree_line_count(&document.piece_tree)
}

// Get the byte offset where a line starts (0-indexed).
document_line_start :: proc(document: ^Document, line_index: u32) -> u32 {
	return piecetree_line_start(&document.piece_tree, line_index)
}

// Get the line number for a byte offset.
document_offset_to_line :: proc(document: ^Document, offset: u32) -> u32 {
	return piecetree_offset_to_line(&document.piece_tree, offset)
}

// Get the content of a line (without trailing newline).
document_get_line :: proc(document: ^Document, line_index: u32, allocator := context.allocator) -> string {
	return piecetree_get_line(&document.piece_tree, line_index, allocator)
}

// Mark the document as saved (clears dirty flag).
document_mark_saved :: proc(document: ^Document) {
	document.has_unsaved_changes = false
}

// Check if document has unsaved changes.
document_is_dirty :: proc(document: ^Document) -> bool {
	return document.has_unsaved_changes
}

// --- Internal undo helpers ---

@(private="file")
undo_truncate_redo :: proc(document: ^Document) {
	current_position := document.undo_stack.current_position
	for operation_index := current_position; operation_index < len(document.undo_stack.operations); operation_index += 1 {
		edit_operation_destroy(&document.undo_stack.operations[operation_index])
	}
	resize(&document.undo_stack.operations, current_position)
}
