// Event handling + render for the F3 git history dialog.
package git_history

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F3:
			close(state)
			return nil, true

		case sdl3.K_TAB:
			if shift_held { focus_prev(state) } else { focus_next(state) }
			return nil, true

		case sdl3.K_UP:
			if state.focus == .List { move_selection(state, -1); return nil, true }
		case sdl3.K_DOWN:
			if state.focus == .List { move_selection(state,  1); return nil, true }
		case sdl3.K_PAGEUP:
			if state.focus == .List {
				step := state.visible_row_count; if step < 1 { step = 1 }
				move_selection(state, -step)
				return nil, true
			}
		case sdl3.K_PAGEDOWN:
			if state.focus == .List {
				step := state.visible_row_count; if step < 1 { step = 1 }
				move_selection(state, step)
				return nil, true
			}
		case sdl3.K_HOME:
			if state.focus == .List { move_selection(state, -len(state.entries)); return nil, true }
		case sdl3.K_END:
			if state.focus == .List { move_selection(state,  len(state.entries)); return nil, true }

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .List, .OkButton:
				intent = try_activate(state)
				if intent != nil { close(state); return intent, true }
				return nil, false
			case .CancelButton:
				close(state)
				return nil, true
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return nil, false }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.list_rectangle, mouse_x, mouse_y):
			state.focus = .List
			if state.visible_row_count > 0 && state.list_rectangle.h > 0 {
				row_height := state.list_rectangle.h / f32(state.visible_row_count)
				if row_height > 0 {
					relative_y := mouse_y - state.list_rectangle.y
					if relative_y >= 0 {
						row_index_in_view := int(relative_y / row_height)
						target_index := state.scroll_offset + row_index_in_view
						if target_index >= 0 && target_index < len(state.entries) {
							state.selected_index = target_index
						}
					}
				}
			}
			return nil, true
		case ui.point_in_rect(state.ok_rectangle,     mouse_x, mouse_y):
			state.focus = .OkButton
			intent = try_activate(state)
			if intent != nil { close(state); return intent, true }
			return nil, true
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			close(state)
			return nil, true
		}

	case .MOUSE_WHEEL:
		if state.visible_row_count > 0 && len(state.entries) > 0 {
			scroll_delta := -int(event.wheel.y * 3)
			max_offset   := max(0, len(state.entries) - state.visible_row_count)
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

render :: proc(state: ^State, ui_context: ^ui.Context, title_subject: string, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := ui_context.character_width
	line_height     := ui_context.line_height

	dialog_width  := min(110 * character_width + 32, viewport_width  - 40)
	dialog_height := min(30  * line_height     + 60, viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 240 { dialog_height = min(viewport_height - 16, 240) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title: string
	if len(title_subject) > 0 {
		title = fmt.tprintf("Git History — %s", title_subject)
	} else {
		title = "Git History"
	}
	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, title, theme)

	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	if len(state.error_message) > 0 {
		ui.draw_text(ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_height + 6
	}

	button_width:  i32 = 14 * character_width
	button_height: i32 = line_height + 12
	button_gap:    i32 = 8
	button_y := i32(dialog_rectangle.y + dialog_rectangle.h) - button_height - line_height - 22

	buttons_total_width := button_width * 2 + button_gap
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2
	state.ok_rectangle     = sdl3.FRect{f32(buttons_start_x),                              f32(button_y), f32(button_width), f32(button_height)}
	state.cancel_rectangle = sdl3.FRect{f32(buttons_start_x + button_width + button_gap), f32(button_y), f32(button_width), f32(button_height)}

	list_top_y       := content_y
	list_bottom_y    := button_y - 12
	list_area_height := list_bottom_y - list_top_y
	if list_area_height < line_height { list_area_height = line_height }
	visible_rows := int(list_area_height / line_height)
	if visible_rows < 1 { visible_rows = 1 }
	state.visible_row_count = visible_rows
	state.list_rectangle = sdl3.FRect{f32(content_x), f32(list_top_y), f32(content_width), f32(list_area_height)}

	max_scroll_offset := max(0, len(state.entries) - visible_rows)
	if state.scroll_offset > max_scroll_offset { state.scroll_offset = max_scroll_offset }
	if state.scroll_offset < 0                 { state.scroll_offset = 0 }

	if len(state.entries) == 0 {
		if len(state.error_message) == 0 {
			ui.draw_text(ui_context, "(no commits)", content_x + 8, list_top_y, theme.dim_foreground)
		}
	} else {
		end_row_index := min(state.scroll_offset + visible_rows, len(state.entries))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry := state.entries[row_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_height
			is_selected := row_index == state.selected_index && state.focus == .List

			date_display := entry.date
			if len(date_display) > 16 {
				date_display = date_display[:16]
			}
			date_display, _ = strings.replace_all(date_display, "T", " ", context.temp_allocator)

			row_label := fmt.tprintf("%s  %s  %-20s  %s", entry.short_hash, date_display, entry.author, entry.subject)
			ui.draw_list_row(ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	ui.draw_button(ui_context, state.ok_rectangle,     "OK",     state.focus == .OkButton,     theme)
	ui.draw_button(ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)

	footer_text := "↑/↓ navigate    Enter open in opposite pane    Esc cancel"
	footer_width, _ := ui.text_size(ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_height - 8
	ui.draw_text(ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}
