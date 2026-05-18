package editor

import "../document"

// --- Diff types ------------------------------------------------------------

DiffRowKind :: enum u8 {
	Equal,   // line present in both panes, same content
	Delete,  // line present only in the left pane (pane 0)
	Insert,  // line present only in the right pane (pane 1)
	Change,  // line present in BOTH panes with different content — kept side-by-side
}

// One row in the aligned diff display. `left_line` / `right_line` are document
// line indices; either may be -1 to indicate "no content on this side" (a gap
// row that aligns its counterpart on the other side).
//
// For `Change` rows both indices are valid (>= 0). The `*_change_start` /
// `*_change_end` fields are byte offsets within each side's line text that
// bound the differing region — computed via longest-common-prefix /
// longest-common-suffix at diff time so the renderer can paint an inline
// highlight without re-fetching the other pane's line content per frame.
// They're zero for non-Change rows.
DiffRow :: struct {
	kind:               DiffRowKind,
	left_line:          i32,
	right_line:         i32,
	left_change_start:  i32,
	left_change_end:    i32,
	right_change_start: i32,
	right_change_end:   i32,
}

// State shared by both panes while diff mode is active. Both panes scroll
// together using `scroll_y` / `scroll_y_target` — there's only one scroll
// position for the aligned diff view.
DiffState :: struct {
	active:           bool,
	rows:             [dynamic]DiffRow,

	// Synchronised vertical scroll, in pixels, indexed against `rows`.
	scroll_y:         f32,
	scroll_y_target:  f32,

	// Map doc-line → diff-row index (or -1 if the line is gone in this pane).
	// Used by the cursor scroll-into-view logic.
	left_line_to_row:  [dynamic]i32,
	right_line_to_row: [dynamic]i32,
}

// Combined-line cap that protects the diff from pathological inputs. The
// Myers snapshot table is O((N+M)·D) in the worst case (two completely
// unrelated files); 4000 combined lines keeps the worst-case memory in the
// low hundreds of MB.
DIFF_MAX_LINES :: 4000

@(private)
diff_state_destroy :: proc(diff_state: ^DiffState) {
	// Guard each delete on cap > 0 so we never hand the heap allocator a
	// zero-sized free (the Windows debug heap fires a breakpoint on those
	// in some configurations even though it's logically a no-op).
	if cap(diff_state.rows)               > 0 { delete(diff_state.rows) }
	if cap(diff_state.left_line_to_row)   > 0 { delete(diff_state.left_line_to_row) }
	if cap(diff_state.right_line_to_row)  > 0 { delete(diff_state.right_line_to_row) }
	diff_state^ = DiffState{}
}

@(private="file")
diff_build_line_maps :: proc(diff_state: ^DiffState, left_line_count, right_line_count: int) {
	resize(&diff_state.left_line_to_row,  left_line_count)
	resize(&diff_state.right_line_to_row, right_line_count)
	for line_index in 0..<left_line_count  { diff_state.left_line_to_row[line_index]  = -1 }
	for line_index in 0..<right_line_count { diff_state.right_line_to_row[line_index] = -1 }
	for diff_row, row_index in diff_state.rows {
		if diff_row.left_line  >= 0 { diff_state.left_line_to_row[diff_row.left_line]   = i32(row_index) }
		if diff_row.right_line >= 0 { diff_state.right_line_to_row[diff_row.right_line] = i32(row_index) }
	}
}

