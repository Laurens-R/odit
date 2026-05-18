package document

import "core:bytes"
import "core:strings"

// A piece references a contiguous span in either the source or edit buffer.
Piece :: struct {
	buffer_kind:   DocumentBufferKind,
	start:         u32, // byte offset into the buffer
	length:        u32, // byte length of this piece
	newline_count: u32, // number of newline characters in this piece
}

// Red-black tree node color
Color :: enum {
	Red,
	Black,
}

// Each node stores a piece and caches subtree metadata for O(log n) lookups.
Node :: struct {
	piece:           Piece,
	color:           Color,
	left:            ^Node,
	right:           ^Node,
	parent:          ^Node,
	left_size:       u32, // total byte length in the left subtree
	left_newlines:   u32, // total newline count in the left subtree
	size_self:       u32, // piece.length cached
}

PieceTree :: struct {
	root:          ^Node,
	source_buffer: DocumentBuffer,
	edit_buffer:   DocumentBuffer,
	total_length:  u32,
	total_lines:   u32, // total newline count + 1
}

// --- Initialization / Destruction ---

piecetree_init :: proc(piece_tree: ^PieceTree, initial_text: string) {
	document_buffer_init(&piece_tree.source_buffer, .Source, initial_text)
	document_buffer_init(&piece_tree.edit_buffer, .Edit, "")
	piece_tree.root = nil
	piece_tree.total_length = 0
	piece_tree.total_lines = 1

	if len(initial_text) > 0 {
		newline_count := count_newlines_in_string(initial_text)
		initial_piece := Piece{
			buffer_kind   = .Source,
			start         = 0,
			length        = u32(len(initial_text)),
			newline_count = newline_count,
		}
		piece_tree.root = node_create(initial_piece, nil)
		piece_tree.root.color = .Black
		piece_tree.total_length = initial_piece.length
		piece_tree.total_lines = newline_count + 1
	}
}

piecetree_destroy :: proc(piece_tree: ^PieceTree) {
	node_destroy_recursive(piece_tree.root)
	piece_tree.root = nil
	document_buffer_destroy(&piece_tree.source_buffer)
	document_buffer_destroy(&piece_tree.edit_buffer)
	piece_tree.total_length = 0
	piece_tree.total_lines = 1
}

// --- Public API ---

// Insert text at a byte offset in the document.
piecetree_insert :: proc(piece_tree: ^PieceTree, offset: u32, text_to_insert: string) {
	if len(text_to_insert) == 0 {
		return
	}

	// Append to edit buffer
	edit_buffer_start := u32(bytes.buffer_length(&piece_tree.edit_buffer.buffer))
	document_buffer_append(&piece_tree.edit_buffer, text_to_insert)

	newline_count := count_newlines_in_string(text_to_insert)
	new_piece := Piece{
		buffer_kind   = .Edit,
		start         = edit_buffer_start,
		length        = u32(len(text_to_insert)),
		newline_count = newline_count,
	}

	if piece_tree.root == nil {
		piece_tree.root = node_create(new_piece, nil)
		piece_tree.root.color = .Black
		piece_tree.total_length = new_piece.length
		piece_tree.total_lines += newline_count
		return
	}

	// Clamp offset
	clamped_offset := min(offset, piece_tree.total_length)

	// Find the node and local offset where the insertion point falls
	target_node, local_offset := node_find_at_offset(piece_tree.root, clamped_offset)

	if local_offset == 0 {
		new_node := node_create(new_piece, nil)
		tree_insert_before(piece_tree, target_node, new_node)
	} else if local_offset == target_node.piece.length {
		new_node := node_create(new_piece, nil)
		tree_insert_after(piece_tree, target_node, new_node)
	} else {
		// Split the target piece
		left_newline_count := count_newlines_in_piece(piece_tree, target_node.piece.buffer_kind, target_node.piece.start, local_offset)
		right_newline_count := target_node.piece.newline_count - left_newline_count

		left_piece := Piece{
			buffer_kind   = target_node.piece.buffer_kind,
			start         = target_node.piece.start,
			length        = local_offset,
			newline_count = left_newline_count,
		}
		right_piece := Piece{
			buffer_kind   = target_node.piece.buffer_kind,
			start         = target_node.piece.start + local_offset,
			length        = target_node.piece.length - local_offset,
			newline_count = right_newline_count,
		}

		// Modify target to be the left portion
		target_node.piece = left_piece
		target_node.size_self = left_piece.length

		// Insert new piece after target
		new_node := node_create(new_piece, nil)
		tree_insert_after(piece_tree, target_node, new_node)

		// Insert right portion after new piece
		right_node := node_create(right_piece, nil)
		tree_insert_after(piece_tree, new_node, right_node)
	}

	piece_tree.total_length += new_piece.length
	piece_tree.total_lines += newline_count
}

