// Event handling + render for the Save-As modal.
package save_as

import "vendor:sdl3"

import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .TEXT_INPUT:
		if state.focus == .PathInput {
			input_text := string(event.text.text)
			for byte_value in transmute([]u8)input_text {
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(&state.path_buffer, byte_value)
			}
			return nil, true
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			close(state); return nil, true

		case sdl3.K_TAB:
			if shift_held { focus_prev(state) } else { focus_next(state) }
			return nil, true

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .PathInput, .OkButton:
				return try_commit(state)
			case .CancelButton:
				close(state); return nil, true
			}

		case sdl3.K_BACKSPACE:
			if state.focus == .PathInput {
				buffer_length := len(state.path_buffer)
				if buffer_length > 0 {
					new_end := buffer_length - 1
					for new_end > 0 && (state.path_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
					resize(&state.path_buffer, new_end)
					return nil, true
				}
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return nil, false }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.input_rectangle,  mouse_x, mouse_y):
			state.focus = .PathInput; return nil, true
		case ui.point_in_rect(state.ok_rectangle,     mouse_x, mouse_y):
			state.focus = .OkButton
			return try_commit(state)
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton; close(state); return nil, true
		}
	}
	return nil, false
}

render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := ui_context.character_width
	line_height     := ui_context.line_height

	dialog_width  := min(80 * character_width + 32, viewport_width  - 40)
	dialog_height := min(10 * line_height     + 60, viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title := state.close_after_save ? "Save before closing" : "Save As"
	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, title, theme)

	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	ui.draw_text(ui_context, "File path:", content_x, content_y, theme.text_foreground)
	content_y += line_height + 6

	state.input_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_height + 4)}
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "", string(state.path_buffer[:]), theme, state.focus == .PathInput)
	content_y += line_height + 14

	if len(state.error_message) > 0 {
		ui.draw_text(ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_height + 4
	}

	button_width:  i32 = 14 * character_width
	button_height: i32 = line_height + 12
	button_gap:    i32 = 8
	buttons_total_width := button_width * 2 + button_gap
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2
	button_y := i32(dialog_rectangle.y + dialog_rectangle.h) - button_height - 16

	state.ok_rectangle     = sdl3.FRect{f32(buttons_start_x),                              f32(button_y), f32(button_width), f32(button_height)}
	state.cancel_rectangle = sdl3.FRect{f32(buttons_start_x + button_width + button_gap), f32(button_y), f32(button_width), f32(button_height)}

	ui.draw_button(ui_context, state.ok_rectangle,     "OK",     state.focus == .OkButton,     theme)
	ui.draw_button(ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)
}
