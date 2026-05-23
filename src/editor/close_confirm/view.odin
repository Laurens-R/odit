// Event handling + render for the close-confirm dialog.
package close_confirm

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
		case sdl3.K_ESCAPE:
			close(state); return nil, true
		case sdl3.K_LEFT:
			focus_step(state, -1); return nil, true
		case sdl3.K_RIGHT:
			focus_step(state, +1); return nil, true
		case sdl3.K_TAB:
			focus_step(state, shift_held ? -1 : +1); return nil, true
		case sdl3.K_Y:
			return submit_save(state), true
		case sdl3.K_N:
			return submit_discard(state), true
		case sdl3.K_C:
			close(state); return nil, true
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .YesButton:    return submit_save(state), true
			case .NoButton:     return submit_discard(state), true
			case .CancelButton: close(state); return nil, true
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return nil, false }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.yes_rectangle,    mouse_x, mouse_y):
			return submit_save(state), true
		case ui.point_in_rect(state.no_rectangle,     mouse_x, mouse_y):
			return submit_discard(state), true
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			close(state); return nil, true
		}

	case .MOUSE_MOTION:
		mouse_x, mouse_y := event.motion.x, event.motion.y
		previous_focus := state.focus
		if ui.point_in_rect(state.yes_rectangle,    mouse_x, mouse_y) { state.focus = .YesButton    }
		if ui.point_in_rect(state.no_rectangle,     mouse_x, mouse_y) { state.focus = .NoButton     }
		if ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y) { state.focus = .CancelButton }
		return nil, state.focus != previous_focus
	}
	return nil, false
}

render :: proc(state: ^State, ui_context: ^ui.Context, subject_name: string, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	character_width_f, line_height_f := f32(ui_context.character_width), f32(ui_context.line_height)

	dialog_width := f32(70) * character_width_f
	if dialog_width > f32(viewport_width) - 60 { dialog_width = f32(viewport_width) - 60 }
	if dialog_width < 360                       { dialog_width = 360 }
	dialog_height := line_height_f * 3 + 36 + 36 + 60
	if dialog_height > f32(viewport_height) - 60 { dialog_height = f32(viewport_height) - 60 }
	dialog_x := (f32(viewport_width)  - dialog_width)  / 2
	dialog_y := (f32(viewport_height) - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{ dialog_x, dialog_y, dialog_width, dialog_height }

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Close file", theme)

	question_text := build_question_text(subject_name)
	ui.draw_text(ui_context, question_text, i32(content_rectangle.x), i32(content_rectangle.y), theme.text_foreground)

	button_width  := f32(96)
	button_height := f32(32)
	button_gap    := f32(12)
	buttons_total := button_width * 3 + button_gap * 2
	start_x := content_rectangle.x + (content_rectangle.w - buttons_total) / 2
	button_y := content_rectangle.y + content_rectangle.h - button_height - 32

	state.yes_rectangle    = sdl3.FRect{ start_x,                                      button_y, button_width, button_height }
	state.no_rectangle     = sdl3.FRect{ start_x + button_width + button_gap,          button_y, button_width, button_height }
	state.cancel_rectangle = sdl3.FRect{ start_x + (button_width + button_gap) * 2,    button_y, button_width, button_height }

	ui.draw_button(ui_context, state.yes_rectangle,    "Yes",    state.focus == .YesButton,    theme)
	ui.draw_button(ui_context, state.no_rectangle,     "No",     state.focus == .NoButton,     theme)
	ui.draw_button(ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)

	footer_text := "Y save • N discard • C / Esc cancel    ←/→ or Tab switch    Enter confirms"
	footer_width, _ := ui.text_size(ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - ui_context.line_height - 8
	ui.draw_text(ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}

// Build the question text by hand rather than pulling in core:fmt
// for one printf-style call. Allocates from temp_allocator.
@(private="file")
build_question_text :: proc(subject_name: string) -> string {
	prefix :: "Save changes to "
	suffix :: " before closing?"
	total_length := len(prefix) + len(subject_name) + len(suffix)
	buffer := make([]u8, total_length, context.temp_allocator)
	copy(buffer[:],                                transmute([]u8)string(prefix))
	copy(buffer[len(prefix):],                     transmute([]u8)subject_name)
	copy(buffer[len(prefix) + len(subject_name):], transmute([]u8)string(suffix))
	return string(buffer)
}
