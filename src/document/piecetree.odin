package odin

import "core:bytes"
import "core:strings"

// A piece references a contiguous span in either the source or edit buffer.
Piece :: struct {
	buffer_kind: DocumentBufferKind,
	start:       u32, // byte offset into the buffer
	length:      u32, // byte length of this piece
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

piecetree_init :: proc(tree: ^PieceTree, initial := "") {
	document_buffer_init(&tree.source_buffer, .Source, initial)
	document_buffer_init(&tree.edit_buffer, .Edit)
	tree.root = nil
	tree.total_length = 0
	tree.total_lines = 1

	if len(initial) > 0 {
		nl_count := count_newlines_in_string(initial)
		piece := Piece{
			buffer_kind   = .Source,
			start         = 0,
			length        = u32(len(initial)),
			newline_count = nl_count,
		}
		tree.root = node_create(piece, nil)
		tree.root.color = .Black
		tree.total_length = piece.length
		tree.total_lines = nl_count + 1
	}
}

piecetree_destroy :: proc(tree: ^PieceTree) {
	node_destroy_recursive(tree.root)
	tree.root = nil
	document_buffer_destroy(&tree.source_buffer)
	document_buffer_destroy(&tree.edit_buffer)
	tree.total_length = 0
	tree.total_lines = 1
}

// --- Public API ---

// Insert text at a byte offset in the document.
piecetree_insert :: proc(tree: ^PieceTree, offset: u32, text: string) {
	if len(text) == 0 {
		return
	}

	// Append to edit buffer
	edit_start := u32(bytes.buffer_length(&tree.edit_buffer.buffer))
	document_buffer_append(&tree.edit_buffer, text)

	nl_count := count_newlines_in_string(text)
	new_piece := Piece{
		buffer_kind   = .Edit,
		start         = edit_start,
		length        = u32(len(text)),
		newline_count = nl_count,
	}

	if tree.root == nil {
		tree.root = node_create(new_piece, nil)
		tree.root.color = .Black
		tree.total_length = new_piece.length
		tree.total_lines += nl_count
		return
	}

	// Clamp offset
	off := min(offset, tree.total_length)

	// Find the node and local offset where the insertion point falls
	target, local_off := node_find_at(tree.root, off)

	if local_off == 0 {
		new_node := node_create(new_piece, nil)
		tree_insert_before(tree, target, new_node)
	} else if local_off == target.piece.length {
		new_node := node_create(new_piece, nil)
		tree_insert_after(tree, target, new_node)
	} else {
		// Split the target piece
		left_nl := count_newlines_in_piece(tree, target.piece.buffer_kind, target.piece.start, local_off)
		right_nl := target.piece.newline_count - left_nl

		left_piece := Piece{
			buffer_kind   = target.piece.buffer_kind,
			start         = target.piece.start,
			length        = local_off,
			newline_count = left_nl,
		}
		right_piece := Piece{
			buffer_kind   = target.piece.buffer_kind,
			start         = target.piece.start + local_off,
			length        = target.piece.length - local_off,
			newline_count = right_nl,
		}

		// Modify target to be the left portion
		target.piece = left_piece
		target.size_self = left_piece.length

		// Insert new piece after target
		new_node := node_create(new_piece, nil)
		tree_insert_after(tree, target, new_node)

		// Insert right portion after new piece
		right_node := node_create(right_piece, nil)
		tree_insert_after(tree, new_node, right_node)
	}

	tree.total_length += new_piece.length
	tree.total_lines += nl_count
}

// Delete `length` bytes starting at `offset`.
piecetree_delete :: proc(tree: ^PieceTree, offset: u32, length: u32) {
	if length == 0 || tree.root == nil {
		return
	}

	off := min(offset, tree.total_length)
	len_to_delete := min(length, tree.total_length - off)
	remaining := len_to_delete
	deleted_newlines: u32 = 0

	for remaining > 0 && tree.root != nil {
		target, local_off := node_find_at(tree.root, off)
		if target == nil {
			break
		}

		available := target.piece.length - local_off
		to_remove := min(remaining, available)

		if local_off == 0 && to_remove == target.piece.length {
			// Remove entire node
			deleted_newlines += target.piece.newline_count
			tree_delete_node(tree, target)
		} else if local_off == 0 {
			// Trim from the start
			removed_nl := count_newlines_in_piece(tree, target.piece.buffer_kind, target.piece.start, to_remove)
			deleted_newlines += removed_nl
			target.piece.start += to_remove
			target.piece.length -= to_remove
			target.piece.newline_count -= removed_nl
			target.size_self = target.piece.length
			node_update_metadata_up(target)
		} else if local_off + to_remove == target.piece.length {
			// Trim from the end
			removed_nl := count_newlines_in_piece(tree, target.piece.buffer_kind, target.piece.start + local_off, to_remove)
			deleted_newlines += removed_nl
			target.piece.length = local_off
			target.piece.newline_count -= removed_nl
			target.size_self = target.piece.length
			node_update_metadata_up(target)
		} else {
			// Remove from the middle — split into two pieces
			removed_nl := count_newlines_in_piece(tree, target.piece.buffer_kind, target.piece.start + local_off, to_remove)
			deleted_newlines += removed_nl

			right_start := target.piece.start + local_off + to_remove
			right_len := target.piece.length - local_off - to_remove
			right_nl := count_newlines_in_piece(tree, target.piece.buffer_kind, right_start, right_len)

			right_piece := Piece{
				buffer_kind   = target.piece.buffer_kind,
				start         = right_start,
				length        = right_len,
				newline_count = right_nl,
			}

			left_nl := count_newlines_in_piece(tree, target.piece.buffer_kind, target.piece.start, local_off)
			target.piece.length = local_off
			target.piece.newline_count = left_nl
			target.size_self = target.piece.length
			node_update_metadata_up(target)

			right_node := node_create(right_piece, nil)
			tree_insert_after(tree, target, right_node)
		}

		remaining -= to_remove
	}

	tree.total_length -= len_to_delete
	tree.total_lines -= deleted_newlines
}

// Get the full document text. Caller must delete the returned string's backing memory.
piecetree_get_text :: proc(tree: ^PieceTree, allocator := context.allocator) -> string {
	if tree.total_length == 0 {
		return ""
	}

	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, int(tree.total_length), allocator)
	node_collect_inorder(tree, tree.root, &buf)
	return bytes.buffer_to_string(&buf)
}

