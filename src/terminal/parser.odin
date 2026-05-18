package terminal

import "core:unicode/utf8"

// Feed a chunk of bytes through the parser, mutating screen state as we go.
// The parser is a flat state machine — Ground / Escape / Csi / Osc — chosen
// for simplicity over the rigorous Paul Williams VT500 table. This is
// enough for PowerShell, cmd.exe, and most ANSI-emitting CLIs to render
// correctly. OSC payloads are consumed but not acted on yet.
@(private)
parser_feed :: proc(terminal: ^Terminal, data: []u8) {
	parser := &terminal.parser
	screen := &terminal.screen

	data_index := 0
	for data_index < len(data) {
		current_byte := data[data_index]
		data_index += 1

		switch parser.state {
		case .Ground:
			parser_ground_byte(terminal, screen, current_byte, data[data_index:], &data_index)

		case .Escape:
			parser_escape_byte(terminal, screen, current_byte)

		case .Csi:
			parser_csi_byte(terminal, screen, current_byte)

		case .Osc:
			// Consume until BEL (0x07) or ST (ESC \). We don't act on OSC
			// yet, but we must exit cleanly or the parser stays stuck.
			if current_byte == 0x07 { parser.state = .Ground }
			// ESC \ string terminator handled in .Escape from the next byte.
		}
	}
}

@(private="file")
parser_ground_byte :: proc(terminal: ^Terminal, screen: ^Screen, current_byte: u8, remaining_data: []u8, data_index_inout: ^int) {
	parser := &terminal.parser
	switch current_byte {
	case 0x07: // BEL — ignored (could flash later)
	case 0x08: screen_backspace(screen)
	case 0x09: screen_tab(screen)
	case 0x0A: screen_line_feed(screen)
	case 0x0B: screen_line_feed(screen) // VT
	case 0x0C: screen_line_feed(screen) // FF
	case 0x0D: screen_carriage_return(screen)
	case 0x1B: parser.state = .Escape; parser_reset_csi(parser)
	case:
		if current_byte < 0x20 { return } // drop other C0 controls silently
		// Decode the leading byte plus any UTF-8 continuation bytes that
		// happen to be available in this same chunk.
		if current_byte < 0x80 {
			screen_put_rune(screen, rune(current_byte))
			return
		}
		// Multi-byte UTF-8: try to assemble from the head + `remaining_data`.
		// Worst case is a 4-byte sequence, so peek up to 3 trailing bytes.
		utf8_buffer: [4]u8
		utf8_buffer[0] = current_byte
		continuation_bytes_needed := 0
		switch {
		case current_byte & 0xE0 == 0xC0: continuation_bytes_needed = 1
		case current_byte & 0xF0 == 0xE0: continuation_bytes_needed = 2
		case current_byte & 0xF8 == 0xF0: continuation_bytes_needed = 3
		case:                              continuation_bytes_needed = 0 // stray continuation; render as '?'
		}
		if continuation_bytes_needed == 0 || continuation_bytes_needed > len(remaining_data) {
			screen_put_rune(screen, '?')
			return
		}
		for continuation_index in 0..<continuation_bytes_needed { utf8_buffer[1+continuation_index] = remaining_data[continuation_index] }
		decoded_rune, _ := utf8.decode_rune(utf8_buffer[:1+continuation_bytes_needed])
		screen_put_rune(screen, decoded_rune)
		data_index_inout^ += continuation_bytes_needed
	}
}

@(private="file")
parser_escape_byte :: proc(terminal: ^Terminal, screen: ^Screen, current_byte: u8) {
	parser := &terminal.parser
	switch current_byte {
	case '[':
		parser.state = .Csi
		parser_reset_csi(parser)
	case ']':
		parser.state = .Osc
	case '\\':
		// String terminator for OSC, etc.
		parser.state = .Ground
	case '7':
		screen.saved_cursor_row    = screen.cursor_row
		screen.saved_cursor_column = screen.cursor_column
		parser.state = .Ground
	case '8':
		screen.cursor_row    = screen.saved_cursor_row
		screen.cursor_column = screen.saved_cursor_column
		parser.state = .Ground
	case 'M':
		// Reverse Index — move up, scroll down at top of region.
		if screen.cursor_row == screen.scroll_region_top {
			screen_scroll_down(screen, 1)
		} else if screen.cursor_row > 0 {
			screen.cursor_row -= 1
		}
		parser.state = .Ground
	case 'c':
		// RIS — full reset.
		screen.current_attributes       = 0
		screen.current_foreground_color = screen.default_foreground_color
		screen.current_background_color = screen.default_background_color
		screen.cursor_row               = 0
		screen.cursor_column            = 0
		screen.scroll_region_top        = 0
		screen.scroll_region_bottom     = screen.rows - 1
		screen_clear(screen)
		parser.state = .Ground
	case:
		// Unrecognized 2-byte escape — drop and resume.
		parser.state = .Ground
	}
}