// Delete `length_to_delete` bytes starting at `offset`.
piecetree_delete :: proc(piece_tree: ^PieceTree, offset: u32, length_to_delete: u32) {
	if length_to_delete == 0 || piece_tree.root == nil {
		return
	}

	clamped_offset := min(offset, piece_tree.total_length)
	actual_delete_length := min(length_to_delete, piece_tree.total_length - clamped_offset)
	remaining_to_delete := actual_delete_length
	deleted_newline_count: u32 = 0

	for remaining_to_delete > 0 && piece_tree.root != nil {
		target_node, local_offset := node_find_at_offset(piece_tree.root, clamped_offset)
		if target_node == nil {
			break
		}

		available_in_piece := target_node.piece.length - local_offset
		bytes_to_remove := min(remaining_to_delete, available_in_piece)

		if local_offset == 0 && bytes_to_remove == target_node.piece.length {
			// Remove entire node
			deleted_newline_count += target_node.piece.newline_count
			tree_delete_node(piece_tree, target_node)
		} else if local_offset == 0 {
			// Trim from the start
			removed_newline_count := count_newlines_in_piece(piece_tree, target_node.piece.buffer_kind, target_node.piece.start, bytes_to_remove)
			deleted_newline_count += removed_newline_count
			target_node.piece.start += bytes_to_remove
			target_node.piece.length -= bytes_to_remove
			target_node.piece.newline_count -= removed_newline_count
			target_node.size_self = target_node.piece.length
			node_update_metadata_up(target_node)
		} else if local_offset + bytes_to_remove == target_node.piece.length {
			// Trim from the end
			removed_newline_count := count_newlines_in_piece(piece_tree, target_node.piece.buffer_kind, target_node.piece.start + local_offset, bytes_to_remove)
			deleted_newline_count += removed_newline_count
			target_node.piece.length = local_offset
			target_node.piece.newline_count -= removed_newline_count
			target_node.size_self = target_node.piece.length
			node_update_metadata_up(target_node)
		} else {
			// Remove from the middle — split into two pieces
			removed_newline_count := count_newlines_in_piece(piece_tree, target_node.piece.buffer_kind, target_node.piece.start + local_offset, bytes_to_remove)
			deleted_newline_count += removed_newline_count

			right_piece_start := target_node.piece.start + local_offset + bytes_to_remove
			right_piece_length := target_node.piece.length - local_offset - bytes_to_remove
			right_piece_newline_count := count_newlines_in_piece(piece_tree, target_node.piece.buffer_kind, right_piece_start, right_piece_length)

			right_piece := Piece{
				buffer_kind   = target_node.piece.buffer_kind,
				start         = right_piece_start,
				length        = right_piece_length,
				newline_count = right_piece_newline_count,
			}

			left_newline_count := count_newlines_in_piece(piece_tree, target_node.piece.buffer_kind, target_node.piece.start, local_offset)
			target_node.piece.length = local_offset
			target_node.piece.newline_count = left_newline_count
			target_node.size_self = target_node.piece.length
			node_update_metadata_up(target_node)

			right_node := node_create(right_piece, nil)
			tree_insert_after(piece_tree, target_node, right_node)
		}

		remaining_to_delete -= bytes_to_remove
	}

	piece_tree.total_length -= actual_delete_length
	piece_tree.total_lines -= deleted_newline_count
}