// Get a substring of the document from `offset` with `length` bytes.
piecetree_get_slice :: proc(tree: ^PieceTree, offset: u32, length: u32, allocator := context.allocator) -> string {
	if length == 0 || tree.root == nil {
		return ""
	}

	off := min(offset, tree.total_length)
	len_to_get := min(length, tree.total_length - off)

	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, int(len_to_get), allocator)

	remaining := len_to_get
	cur_off := off

	for remaining > 0 {
		target, local_off := node_find_at(tree.root, cur_off)
		if target == nil {
			break
		}

		available := target.piece.length - local_off
		to_read := min(remaining, available)

		piece_text := piece_get_bytes(tree, &target.piece)
		bytes.buffer_write(&buf, piece_text[local_off:local_off + to_read])

		remaining -= to_read
		cur_off += to_read
	}

	return bytes.buffer_to_string(&buf)
}

// Return the total length of the document in bytes.
piecetree_length :: proc(tree: ^PieceTree) -> u32 {
	return tree.total_length
}

// Return the total number of lines (newline_count + 1).
piecetree_line_count :: proc(tree: ^PieceTree) -> u32 {
	return tree.total_lines
}

// Get the byte offset of the start of a given line (0-indexed).
piecetree_line_start :: proc(tree: ^PieceTree, line: u32) -> u32 {
	if line == 0 {
		return 0
	}

	// We need to find the (line)th newline's position + 1
	// Walk the tree using left_newlines to find it in O(log n)
	newlines_to_skip := line
	if newlines_to_skip >= tree.total_lines {
		return tree.total_length
	}

	node := tree.root
	offset: u32 = 0

	for node != nil {
		if newlines_to_skip <= node.left_newlines {
			node = node.left
		} else {
			// Skip past left subtree and potentially this node
			newlines_to_skip -= node.left_newlines
			offset += node.left_size

			if newlines_to_skip <= node.piece.newline_count {
				// The target newline is within this piece
				piece_data := piece_get_bytes(tree, &node.piece)
				nl_found: u32 = 0
				for i: u32 = 0; i < node.piece.length; i += 1 {
					if piece_data[i] == '\n' {
						nl_found += 1
						if nl_found == newlines_to_skip {
							return offset + i + 1
						}
					}
				}
				return offset + node.piece.length
			}

			newlines_to_skip -= node.piece.newline_count
			offset += node.size_self
			node = node.right
		}
	}

	return offset
}

