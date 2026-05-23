// Package `hover` is the LSP hover popup. The bubble that pops next
// to the editor cursor on Ctrl+K with type / doc info from the
// language server.
//
// File layout (canonical subpackage shape):
//   * `state.odin`    — types + lifecycle.
//   * `dispatch.odin` — set_content / set_anchor / auto-close: the
//                       per-frame mutators the editor calls between
//                       events.
//   * `view.odin`     — render.
//   * `binding.odin`  — vtable + Hooks for the editor's plugin
//                       registry.
package hover

import "vendor:sdl3"

import "../../markdown"

State :: struct {
	visible:           bool,
	text:              string, // owned, raw markdown
	anchor_line:       u32,
	anchor_column:     u32,
	anchor_pane_index: int,

	// "Stickiness" range — while the cursor sits anywhere in this byte
	// span on `anchor_line`, the popup stays open. Seeded by the editor
	// with a generous default around the cursor; the LSP `range` field
	// will eventually feed in a tighter span.
	range_start_column: u32,
	range_end_column:   u32,

	blocks:            [dynamic]markdown.Block,
	layouted_blocks:   [dynamic]markdown.LayoutedBlock,
	layout_width:      i32,
}

// Where the popup should anchor on screen, in viewport coordinates.
AnchorScreenPosition :: struct {
	cursor_screen_top_y: i32,
	cursor_line_height:  i32,
	pane_left_x:         i32,
	character_width:     i32,
}

// Cursor snapshot the editor passes into `auto_close_if_cursor_moved`.
CursorState :: struct {
	active_pane_index: int,
	cursor_line:       u32,
	cursor_column:     u32,
	pane_is_editor:    bool,
}

Chrome :: struct {
	background: sdl3.FColor,
	border:     sdl3.FColor,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	markdown.clear_layouted_blocks(&state.layouted_blocks)
	if cap(state.layouted_blocks) > 0 { delete(state.layouted_blocks) }
	markdown.clear_blocks(&state.blocks)
	if cap(state.blocks)          > 0 { delete(state.blocks) }
	if len(state.text) > 0 { delete(state.text) }
	state^ = State{}
}

// Tear the popup down without freeing the dynamic-array backing buffers
// (preserves `state.blocks` / `state.layouted_blocks` cap for reuse).
close :: proc(state: ^State) {
	if !state.visible && len(state.text) == 0 && len(state.blocks) == 0 { return }
	destroy(state)
}