@(private="file")
parser_csi_byte :: proc(terminal: ^Terminal, screen: ^Screen, current_byte: u8) {
	parser := &terminal.parser
	// Parameter bytes 0x30–0x3F. Digits build numeric params, ';' separates.
	if current_byte >= '0' && current_byte <= '9' {
		if parser.parameter_count == 0 { parser.parameter_count = 1; parser.parameters[0] = 0 }
		current_value := parser.parameters[parser.parameter_count-1]
		if current_value < 0 { current_value = 0 }
		parser.parameters[parser.parameter_count-1] = current_value*10 + i32(current_byte - '0')
		return
	}
	if current_byte == ';' {
		if parser.parameter_count < len(parser.parameters) {
			parser.parameter_count += 1
			parser.parameters[parser.parameter_count-1] = 0
		}
		return
	}
	if current_byte == '?' || current_byte == '<' || current_byte == '=' || current_byte == '>' {
		// Private mode marker. We remember it but most ?-modes are ignored.
		parser.private_mark = current_byte
		return
	}
	if current_byte >= 0x20 && current_byte <= 0x2F {
		// Intermediate (' '..'/'); rare. Remember the last one.
		parser.intermediate_byte = current_byte
		return
	}
	// Final byte 0x40–0x7E — dispatch and return to Ground.
	parser_csi_dispatch(terminal, screen, current_byte)
	parser.state = .Ground
}

@(private="file")
parser_csi_dispatch :: proc(terminal: ^Terminal, screen: ^Screen, final_byte: u8) {
	parser := &terminal.parser

	// Ensure at least one slot so `parameter_or_default` works uniformly.
	if parser.parameter_count == 0 { parser.parameter_count = 1; parser.parameters[0] = 0 }

	switch final_byte {
	case 'A':
		screen_move_cursor(screen, -parameter_or_default(parser, 0, 1), 0)
	case 'B', 'e':
		screen_move_cursor(screen,  parameter_or_default(parser, 0, 1), 0)
	case 'C', 'a':
		screen_move_cursor(screen,  0,  parameter_or_default(parser, 0, 1))
	case 'D':
		screen_move_cursor(screen,  0, -parameter_or_default(parser, 0, 1))
	case 'E':
		screen_move_cursor(screen,  parameter_or_default(parser, 0, 1), 0)
		screen.cursor_column = 0
	case 'F':
		screen_move_cursor(screen, -parameter_or_default(parser, 0, 1), 0)
		screen.cursor_column = 0
	case 'G', '`':
		screen_set_cursor(screen, screen.cursor_row + 1, parameter_or_default(parser, 0, 1))
	case 'H', 'f':
		screen_set_cursor(screen, parameter_or_default(parser, 0, 1), parameter_or_default(parser, 1, 1))
	case 'd':
		screen_set_cursor(screen, parameter_or_default(parser, 0, 1), screen.cursor_column + 1)
	case 'J':
		screen_erase_display(screen, parameter_or_default(parser, 0, 0))
	case 'K':
		screen_erase_line(screen, parameter_or_default(parser, 0, 0))
	case 'L':
		// Insert lines at cursor (within scroll region).
		screen_insert_lines(screen, parameter_or_default(parser, 0, 1))
	case 'M':
		screen_delete_lines(screen, parameter_or_default(parser, 0, 1))
	case 'P':
		screen_delete_chars(screen, parameter_or_default(parser, 0, 1))
	case '@':
		screen_insert_chars(screen, parameter_or_default(parser, 0, 1))
	case 'S':
		screen_scroll_up(screen,   parameter_or_default(parser, 0, 1))
	case 'T':
		screen_scroll_down(screen, parameter_or_default(parser, 0, 1))
	case 'X':
		// ECH — erase n chars from cursor, no cursor move.
		screen_erase_chars(screen, parameter_or_default(parser, 0, 1))
	case 'r':
		// Set scroll region.
		new_region_top    := parameter_or_default(parser, 0, 1) - 1
		new_region_bottom := parameter_or_default(parser, 1, screen.rows) - 1
		if new_region_top < 0               { new_region_top = 0 }
		if new_region_bottom >= screen.rows { new_region_bottom = screen.rows - 1 }
		if new_region_top < new_region_bottom {
			screen.scroll_region_top    = new_region_top
			screen.scroll_region_bottom = new_region_bottom
			screen.cursor_row           = 0
			screen.cursor_column        = 0
		}
	case 's':
		screen.saved_cursor_row    = screen.cursor_row
		screen.saved_cursor_column = screen.cursor_column
	case 'u':
		screen.cursor_row    = screen.saved_cursor_row
		screen.cursor_column = screen.saved_cursor_column
	case 'h', 'l':
		// (Re)set modes. We only act on ?25 (show/hide cursor).
		if parser.private_mark == '?' {
			for parameter_index in 0..<parser.parameter_count {
				if parser.parameters[parameter_index] == 25 {
					screen.cursor_visible = final_byte == 'h'
				}
			}
		}
	case 'm':
		sgr_apply(screen, parser.parameters[:parser.parameter_count], &terminal.palette)
	}
}