// Get the full document text. Caller must delete the returned string's backing memory.
piecetree_get_text :: proc(piece_tree: ^PieceTree, allocator := context.allocator) -> string {
	if piece_tree.total_length == 0 {
		return ""
	}

	output_buffer: bytes.Buffer
	bytes.buffer_init_allocator(&output_buffer, 0, int(piece_tree.total_length), allocator)
	node_collect_inorder(piece_tree, piece_tree.root, &output_buffer)
	return bytes.buffer_to_string(&output_buffer)
}

// Get a substring of the document from `offset` with `length_to_get` bytes.
piecetree_get_slice :: proc(piece_tree: ^PieceTree, offset: u32, length: u32, allocator := context.allocator) -> string {
	if length == 0 || piece_tree.root == nil {
		return ""
	}

	clamped_offset := min(offset, piece_tree.total_length)
	actual_length_to_get := min(length, piece_tree.total_length - clamped_offset)

	output_buffer: bytes.Buffer
	bytes.buffer_init_allocator(&output_buffer, 0, int(actual_length_to_get), allocator)

	remaining_bytes := actual_length_to_get
	current_offset := clamped_offset

	for remaining_bytes > 0 {
		target_node, local_offset := node_find_at_offset(piece_tree.root, current_offset)
		if target_node == nil {
			break
		}

		available_in_piece := target_node.piece.length - local_offset
		bytes_to_read := min(remaining_bytes, available_in_piece)

		piece_text := piece_get_bytes(piece_tree, &target_node.piece)
		bytes.buffer_write(&output_buffer, piece_text[local_offset:local_offset + bytes_to_read])

		remaining_bytes -= bytes_to_read
		current_offset += bytes_to_read
	}

	return bytes.buffer_to_string(&output_buffer)
}

// Return the total length of the document in bytes.
piecetree_length :: proc(piece_tree: ^PieceTree) -> u32 {
	return piece_tree.total_length
}

// Return the total number of lines (newline_count + 1).
piecetree_line_count :: proc(piece_tree: ^PieceTree) -> u32 {
	return piece_tree.total_lines
}

// Get the byte offset of the start of a given line (0-indexed).
piecetree_line_start :: proc(piece_tree: ^PieceTree, line_index: u32) -> u32 {
	if line_index == 0 {
		return 0
	}

	// We need to find the (line)th newline's position + 1
	// Walk the tree using left_newlines to find it in O(log n)
	newlines_to_skip := line_index
	if newlines_to_skip >= piece_tree.total_lines {
		return piece_tree.total_length
	}

	current_node := piece_tree.root
	accumulated_offset: u32 = 0

	for current_node != nil {
		if newlines_to_skip <= current_node.left_newlines {
			current_node = current_node.left
		} else {
			// Skip past left subtree and potentially this node
			newlines_to_skip -= current_node.left_newlines
			accumulated_offset += current_node.left_size

			if newlines_to_skip <= current_node.piece.newline_count {
				// The target newline is within this piece
				piece_data := piece_get_bytes(piece_tree, &current_node.piece)
				newlines_found: u32 = 0
				for byte_index: u32 = 0; byte_index < current_node.piece.length; byte_index += 1 {
					if piece_data[byte_index] == '\n' {
						newlines_found += 1
						if newlines_found == newlines_to_skip {
							return accumulated_offset + byte_index + 1
						}
					}
				}
				return accumulated_offset + current_node.piece.length
			}

			newlines_to_skip -= current_node.piece.newline_count
			accumulated_offset += current_node.size_self
			current_node = current_node.right
		}
	}

	return accumulated_offset
}

