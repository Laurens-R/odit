// Per-frame mutators: open / set_items / consume_text /
// consume_backspace / auto_close_if_cursor_moved.
package completion_popup

import "core:strings"

import "../../ui"

// Open the popup at the cursor and mark "waiting for LSP".
open :: proc(state: ^State, pane_index: int, anchor_line, anchor_column: u32) {
	close(state)
	state.visible         = true
	state.pane_index      = pane_index
	state.anchor_line     = anchor_line
	state.anchor_column   = anchor_column
	state.request_pending = true
}

// Replace the snapshot with a fresh list of items from an LSP
// response. Clones every string. Pre-measures label / detail width
// when `ui_context` has a usable font; otherwise leaves widths at 0
// and the renderer fills them in lazily on the next paint
// (`ensure_item_widths_measured`). The LSP poll path runs outside
// the render loop and doesn't have a real `ui.Context` to hand in,
// so the lazy path is the common case.
set_items :: proc(state: ^State, ui_context: ^ui.Context, sources: []ItemSource) {
	clear_items(state)
	state.request_pending = false
	state.selected_index  = 0
	state.scroll_offset   = 0

	can_measure := ui_context != nil && ui_context.font != nil

	for source in sources {
		label_copy  := strings.clone(source.label)
		detail_copy := strings.clone(source.detail)
		insert_copy := strings.clone(source.insert_text)
		label_width:  i32 = 0
		detail_width: i32 = 0
		if can_measure {
			if len(label_copy)  > 0 { label_width,  _ = ui.text_size(ui_context, label_copy)  }
			if len(detail_copy) > 0 { detail_width, _ = ui.text_size(ui_context, detail_copy) }
		}
		append(&state.items_snapshot, Item{
			label              = label_copy,
			detail             = detail_copy,
			insert_text        = insert_copy,
			label_pixel_width  = label_width,
			detail_pixel_width = detail_width,
		})
	}
}

// Fill in any missing per-item label / detail pixel widths using
// the render-time `ui_context`. Cheap on subsequent frames (the
// width != 0 fast path skips). Called by the renderer before it
// uses the widths to size the popup.
@(private)
ensure_item_widths_measured :: proc(state: ^State, ui_context: ^ui.Context) {
	if ui_context == nil || ui_context.font == nil { return }
	for &item in state.items_snapshot {
		if item.label_pixel_width == 0 && len(item.label) > 0 {
			width, _ := ui.text_size(ui_context, item.label)
			item.label_pixel_width = width
		}
		if item.detail_pixel_width == 0 && len(item.detail) > 0 {
			width, _ := ui.text_size(ui_context, item.detail)
			item.detail_pixel_width = width
		}
	}
}

// Auto-close when the cursor wanders off the trigger.
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
	case u32(cursor.cursor_column + 1) < state.anchor_column:
		close_reason = true
	}

	if !close_reason { return false }
	close(state)
	return true
}

// Called from the editor's text-input path so the popup tracks what
// the user is typing while it's open.
consume_text :: proc(state: ^State, input_text: string) -> (consumed: bool, needs_redraw: bool) {
	if !state.visible || state.request_pending { return false, false }
	if len(input_text) == 0                    { return false, false }
	for byte_value in transmute([]u8)input_text { append(&state.filter_buffer, byte_value) }
	state.selected_index = 0
	state.scroll_offset  = 0
	return false, true
}

consume_backspace :: proc(state: ^State) -> (consumed: bool, needs_redraw: bool) {
	if !state.visible || state.request_pending { return false, false }
	if len(state.filter_buffer) == 0           { return false, false }
	new_end := len(state.filter_buffer) - 1
	for new_end > 0 && (state.filter_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
	resize(&state.filter_buffer, new_end)
	return false, true
}