// Get the line number (0-indexed) for a given byte offset.
piecetree_offset_to_line :: proc(tree: ^PieceTree, offset: u32) -> u32 {
	if tree.root == nil || offset == 0 {
		return 0
	}

	off := min(offset, tree.total_length)
	line: u32 = 0
	node := tree.root
	remaining := off

	for node != nil {
		if remaining <= node.left_size {
			node = node.left
		} else {
			line += node.left_newlines
			remaining -= node.left_size

			if remaining <= node.size_self {
				// Count newlines within this piece up to `remaining`
				piece_data := piece_get_bytes(tree, &node.piece)
				for i: u32 = 0; i < remaining; i += 1 {
					if piece_data[i] == '\n' {
						line += 1
					}
				}
				return line
			}

			line += node.piece.newline_count
			remaining -= node.size_self
			node = node.right
		}
	}

	return line
}

// Get the text content of a specific line (0-indexed), without the trailing newline.
piecetree_get_line :: proc(tree: ^PieceTree, line: u32, allocator := context.allocator) -> string {
	start := piecetree_line_start(tree, line)
	end: u32
	if line + 1 >= tree.total_lines {
		end = tree.total_length
	} else {
		end = piecetree_line_start(tree, line + 1)
		// Strip trailing newline
		if end > start {
			// Check if previous char is \n
			slice := piecetree_get_slice(tree, end - 1, 1, allocator)
			if len(slice) > 0 && slice[0] == '\n' {
				end -= 1
				// Also strip \r if \r\n
				if end > start {
					slice2 := piecetree_get_slice(tree, end - 1, 1, allocator)
					if len(slice2) > 0 && slice2[0] == '\r' {
						end -= 1
					}
				}
			}
		}
	}

	if end <= start {
		return ""
	}
	return piecetree_get_slice(tree, start, end - start, allocator)
}

// --- Internal: node helpers ---

node_create :: proc(piece: Piece, parent: ^Node) -> ^Node {
	node := new(Node)
	node.piece = piece
	node.color = .Red
	node.left = nil
	node.right = nil
	node.parent = parent
	node.left_size = 0
	node.left_newlines = 0
	node.size_self = piece.length
	return node
}

node_destroy_recursive :: proc(node: ^Node) {
	if node == nil {
		return
	}
	node_destroy_recursive(node.left)
	node_destroy_recursive(node.right)
	free(node)
}

// Find the node containing the given document offset, and return the local offset within that node.
node_find_at :: proc(root: ^Node, offset: u32) -> (^Node, u32) {
	node := root
	off := offset

	for node != nil {
		if off < node.left_size {
			node = node.left
		} else if off < node.left_size + node.size_self {
			return node, off - node.left_size
		} else {
			off -= node.left_size + node.size_self
			node = node.right
		}
	}

	// Offset at the very end — return the rightmost node
	node = root
	for node.right != nil {
		node = node.right
	}
	return node, node.size_self
}

// Collect text from all pieces in order.
node_collect_inorder :: proc(tree: ^PieceTree, node: ^Node, buf: ^bytes.Buffer) {
	if node == nil {
		return
	}
	node_collect_inorder(tree, node.left, buf)
	piece_text := piece_get_bytes(tree, &node.piece)
	bytes.buffer_write(buf, piece_text)
	node_collect_inorder(tree, node.right, buf)
}

// Get the byte slice for a piece.
piece_get_bytes :: proc(tree: ^PieceTree, piece: ^Piece) -> []u8 {
	buffer := piece.buffer_kind == .Source ? &tree.source_buffer : &tree.edit_buffer
	all := bytes.buffer_to_bytes(&buffer.buffer)
	return all[piece.start:piece.start + piece.length]
}