// Get the line number (0-indexed) for a given byte offset.
piecetree_offset_to_line :: proc(piece_tree: ^PieceTree, offset: u32) -> u32 {
	if piece_tree.root == nil || offset == 0 {
		return 0
	}

	clamped_offset := min(offset, piece_tree.total_length)
	current_line: u32 = 0
	current_node := piece_tree.root
	remaining_offset := clamped_offset

	for current_node != nil {
		if remaining_offset <= current_node.left_size {
			current_node = current_node.left
		} else {
			current_line += current_node.left_newlines
			remaining_offset -= current_node.left_size

			if remaining_offset <= current_node.size_self {
				// Count newlines within this piece up to `remaining_offset`
				piece_data := piece_get_bytes(piece_tree, &current_node.piece)
				for byte_index: u32 = 0; byte_index < remaining_offset; byte_index += 1 {
					if piece_data[byte_index] == '\n' {
						current_line += 1
					}
				}
				return current_line
			}

			current_line += current_node.piece.newline_count
			remaining_offset -= current_node.size_self
			current_node = current_node.right
		}
	}

	return current_line
}

// Get the text content of a specific line (0-indexed), without the trailing newline.
piecetree_get_line :: proc(piece_tree: ^PieceTree, line_index: u32, allocator := context.allocator) -> string {
	line_start_offset := piecetree_line_start(piece_tree, line_index)
	line_end_offset: u32
	if line_index + 1 >= piece_tree.total_lines {
		line_end_offset = piece_tree.total_length
	} else {
		line_end_offset = piecetree_line_start(piece_tree, line_index + 1)
		// Strip trailing newline
		if line_end_offset > line_start_offset {
			// Check if previous char is \n
			last_byte_slice := piecetree_get_slice(piece_tree, line_end_offset - 1, 1, allocator)
			if len(last_byte_slice) > 0 && last_byte_slice[0] == '\n' {
				line_end_offset -= 1
				// Also strip \r if \r\n
				if line_end_offset > line_start_offset {
					second_to_last_byte_slice := piecetree_get_slice(piece_tree, line_end_offset - 1, 1, allocator)
					if len(second_to_last_byte_slice) > 0 && second_to_last_byte_slice[0] == '\r' {
						line_end_offset -= 1
					}
				}
			}
		}
	}

	if line_end_offset <= line_start_offset {
		return ""
	}
	return piecetree_get_slice(piece_tree, line_start_offset, line_end_offset - line_start_offset, allocator)
}

// --- Internal: node helpers ---

node_create :: proc(piece: Piece, parent_node: ^Node) -> ^Node {
	new_node := new(Node)
	new_node.piece = piece
	new_node.color = .Red
	new_node.left = nil
	new_node.right = nil
	new_node.parent = parent_node
	new_node.left_size = 0
	new_node.left_newlines = 0
	new_node.size_self = piece.length
	return new_node
}

node_destroy_recursive :: proc(node_to_destroy: ^Node) {
	if node_to_destroy == nil {
		return
	}
	node_destroy_recursive(node_to_destroy.left)
	node_destroy_recursive(node_to_destroy.right)
	free(node_to_destroy)
}

// Find the node containing the given document offset, and return the local offset within that node.
node_find_at_offset :: proc(root: ^Node, offset: u32) -> (^Node, u32) {
	current_node := root
	remaining_offset := offset

	for current_node != nil {
		if remaining_offset < current_node.left_size {
			current_node = current_node.left
		} else if remaining_offset < current_node.left_size + current_node.size_self {
			return current_node, remaining_offset - current_node.left_size
		} else {
			remaining_offset -= current_node.left_size + current_node.size_self
			current_node = current_node.right
		}
	}

	// Offset at the very end — return the rightmost node
	current_node = root
	for current_node.right != nil {
		current_node = current_node.right
	}
	return current_node, current_node.size_self
}