@(private="file")
parameter_or_default :: proc(parser: ^Parser, parameter_index: int, default_value: i32) -> i32 {
	if parameter_index >= parser.parameter_count { return default_value }
	parameter_value := parser.parameters[parameter_index]
	if parameter_value <= 0 { return default_value }
	return parameter_value
}

@(private="file")
parser_reset_csi :: proc(parser: ^Parser) {
	parser.parameter_count = 0
	parser.private_mark = 0
	parser.intermediate_byte = 0
	for parameter_index in 0..<len(parser.parameters) { parser.parameters[parameter_index] = 0 }
}

// --- SGR (colors + attrs) ----------------------------------------------

@(private="file")
sgr_apply :: proc(screen: ^Screen, sgr_parameters: []i32, palette: ^[256]Color) {
	if len(sgr_parameters) == 0 {
		screen.current_attributes       = 0
		screen.current_foreground_color = screen.default_foreground_color
		screen.current_background_color = screen.default_background_color
		return
	}
	parameter_index := 0
	for parameter_index < len(sgr_parameters) {
		current_parameter := sgr_parameters[parameter_index]
		switch current_parameter {
		case 0:
			screen.current_attributes       = 0
			screen.current_foreground_color = screen.default_foreground_color
			screen.current_background_color = screen.default_background_color
		case 1:  screen.current_attributes |= ATTRIBUTE_BOLD
		case 2:  screen.current_attributes |= ATTRIBUTE_DIM
		case 3:  screen.current_attributes |= ATTRIBUTE_ITALIC
		case 4:  screen.current_attributes |= ATTRIBUTE_UNDERLINE
		case 7:  screen.current_attributes |= ATTRIBUTE_REVERSE
		case 22: screen.current_attributes &~= (ATTRIBUTE_BOLD | ATTRIBUTE_DIM)
		case 23: screen.current_attributes &~= ATTRIBUTE_ITALIC
		case 24: screen.current_attributes &~= ATTRIBUTE_UNDERLINE
		case 27: screen.current_attributes &~= ATTRIBUTE_REVERSE
		case 30, 31, 32, 33, 34, 35, 36, 37:
			screen.current_foreground_color = palette[current_parameter - 30]
		case 38:
			// 38;5;<idx> (256-color) or 38;2;r;g;b (truecolor).
			if parameter_index + 1 < len(sgr_parameters) {
				switch sgr_parameters[parameter_index+1] {
				case 5:
					if parameter_index + 2 < len(sgr_parameters) {
						palette_index := sgr_parameters[parameter_index+2]
						if palette_index < 0 { palette_index = 0 }; if palette_index > 255 { palette_index = 255 }
						screen.current_foreground_color = palette[palette_index]
						parameter_index += 2
					}
				case 2:
					if parameter_index + 4 < len(sgr_parameters) {
						screen.current_foreground_color = color_from_rgb(sgr_parameters[parameter_index+2], sgr_parameters[parameter_index+3], sgr_parameters[parameter_index+4])
						parameter_index += 4
					}
				}
			}
		case 39: screen.current_foreground_color = screen.default_foreground_color
		case 40, 41, 42, 43, 44, 45, 46, 47:
			screen.current_background_color = palette[current_parameter - 40]
		case 48:
			if parameter_index + 1 < len(sgr_parameters) {
				switch sgr_parameters[parameter_index+1] {
				case 5:
					if parameter_index + 2 < len(sgr_parameters) {
						palette_index := sgr_parameters[parameter_index+2]
						if palette_index < 0 { palette_index = 0 }; if palette_index > 255 { palette_index = 255 }
						screen.current_background_color = palette[palette_index]
						parameter_index += 2
					}
				case 2:
					if parameter_index + 4 < len(sgr_parameters) {
						screen.current_background_color = color_from_rgb(sgr_parameters[parameter_index+2], sgr_parameters[parameter_index+3], sgr_parameters[parameter_index+4])
						parameter_index += 4
					}
				}
			}
		case 49: screen.current_background_color = screen.default_background_color
		case 90, 91, 92, 93, 94, 95, 96, 97:
			screen.current_foreground_color = palette[8 + (current_parameter - 90)]
		case 100, 101, 102, 103, 104, 105, 106, 107:
			screen.current_background_color = palette[8 + (current_parameter - 100)]
		}
		parameter_index += 1
	}
}

