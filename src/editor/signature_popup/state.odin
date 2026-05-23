// Package `signature_popup` — small popup showing a procedure's
// signature while the user is inside the argument list. Triggered
// when `(` is typed (and refreshed on `,` / cursor moves), closed
// by the matching `)`, Esc, jumping to a different row, or backing
// past the opening paren.
//
// File layout:
//   * `state.odin`    — types + lifecycle.
//   * `dispatch.odin` — open / mark_request_pending /
//                       should_coalesce_request / set_content /
//                       auto_close_if_cursor_moved (per-frame
//                       mutators).
//   * `view.odin`     — render.
//   * `binding.odin`  — vtable + Hooks.
package signature_popup

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../../markdown"

State :: struct {
	visible:           bool,
	pane_index:        int,
	anchor_line:       u32,
	open_paren_offset: u32,    // byte offset of the `(` that triggered the popup
	request_pending:   bool,

	// If a `,` (or another paren-list cursor move) arrives while a
	// previous request is still in flight, we DON'T fire a second one.
	// We just flip this flag; the moment the in-flight response lands,
	// the editor fires the latest position. End state converges on the
	// cursor's current location.
	needs_refresh:     bool,

	// Snapshotted from the latest server response so re-renders don't
	// need to peek at the LSP client's state.
	signature_label:   string, // owned
	documentation:     string, // owned
	active_start:      i32,
	active_end:        i32,

	signature_text_object: ^ttf.Text,
	signature_text_dirty:  bool,

	doc_blocks:           [dynamic]markdown.Block,
	doc_layouted_blocks:  [dynamic]markdown.LayoutedBlock,
	doc_layout_width:     i32,
}

AnchorScreenPosition :: struct {
	cursor_screen_top_y: i32,
	cursor_line_height:  i32,
	character_width:     i32,
	text_left_x:         i32,
	pane_top_y:          i32,
}

CursorState :: struct {
	pane_index:     int,
	cursor_line:    u32,
	cursor_offset:  u32,
	pane_is_editor: bool,
}

Content :: struct {
	signature_label: string,
	documentation:   string,
	active_start:    i32,
	active_end:      i32,
}

Chrome :: struct {
	background:             sdl3.FColor,
	border:                 sdl3.FColor,
	signature_color:        sdl3.FColor,
	active_underline_color: sdl3.FColor,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	markdown.clear_layouted_blocks(&state.doc_layouted_blocks)
	if cap(state.doc_layouted_blocks) > 0 { delete(state.doc_layouted_blocks) }
	markdown.clear_blocks(&state.doc_blocks)
	if cap(state.doc_blocks) > 0 { delete(state.doc_blocks) }
	if len(state.signature_label) > 0 { delete(state.signature_label) }
	if len(state.documentation)   > 0 { delete(state.documentation)   }
	if state.signature_text_object != nil {
		ttf.DestroyText(state.signature_text_object)
		state.signature_text_object = nil
	}
	state^ = State{}
}

close :: proc(state: ^State) {
	if !state.visible { return }
	destroy(state)
}