// Collect text from all pieces in order.
node_collect_inorder :: proc(piece_tree: ^PieceTree, node: ^Node, output_buffer: ^bytes.Buffer) {
	if node == nil {
		return
	}
	node_collect_inorder(piece_tree, node.left, output_buffer)
	piece_text := piece_get_bytes(piece_tree, &node.piece)
	bytes.buffer_write(output_buffer, piece_text)
	node_collect_inorder(piece_tree, node.right, output_buffer)
}

// Get the byte slice for a piece.
piece_get_bytes :: proc(piece_tree: ^PieceTree, piece: ^Piece) -> []u8 {
	source_or_edit_buffer := piece.buffer_kind == .Source ? &piece_tree.source_buffer : &piece_tree.edit_buffer
	all_buffer_bytes := bytes.buffer_to_bytes(&source_or_edit_buffer.buffer)
	return all_buffer_bytes[piece.start:piece.start + piece.length]
}

// Count newlines in a portion of a buffer.
count_newlines_in_piece :: proc(piece_tree: ^PieceTree, kind: DocumentBufferKind, start: u32, length: u32) -> u32 {
	source_or_edit_buffer := kind == .Source ? &piece_tree.source_buffer : &piece_tree.edit_buffer
	all_buffer_bytes := bytes.buffer_to_bytes(&source_or_edit_buffer.buffer)
	piece_bytes := all_buffer_bytes[start:start + length]
	newline_count: u32 = 0
	for byte_value in piece_bytes {
		if byte_value == '\n' {
			newline_count += 1
		}
	}
	return newline_count
}

count_newlines_in_string :: proc(text: string) -> u32 {
	newline_count: u32 = 0
	for character_value in text {
		if character_value == '\n' {
			newline_count += 1
		}
	}
	return newline_count
}

// --- Internal: tree insertion ---

tree_insert_before :: proc(piece_tree: ^PieceTree, target_node: ^Node, new_node: ^Node) {
	if target_node.left == nil {
		target_node.left = new_node
		new_node.parent = target_node
	} else {
		predecessor_node := target_node.left
		for predecessor_node.right != nil {
			predecessor_node = predecessor_node.right
		}
		predecessor_node.right = new_node
		new_node.parent = predecessor_node
	}
	node_update_metadata_up(new_node)
	tree_fix_insert(piece_tree, new_node)
}

tree_insert_after :: proc(piece_tree: ^PieceTree, target_node: ^Node, new_node: ^Node) {
	if target_node.right == nil {
		target_node.right = new_node
		new_node.parent = target_node
	} else {
		successor_node := target_node.right
		for successor_node.left != nil {
			successor_node = successor_node.left
		}
		successor_node.left = new_node
		new_node.parent = successor_node
	}
	node_update_metadata_up(new_node)
	tree_fix_insert(piece_tree, new_node)
}

// --- Internal: Red-Black tree balancing ---

tree_fix_insert :: proc(piece_tree: ^PieceTree, node: ^Node) {
	current_node := node
	for current_node != piece_tree.root && current_node.parent != nil && current_node.parent.color == .Red {
		parent_node := current_node.parent
		grandparent_node := parent_node.parent
		if grandparent_node == nil {
			break
		}

		if parent_node == grandparent_node.left {
			uncle_node := grandparent_node.right
			if uncle_node != nil && uncle_node.color == .Red {
				parent_node.color = .Black
				uncle_node.color = .Black
				grandparent_node.color = .Red
				current_node = grandparent_node
			} else {
				if current_node == parent_node.right {
					current_node = parent_node
					rotate_left(piece_tree, current_node)
					parent_node = current_node.parent
					grandparent_node = parent_node.parent if parent_node != nil else nil
					if grandparent_node == nil { break }
				}
				parent_node.color = .Black
				grandparent_node.color = .Red
				rotate_right(piece_tree, grandparent_node)
			}
		} else {
			uncle_node := grandparent_node.left
			if uncle_node != nil && uncle_node.color == .Red {
				parent_node.color = .Black
				uncle_node.color = .Black
				grandparent_node.color = .Red
				current_node = grandparent_node
			} else {
				if current_node == parent_node.left {
					current_node = parent_node
					rotate_right(piece_tree, current_node)
					parent_node = current_node.parent
					grandparent_node = parent_node.parent if parent_node != nil else nil
					if grandparent_node == nil { break }
				}
				parent_node.color = .Black
				grandparent_node.color = .Red
				rotate_left(piece_tree, grandparent_node)
			}
		}
	}
	piece_tree.root.color = .Black
}