// Compute a line-level diff between two documents using Myers' algorithm
// (Eugene W. Myers, "An O(ND) Difference Algorithm and its Variations", 1986).
//
// Forward pass: for each `d` from 0..max_d, propagate the furthest-reaching
// x-coordinate on each diagonal `k = x - y` until we reach (left_line_count,
// right_line_count). The state of the `furthest_x_by_diagonal[k]` vector at
// the *start* of each iteration is snapshotted into `snapshots[d]` so the
// backward pass can recover the actual edit script.
//
// Backward pass: starting from (left_line_count, right_line_count),
// reconstruct the moves that got us there. At each `d`, the snapshot tells
// us which neighbour diagonal we came from and where the previous step
// ended. Diagonal moves are emitted as `Equal`; the non-diagonal step is
// emitted as `Insert` (came from below) or `Delete` (came from the left).
//
// Returns true on success, false if the input exceeds DIFF_MAX_LINES.
@(private)
diff_compute :: proc(diff_state: ^DiffState, left_document, right_document: ^document.Document) -> bool {
	diff_state_destroy(diff_state)

	left_line_count  := int(document.document_line_count(left_document))
	right_line_count := int(document.document_line_count(right_document))

	if left_line_count + right_line_count > DIFF_MAX_LINES { return false }

	// Explicitly initialize the persistent dynamic arrays with context.allocator
	// rather than relying on lazy initialization on first append. This keeps
	// the allocator field explicit and makes destroy/realloc behavior
	// deterministic.
	diff_state.rows              = make([dynamic]DiffRow, 0, 32, context.allocator)
	diff_state.left_line_to_row  = make([dynamic]i32,     0, 32, context.allocator)
	diff_state.right_line_to_row = make([dynamic]i32,     0, 32, context.allocator)

	left_line_texts  := make([]string, left_line_count,  context.temp_allocator)
	right_line_texts := make([]string, right_line_count, context.temp_allocator)
	for left_line_index in 0..<left_line_count   { left_line_texts[left_line_index]   = document.document_get_line(left_document,  u32(left_line_index),  context.temp_allocator) }
	for right_line_index in 0..<right_line_count { right_line_texts[right_line_index] = document.document_get_line(right_document, u32(right_line_index), context.temp_allocator) }

	// Trivial cases — no need to run Myers for empty sides.
	if left_line_count == 0 && right_line_count == 0 { return true }
	if left_line_count == 0 {
		for right_line_index in 0..<right_line_count { append(&diff_state.rows, DiffRow{kind = .Insert, left_line = -1, right_line = i32(right_line_index)}) }
		diff_build_line_maps(diff_state, left_line_count, right_line_count)
		return true
	}
	if right_line_count == 0 {
		for left_line_index in 0..<left_line_count { append(&diff_state.rows, DiffRow{kind = .Delete, left_line = i32(left_line_index), right_line = -1}) }
		diff_build_line_maps(diff_state, left_line_count, right_line_count)
		return true
	}

	max_edit_distance := left_line_count + right_line_count
	furthest_x_vector_size   := 2 * max_edit_distance + 1
	furthest_x_offset := max_edit_distance

	furthest_x_by_diagonal := make([]int, furthest_x_vector_size, context.temp_allocator)
	// furthest_x_by_diagonal[k=1] = 0 is the bootstrap value that lets the
	// d=0 step pick up the origin. The vector is zero-initialized so this
	// is implicit, but it's worth noting.

	// snapshots[d] = state of furthest_x_by_diagonal before iteration d
	// (== state after iteration d-1). The d=0 snapshot is the initial
	// zeroed vector. Stored in temp memory so the entire table is freed
	// when the proc returns. Pre-reserve so the dynamic array doesn't
	// repeatedly grow during the forward pass.
	snapshots := make([dynamic][]int, 0, 64, context.temp_allocator)

	found_edit_distance := -1

	outer: for current_edit_distance in 0..=max_edit_distance {
		// Snapshot the diagonal vector before this iteration (this is what
		// the backward pass reads to recover the previous step).
		snapshot_vector := make([]int, furthest_x_vector_size, context.temp_allocator)
		copy(snapshot_vector, furthest_x_by_diagonal)
		append(&snapshots, snapshot_vector)

		for diagonal := -current_edit_distance; diagonal <= current_edit_distance; diagonal += 2 {
			// Pick the better of the two neighbours and slide diagonally.
			furthest_x: int
			if diagonal == -current_edit_distance || (diagonal != current_edit_distance && furthest_x_by_diagonal[furthest_x_offset + diagonal - 1] < furthest_x_by_diagonal[furthest_x_offset + diagonal + 1]) {
				furthest_x = furthest_x_by_diagonal[furthest_x_offset + diagonal + 1]      // "down" — came from the diagonal above
			} else {
				furthest_x = furthest_x_by_diagonal[furthest_x_offset + diagonal - 1] + 1  // "right" — came from the diagonal below
			}
			furthest_y := furthest_x - diagonal

			// Free snake: match as far as possible along this diagonal.
			for furthest_x < left_line_count && furthest_y < right_line_count && left_line_texts[furthest_x] == right_line_texts[furthest_y] {
				furthest_x += 1
				furthest_y += 1
			}
			furthest_x_by_diagonal[furthest_x_offset + diagonal] = furthest_x

			if furthest_x >= left_line_count && furthest_y >= right_line_count {
				found_edit_distance = current_edit_distance
				break outer
			}
		}
	}

	if found_edit_distance < 0 { return false } // unreachable for valid inputs

	// Backward pass — emit rows in reverse, then flip into diff_state.rows.
	backtrack_rows := make([dynamic]DiffRow, 0, 0, context.temp_allocator)
	current_x, current_y := left_line_count, right_line_count

	for distance_index := found_edit_distance; distance_index > 0; distance_index -= 1 {
		previous_diagonal_vector := snapshots[distance_index]
		current_diagonal := current_x - current_y

		previous_diagonal: int
		if current_diagonal == -distance_index || (current_diagonal != distance_index && previous_diagonal_vector[furthest_x_offset + current_diagonal - 1] < previous_diagonal_vector[furthest_x_offset + current_diagonal + 1]) {
			previous_diagonal = current_diagonal + 1
		} else {
			previous_diagonal = current_diagonal - 1
		}

		previous_x := previous_diagonal_vector[furthest_x_offset + previous_diagonal]
		previous_y := previous_x - previous_diagonal

		// Diagonal first — every matched line on the way back from
		// (current_x, current_y) to the start of the previous step's snake.
		for current_x > previous_x && current_y > previous_y {
			append(&backtrack_rows, DiffRow{kind = .Equal, left_line = i32(current_x-1), right_line = i32(current_y-1)})
			current_x -= 1
			current_y -= 1
		}

		// The single non-diagonal step taken at this distance.
		if current_x == previous_x {
			append(&backtrack_rows, DiffRow{kind = .Insert, left_line = -1, right_line = i32(current_y-1)})
		} else {
			append(&backtrack_rows, DiffRow{kind = .Delete, left_line = i32(current_x-1), right_line = -1})
		}
		current_x = previous_x
		current_y = previous_y
	}

	// Any remaining diagonal from the d=0 prefix.
	for current_x > 0 && current_y > 0 {
		append(&backtrack_rows, DiffRow{kind = .Equal, left_line = i32(current_x-1), right_line = i32(current_y-1)})
		current_x -= 1
		current_y -= 1
	}

	// Flip into forward order.
	for reverse_index := len(backtrack_rows) - 1; reverse_index >= 0; reverse_index -= 1 {
		append(&diff_state.rows, backtrack_rows[reverse_index])
	}

	// Post-process Delete/Insert runs into Change pairs so modified lines sit
	// side-by-side instead of shoving everything below them down by one row.
	diff_pair_changes(&diff_state.rows, left_line_texts, right_line_texts)

	diff_build_line_maps(diff_state, left_line_count, right_line_count)
	return true
}

