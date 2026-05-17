package editor

import "vendor:sdl3"

import "../ui"

// State for the "Are you sure you want to close the terminal?" prompt that
// gates F9-when-terminal-is-open. Keeping it as its own little modal — same
// shape as help / browse / symbols — means the existing modal-dispatch
// machinery in editor_handle_event picks it up without special-casing.
@(private)
TerminalCloseConfirm :: struct {
	focus_yes: bool,        // true == "Yes" button focused, false == "No"
	yes_rect:  sdl3.FRect,  // filled in by the renderer for mouse hit-test
	no_rect:   sdl3.FRect,
}

@(private)
terminal_close_confirm_open :: proc(ed: ^Editor) {
	if _, ok := ed.panes[1].content.(TerminalPane); !ok { return }
	ed.terminal_close_confirm = TerminalCloseConfirm{ focus_yes = false } // default to No so an accidental Enter doesn't kill the shell
	ed.show_terminal_close_confirm = true
}

@(private)
terminal_close_confirm_dismiss :: proc(ed: ^Editor) {
	ed.show_terminal_close_confirm = false
}

@(private)
terminal_close_confirm_handle_event :: proc(ed: ^Editor, event: ^sdl3.Event) {
	cc := &ed.terminal_close_confirm

	#partial switch event.type {
	case .KEY_DOWN:
		key := event.key.key
		switch key {
		case sdl3.K_ESCAPE, sdl3.K_N:
			terminal_close_confirm_dismiss(ed)
		case sdl3.K_Y:
			terminal_close_confirm_dismiss(ed)
			editor_close_terminal(ed)
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			terminal_close_confirm_dismiss(ed)
			if cc.focus_yes { editor_close_terminal(ed) }
		case sdl3.K_LEFT, sdl3.K_RIGHT, sdl3.K_TAB:
			cc.focus_yes = !cc.focus_yes
		}

	case .MOUSE_BUTTON_DOWN:
		x := event.button.x
		y := event.button.y
		if ui.point_in_rect(cc.yes_rect, x, y) {
			terminal_close_confirm_dismiss(ed)
			editor_close_terminal(ed)
			return
		}
		if ui.point_in_rect(cc.no_rect, x, y) {
			terminal_close_confirm_dismiss(ed)
		}

	case .MOUSE_MOTION:
		// Move focus to whichever button the cursor is over so the keyboard
		// state matches what the user sees highlighted.
		x := event.motion.x
		y := event.motion.y
		if ui.point_in_rect(cc.yes_rect, x, y) { cc.focus_yes = true  }
		if ui.point_in_rect(cc.no_rect,  x, y) { cc.focus_yes = false }
	}
}

@(private)
terminal_close_confirm_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width, height: i32) {
	ctx := ui.Context{
		renderer    = renderer,
		font        = ed.font,
		engine      = ed.engine,
		char_width  = ed.char_width,
		line_height = ed.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ctx, width, height, theme.overlay)

	// Compact dialog: title strip + one question line + a row with two
	// buttons. Sized in cells so it scales with the editor's font.
	cw, lh := f32(ed.char_width), f32(ed.line_height)

	dialog_w := f32(64) * cw
	if dialog_w > f32(width) - 60  { dialog_w = f32(width) - 60 }
	if dialog_w < 320              { dialog_w = 320 }
	dialog_h := lh*2 + 24 + lh + 12 + 36 + 50 // title + question + spacer + buttons + bottom padding
	if dialog_h > f32(height) - 60 { dialog_h = f32(height) - 60 }

	dx := (f32(width)  - dialog_w) / 2
	dy := (f32(height) - dialog_h) / 2
	rect := sdl3.FRect{ dx, dy, dialog_w, dialog_h }

	content := ui.draw_window(&ctx, rect, "Close terminal", theme)

	question := "Closing the terminal will end the running shell."
	hint     := "Are you sure?"
	ui.draw_text(&ctx, question, i32(content.x), i32(content.y), theme.text_fg)
	ui.draw_text(&ctx, hint,     i32(content.x), i32(content.y) + ed.line_height + 6, theme.dim_fg)

	cc := &ed.terminal_close_confirm

	// Two buttons, right-aligned, "No" on the right closest to the user's
	// thumb the way native dialogs lay them out on Windows.
	btn_w := f32(96)
	btn_h := f32(32)
	gap   := f32(12)
	bx_no  := content.x + content.w - btn_w
	bx_yes := bx_no - btn_w - gap
	by     := content.y + content.h - btn_h - 32
	cc.yes_rect = sdl3.FRect{ bx_yes, by, btn_w, btn_h }
	cc.no_rect  = sdl3.FRect{ bx_no,  by, btn_w, btn_h }

	ui.draw_button(&ctx, cc.yes_rect, "Yes",  cc.focus_yes,  theme)
	ui.draw_button(&ctx, cc.no_rect,  "No",  !cc.focus_yes,  theme)

	foot := "←/→ or Tab to switch    Enter confirms    Esc cancels"
	fw, _ := ui.text_size(&ctx, foot)
	foot_x := i32(rect.x + (rect.w - f32(fw)) / 2)
	foot_y := i32(rect.y + rect.h) - ed.line_height - 8
	ui.draw_text(&ctx, foot, foot_x, foot_y, theme.dim_fg)
}
