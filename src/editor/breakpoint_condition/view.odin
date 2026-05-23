// Input event handling + render. Both share enough geometry (the
// hit-test rects rewritten by the renderer feed the mouse handler)
// that splitting further would be friction; everything that ISN'T
// either of those lives in `state.odin`.
package breakpoint_condition

import "vendor:sdl3"

import "../../ui"

// Single SDL event dispatch. Pure: returns an Intent on submission,
// or `needs_redraw` for state changes the host should react to.
// Callers that prefer the host-callback flow use `dispatch_event` in
// `dispatch.odin` instead; this is the lower-level entry point.
handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .TEXT_INPUT:
		if state.focus == .Input {
			input_text := string(event.text.text)
			for byte_value in transmute([]u8)input_text {
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(&state.input_buffer, byte_value)
			}
			return nil, true
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			close(state)
			return nil, true

		case sdl3.K_TAB:
			if shift_held { focus_prev(state) } else { focus_next(state) }
			return nil, true

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .Input, .OkButton:
				return try_commit(state)
			case .CancelButton:
				close(state)
				return nil, true
			}

		case sdl3.K_BACKSPACE:
			if state.focus == .Input {
				buffer_length := len(state.input_buffer)
				if buffer_length > 0 {
					new_end := buffer_length - 1
					for new_end > 0 && (state.input_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
					resize(&state.input_buffer, new_end)
					return nil, true
				}
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return nil, false }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.input_rectangle,  mouse_x, mouse_y):
			state.focus = .Input
			return nil, true
		case ui.point_in_rect(state.ok_rectangle,     mouse_x, mouse_y):
			state.focus = .OkButton
			return try_commit(state)
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			close(state)
			return nil, true
		}
	}
	return nil, false
}

// Paint the dialog. No-op when `state.visible` is false so callers can
// dispatch unconditionally.
render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := ui_context.character_width
	line_height     := ui_context.line_height

	dialog_width  := min(64 * character_width + 32, viewport_width  - 40)
	dialog_height := min(6 * line_height      + 60, viewport_height - 40)
	if dialog_width  < 360 { dialog_width  = min(viewport_width  - 16, 360) }
	if dialog_height < 160 { dialog_height = min(viewport_height - 16, 160) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title := state.had_breakpoint ? "Edit breakpoint condition" : "Add conditional breakpoint"
	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, title, theme)

	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	condition_text := string(state.input_buffer[:])
	input_y := content_y
	state.input_rectangle = sdl3.FRect{ f32(content_x), f32(input_y), f32(content_width), f32(line_height + 4) }
	ui.draw_input_field(ui_context, content_x, input_y, content_width, "Condition: ", condition_text, theme, state.focus == .Input)

	button_width  := 8 * character_width + 16
	button_height := line_height + 8
	button_gap   : i32 = 8
	row_y := i32(dialog_rectangle.y + dialog_rectangle.h) - button_height - 16
	ok_x  := i32(dialog_rectangle.x + dialog_rectangle.w) - 2 * button_width - button_gap - 16
	cancel_x := ok_x + button_width + button_gap
	state.ok_rectangle     = sdl3.FRect{ f32(ok_x),     f32(row_y), f32(button_width), f32(button_height) }
	state.cancel_rectangle = sdl3.FRect{ f32(cancel_x), f32(row_y), f32(button_width), f32(button_height) }
	ui.draw_button(ui_context, state.ok_rectangle,     "OK",     state.focus == .OkButton,     theme)
	ui.draw_button(ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)

	hint_text := "Empty condition = unconditional. Enter commits, Esc cancels."
	ui.draw_text(ui_context, hint_text, content_x, row_y - line_height - 4, theme.dim_foreground)
}
