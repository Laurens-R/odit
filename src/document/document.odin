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
}

EditOperation :: struct {
	kind:   EditKind,
	offset: u32,
	length: u32,    // length of the inserted or deleted text
	text:   string, // for Delete: the deleted text (needed to redo insert on undo)
	                // for Insert: the inserted text (needed to redo delete on undo)
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
	// Free stored text in edit operations
	for &edit_operation in document.undo_stack.operations {
		if len(edit_operation.text) > 0 {
			delete(edit_operation.text)
		}
	}
	delete(document.undo_stack.operations)
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

	switch edit_operation.kind {
	case .Insert:
		// Undo an insert = delete the inserted text
		piecetree_delete(&document.piece_tree, edit_operation.offset, edit_operation.length)
		cursor_offset = edit_operation.offset
	case .Delete:
		// Undo a delete = re-insert the deleted text
		piecetree_insert(&document.piece_tree, edit_operation.offset, edit_operation.text)
		cursor_offset = edit_operation.offset + edit_operation.length
	}

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

	switch edit_operation.kind {
	case .Insert:
		// Redo an insert = insert again
		piecetree_insert(&document.piece_tree, edit_operation.offset, edit_operation.text)
		cursor_offset = edit_operation.offset + edit_operation.length
	case .Delete:
		// Redo a delete = delete again
		piecetree_delete(&document.piece_tree, edit_operation.offset, edit_operation.length)
		cursor_offset = edit_operation.offset
	}

	document.has_unsaved_changes = true
	success = true
	return
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
	// If we're not at the end, discard all operations after current position
	current_position := document.undo_stack.current_position
	for operation_index := current_position; operation_index < len(document.undo_stack.operations); operation_index += 1 {
		edit_operation := &document.undo_stack.operations[operation_index]
		if len(edit_operation.text) > 0 {
			delete(edit_operation.text)
		}
	}
	resize(&document.undo_stack.operations, current_position)
}
