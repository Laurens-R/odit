package terminal

import "vendor:sdl3"

// Translate one SDL event into bytes that get pushed to the shell's stdin.
// We intentionally swallow KEY_UP (PowerShell doesn't care) and pass through
// any TEXT_INPUT verbatim — SDL already gives us UTF-8.
//
// Special keys are turned into the xterm-style escape sequences that
// PowerShell's PSReadLine accepts: arrow keys, Home/End/PgUp/PgDn, function
// keys, and the common control combos (Ctrl-C, Ctrl-D, Ctrl-Z, Ctrl-Break).
terminal_handle_event :: proc(terminal: ^Terminal, event: ^sdl3.Event) {
	if terminal == nil { return }

	#partial switch event.type {
	case .TEXT_INPUT:
		// event.text.text is a NUL-terminated UTF-8 buffer (cstring).
		input_text := string(event.text.text)
		if len(input_text) > 0 { terminal_write_string(terminal, input_text) }

	case .KEY_DOWN:
		key            := event.key.key
		key_modifiers  := event.key.mod

		ctrl_held  := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
		_ = shift_held

		switch key {
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			terminal_write(terminal, []u8{ '\r' })
		case sdl3.K_BACKSPACE:
			terminal_write(terminal, []u8{ 0x7F })
		case sdl3.K_TAB:
			terminal_write(terminal, []u8{ '\t' })
		case sdl3.K_ESCAPE:
			terminal_write(terminal, []u8{ 0x1B })

		case sdl3.K_UP:    terminal_write_string(terminal, "\x1B[A")
		case sdl3.K_DOWN:  terminal_write_string(terminal, "\x1B[B")
		case sdl3.K_RIGHT: terminal_write_string(terminal, "\x1B[C")
		case sdl3.K_LEFT:  terminal_write_string(terminal, "\x1B[D")
		case sdl3.K_HOME:  terminal_write_string(terminal, "\x1B[H")
		case sdl3.K_END:   terminal_write_string(terminal, "\x1B[F")
		case sdl3.K_PAGEUP:   terminal_write_string(terminal, "\x1B[5~")
		case sdl3.K_PAGEDOWN: terminal_write_string(terminal, "\x1B[6~")
		case sdl3.K_INSERT:   terminal_write_string(terminal, "\x1B[2~")
		case sdl3.K_DELETE:   terminal_write_string(terminal, "\x1B[3~")

		case sdl3.K_F1:  terminal_write_string(terminal, "\x1BOP")
		case sdl3.K_F2:  terminal_write_string(terminal, "\x1BOQ")
		case sdl3.K_F3:  terminal_write_string(terminal, "\x1BOR")
		case sdl3.K_F4:  terminal_write_string(terminal, "\x1BOS")
		case sdl3.K_F5:  terminal_write_string(terminal, "\x1B[15~")
		case sdl3.K_F6:  terminal_write_string(terminal, "\x1B[17~")
		case sdl3.K_F7:  terminal_write_string(terminal, "\x1B[18~")
		case sdl3.K_F8:  terminal_write_string(terminal, "\x1B[19~")
		case sdl3.K_F9:  terminal_write_string(terminal, "\x1B[20~")
		case sdl3.K_F10: terminal_write_string(terminal, "\x1B[21~")
		case sdl3.K_F11: terminal_write_string(terminal, "\x1B[23~")
		case sdl3.K_F12: terminal_write_string(terminal, "\x1B[24~")

		case:
			// Ctrl + ASCII letter → C0 control byte (0x01..0x1A).
			if ctrl_held && key >= sdl3.K_A && key <= sdl3.K_Z {
				control_byte := u8(int(key) - int(sdl3.K_A) + 1)
				terminal_write(terminal, []u8{ control_byte })
				return
			}
			// Ctrl + [, \, ], ^, _ are the rest of the C0 group.
			if ctrl_held {
				switch key {
				case sdl3.K_LEFTBRACKET:  terminal_write(terminal, []u8{ 0x1B }); return
				case sdl3.K_BACKSLASH:    terminal_write(terminal, []u8{ 0x1C }); return
				case sdl3.K_RIGHTBRACKET: terminal_write(terminal, []u8{ 0x1D }); return
				case sdl3.K_SPACE:        terminal_write(terminal, []u8{ 0x00 }); return
				}
			}
			// Anything else falls through — printable keys arrive as
			// TEXT_INPUT events anyway, so we don't have to translate them.
		}
	}
}
