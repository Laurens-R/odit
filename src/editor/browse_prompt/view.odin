// Event handling + render for the rename / new-file sub-modal.
package browse_prompt

import "core:strings"
import "vendor:sdl3"

import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, needs_redraw: bool) {
	#partial switch event.type {
	case .TEXT_INPUT:
		if state.focused_widget == .Input {
			input_text := string(event.text.text)
			if len(input_text) > 0 {
				append_value(state, input_text)
				return nil, true
			}
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
		case sdl3.K_RETURN:
			switch state.focused_widget {
			case .Input, .Primary:
				return try_submit(state)
			case .Cancel:
				close(state); return nil, true
			}
		case sdl3.K_BACKSPACE:
			if state.focused_widget == .Input {
				backspace_value(state)
				return nil, true
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			mouse_x, mouse_y := event.button.x, event.button.y
			switch {
			case ui.point_in_rect(state.input_rectangle, mouse_x, mouse_y):
				state.focused_widget = .Input; return nil, true
			case ui.point_in_rect(state.primary_rectangle, mouse_x, mouse_y):
				state.focused_widget = .Primary
				return try_submit(state)
			case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
				state.focused_widget = .Cancel; close(state); return nil, true
			}
		}
	}
	return nil, false
}

render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	if state.kind == .None { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	popup_width  := min(50 * ui_context.character_width + 32, viewport_width  - 80)
	popup_height := min(8  * ui_context.line_height + 40,     viewport_height - 80)
	if popup_width  < 240 { popup_width  = min(viewport_width  - 16, 240) }
	if popup_height < 160 { popup_height = min(viewport_height - 16, 160) }
	popup_x := (viewport_width  - popup_width)  / 2
	popup_y := (viewport_height - popup_height) / 2
	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}

	title: string
	switch state.kind {
	case .Rename:    title = "Rename"
	case .NewFile:   title = "New File"
	case .NewFolder: title = "New Folder"
	case .None:      title = ""
	}
	content_rectangle := ui.draw_window(ui_context, popup_rectangle, title, theme)

	line_step     := ui_context.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	headline_text: string
	switch state.kind {
	case .Rename:    headline_text = strings.concatenate({`Rename "`, state.target_name, `" to:`}, context.temp_allocator)
	case .NewFile:   headline_text = "New file name:"
	case .NewFolder: headline_text = "New folder name:"
	case .None:      return
	}
	ui.draw_text(ui_context, headline_text, content_x, content_y, theme.text_foreground)
	content_y += line_step + 6

	state.input_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	value_string := string(state.value_buffer[:])
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "", value_string, theme, state.focused_widget == .Input)
	content_y += line_step + 16

	button_width:  i32 = 14 * ui_context.character_width
	button_height: i32 = line_step + 12
	button_gap:    i32 = 8
	total_button_row_width := button_width * 2 + button_gap
	button_start_x := content_x + (content_width - total_button_row_width) / 2
	button_y := i32(popup_rectangle.y + popup_rectangle.h) - button_height - 12

	primary_label: string
	switch state.kind {
	case .Rename:    primary_label = "Rename"
	case .NewFile:   primary_label = "Create"
	case .NewFolder: primary_label = "Create"
	case .None:      primary_label = ""
	}

	state.primary_rectangle = sdl3.FRect{f32(button_start_x),                              f32(button_y), f32(button_width), f32(button_height)}
	state.cancel_rectangle  = sdl3.FRect{f32(button_start_x + button_width + button_gap), f32(button_y), f32(button_width), f32(button_height)}

	ui.draw_button(ui_context, state.primary_rectangle, primary_label, state.focused_widget == .Primary, theme)
	ui.draw_button(ui_context, state.cancel_rectangle,  "Cancel",      state.focused_widget == .Cancel,  theme)
}
