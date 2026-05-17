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
diff_state_destroy :: proc(d: ^DiffState) {
	// Guard each delete on cap > 0 so we never hand the heap allocator a
	// zero-sized free (the Windows debug heap fires a breakpoint on those
	// in some configurations even though it's logically a no-op).
	if cap(d.rows)               > 0 { delete(d.rows) }
	if cap(d.left_line_to_row)   > 0 { delete(d.left_line_to_row) }
	if cap(d.right_line_to_row)  > 0 { delete(d.right_line_to_row) }
	d^ = DiffState{}
}

@(private="file")
diff_build_line_maps :: proc(d: ^DiffState, n, m: int) {
	resize(&d.left_line_to_row,  n)
	resize(&d.right_line_to_row, m)
	for k in 0..<n { d.left_line_to_row[k]  = -1 }
	for k in 0..<m { d.right_line_to_row[k] = -1 }
	for row, idx in d.rows {
		if row.left_line  >= 0 { d.left_line_to_row[row.left_line]   = i32(idx) }
		if row.right_line >= 0 { d.right_line_to_row[row.right_line] = i32(idx) }
	}
}

// Compute a line-level diff between two documents using Myers' algorithm
// (Eugene W. Myers, "An O(ND) Difference Algorithm and its Variations", 1986).
//
// Forward pass: for each `d` from 0..max_d, propagate the furthest-reaching
// x-coordinate on each diagonal `k = x - y` until we reach (n, m). The state
// of the `V[k]` vector at the *start* of each iteration is snapshotted into
// `snapshots[d]` so the backward pass can recover the actual edit script.
//
// Backward pass: starting from (n, m), reconstruct the moves that got us
// there. At each `d`, the snapshot tells us which neighbour diagonal we came
// from and where the previous step ended. Diagonal moves are emitted as
// `Equal`; the non-diagonal step is emitted as `Insert` (came from below) or
// `Delete` (came from the left).
//
// Returns true on success, false if the input exceeds DIFF_MAX_LINES.
@(private)
diff_compute :: proc(d: ^DiffState, left_doc, right_doc: ^document.Document) -> bool {
	diff_state_destroy(d)

	n := int(document.document_line_count(left_doc))
	m := int(document.document_line_count(right_doc))

	if n + m > DIFF_MAX_LINES { return false }

	// Explicitly initialize the persistent dynamic arrays with context.allocator
	// rather than relying on lazy initialization on first append. This keeps
	// the allocator field explicit and makes destroy/realloc behavior
	// deterministic.
	d.rows              = make([dynamic]DiffRow, 0, 32, context.allocator)
	d.left_line_to_row  = make([dynamic]i32,     0, 32, context.allocator)
	d.right_line_to_row = make([dynamic]i32,     0, 32, context.allocator)

	left  := make([]string, n, context.temp_allocator)
	right := make([]string, m, context.temp_allocator)
	for i in 0..<n { left[i]  = document.document_get_line(left_doc,  u32(i), context.temp_allocator) }
	for j in 0..<m { right[j] = document.document_get_line(right_doc, u32(j), context.temp_allocator) }

	// Trivial cases — no need to run Myers for empty sides.
	if n == 0 && m == 0 { return true }
	if n == 0 {
		for j in 0..<m { append(&d.rows, DiffRow{.Insert, -1, i32(j)}) }
		diff_build_line_maps(d, n, m)
		return true
	}
	if m == 0 {
		for i in 0..<n { append(&d.rows, DiffRow{.Delete, i32(i), -1}) }
		diff_build_line_maps(d, n, m)
		return true
	}

	max_d    := n + m
	v_size   := 2 * max_d + 1
	v_offset := max_d

	V := make([]int, v_size, context.temp_allocator)
	// V[k=1] = 0 is the bootstrap value that lets the d=0 step pick up the
	// origin. V is zero-initialized so this is implicit, but it's worth
	// noting.

	// snapshots[d] = state of V before iteration d (== state after iteration
	// d-1). The d=0 snapshot is the initial zeroed V. Stored in temp memory
	// so the entire table is freed when the proc returns. Pre-reserve so the
	// dynamic array doesn't repeatedly grow during the forward pass.
	snapshots := make([dynamic][]int, 0, 64, context.temp_allocator)

	found_d := -1

	outer: for current_d in 0..=max_d {
		// Snapshot V before this iteration (this is what the backward pass
		// reads to recover the previous step).
		snap := make([]int, v_size, context.temp_allocator)
		copy(snap, V)
		append(&snapshots, snap)

		for k := -current_d; k <= current_d; k += 2 {
			// Pick the better of the two neighbours and slide diagonally.
			x: int
			if k == -current_d || (k != current_d && V[v_offset + k - 1] < V[v_offset + k + 1]) {
				x = V[v_offset + k + 1]      // "down" — came from the diagonal above
			} else {
				x = V[v_offset + k - 1] + 1  // "right" — came from the diagonal below
			}
			y := x - k

			// Free snake: match as far as possible along this diagonal.
			for x < n && y < m && left[x] == right[y] {
				x += 1
				y += 1
			}
			V[v_offset + k] = x

			if x >= n && y >= m {
				found_d = current_d
				break outer
			}
		}
	}

	if found_d < 0 { return false } // unreachable for valid inputs

	// Backward pass — emit rows in reverse, then flip into d.rows.
	backtrack := make([dynamic]DiffRow, 0, 0, context.temp_allocator)
	x, y := n, m

	for di := found_d; di > 0; di -= 1 {
		V_prev := snapshots[di]
		k := x - y

		prev_k: int
		if k == -di || (k != di && V_prev[v_offset + k - 1] < V_prev[v_offset + k + 1]) {
			prev_k = k + 1
		} else {
			prev_k = k - 1
		}

		prev_x := V_prev[v_offset + prev_k]
		prev_y := prev_x - prev_k

		// Diagonal first — every matched line on the way back from (x,y) to
		// the start of the previous step's snake.
		for x > prev_x && y > prev_y {
			append(&backtrack, DiffRow{.Equal, i32(x-1), i32(y-1)})
			x -= 1
			y -= 1
		}

		// The single non-diagonal step taken at this `d`.
		if x == prev_x {
			append(&backtrack, DiffRow{.Insert, -1, i32(y-1)})
		} else {
			append(&backtrack, DiffRow{.Delete, i32(x-1), -1})
		}
		x = prev_x
		y = prev_y
	}

	// Any remaining diagonal from the d=0 prefix.
	for x > 0 && y > 0 {
		append(&backtrack, DiffRow{.Equal, i32(x-1), i32(y-1)})
		x -= 1
		y -= 1
	}

	// Flip into forward order.
	for i := len(backtrack) - 1; i >= 0; i -= 1 {
		append(&d.rows, backtrack[i])
	}

	diff_build_line_maps(d, n, m)
	return true
}

// Toggle diff mode. Requires both panes to be open and contain editor content;
// otherwise it's a no-op. Diff state is freed on exit so memory doesn't linger.
@(private)
diff_toggle :: proc(ed: ^Editor) {
	if ed.diff_state.active {
		diff_state_destroy(&ed.diff_state)
		return
	}

	if !ed.split_active { return }
	left  := pane_as_editor(&ed.panes[0])
	right := pane_as_editor(&ed.panes[1])
	if left == nil || right == nil { return }

	if !diff_compute(&ed.diff_state, &left.doc, &right.doc) { return }
	ed.diff_state.active = true

	// Start the diff view at the top.
	ed.diff_state.scroll_y = 0
	ed.diff_state.scroll_y_target = 0

	// Reset any selections that would now be visually meaningless.
	left.sel_active = false
	right.sel_active = false
}
