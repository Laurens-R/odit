// Event handling + render for the Ctrl+Shift+F find-in-files dialog.
package find_in_files

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .TEXT_INPUT:
		if buffer := focused_buffer(state); buffer != nil {
			input_text := string(event.text.text)
			if len(input_text) > 0 {
				buffer_append(buffer, input_text)
				return nil, true
			}
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		if ctrl_held && shift_held && pressed_key == sdl3.K_F {
			close(state)
			return nil, true
		}

		switch pressed_key {
		case sdl3.K_ESCAPE:
			close(state)
			return nil, true

		case sdl3.K_TAB:
			if shift_held { focus_prev(state) } else { focus_next(state) }
			return nil, true

		case sdl3.K_RETURN:
			switch state.focus {
			case .PathInput, .QueryInput, .FindButton:
				return try_execute(state), true
			case .ClearButton:
				clear_action(state)
				return nil, true
			case .CancelButton:
				close(state)
				return nil, true
			case .Results:
				return try_activate(state), true
			}

		case sdl3.K_BACKSPACE:
			if buffer := focused_buffer(state); buffer != nil {
				buffer_backspace(buffer)
				return nil, true
			}

		case sdl3.K_UP:
			if state.focus == .Results { move_selection(state, -1); return nil, true }

		case sdl3.K_DOWN:
			if state.focus == .Results { move_selection(state, +1); return nil, true }

		case sdl3.K_PAGEUP:
			if state.focus == .Results {
				step := state.visible_row_count; if step < 1 { step = 1 }
				move_selection(state, -step)
				return nil, true
			}

		case sdl3.K_PAGEDOWN:
			if state.focus == .Results {
				step := state.visible_row_count; if step < 1 { step = 1 }
				move_selection(state, +step)
				return nil, true
			}

		case sdl3.K_HOME:
			if state.focus == .Results { move_selection(state, -len(state.results)); return nil, true }

		case sdl3.K_END:
			if state.focus == .Results { move_selection(state, +len(state.results)); return nil, true }
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return nil, false }
		mouse_x, mouse_y := event.button.x, event.button.y

		if ui.scrollbar_thumb_hit(&state.results_scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_thumb_drag(&state.results_scrollbar, mouse_y)
			return nil, false
		}
		if ui.scrollbar_track_hit(&state.results_scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_track_drag(&state.results_scrollbar)
			apply_scrollbar_drag(state, mouse_y)
			return nil, true
		}

		switch {
		case ui.point_in_rect(state.path_field_rectangle,    mouse_x, mouse_y):
			state.focus = .PathInput
			return nil, true
		case ui.point_in_rect(state.query_field_rectangle,   mouse_x, mouse_y):
			state.focus = .QueryInput
			return nil, true
		case ui.point_in_rect(state.find_button_rectangle,   mouse_x, mouse_y):
			state.focus = .FindButton
			return try_execute(state), true
		case ui.point_in_rect(state.clear_button_rectangle,  mouse_x, mouse_y):
			state.focus = .ClearButton
			clear_action(state)
			return nil, true
		case ui.point_in_rect(state.cancel_button_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			close(state)
			return nil, true
		case ui.point_in_rect(state.results_list_rectangle,  mouse_x, mouse_y):
			state.focus = .Results
			if state.cached_line_height > 0 {
				row_height := f32(state.cached_line_height)
				relative_y := mouse_y - state.results_list_rectangle.y
				if relative_y >= 0 {
					row_index_in_view := int(relative_y / row_height)
					target_index := state.scroll_offset + row_index_in_view
					if target_index >= 0 && target_index < len(state.results) {
						state.selected_index = target_index
						return try_activate(state), true
					}
				}
			}
			return nil, true
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT && state.results_scrollbar.is_dragging {
			ui.scrollbar_end_drag(&state.results_scrollbar)
			return nil, true
		}

	case .MOUSE_MOTION:
		if state.results_scrollbar.is_dragging {
			apply_scrollbar_drag(state, event.motion.y)
			return nil, true
		}
		if ui.scrollbar_update_hover(&state.results_scrollbar, event.motion.x, event.motion.y) {
			return nil, true
		}

	case .MOUSE_WHEEL:
		if state.visible_row_count > 0 && len(state.results) > 0 {
			scroll_delta := -int(event.wheel.y * 3)
			max_offset   := max(0, len(state.results) - state.visible_row_count)
			new_offset   := state.scroll_offset + scroll_delta
			if new_offset < 0          { new_offset = 0 }
			if new_offset > max_offset { new_offset = max_offset }
			if new_offset != state.scroll_offset {
				state.scroll_offset = new_offset
				return nil, true
			}
		}
	}
	return nil, false
}

render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	line_step       := ui_context.line_height
	character_width := ui_context.character_width
	state.cached_line_height = line_step

	desired_columns: i32 = 110
	desired_rows:    i32 = 36
	dialog_width  := min(desired_columns * character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows    * line_step       + 40, viewport_height - 40)
	if dialog_width  < 280 { dialog_width  = min(viewport_width  - 16, 280) }
	if dialog_height < 240 { dialog_height = min(viewport_height - 16, 240) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Find in Files", theme)

	content_x       := i32(content_rectangle.x)
	content_y       := i32(content_rectangle.y)
	content_width   := i32(content_rectangle.w)

	state.path_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Path:   ", string(state.path_buffer[:]), theme, state.focus == .PathInput)
	content_y += line_step + 14

	state.query_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Search: ", string(state.query_buffer[:]), theme, state.focus == .QueryInput)
	content_y += line_step + 14

	button_width:  i32 = 14 * character_width
	button_height: i32 = line_step + 12
	button_gap:    i32 = 8
	buttons_total_width := button_width * 3 + button_gap * 2
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2

	state.find_button_rectangle   = sdl3.FRect{f32(buttons_start_x),                                    f32(content_y), f32(button_width), f32(button_height)}
	state.clear_button_rectangle  = sdl3.FRect{f32(buttons_start_x + (button_width + button_gap) * 1), f32(content_y), f32(button_width), f32(button_height)}
	state.cancel_button_rectangle = sdl3.FRect{f32(buttons_start_x + (button_width + button_gap) * 2), f32(content_y), f32(button_width), f32(button_height)}

	ui.draw_button(ui_context, state.find_button_rectangle,   "Find",   state.focus == .FindButton,   theme)
	ui.draw_button(ui_context, state.clear_button_rectangle,  "Clear",  state.focus == .ClearButton,  theme)
	ui.draw_button(ui_context, state.cancel_button_rectangle, "Cancel", state.focus == .CancelButton, theme)

	content_y += button_height + 12

	if len(state.error_message) > 0 {
		ui.draw_text(ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_step + 4
	}

	footer_height: i32 = line_step + 12
	list_top_y    := content_y
	list_bottom_y := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	if list_area_height < line_step { list_area_height = line_step }
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	state.results_list_rectangle = sdl3.FRect{f32(content_x), f32(list_top_y), f32(content_width), f32(list_area_height)}

	max_scroll_offset := max(0, len(state.results) - computed_visible_rows)
	if state.scroll_offset > max_scroll_offset { state.scroll_offset = max_scroll_offset }
	if state.scroll_offset < 0                 { state.scroll_offset = 0 }

	scrollbar_reservation: i32 = ui.SCROLLBAR_NARROW_WIDTH + 2
	row_width := content_width - scrollbar_reservation
	if row_width < character_width { row_width = character_width }

	if len(state.results) == 0 {
		empty_message: string
		if len(state.query_buffer) == 0 {
			empty_message = "(enter a query and press Find)"
		} else if len(state.error_message) == 0 {
			empty_message = "(no results)"
		}
		if len(empty_message) > 0 {
			ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
		}
	} else {
		label_indent_pixels: i32 = 8
		right_margin_pixels: i32 = 8
		usable_pixels := row_width - label_indent_pixels - right_margin_pixels
		if usable_pixels < character_width { usable_pixels = character_width }
		max_chars_per_row := int(usable_pixels / character_width)

		padded_prefix_chars := state.max_prefix_chars + 2
		if padded_prefix_chars > max_chars_per_row - 8 { padded_prefix_chars = max_chars_per_row - 8 }
		if padded_prefix_chars < 1                     { padded_prefix_chars = 1 }

		end_row_index := min(state.scroll_offset + computed_visible_rows, len(state.results))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			result := state.results[row_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
			is_selected := row_index == state.selected_index && state.focus == .Results

			prefix_string := fmt.tprintf("%s:%d:%d", result.relative_path, result.line + 1, result.column + 1)
			prefix_chars := utf8.rune_count_in_string(prefix_string)
			padding_chars := padded_prefix_chars - prefix_chars
			if padding_chars < 1 { padding_chars = 1 }
			padding_string := strings.repeat(" ", padding_chars, context.temp_allocator)

			combined_row := strings.concatenate({prefix_string, padding_string, result.snippet}, context.temp_allocator)
			row_label := truncate_to_runes_with_ellipsis(combined_row, max_chars_per_row)

			ui.draw_list_row(ui_context, content_x, row_y_position, row_width, row_label, is_selected, theme)
		}
	}

	total_rows := len(state.results)
	if total_rows > 0 {
		content_height_pixels  := f32(total_rows * int(line_step))
		viewport_height_pixels := f32(list_area_height)
		current_scroll_pixels  := f32(state.scroll_offset * int(line_step))
		ui.scrollbar_render(ui_context, &state.results_scrollbar,
			content_x + content_width, list_top_y, list_area_height,
			viewport_height_pixels, content_height_pixels, current_scroll_pixels, theme)
	} else {
		state.results_scrollbar.track_rectangle = sdl3.FRect{}
		state.results_scrollbar.thumb_rectangle = sdl3.FRect{}
	}

	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	hint_text := "Tab focus  Enter find/open  ↑/↓ navigate results  Esc close"
	ui.draw_text(ui_context, hint_text, i32(dialog_rectangle.x) + 12, footer_y, theme.dim_foreground)
}