// Walk the row list and turn each contiguous Delete+Insert run into a stream
// of Change pairs (followed by any unmatched remainder as plain Delete /
// Insert rows). The intent is to keep modified lines on the same row across
// the two panes — the previous behavior pushed every change down by the size
// of its counterpart block, which made it nearly impossible to compare
// side-by-side.
//
// Pairing is by position: i-th delete in the block ↔ i-th insert. Remainders
// stay as gap rows. For each Change row we precompute byte-level change
// bounds via longest-common-prefix / longest-common-suffix so the renderer
// can paint an inline highlight cheaply.
@(private="file")
diff_pair_changes :: proc(rows: ^[dynamic]DiffRow, left_line_texts, right_line_texts: []string) {
	if len(rows^) == 0 { return }

	rewritten_rows := make([dynamic]DiffRow, 0, len(rows^), context.allocator)

	row_index := 0
	for row_index < len(rows^) {
		current_kind := rows[row_index].kind
		if current_kind != .Delete && current_kind != .Insert {
			append(&rewritten_rows, rows[row_index])
			row_index += 1
			continue
		}

		// Walk the full Delete/Insert block (mixed order is fine — Myers can
		// emit them either way around the snake).
		block_start := row_index
		block_end   := row_index
		for block_end < len(rows^) && (rows[block_end].kind == .Delete || rows[block_end].kind == .Insert) {
			block_end += 1
		}

		// Collect each side in source order. Both arrays are already in
		// ascending document-line order because Myers walks document order.
		deletes_left_lines:  [dynamic]i32; deletes_left_lines.allocator  = context.temp_allocator
		inserts_right_lines: [dynamic]i32; inserts_right_lines.allocator = context.temp_allocator
		for collect_index := block_start; collect_index < block_end; collect_index += 1 {
			#partial switch rows[collect_index].kind {
			case .Delete: append(&deletes_left_lines,  rows[collect_index].left_line)
			case .Insert: append(&inserts_right_lines, rows[collect_index].right_line)
			}
		}

		pair_count := min(len(deletes_left_lines), len(inserts_right_lines))

		// Change rows first, in matched index order.
		for pair_index in 0..<pair_count {
			left_doc_line  := deletes_left_lines[pair_index]
			right_doc_line := inserts_right_lines[pair_index]

			left_text  := left_line_texts[left_doc_line]
			right_text := right_line_texts[right_doc_line]
			left_start, left_end, right_start, right_end := compute_inline_change_bounds(left_text, right_text)

			append(&rewritten_rows, DiffRow{
				kind               = .Change,
				left_line          = left_doc_line,
				right_line         = right_doc_line,
				left_change_start  = i32(left_start),
				left_change_end    = i32(left_end),
				right_change_start = i32(right_start),
				right_change_end   = i32(right_end),
			})
		}
		// Then the leftover Delete / Insert rows on their original side. Order
		// these so unpaired deletes appear before unpaired inserts — the only
		// time both leftovers coexist is the asymmetric case which is rare.
		for leftover_index := pair_count; leftover_index < len(deletes_left_lines); leftover_index += 1 {
			append(&rewritten_rows, DiffRow{kind = .Delete, left_line = deletes_left_lines[leftover_index], right_line = -1})
		}
		for leftover_index := pair_count; leftover_index < len(inserts_right_lines); leftover_index += 1 {
			append(&rewritten_rows, DiffRow{kind = .Insert, left_line = -1, right_line = inserts_right_lines[leftover_index]})
		}

		row_index = block_end
	}

	delete(rows^)
	rows^ = rewritten_rows
}