// --- Internal: Red-Black tree deletion ---

tree_delete_node :: proc(piece_tree: ^PieceTree, node_to_delete: ^Node) {
	target_node := node_to_delete
	original_color := target_node.color
	fix_node: ^Node = nil
	fix_parent: ^Node = nil

	if node_to_delete.left == nil {
		fix_node = node_to_delete.right
		fix_parent = node_to_delete.parent
		transplant(piece_tree, node_to_delete, node_to_delete.right)
	} else if node_to_delete.right == nil {
		fix_node = node_to_delete.left
		fix_parent = node_to_delete.parent
		transplant(piece_tree, node_to_delete, node_to_delete.left)
	} else {
		target_node = node_to_delete.right
		for target_node.left != nil {
			target_node = target_node.left
		}
		original_color = target_node.color
		fix_node = target_node.right
		fix_parent = target_node

		if target_node.parent == node_to_delete {
			if fix_node != nil {
				fix_node.parent = target_node
			}
			fix_parent = target_node
		} else {
			fix_parent = target_node.parent
			transplant(piece_tree, target_node, target_node.right)
			target_node.right = node_to_delete.right
			if target_node.right != nil {
				target_node.right.parent = target_node
			}
		}
		transplant(piece_tree, node_to_delete, target_node)
		target_node.left = node_to_delete.left
		if target_node.left != nil {
			target_node.left.parent = target_node
		}
		target_node.color = node_to_delete.color
		target_node.left_size = subtree_size(target_node.left)
		target_node.left_newlines = subtree_newlines(target_node.left)
	}

	if fix_parent != nil {
		recompute_metadata(fix_parent)
		node_update_metadata_up(fix_parent)
	}

	if original_color == .Black {
		tree_fix_delete(piece_tree, fix_node, fix_parent)
	}

	free(node_to_delete)
}

transplant :: proc(piece_tree: ^PieceTree, node_to_replace: ^Node, replacement_node: ^Node) {
	if node_to_replace.parent == nil {
		piece_tree.root = replacement_node
	} else if node_to_replace == node_to_replace.parent.left {
		node_to_replace.parent.left = replacement_node
	} else {
		node_to_replace.parent.right = replacement_node
	}
	if replacement_node != nil {
		replacement_node.parent = node_to_replace.parent
	}
}

