package editor

import "vendor:sdl3"

import "../ui"

// State for the "Are you sure you want to close the terminal?" prompt that
// gates F9-when-terminal-is-open. Keeping it as its own little modal — same
// shape as help / browse / symbols — means the existing modal-dispatch
// machinery in editor_handle_event picks it up without special-casing.
@(private)
TerminalCloseConfirm :: struct {
	yes_is_focused:     bool,       // true == "Yes" button focused, false == "No"
	yes_button_rectangle: sdl3.FRect, // filled in by the renderer for mouse hit-test
	no_button_rectangle:  sdl3.FRect,
}

@(private)
terminal_close_confirm_open :: proc(editor: ^Editor) {
	if _, is_terminal_pane := editor.panes[1].content.(TerminalPane); !is_terminal_pane { return }
	editor.terminal_close_confirm = TerminalCloseConfirm{ yes_is_focused = false } // default to No so an accidental Enter doesn't kill the shell
	editor.show_terminal_close_confirm = true
}

@(private)
terminal_close_confirm_dismiss :: proc(editor: ^Editor) {
	editor.show_terminal_close_confirm = false
}

@(private)
terminal_close_confirm_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	confirm_state := &editor.terminal_close_confirm

	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_N:
			terminal_close_confirm_dismiss(editor)
		case sdl3.K_Y:
			terminal_close_confirm_dismiss(editor)
			editor_close_terminal(editor)
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			terminal_close_confirm_dismiss(editor)
			if confirm_state.yes_is_focused { editor_close_terminal(editor) }
		case sdl3.K_LEFT, sdl3.K_RIGHT, sdl3.K_TAB:
			confirm_state.yes_is_focused = !confirm_state.yes_is_focused
		}

	case .MOUSE_BUTTON_DOWN:
		mouse_x := event.button.x
		mouse_y := event.button.y
		if ui.point_in_rect(confirm_state.yes_button_rectangle, mouse_x, mouse_y) {
			terminal_close_confirm_dismiss(editor)
			editor_close_terminal(editor)
			return
		}
		if ui.point_in_rect(confirm_state.no_button_rectangle, mouse_x, mouse_y) {
			terminal_close_confirm_dismiss(editor)
		}

	case .MOUSE_MOTION:
		// Move focus to whichever button the cursor is over so the keyboard
		// state matches what the user sees highlighted.
		mouse_x := event.motion.x
		mouse_y := event.motion.y
		if ui.point_in_rect(confirm_state.yes_button_rectangle, mouse_x, mouse_y) { confirm_state.yes_is_focused = true  }
		if ui.point_in_rect(confirm_state.no_button_rectangle,  mouse_x, mouse_y) { confirm_state.yes_is_focused = false }
	}
}

@(private)
terminal_close_confirm_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	// Compact dialog: title strip + one question line + a row with two
	// buttons. Sized in cells so it scales with the editor's font.
	character_width_f, line_height_f := f32(editor.character_width), f32(editor.line_height)

	dialog_width := f32(64) * character_width_f
	if dialog_width > f32(viewport_width) - 60  { dialog_width = f32(viewport_width) - 60 }
	if dialog_width < 320                       { dialog_width = 320 }
	dialog_height := line_height_f*2 + 24 + line_height_f + 12 + 36 + 50 // title + question + spacer + buttons + bottom padding
	if dialog_height > f32(viewport_height) - 60 { dialog_height = f32(viewport_height) - 60 }

	dialog_x := (f32(viewport_width)  - dialog_width) / 2
	dialog_y := (f32(viewport_height) - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{ dialog_x, dialog_y, dialog_width, dialog_height }

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Close terminal", theme)

	question_text := "Closing the terminal will end the running shell."
	hint_text     := "Are you sure?"
	ui.draw_text(&ui_context, question_text, i32(content_rectangle.x), i32(content_rectangle.y), theme.text_foreground)
	ui.draw_text(&ui_context, hint_text,     i32(content_rectangle.x), i32(content_rectangle.y) + editor.line_height + 6, theme.dim_foreground)

	confirm_state := &editor.terminal_close_confirm

	// Two buttons, right-aligned, "No" on the right closest to the user's
	// thumb the way native dialogs lay them out on Windows.
	button_width  := f32(96)
	button_height := f32(32)
	button_gap    := f32(12)
	no_button_x  := content_rectangle.x + content_rectangle.w - button_width
	yes_button_x := no_button_x - button_width - button_gap
	button_y     := content_rectangle.y + content_rectangle.h - button_height - 32
	confirm_state.yes_button_rectangle = sdl3.FRect{ yes_button_x, button_y, button_width, button_height }
	confirm_state.no_button_rectangle  = sdl3.FRect{ no_button_x,  button_y, button_width, button_height }

	ui.draw_button(&ui_context, confirm_state.yes_button_rectangle, "Yes",  confirm_state.yes_is_focused,  theme)
	ui.draw_button(&ui_context, confirm_state.no_button_rectangle,  "No",  !confirm_state.yes_is_focused,  theme)

	footer_text := "←/→ or Tab to switch    Enter confirms    Esc cancels"
	footer_width, _ := ui.text_size(&ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - editor.line_height - 8
	ui.draw_text(&ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}
