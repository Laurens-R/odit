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

EditOp :: struct {
	kind:   EditKind,
	offset: u32,
	length: u32,    // length of the inserted or deleted text
	text:   string, // for Delete: the deleted text (needed to redo insert on undo)
	                // for Insert: the inserted text (needed to redo delete on undo)
}

UndoStack :: struct {
	ops:      [dynamic]EditOp,
	position: int, // current position in the stack (for undo/redo)
}

// --- Document ---

Document :: struct {
	tree:       PieceTree,
	undo_stack: UndoStack,
	dirty:      bool, // true if modified since last save
}

// --- DocumentBuffer procs (used internally by PieceTree) ---

document_buffer_init :: proc(buffer: ^DocumentBuffer, kind: DocumentBufferKind, initial: string) {
	buffer.kind = kind
	if len(initial) > 0 {
		bytes.buffer_init_string(&buffer.buffer, initial)
	}
}

document_buffer_destroy :: proc(buffer: ^DocumentBuffer) {
	bytes.buffer_destroy(&buffer.buffer)
}

document_buffer_append :: proc(buffer: ^DocumentBuffer, str: string) {
	bytes.buffer_write_string(&buffer.buffer, str)
}

// --- Document lifecycle ---

document_init :: proc(doc: ^Document, initial: string) {
	piecetree_init(&doc.tree, initial)
	doc.undo_stack.ops = make([dynamic]EditOp)
	doc.undo_stack.position = 0
	doc.dirty = false
}

document_destroy :: proc(doc: ^Document) {
	piecetree_destroy(&doc.tree)
	// Free stored text in edit ops
	for &op in doc.undo_stack.ops {
		if len(op.text) > 0 {
			delete(op.text)
		}
	}
	delete(doc.undo_stack.ops)
}

// --- Document editing API ---

// Insert text at offset. Records an undo operation.
document_insert :: proc(doc: ^Document, offset: u32, text: string) {
	if len(text) == 0 {
		return
	}

	piecetree_insert(&doc.tree, offset, text)

	// Truncate any redo history beyond current position
	undo_truncate_redo(doc)

	// Record the operation
	op := EditOp{
		kind   = .Insert,
		offset = offset,
		length = u32(len(text)),
		text   = strings.clone(text),
	}
	append(&doc.undo_stack.ops, op)
	doc.undo_stack.position += 1
	doc.dirty = true
}

// Delete `length` bytes at offset. Records an undo operation.
document_delete :: proc(doc: ^Document, offset: u32, length: u32) {
	if length == 0 {
		return
	}

	// Capture the text being deleted (needed for undo)
	deleted_text := piecetree_get_slice(&doc.tree, offset, length)

	piecetree_delete(&doc.tree, offset, length)

	// Truncate any redo history
	undo_truncate_redo(doc)

	op := EditOp{
		kind   = .Delete,
		offset = offset,
		length = length,
		text   = deleted_text, // already allocated by get_slice
	}
	append(&doc.undo_stack.ops, op)
	doc.undo_stack.position += 1
	doc.dirty = true
}

// --- Undo / Redo ---

// Undo the last operation. Returns the cursor offset after the undo and whether
// an operation was undone.
document_undo :: proc(doc: ^Document) -> (cursor_offset: u32, ok: bool) {
	if doc.undo_stack.position <= 0 {
		return 0, false
	}

	doc.undo_stack.position -= 1
	op := &doc.undo_stack.ops[doc.undo_stack.position]

	switch op.kind {
	case .Insert:
		// Undo an insert = delete the inserted text
		piecetree_delete(&doc.tree, op.offset, op.length)
		cursor_offset = op.offset
	case .Delete:
		// Undo a delete = re-insert the deleted text
		piecetree_insert(&doc.tree, op.offset, op.text)
		cursor_offset = op.offset + op.length
	}

	doc.dirty = true
	ok = true
	return
}

// Redo the last undone operation. Returns the cursor offset after the redo and
// whether an operation was redone.
document_redo :: proc(doc: ^Document) -> (cursor_offset: u32, ok: bool) {
	if doc.undo_stack.position >= len(doc.undo_stack.ops) {
		return 0, false
	}

	op := &doc.undo_stack.ops[doc.undo_stack.position]
	doc.undo_stack.position += 1

	switch op.kind {
	case .Insert:
		// Redo an insert = insert again
		piecetree_insert(&doc.tree, op.offset, op.text)
		cursor_offset = op.offset + op.length
	case .Delete:
		// Redo a delete = delete again
		piecetree_delete(&doc.tree, op.offset, op.length)
		cursor_offset = op.offset
	}

	doc.dirty = true
	ok = true
	return
}

// --- Document query API (delegates to PieceTree) ---

// Get the full document text.
document_get_text :: proc(doc: ^Document, allocator := context.allocator) -> string {
	return piecetree_get_text(&doc.tree, allocator)
}

// Get a slice of document text.
document_get_slice :: proc(doc: ^Document, offset: u32, length: u32, allocator := context.allocator) -> string {
	return piecetree_get_slice(&doc.tree, offset, length, allocator)
}

// Total byte length of the document.
document_length :: proc(doc: ^Document) -> u32 {
	return piecetree_length(&doc.tree)
}

// Total number of lines.
document_line_count :: proc(doc: ^Document) -> u32 {
	return piecetree_line_count(&doc.tree)
}

// Get the byte offset where a line starts (0-indexed).
document_line_start :: proc(doc: ^Document, line: u32) -> u32 {
	return piecetree_line_start(&doc.tree, line)
}

// Get the line number for a byte offset.
document_offset_to_line :: proc(doc: ^Document, offset: u32) -> u32 {
	return piecetree_offset_to_line(&doc.tree, offset)
}

// Get the content of a line (without trailing newline).
document_get_line :: proc(doc: ^Document, line: u32, allocator := context.allocator) -> string {
	return piecetree_get_line(&doc.tree, line, allocator)
}

// Mark the document as saved (clears dirty flag).
document_mark_saved :: proc(doc: ^Document) {
	doc.dirty = false
}

// Check if document has unsaved changes.
document_is_dirty :: proc(doc: ^Document) -> bool {
	return doc.dirty
}

// --- Internal undo helpers ---

@(private="file")
undo_truncate_redo :: proc(doc: ^Document) {
	// If we're not at the end, discard all operations after current position
	pos := doc.undo_stack.position
	for i := pos; i < len(doc.undo_stack.ops); i += 1 {
		op := &doc.undo_stack.ops[i]
		if len(op.text) > 0 {
			delete(op.text)
		}
	}
	resize(&doc.undo_stack.ops, pos)
}
