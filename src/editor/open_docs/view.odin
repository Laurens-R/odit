// Input event handling + render for the F4 open-documents picker.
package open_docs

import "vendor:sdl3"

import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			filter_append(state, input_text)
			needs_redraw = true
		}

	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F4:
			close(state)
			needs_redraw = true
		case sdl3.K_UP:
			move_selection(state, -1); needs_redraw = true
		case sdl3.K_DOWN:
			move_selection(state, 1); needs_redraw = true
		case sdl3.K_PAGEUP:
			step := state.visible_row_count; if step < 1 { step = 1 }
			move_selection(state, -step); needs_redraw = true
		case sdl3.K_PAGEDOWN:
			step := state.visible_row_count; if step < 1 { step = 1 }
			move_selection(state, step); needs_redraw = true
		case sdl3.K_HOME:
			move_selection(state, -len(state.filtered_indices)); needs_redraw = true
		case sdl3.K_END:
			move_selection(state, len(state.filtered_indices)); needs_redraw = true
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			intent = try_activate(state)
			if intent != nil {
				close(state)
				needs_redraw = true
			}
		case sdl3.K_BACKSPACE:
			if filter_backspace(state) { needs_redraw = true }
		}
	}
	return intent, needs_redraw
}

render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()
	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 80
	desired_rows:    i32 = 24
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 40,        viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Open documents", theme)

	line_step     := ui_context.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	filter_string := string(state.filter_buffer[:])
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	if state.selected_index < state.scroll_offset {
		state.scroll_offset = state.selected_index
	} else if state.selected_index >= state.scroll_offset + computed_visible_rows {
		state.scroll_offset = state.selected_index - computed_visible_rows + 1
	}
	if state.scroll_offset < 0 { state.scroll_offset = 0 }

	if len(state.filtered_indices) == 0 {
		empty_message := len(state.filter_buffer) > 0 ? "(no matches)" : "(no other open documents)"
		ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		filtered_view := state.filtered_indices[:]
		end_row_index := min(state.scroll_offset + computed_visible_rows, len(filtered_view))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry_index    := filtered_view[row_index]
			current_entry  := state.entries[entry_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
			is_selected := row_index == state.selected_index
			ui.draw_list_row(ui_context, content_x, row_y_position, content_width, current_entry.label, is_selected, theme, .File)
		}
	}

	hint_text := "↑/↓ navigate    Enter switch    Type to filter    F4/Esc close"
	hint_width, _ := ui.text_size(ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}