// Byte-level longest-common-prefix / longest-common-suffix bracket on the two
// strings. Returns the byte half-open ranges [left_start, left_end) and
// [right_start, right_end) that actually differ — collapsing to (len, len)
// for identical strings (caller treats as "nothing to highlight"). Both
// strings are assumed UTF-8; bytes that match across the boundary are by
// definition on rune boundaries (the only way two valid UTF-8 byte sequences
// can match for a stretch is if they encode the same code points).
@(private="file")
compute_inline_change_bounds :: proc(left_text, right_text: string) -> (left_start, left_end, right_start, right_end: int) {
	prefix_length := 0
	left_length   := len(left_text)
	right_length  := len(right_text)
	for prefix_length < left_length && prefix_length < right_length && left_text[prefix_length] == right_text[prefix_length] {
		prefix_length += 1
	}

	suffix_length := 0
	for prefix_length + suffix_length < left_length &&
	    prefix_length + suffix_length < right_length &&
	    left_text [left_length  - 1 - suffix_length] == right_text[right_length - 1 - suffix_length] {
		suffix_length += 1
	}

	left_start  = prefix_length
	left_end    = left_length  - suffix_length
	right_start = prefix_length
	right_end   = right_length - suffix_length
	return
}

// Toggle diff mode. Requires both panes to be open and contain editor content;
// otherwise it's a no-op. Diff state is freed on exit so memory doesn't linger.
@(private)
diff_toggle :: proc(editor: ^Editor) {
	if editor.diff_state.active {
		diff_state_destroy(&editor.diff_state)
		return
	}

	if !editor.split_active { return }
	left_pane  := pane_as_editor(&editor.panes[0])
	right_pane := pane_as_editor(&editor.panes[1])
	if left_pane == nil || right_pane == nil { return }

	if !diff_compute(&editor.diff_state, &left_pane.document, &right_pane.document) { return }
	editor.diff_state.active = true

	// Start the diff view at the top.
	editor.diff_state.scroll_y = 0
	editor.diff_state.scroll_y_target = 0

	// Reset any selections that would now be visually meaningless.
	left_pane.selection_active  = false
	right_pane.selection_active = false
}
