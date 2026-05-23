// Per-frame mutators: open / coalesce / set_content / auto-close.
package signature_popup

import "core:strings"
import "vendor:sdl3/ttf"

import "../../markdown"

// Open the popup at the `(` that just got typed (or refresh anchor on
// a `,`). Safe to call repeatedly — only the first call sets the
// anchor; subsequent calls leave existing anchor info untouched.
open :: proc(state: ^State, pane_index: int, anchor_line: u32, open_paren_offset: u32) {
	if state.visible { return }
	destroy(state)
	state.visible            = true
	state.pane_index         = pane_index
	state.anchor_line        = anchor_line
	state.open_paren_offset  = open_paren_offset
}

// Editor calls this right after issuing
// `lsp.client_request_signature_help` so the popup knows to wait.
mark_request_pending :: proc(state: ^State) {
	state.request_pending = true
}

// Returns true when the editor should ACTUALLY skip firing a new
// request because one is in flight; flips the "refire when previous
// lands" flag.
should_coalesce_request :: proc(state: ^State) -> bool {
	if !state.request_pending { return false }
	state.needs_refresh = true
	return true
}

// Auto-close when the cursor wanders off the call expression.
auto_close_if_cursor_moved :: proc(state: ^State, cursor: CursorState) -> (closed: bool) {
	if !state.visible { return false }

	close_reason := false
	switch {
	case state.pane_index < 0:
		close_reason = true
	case state.pane_index != cursor.pane_index:
		close_reason = true
	case !cursor.pane_is_editor:
		close_reason = true
	case cursor.cursor_line != state.anchor_line:
		close_reason = true
	case cursor.cursor_offset < state.open_paren_offset:
		close_reason = true
	}

	if !close_reason { return false }
	close(state)
	return true
}

// Populate with fresh signature data. Strings inside `content` are
// cloned. Marks the cached signature text-object dirty so the next
// render rebuilds it. Returns true when the editor should refire the
// request immediately (a `,` arrived while waiting).
set_content :: proc(state: ^State, content: Content) -> (needs_refire: bool) {
	state.request_pending = false

	markdown.clear_layouted_blocks(&state.doc_layouted_blocks)
	markdown.clear_blocks(&state.doc_blocks)
	state.doc_layout_width = 0
	if len(state.signature_label) > 0 { delete(state.signature_label); state.signature_label = "" }
	if len(state.documentation)   > 0 { delete(state.documentation);   state.documentation   = "" }
	if state.signature_text_object != nil {
		ttf.DestroyText(state.signature_text_object)
		state.signature_text_object = nil
	}

	state.signature_label = strings.clone(content.signature_label)
	state.documentation   = strings.clone(content.documentation)
	state.active_start    = content.active_start
	state.active_end      = content.active_end
	state.signature_text_dirty = true

	if len(state.documentation) > 0 {
		markdown.parse_into(state.documentation, &state.doc_blocks)
	}

	needs_refire = state.needs_refresh
	state.needs_refresh = false
	return needs_refire
}
