// Package `diff` — line-level diff (Myers' algorithm) used by F8
// diff mode. Pure algorithm + state container; no editor coupling
// (the editor stores a `State` and feeds the algorithm two
// `^document.Document` pointers).
//
// File layout:
//   * `state.odin`    — types + lifecycle.
//   * `dispatch.odin` — Myers' compute + change-pairing + inline
//                       byte-bounds.
package diff

RowKind :: enum u8 {
	Equal,   // line present in both panes, same content
	Delete,  // line present only in the left pane (pane 0)
	Insert,  // line present only in the right pane (pane 1)
	Change,  // line present in BOTH panes with different content — kept side-by-side
}

// One row in the aligned diff display. `left_line` / `right_line`
// are document line indices; either may be -1 to indicate "no
// content on this side" (a gap row that aligns its counterpart on
// the other side).
//
// For `Change` rows both indices are valid (>= 0). The
// `*_change_start` / `*_change_end` fields are byte offsets within
// each side's line text that bound the differing region — computed
// via longest-common-prefix / longest-common-suffix at diff time so
// the renderer can paint an inline highlight without re-fetching
// the other pane's line content per frame. They're zero for
// non-Change rows.
Row :: struct {
	kind:               RowKind,
	left_line:          i32,
	right_line:         i32,
	left_change_start:  i32,
	left_change_end:    i32,
	right_change_start: i32,
	right_change_end:   i32,
}

// State shared by both panes while diff mode is active. Both panes
// scroll together using `scroll_y` / `scroll_y_target` — there's
// only one scroll position for the aligned diff view.
State :: struct {
	active:           bool,
	rows:             [dynamic]Row,

	// Synchronised vertical scroll, in pixels, indexed against
	// `rows`.
	scroll_y:         f32,
	scroll_y_target:  f32,

	// Map doc-line → diff-row index (or -1 if the line is gone in
	// this pane). Used by the cursor scroll-into-view logic.
	left_line_to_row:  [dynamic]i32,
	right_line_to_row: [dynamic]i32,
}

// Combined-line cap that protects the diff from pathological
// inputs. The Myers snapshot table is O((N+M)·D) in the worst case
// (two completely unrelated files); 4000 combined lines keeps the
// worst-case memory in the low hundreds of MB.
MAX_LINES :: 4000

destroy :: proc(state: ^State) {
	// Guard each delete on cap > 0 so we never hand the heap
	// allocator a zero-sized free (the Windows debug heap fires a
	// breakpoint on those in some configurations).
	if cap(state.rows)               > 0 { delete(state.rows) }
	if cap(state.left_line_to_row)   > 0 { delete(state.left_line_to_row) }
	if cap(state.right_line_to_row)  > 0 { delete(state.right_line_to_row) }
	state^ = State{}
}