// Count newlines in a portion of a buffer.
count_newlines_in_piece :: proc(tree: ^PieceTree, kind: DocumentBufferKind, start: u32, length: u32) -> u32 {
	buffer := kind == .Source ? &tree.source_buffer : &tree.edit_buffer
	all := bytes.buffer_to_bytes(&buffer.buffer)
	slice := all[start:start + length]
	count: u32 = 0
	for b in slice {
		if b == '\n' {
			count += 1
		}
	}
	return count
}

count_newlines_in_string :: proc(s: string) -> u32 {
	count: u32 = 0
	for c in s {
		if c == '\n' {
			count += 1
		}
	}
	return count
}

// --- Internal: tree insertion ---

tree_insert_before :: proc(tree: ^PieceTree, target: ^Node, new_node: ^Node) {
	if target.left == nil {
		target.left = new_node
		new_node.parent = target
	} else {
		pred := target.left
		for pred.right != nil {
			pred = pred.right
		}
		pred.right = new_node
		new_node.parent = pred
	}
	node_update_metadata_up(new_node)
	tree_fix_insert(tree, new_node)
}

tree_insert_after :: proc(tree: ^PieceTree, target: ^Node, new_node: ^Node) {
	if target.right == nil {
		target.right = new_node
		new_node.parent = target
	} else {
		succ := target.right
		for succ.left != nil {
			succ = succ.left
		}
		succ.left = new_node
		new_node.parent = succ
	}
	node_update_metadata_up(new_node)
	tree_fix_insert(tree, new_node)
}

// --- Internal: Red-Black tree balancing ---

tree_fix_insert :: proc(tree: ^PieceTree, node: ^Node) {
	n := node
	for n != tree.root && n.parent != nil && n.parent.color == .Red {
		parent := n.parent
		grandparent := parent.parent
		if grandparent == nil {
			break
		}

		if parent == grandparent.left {
			uncle := grandparent.right
			if uncle != nil && uncle.color == .Red {
				parent.color = .Black
				uncle.color = .Black
				grandparent.color = .Red
				n = grandparent
			} else {
				if n == parent.right {
					n = parent
					rotate_left(tree, n)
					parent = n.parent
					grandparent = parent.parent if parent != nil else nil
					if grandparent == nil { break }
				}
				parent.color = .Black
				grandparent.color = .Red
				rotate_right(tree, grandparent)
			}
		} else {
			uncle := grandparent.left
			if uncle != nil && uncle.color == .Red {
				parent.color = .Black
				uncle.color = .Black
				grandparent.color = .Red
				n = grandparent
			} else {
				if n == parent.left {
					n = parent
					rotate_right(tree, n)
					parent = n.parent
					grandparent = parent.parent if parent != nil else nil
					if grandparent == nil { break }
				}
				parent.color = .Black
				grandparent.color = .Red
				rotate_left(tree, grandparent)
			}
		}
	}
	tree.root.color = .Black
}

// --- Internal: Red-Black tree deletion ---

tree_delete_node :: proc(tree: ^PieceTree, node: ^Node) {
	target := node
	original_color := target.color
	fix_node: ^Node = nil
	fix_parent: ^Node = nil

	if node.left == nil {
		fix_node = node.right
		fix_parent = node.parent
		transplant(tree, node, node.right)
	} else if node.right == nil {
		fix_node = node.left
		fix_parent = node.parent
		transplant(tree, node, node.left)
	} else {
		target = node.right
		for target.left != nil {
			target = target.left
		}
		original_color = target.color
		fix_node = target.right
		fix_parent = target

		if target.parent == node {
			if fix_node != nil {
				fix_node.parent = target
			}
			fix_parent = target
		} else {
			fix_parent = target.parent
			transplant(tree, target, target.right)
			target.right = node.right
			if target.right != nil {
				target.right.parent = target
			}
		}
		transplant(tree, node, target)
		target.left = node.left
		if target.left != nil {
			target.left.parent = target
		}
		target.color = node.color
		target.left_size = subtree_size(target.left)
		target.left_newlines = subtree_newlines(target.left)
	}

	if fix_parent != nil {
		recompute_metadata(fix_parent)
		node_update_metadata_up(fix_parent)
	}

	if original_color == .Black {
		tree_fix_delete(tree, fix_node, fix_parent)
	}

	free(node)
}

