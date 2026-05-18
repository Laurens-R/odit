package editor

import "../document"

// --- Diff types ------------------------------------------------------------

DiffRowKind :: enum u8 {
	Equal,   // line present in both panes, same content
	Delete,  // line present only in the left pane (pane 0)
	Insert,  // line present only in the right pane (pane 1)
}

// One row in the aligned diff display. `left_line` / `right_line` are document
// line indices; either may be -1 to indicate "no content on this side" (a gap
// row that aligns its counterpart on the other side).
DiffRow :: struct {
	kind:       DiffRowKind,
	left_line:  i32,
	right_line: i32,
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
		for right_line_index in 0..<right_line_count { append(&diff_state.rows, DiffRow{.Insert, -1, i32(right_line_index)}) }
		diff_build_line_maps(diff_state, left_line_count, right_line_count)
		return true
	}
	if right_line_count == 0 {
		for left_line_index in 0..<left_line_count { append(&diff_state.rows, DiffRow{.Delete, i32(left_line_index), -1}) }
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
			append(&backtrack_rows, DiffRow{.Equal, i32(current_x-1), i32(current_y-1)})
			current_x -= 1
			current_y -= 1
		}

		// The single non-diagonal step taken at this distance.
		if current_x == previous_x {
			append(&backtrack_rows, DiffRow{.Insert, -1, i32(current_y-1)})
		} else {
			append(&backtrack_rows, DiffRow{.Delete, i32(current_x-1), -1})
		}
		current_x = previous_x
		current_y = previous_y
	}

	// Any remaining diagonal from the d=0 prefix.
	for current_x > 0 && current_y > 0 {
		append(&backtrack_rows, DiffRow{.Equal, i32(current_x-1), i32(current_y-1)})
		current_x -= 1
		current_y -= 1
	}

	// Flip into forward order.
	for reverse_index := len(backtrack_rows) - 1; reverse_index >= 0; reverse_index -= 1 {
		append(&diff_state.rows, backtrack_rows[reverse_index])
	}

	diff_build_line_maps(diff_state, left_line_count, right_line_count)
	return true
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