tree_fix_delete :: proc(piece_tree: ^PieceTree, node: ^Node, parent_node: ^Node) {
	current_node := node
	current_parent := parent_node

	for current_node != piece_tree.root && (current_node == nil || current_node.color == .Black) {
		if current_parent == nil { break }

		if current_node == current_parent.left {
			sibling_node := current_parent.right
			if sibling_node != nil && sibling_node.color == .Red {
				sibling_node.color = .Black
				current_parent.color = .Red
				rotate_left(piece_tree, current_parent)
				sibling_node = current_parent.right
			}
			if sibling_node == nil { break }
			left_is_black := sibling_node.left == nil || sibling_node.left.color == .Black
			right_is_black := sibling_node.right == nil || sibling_node.right.color == .Black
			if left_is_black && right_is_black {
				sibling_node.color = .Red
				current_node = current_parent
				current_parent = current_node.parent
			} else {
				if right_is_black {
					if sibling_node.left != nil { sibling_node.left.color = .Black }
					sibling_node.color = .Red
					rotate_right(piece_tree, sibling_node)
					sibling_node = current_parent.right
				}
				if sibling_node != nil {
					sibling_node.color = current_parent.color
					if sibling_node.right != nil { sibling_node.right.color = .Black }
				}
				current_parent.color = .Black
				rotate_left(piece_tree, current_parent)
				current_node = piece_tree.root
				current_parent = nil
			}
		} else {
			sibling_node := current_parent.left
			if sibling_node != nil && sibling_node.color == .Red {
				sibling_node.color = .Black
				current_parent.color = .Red
				rotate_right(piece_tree, current_parent)
				sibling_node = current_parent.left
			}
			if sibling_node == nil { break }
			left_is_black := sibling_node.left == nil || sibling_node.left.color == .Black
			right_is_black := sibling_node.right == nil || sibling_node.right.color == .Black
			if left_is_black && right_is_black {
				sibling_node.color = .Red
				current_node = current_parent
				current_parent = current_node.parent
			} else {
				if left_is_black {
					if sibling_node.right != nil { sibling_node.right.color = .Black }
					sibling_node.color = .Red
					rotate_left(piece_tree, sibling_node)
					sibling_node = current_parent.left
				}
				if sibling_node != nil {
					sibling_node.color = current_parent.color
					if sibling_node.left != nil { sibling_node.left.color = .Black }
				}
				current_parent.color = .Black
				rotate_right(piece_tree, current_parent)
				current_node = piece_tree.root
				current_parent = nil
			}
		}
	}
	if current_node != nil {
		current_node.color = .Black
	}
}

// --- Internal: rotations ---

rotate_left :: proc(piece_tree: ^PieceTree, pivot_node: ^Node) {
	right_child := pivot_node.right
	if right_child == nil { return }

	pivot_node.right = right_child.left
	if right_child.left != nil {
		right_child.left.parent = pivot_node
	}
	right_child.parent = pivot_node.parent
	if pivot_node.parent == nil {
		piece_tree.root = right_child
	} else if pivot_node == pivot_node.parent.left {
		pivot_node.parent.left = right_child
	} else {
		pivot_node.parent.right = right_child
	}
	right_child.left = pivot_node
	pivot_node.parent = right_child

	// Update metadata
	right_child.left_size = pivot_node.left_size + pivot_node.size_self + subtree_size(pivot_node.right)
	right_child.left_newlines = pivot_node.left_newlines + pivot_node.piece.newline_count + subtree_newlines(pivot_node.right)
}

rotate_right :: proc(piece_tree: ^PieceTree, pivot_node: ^Node) {
	left_child := pivot_node.left
	if left_child == nil { return }

	pivot_node.left = left_child.right
	if left_child.right != nil {
		left_child.right.parent = pivot_node
	}
	left_child.parent = pivot_node.parent
	if pivot_node.parent == nil {
		piece_tree.root = left_child
	} else if pivot_node == pivot_node.parent.right {
		pivot_node.parent.right = left_child
	} else {
		pivot_node.parent.left = left_child
	}
	left_child.right = pivot_node
	pivot_node.parent = left_child

	// Update pivot_node's left metadata
	pivot_node.left_size = subtree_size(pivot_node.left)
	pivot_node.left_newlines = subtree_newlines(pivot_node.left)
}

// --- Internal: size/newline helpers ---

subtree_size :: proc(subtree_root: ^Node) -> u32 {
	if subtree_root == nil {
		return 0
	}
	return subtree_root.left_size + subtree_root.size_self + subtree_size(subtree_root.right)
}

subtree_newlines :: proc(subtree_root: ^Node) -> u32 {
	if subtree_root == nil {
		return 0
	}
	return subtree_root.left_newlines + subtree_root.piece.newline_count + subtree_newlines(subtree_root.right)
}

recompute_metadata :: proc(node: ^Node) {
	if node == nil { return }
	node.left_size = subtree_size(node.left)
	node.left_newlines = subtree_newlines(node.left)
}

node_update_metadata_up :: proc(starting_node: ^Node) {
	current_node := starting_node
	for current_node != nil {
		recompute_metadata(current_node)
		current_node = current_node.parent
	}
}