transplant :: proc(tree: ^PieceTree, u: ^Node, v: ^Node) {
	if u.parent == nil {
		tree.root = v
	} else if u == u.parent.left {
		u.parent.left = v
	} else {
		u.parent.right = v
	}
	if v != nil {
		v.parent = u.parent
	}
}

tree_fix_delete :: proc(tree: ^PieceTree, node: ^Node, parent: ^Node) {
	n := node
	p := parent

	for n != tree.root && (n == nil || n.color == .Black) {
		if p == nil { break }

		if n == p.left {
			sibling := p.right
			if sibling != nil && sibling.color == .Red {
				sibling.color = .Black
				p.color = .Red
				rotate_left(tree, p)
				sibling = p.right
			}
			if sibling == nil { break }
			left_black := sibling.left == nil || sibling.left.color == .Black
			right_black := sibling.right == nil || sibling.right.color == .Black
			if left_black && right_black {
				sibling.color = .Red
				n = p
				p = n.parent
			} else {
				if right_black {
					if sibling.left != nil { sibling.left.color = .Black }
					sibling.color = .Red
					rotate_right(tree, sibling)
					sibling = p.right
				}
				if sibling != nil {
					sibling.color = p.color
					if sibling.right != nil { sibling.right.color = .Black }
				}
				p.color = .Black
				rotate_left(tree, p)
				n = tree.root
				p = nil
			}
		} else {
			sibling := p.left
			if sibling != nil && sibling.color == .Red {
				sibling.color = .Black
				p.color = .Red
				rotate_right(tree, p)
				sibling = p.left
			}
			if sibling == nil { break }
			left_black := sibling.left == nil || sibling.left.color == .Black
			right_black := sibling.right == nil || sibling.right.color == .Black
			if left_black && right_black {
				sibling.color = .Red
				n = p
				p = n.parent
			} else {
				if left_black {
					if sibling.right != nil { sibling.right.color = .Black }
					sibling.color = .Red
					rotate_left(tree, sibling)
					sibling = p.left
				}
				if sibling != nil {
					sibling.color = p.color
					if sibling.left != nil { sibling.left.color = .Black }
				}
				p.color = .Black
				rotate_right(tree, p)
				n = tree.root
				p = nil
			}
		}
	}
	if n != nil {
		n.color = .Black
	}
}

// --- Internal: rotations ---

rotate_left :: proc(tree: ^PieceTree, x: ^Node) {
	y := x.right
	if y == nil { return }

	x.right = y.left
	if y.left != nil {
		y.left.parent = x
	}
	y.parent = x.parent
	if x.parent == nil {
		tree.root = y
	} else if x == x.parent.left {
		x.parent.left = y
	} else {
		x.parent.right = y
	}
	y.left = x
	x.parent = y

	// Update metadata
	y.left_size = x.left_size + x.size_self + subtree_size(x.right)
	y.left_newlines = x.left_newlines + x.piece.newline_count + subtree_newlines(x.right)
}

rotate_right :: proc(tree: ^PieceTree, x: ^Node) {
	y := x.left
	if y == nil { return }

	x.left = y.right
	if y.right != nil {
		y.right.parent = x
	}
	y.parent = x.parent
	if x.parent == nil {
		tree.root = y
	} else if x == x.parent.right {
		x.parent.right = y
	} else {
		x.parent.left = y
	}
	y.right = x
	x.parent = y

	// Update x's left metadata
	x.left_size = subtree_size(x.left)
	x.left_newlines = subtree_newlines(x.left)
}

// --- Internal: size/newline helpers ---

subtree_size :: proc(node: ^Node) -> u32 {
	if node == nil {
		return 0
	}
	return node.left_size + node.size_self + subtree_size(node.right)
}

subtree_newlines :: proc(node: ^Node) -> u32 {
	if node == nil {
		return 0
	}
	return node.left_newlines + node.piece.newline_count + subtree_newlines(node.right)
}

recompute_metadata :: proc(node: ^Node) {
	if node == nil { return }
	node.left_size = subtree_size(node.left)
	node.left_newlines = subtree_newlines(node.left)
}

node_update_metadata_up :: proc(node: ^Node) {
	n := node
	for n != nil {
		recompute_metadata(n)
		n = n.parent
	}
}
