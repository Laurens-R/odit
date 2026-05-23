// Key-driven dispatch + render for the completion popup.
package completion_popup

import "vendor:sdl3"

import "../../ui"

// Per-keypress dispatch. Returns:
//   intent       — Accept on Enter/Tab; nil otherwise.
//   consumed     — true when the key should NOT propagate to the doc
//                  (arrows / Enter / Esc). Filter typing goes through
//                  `consume_text` instead.
//   needs_redraw — anything visible changed.
handle_key :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, consumed: bool, needs_redraw: bool) {
	if !state.visible { return nil, false, false }
	if event.type != .KEY_DOWN { return nil, false, false }

	switch event.key.key {
	case sdl3.K_ESCAPE:
		close(state)
		return nil, true, true
	case sdl3.K_UP:
		move_selection(state, -1)
		return nil, true, true
	case sdl3.K_DOWN:
		move_selection(state, +1)
		return nil, true, true
	case sdl3.K_PAGEUP:
		move_selection(state, -8)
		return nil, true, true
	case sdl3.K_PAGEDOWN:
		move_selection(state, +8)
		return nil, true, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER, sdl3.K_TAB:
		accept_intent, ok := try_accept(state)
		if !ok {
			close(state)
			return nil, false, true
		}
		close(state)
		return accept_intent, true, true
	}
	return nil, false, false
}

render :: proc(state: ^State, ui_context: ^ui.Context, chrome: Chrome, anchor: AnchorScreenPosition, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	renderer := ui_context.renderer
	if renderer == nil { return }

	// Items polled from the LSP layer outside the render loop have
	// no font available — fill in any missing pixel widths now.
	ensure_item_widths_measured(state, ui_context)

	filtered := filtered_indices(state); defer delete(filtered)

	visible_lines := len(filtered)
	if visible_lines > 12 { visible_lines = 12 }
	stub_message := ""
	if state.request_pending     { stub_message = "loading…" }
	else if visible_lines == 0   { stub_message = "no completions" }

	line_step          := anchor.cursor_line_height
	character_width    := anchor.character_width
	horizontal_padding: i32 = 8
	popup_min_width:    i32 = 28 * character_width
	popup_max_width:    i32 = 60 * character_width

	max_label_width:  i32 = 0
	max_detail_width: i32 = 0
	if len(stub_message) > 0 {
		stub_width, _ := ui.text_size(ui_context, stub_message)
		max_label_width = stub_width
	} else {
		for index in filtered {
			item := &state.items_snapshot[index]
			if item.label_pixel_width  > max_label_width  { max_label_width  = item.label_pixel_width }
			if item.detail_pixel_width > max_detail_width { max_detail_width = item.detail_pixel_width }
		}
	}

	gap_between_columns: i32 = max_detail_width > 0 ? 16 : 0
	popup_width := horizontal_padding * 2 + max_label_width + gap_between_columns + max_detail_width
	if popup_width < popup_min_width { popup_width = popup_min_width }
	if popup_width > popup_max_width { popup_width = popup_max_width }

	row_count := visible_lines
	if len(stub_message) > 0 { row_count = 1 }
	popup_height := i32(row_count) * line_step + 8

	popup_y := anchor.cursor_screen_top_y + line_step + 2
	if popup_y + popup_height > viewport_height - 4 {
		popup_y = anchor.cursor_screen_top_y - popup_height - 2
		if popup_y < 4 { popup_y = 4 }
	}
	popup_x := anchor.cursor_screen_x
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	panel_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}
	sdl3.SetRenderDrawColorFloat(renderer, chrome.background.r, chrome.background.g, chrome.background.b, chrome.background.a)
	sdl3.RenderFillRect(renderer, &panel_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, chrome.border.r, chrome.border.g, chrome.border.b, chrome.border.a)
	sdl3.RenderRect(renderer, &panel_rectangle)

	if len(stub_message) > 0 {
		ui.draw_text(ui_context, stub_message, popup_x + horizontal_padding, popup_y + 4, chrome.stub)
		return
	}

	if state.selected_index < state.scroll_offset                  { state.scroll_offset = state.selected_index }
	if state.selected_index >= state.scroll_offset + visible_lines { state.scroll_offset = state.selected_index - visible_lines + 1 }
	if state.scroll_offset < 0 { state.scroll_offset = 0 }

	end_row := state.scroll_offset + visible_lines
	if end_row > len(filtered) { end_row = len(filtered) }

	for visible_row_index in state.scroll_offset..<end_row {
		item := state.items_snapshot[filtered[visible_row_index]]
		row_y := popup_y + 4 + i32(visible_row_index - state.scroll_offset) * line_step
		is_selected := visible_row_index == state.selected_index
		if is_selected {
			highlight_rectangle := sdl3.FRect{f32(popup_x + 2), f32(row_y), f32(popup_width - 4), f32(line_step)}
			sdl3.SetRenderDrawColorFloat(renderer, chrome.selection.r, chrome.selection.g, chrome.selection.b, chrome.selection.a)
			sdl3.RenderFillRect(renderer, &highlight_rectangle)
		}
		label_color  := is_selected ? chrome.label_selected : chrome.label
		ui.draw_text(ui_context, item.label, popup_x + horizontal_padding, row_y, label_color)
		if len(item.detail) > 0 {
			detail_x := popup_x + popup_width - horizontal_padding
			detail_x -= item.detail_pixel_width
			if detail_x < popup_x + horizontal_padding + max_label_width + gap_between_columns {
				detail_x = popup_x + horizontal_padding + max_label_width + gap_between_columns
			}
			ui.draw_text(ui_context, item.detail, detail_x, row_y, chrome.detail)
		}
	}
}