@(private="file")
color_from_rgb :: proc(red, green, blue: i32) -> Color {
	clamped_red   := red;   if clamped_red   < 0 { clamped_red   = 0 }; if clamped_red   > 255 { clamped_red   = 255 }
	clamped_green := green; if clamped_green < 0 { clamped_green = 0 }; if clamped_green > 255 { clamped_green = 255 }
	clamped_blue  := blue;  if clamped_blue  < 0 { clamped_blue  = 0 }; if clamped_blue  > 255 { clamped_blue  = 255 }
	return Color{ red = f32(clamped_red)/255.0, green = f32(clamped_green)/255.0, blue = f32(clamped_blue)/255.0, alpha = 1.0 }
}

// --- Less-common screen ops referenced by the parser -------------------

@(private)
screen_scroll_down :: proc(screen: ^Screen, line_count: i32) {
	if line_count <= 0 { return }
	region_top    := screen.scroll_region_top
	region_bottom := screen.scroll_region_bottom
	if region_top >= region_bottom { return }
	region_row_count := region_bottom - region_top + 1
	shift_amount := line_count; if shift_amount > region_row_count { shift_amount = region_row_count }
	for row_index := region_bottom; row_index >= region_top + shift_amount; row_index -= 1 {
		source_row_base      := (row_index - shift_amount) * screen.columns
		destination_row_base := row_index * screen.columns
		for column_index in 0..<screen.columns { screen.cells[destination_row_base + column_index] = screen.cells[source_row_base + column_index] }
	}
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	for row_index in region_top ..< (region_top + shift_amount) {
		row_base := row_index * screen.columns
		for column_index in 0..<screen.columns { screen.cells[row_base + column_index] = blank_cell }
	}
}

@(private)
screen_insert_lines :: proc(screen: ^Screen, line_count: i32) {
	// Insert line_count blank lines at cursor, pushing existing lines down within the
	// scroll region.
	if screen.cursor_row < screen.scroll_region_top || screen.cursor_row > screen.scroll_region_bottom { return }
	saved_region_top := screen.scroll_region_top
	screen.scroll_region_top = screen.cursor_row
	screen_scroll_down(screen, line_count)
	screen.scroll_region_top = saved_region_top
}

@(private)
screen_delete_lines :: proc(screen: ^Screen, line_count: i32) {
	if screen.cursor_row < screen.scroll_region_top || screen.cursor_row > screen.scroll_region_bottom { return }
	saved_region_top := screen.scroll_region_top
	screen.scroll_region_top = screen.cursor_row
	screen_scroll_up(screen, line_count)
	screen.scroll_region_top = saved_region_top
}

@(private)
screen_delete_chars :: proc(screen: ^Screen, character_count: i32) {
	resolved_count := character_count; if resolved_count < 1 { resolved_count = 1 }
	row_base := screen.cursor_row * screen.columns
	end_column := screen.columns
	for column_index := screen.cursor_column; column_index < end_column - resolved_count; column_index += 1 {
		screen.cells[row_base + column_index] = screen.cells[row_base + column_index + resolved_count]
	}
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	for column_index in (end_column - resolved_count) ..< end_column {
		if column_index < 0 { continue }
		screen.cells[row_base + column_index] = blank_cell
	}
}

@(private)
screen_insert_chars :: proc(screen: ^Screen, character_count: i32) {
	resolved_count := character_count; if resolved_count < 1 { resolved_count = 1 }
	row_base := screen.cursor_row * screen.columns
	for column_index := screen.columns - 1; column_index >= screen.cursor_column + resolved_count; column_index -= 1 {
		screen.cells[row_base + column_index] = screen.cells[row_base + column_index - resolved_count]
	}
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	end_column := screen.cursor_column + resolved_count
	if end_column > screen.columns { end_column = screen.columns }
	for column_index in screen.cursor_column ..< end_column {
		screen.cells[row_base + column_index] = blank_cell
	}
}

@(private)
screen_erase_chars :: proc(screen: ^Screen, character_count: i32) {
	resolved_count := character_count; if resolved_count < 1 { resolved_count = 1 }
	row_base := screen.cursor_row * screen.columns
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	for offset_index in 0..<resolved_count {
		column_index := screen.cursor_column + offset_index
		if column_index >= screen.columns { break }
		screen.cells[row_base + column_index] = blank_cell
	}
}
