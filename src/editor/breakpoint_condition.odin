package editor

import "core:strings"
import "vendor:sdl3"

import "../ui"

// Single-input modal for setting or editing the condition string of one
// breakpoint. Opened by Shift+click in the gutter. An empty condition on
// commit turns the breakpoint back into an unconditional one (and creates
// it if none was there); cancelling preserves whatever was there before.
//
// Shape mirrors `save_close.odin`'s SaveAsDialog: one text-input + OK +
// Cancel, focus cycle on Tab, Enter triggers OK, Esc closes.

@(private)
BreakpointConditionFocus :: enum {
	Input,
	OkButton,
	CancelButton,
}

@(private)
BreakpointConditionDialog :: struct {
	focus:           BreakpointConditionFocus,
	file_path:       string, // owned; locked at open time so a pane switch can't redirect the write
	line:            u32,    // 0-based document line
	had_breakpoint:  bool,   // tracked so the title can say Edit vs Add
	input_buffer:    [dynamic]u8,

	input_rectangle:  sdl3.FRect,
	ok_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

// --- Lifecycle -----------------------------------------------------------

@(private)
breakpoint_condition_dialog_destroy :: proc(state: ^BreakpointConditionDialog) {
	if cap(state.input_buffer) > 0 { delete(state.input_buffer) }
	if len(state.file_path)    > 0 { delete(state.file_path)    }
	state^ = BreakpointConditionDialog{}
}

@(private)
breakpoint_condition_dialog_open :: proc(editor: ^Editor, file_path: string, line: u32) {
	if len(file_path) == 0 { return }
	state := &editor.breakpoint_condition_dialog

	// Reset prior open state — `file_path` is the only owned heap field we
	// have to swap; the buffer can be reused in place.
	if len(state.file_path) > 0 { delete(state.file_path) }
	state.file_path = strings.clone(file_path)
	state.line      = line
	state.focus     = .Input
	clear(&state.input_buffer)

	existing_condition, has_bp := breakpoint_condition_at(editor, file_path, line)
	state.had_breakpoint = has_bp
	for byte_value in transmute([]u8)existing_condition { append(&state.input_buffer, byte_value) }

	editor.show_breakpoint_condition = true
}

@(private)
breakpoint_condition_dialog_close :: proc(editor: ^Editor) {
	editor.show_breakpoint_condition = false
}

@(private="file")
breakpoint_condition_focus_next :: proc(state: ^BreakpointConditionDialog) {
	switch state.focus {
	case .Input:        state.focus = .OkButton
	case .OkButton:     state.focus = .CancelButton
	case .CancelButton: state.focus = .Input
	}
}

@(private="file")
breakpoint_condition_focus_prev :: proc(state: ^BreakpointConditionDialog) {
	switch state.focus {
	case .Input:        state.focus = .CancelButton
	case .OkButton:     state.focus = .Input
	case .CancelButton: state.focus = .OkButton
	}
}

@(private="file")
breakpoint_condition_dialog_commit :: proc(editor: ^Editor) {
	state := &editor.breakpoint_condition_dialog
	if len(state.file_path) == 0 { return }
	condition_text := strings.trim_space(string(state.input_buffer[:]))
	breakpoint_set_condition_at(editor, state.file_path, state.line, condition_text)
	breakpoint_condition_dialog_close(editor)
}

// --- Event handling ------------------------------------------------------

@(private)
breakpoint_condition_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	state := &editor.breakpoint_condition_dialog

	#partial switch event.type {
	case .TEXT_INPUT:
		if state.focus == .Input {
			input_text := string(event.text.text)
			for byte_value in transmute([]u8)input_text {
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(&state.input_buffer, byte_value)
			}
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			breakpoint_condition_dialog_close(editor)

		case sdl3.K_TAB:
			if shift_held { breakpoint_condition_focus_prev(state) } else { breakpoint_condition_focus_next(state) }

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .Input, .OkButton:
				breakpoint_condition_dialog_commit(editor)
			case .CancelButton:
				breakpoint_condition_dialog_close(editor)
			}

		case sdl3.K_BACKSPACE:
			if state.focus == .Input {
				buffer_length := len(state.input_buffer)
				if buffer_length > 0 {
					new_end := buffer_length - 1
					for new_end > 0 && (state.input_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
					resize(&state.input_buffer, new_end)
				}
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.input_rectangle,  mouse_x, mouse_y):
			state.focus = .Input
		case ui.point_in_rect(state.ok_rectangle,     mouse_x, mouse_y):
			state.focus = .OkButton
			breakpoint_condition_dialog_commit(editor)
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			breakpoint_condition_dialog_close(editor)
		}
	}
}

// --- Render --------------------------------------------------------------

@(private)
breakpoint_condition_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	state := &editor.breakpoint_condition_dialog

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := editor.character_width
	line_height     := editor.line_height

	dialog_width  := min(64 * character_width + 32, viewport_width  - 40)
	dialog_height := min(6 * line_height      + 60, viewport_height - 40)
	if dialog_width  < 360 { dialog_width  = min(viewport_width  - 16, 360) }
	if dialog_height < 160 { dialog_height = min(viewport_height - 16, 160) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title := state.had_breakpoint ? "Edit breakpoint condition" : "Add conditional breakpoint"
	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, title, theme)

	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	condition_text := string(state.input_buffer[:])
	input_y := content_y
	state.input_rectangle = sdl3.FRect{ f32(content_x), f32(input_y), f32(content_width), f32(line_height + 4) }
	ui.draw_input_field(&ui_context, content_x, input_y, content_width, "Condition: ", condition_text, theme, state.focus == .Input)

	button_width  := 8 * character_width + 16
	button_height := line_height + 8
	button_gap   : i32 = 8
	row_y := i32(dialog_rectangle.y + dialog_rectangle.h) - button_height - 16
	ok_x  := i32(dialog_rectangle.x + dialog_rectangle.w) - 2 * button_width - button_gap - 16
	cancel_x := ok_x + button_width + button_gap
	state.ok_rectangle     = sdl3.FRect{ f32(ok_x),     f32(row_y), f32(button_width), f32(button_height) }
	state.cancel_rectangle = sdl3.FRect{ f32(cancel_x), f32(row_y), f32(button_width), f32(button_height) }
	ui.draw_button(&ui_context, state.ok_rectangle,     "OK",     state.focus == .OkButton,     theme)
	ui.draw_button(&ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)

	hint_text := "Empty condition = unconditional. Enter commits, Esc cancels."
	ui.draw_text(&ui_context, hint_text, content_x, row_y - line_height - 4, theme.dim_foreground)
}
