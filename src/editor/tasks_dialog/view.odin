// Event handling + render for the F7 Tasks dialog.
package tasks_dialog

import "vendor:sdl3"

import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F7:
			close(state)
			return nil, true
		case sdl3.K_UP:
			move_selection(state, -1)
			return nil, true
		case sdl3.K_DOWN:
			move_selection(state, 1)
			return nil, true
		case sdl3.K_PAGEUP:
			step := state.visible_row_count
			if step < 1 { step = 1 }
			move_selection(state, -step)
			return nil, true
		case sdl3.K_PAGEDOWN:
			step := state.visible_row_count
			if step < 1 { step = 1 }
			move_selection(state, step)
			return nil, true
		case sdl3.K_HOME:
			move_selection(state, -len(state.entries))
			return nil, true
		case sdl3.K_END:
			move_selection(state, len(state.entries))
			return nil, true
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			intent = try_activate(state)
			if intent != nil {
				close(state)
				return intent, true
			}
			return nil, false
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return nil, false }
		mouse_x := event.button.x
		mouse_y := event.button.y
		for row_rect, row_index in state.row_rectangles {
			if ui.point_in_rect(row_rect, mouse_x, mouse_y) {
				state.selected_index = state.scroll_offset + row_index
				intent = try_activate(state)
				if intent != nil {
					close(state)
					return intent, true
				}
				return nil, true
			}
		}
	}
	return nil, false
}

render :: proc(state: ^State, ui_context: ^ui.Context, dialog_title: string, empty_message: string, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 76
	desired_rows:    i32 = 16
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 60,        viewport_height - 40)
	if dialog_width  < 400 { dialog_width  = min(viewport_width  - 16, 400) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, dialog_title, theme)

	line_step     := ui_context.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	count := len(state.entries)
	if state.selected_index < state.scroll_offset {
		state.scroll_offset = state.selected_index
	} else if state.selected_index >= state.scroll_offset + computed_visible_rows {
		state.scroll_offset = state.selected_index - computed_visible_rows + 1
	}
	if state.scroll_offset < 0 { state.scroll_offset = 0 }

	clear(&state.row_rectangles)
	if count == 0 {
		ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		end_row_index := min(state.scroll_offset + computed_visible_rows, count)
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry := state.entries[row_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
			is_selected := row_index == state.selected_index
			row_rect := sdl3.FRect{ f32(content_x), f32(row_y_position), f32(content_width), f32(line_step) }
			ui.draw_list_row(ui_context, content_x, row_y_position, content_width, entry.label, is_selected, theme)
			append(&state.row_rectangles, row_rect)
		}
	}

	hint_text := "↑/↓ navigate    Enter run    Esc / F7 close"
	hint_width, _ := ui.text_size(ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}
