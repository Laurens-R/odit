package terminal

import "core:unicode/utf8"

// Feed a chunk of bytes through the parser, mutating screen state as we go.
// The parser is a flat state machine — Ground / Escape / Csi / Osc — chosen
// for simplicity over the rigorous Paul Williams VT500 table. This is
// enough for PowerShell, cmd.exe, and most ANSI-emitting CLIs to render
// correctly. OSC payloads are consumed but not acted on yet.
@(private)
parser_feed :: proc(t: ^Terminal, data: []u8) {
	p := &t.parser
	s := &t.screen

	i := 0
	for i < len(data) {
		b := data[i]
		i += 1

		switch p.state {
		case .Ground:
			parser_ground_byte(t, s, b, data[i:], &i)

		case .Escape:
			parser_escape_byte(t, s, b)

		case .Csi:
			parser_csi_byte(t, s, b)

		case .Osc:
			// Consume until BEL (0x07) or ST (ESC \). We don't act on OSC
			// yet, but we must exit cleanly or the parser stays stuck.
			if b == 0x07 { p.state = .Ground }
			// ESC \ string terminator handled in .Escape from the next byte.
		}
	}
}

@(private="file")
parser_ground_byte :: proc(t: ^Terminal, s: ^Screen, b: u8, rest: []u8, i_inout: ^int) {
	p := &t.parser
	switch b {
	case 0x07: // BEL — ignored (could flash later)
	case 0x08: screen_backspace(s)
	case 0x09: screen_tab(s)
	case 0x0A: screen_line_feed(s)
	case 0x0B: screen_line_feed(s) // VT
	case 0x0C: screen_line_feed(s) // FF
	case 0x0D: screen_carriage_return(s)
	case 0x1B: p.state = .Escape; parser_reset_csi(p)
	case:
		if b < 0x20 { return } // drop other C0 controls silently
		// Decode the leading byte plus any UTF-8 continuation bytes that
		// happen to be available in this same chunk.
		if b < 0x80 {
			screen_put_rune(s, rune(b))
			return
		}
		// Multi-byte UTF-8: try to assemble from the head + `rest`.
		// Worst case is a 4-byte sequence, so peek up to 3 trailing bytes.
		buf: [4]u8
		buf[0] = b
		needed := 0
		switch {
		case b & 0xE0 == 0xC0: needed = 1
		case b & 0xF0 == 0xE0: needed = 2
		case b & 0xF8 == 0xF0: needed = 3
		case:                   needed = 0 // stray continuation; render as '?'
		}
		if needed == 0 || needed > len(rest) {
			screen_put_rune(s, '?')
			return
		}
		for k in 0..<needed { buf[1+k] = rest[k] }
		r, size := utf8.decode_rune(buf[:1+needed])
		_ = size
		screen_put_rune(s, r)
		i_inout^ += needed
	}
}

@(private="file")
parser_escape_byte :: proc(t: ^Terminal, s: ^Screen, b: u8) {
	p := &t.parser
	switch b {
	case '[':
		p.state = .Csi
		parser_reset_csi(p)
	case ']':
		p.state = .Osc
	case '\\':
		// String terminator for OSC, etc.
		p.state = .Ground
	case '7':
		s.saved_row = s.cursor_row
		s.saved_col = s.cursor_col
		p.state = .Ground
	case '8':
		s.cursor_row = s.saved_row
		s.cursor_col = s.saved_col
		p.state = .Ground
	case 'M':
		// Reverse Index — move up, scroll down at top of region.
		if s.cursor_row == s.scroll_top {
			screen_scroll_down(s, 1)
		} else if s.cursor_row > 0 {
			s.cursor_row -= 1
		}
		p.state = .Ground
	case 'c':
		// RIS — full reset.
		s.attrs = 0
		s.fg = s.default_fg
		s.bg = s.default_bg
		s.cursor_row = 0
		s.cursor_col = 0
		s.scroll_top = 0
		s.scroll_bottom = s.rows - 1
		screen_clear(s)
		p.state = .Ground
	case:
		// Unrecognized 2-byte escape — drop and resume.
		p.state = .Ground
	}
}

@(private="file")
parser_csi_byte :: proc(t: ^Terminal, s: ^Screen, b: u8) {
	p := &t.parser
	// Parameter bytes 0x30–0x3F. Digits build numeric params, ';' separates.
	if b >= '0' && b <= '9' {
		if p.nparams == 0 { p.nparams = 1; p.params[0] = 0 }
		v := p.params[p.nparams-1]
		if v < 0 { v = 0 }
		p.params[p.nparams-1] = v*10 + i32(b - '0')
		return
	}
	if b == ';' {
		if p.nparams < len(p.params) {
			p.nparams += 1
			p.params[p.nparams-1] = 0
		}
		return
	}
	if b == '?' || b == '<' || b == '=' || b == '>' {
		// Private mode marker. We remember it but most ?-modes are ignored.
		p.private_mark = b
		return
	}
	if b >= 0x20 && b <= 0x2F {
		// Intermediate (' '..'/'); rare. Remember the last one.
		p.intermediate = b
		return
	}
	// Final byte 0x40–0x7E — dispatch and return to Ground.
	parser_csi_dispatch(t, s, b)
	p.state = .Ground
}

@(private="file")
parser_csi_dispatch :: proc(t: ^Terminal, s: ^Screen, final: u8) {
	p := &t.parser

	// Ensure at least one slot so `param_or_default` works uniformly.
	if p.nparams == 0 { p.nparams = 1; p.params[0] = 0 }

	switch final {
	case 'A':
		screen_move_cursor(s, -param_or_default(p, 0, 1), 0)
	case 'B', 'e':
		screen_move_cursor(s,  param_or_default(p, 0, 1), 0)
	case 'C', 'a':
		screen_move_cursor(s,  0,  param_or_default(p, 0, 1))
	case 'D':
		screen_move_cursor(s,  0, -param_or_default(p, 0, 1))
	case 'E':
		screen_move_cursor(s,  param_or_default(p, 0, 1), 0)
		s.cursor_col = 0
	case 'F':
		screen_move_cursor(s, -param_or_default(p, 0, 1), 0)
		s.cursor_col = 0
	case 'G', '`':
		screen_set_cursor(s, s.cursor_row + 1, param_or_default(p, 0, 1))
	case 'H', 'f':
		screen_set_cursor(s, param_or_default(p, 0, 1), param_or_default(p, 1, 1))
	case 'd':
		screen_set_cursor(s, param_or_default(p, 0, 1), s.cursor_col + 1)
	case 'J':
		screen_erase_display(s, param_or_default(p, 0, 0))
	case 'K':
		screen_erase_line(s, param_or_default(p, 0, 0))
	case 'L':
		// Insert lines at cursor (within scroll region).
		screen_insert_lines(s, param_or_default(p, 0, 1))
	case 'M':
		screen_delete_lines(s, param_or_default(p, 0, 1))
	case 'P':
		screen_delete_chars(s, param_or_default(p, 0, 1))
	case '@':
		screen_insert_chars(s, param_or_default(p, 0, 1))
	case 'S':
		screen_scroll_up(s,   param_or_default(p, 0, 1))
	case 'T':
		screen_scroll_down(s, param_or_default(p, 0, 1))
	case 'X':
		// ECH — erase n chars from cursor, no cursor move.
		screen_erase_chars(s, param_or_default(p, 0, 1))
	case 'r':
		// Set scroll region.
		top    := param_or_default(p, 0, 1) - 1
		bottom := param_or_default(p, 1, s.rows) - 1
		if top < 0          { top = 0 }
		if bottom >= s.rows { bottom = s.rows - 1 }
		if top < bottom {
			s.scroll_top    = top
			s.scroll_bottom = bottom
			s.cursor_row    = 0
			s.cursor_col    = 0
		}
	case 's':
		s.saved_row = s.cursor_row
		s.saved_col = s.cursor_col
	case 'u':
		s.cursor_row = s.saved_row
		s.cursor_col = s.saved_col
	case 'h', 'l':
		// (Re)set modes. We only act on ?25 (show/hide cursor).
		if p.private_mark == '?' {
			for k in 0..<p.nparams {
				if p.params[k] == 25 {
					s.cursor_visible = final == 'h'
				}
			}
		}
	case 'm':
		sgr_apply(s, p.params[:p.nparams], &t.palette)
	}
}

@(private="file")
param_or_default :: proc(p: ^Parser, idx: int, default_value: i32) -> i32 {
	if idx >= p.nparams { return default_value }
	v := p.params[idx]
	if v <= 0 { return default_value }
	return v
}

@(private="file")
parser_reset_csi :: proc(p: ^Parser) {
	p.nparams = 0
	p.private_mark = 0
	p.intermediate = 0
	for i in 0..<len(p.params) { p.params[i] = 0 }
}

// --- SGR (colors + attrs) ----------------------------------------------

@(private="file")
sgr_apply :: proc(s: ^Screen, params: []i32, palette: ^[256]Color) {
	if len(params) == 0 {
		s.attrs = 0
		s.fg = s.default_fg
		s.bg = s.default_bg
		return
	}
	i := 0
	for i < len(params) {
		p := params[i]
		switch p {
		case 0:
			s.attrs = 0
			s.fg = s.default_fg
			s.bg = s.default_bg
		case 1:  s.attrs |= ATTR_BOLD
		case 2:  s.attrs |= ATTR_DIM
		case 3:  s.attrs |= ATTR_ITALIC
		case 4:  s.attrs |= ATTR_UNDERLINE
		case 7:  s.attrs |= ATTR_REVERSE
		case 22: s.attrs &~= (ATTR_BOLD | ATTR_DIM)
		case 23: s.attrs &~= ATTR_ITALIC
		case 24: s.attrs &~= ATTR_UNDERLINE
		case 27: s.attrs &~= ATTR_REVERSE
		case 30, 31, 32, 33, 34, 35, 36, 37:
			s.fg = palette[p - 30]
		case 38:
			// 38;5;<idx> (256-color) or 38;2;r;g;b (truecolor).
			if i + 1 < len(params) {
				switch params[i+1] {
				case 5:
					if i + 2 < len(params) {
						idx := params[i+2]
						if idx < 0 { idx = 0 }; if idx > 255 { idx = 255 }
						s.fg = palette[idx]
						i += 2
					}
				case 2:
					if i + 4 < len(params) {
						s.fg = color_from_rgb(params[i+2], params[i+3], params[i+4])
						i += 4
					}
				}
			}
		case 39: s.fg = s.default_fg
		case 40, 41, 42, 43, 44, 45, 46, 47:
			s.bg = palette[p - 40]
		case 48:
			if i + 1 < len(params) {
				switch params[i+1] {
				case 5:
					if i + 2 < len(params) {
						idx := params[i+2]
						if idx < 0 { idx = 0 }; if idx > 255 { idx = 255 }
						s.bg = palette[idx]
						i += 2
					}
				case 2:
					if i + 4 < len(params) {
						s.bg = color_from_rgb(params[i+2], params[i+3], params[i+4])
						i += 4
					}
				}
			}
		case 49: s.bg = s.default_bg
		case 90, 91, 92, 93, 94, 95, 96, 97:
			s.fg = palette[8 + (p - 90)]
		case 100, 101, 102, 103, 104, 105, 106, 107:
			s.bg = palette[8 + (p - 100)]
		}
		i += 1
	}
}

@(private="file")
color_from_rgb :: proc(r, g, b: i32) -> Color {
	cr := r; if cr < 0 { cr = 0 }; if cr > 255 { cr = 255 }
	cg := g; if cg < 0 { cg = 0 }; if cg > 255 { cg = 255 }
	cb := b; if cb < 0 { cb = 0 }; if cb > 255 { cb = 255 }
	return Color{ f32(cr)/255.0, f32(cg)/255.0, f32(cb)/255.0, 1.0 }
}

// --- Less-common screen ops referenced by the parser -------------------

@(private)
screen_scroll_down :: proc(s: ^Screen, n: i32) {
	if n <= 0 { return }
	top, bot := s.scroll_top, s.scroll_bottom
	if top >= bot { return }
	region_rows := bot - top + 1
	shift := n; if shift > region_rows { shift = region_rows }
	for r := bot; r >= top + shift; r -= 1 {
		src := (r - shift) * s.cols
		dst := r * s.cols
		for c in 0..<s.cols { s.cells[dst + c] = s.cells[src + c] }
	}
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	for r in top ..< (top + shift) {
		base := r * s.cols
		for c in 0..<s.cols { s.cells[base + c] = blank }
	}
}

@(private)
screen_insert_lines :: proc(s: ^Screen, n: i32) {
	// Insert n blank lines at cursor, pushing existing lines down within the
	// scroll region.
	if s.cursor_row < s.scroll_top || s.cursor_row > s.scroll_bottom { return }
	old_top := s.scroll_top
	s.scroll_top = s.cursor_row
	screen_scroll_down(s, n)
	s.scroll_top = old_top
}

@(private)
screen_delete_lines :: proc(s: ^Screen, n: i32) {
	if s.cursor_row < s.scroll_top || s.cursor_row > s.scroll_bottom { return }
	old_top := s.scroll_top
	s.scroll_top = s.cursor_row
	screen_scroll_up(s, n)
	s.scroll_top = old_top
}

@(private)
screen_delete_chars :: proc(s: ^Screen, n: i32) {
	count := n; if count < 1 { count = 1 }
	row_base := s.cursor_row * s.cols
	end := s.cols
	for c := s.cursor_col; c < end - count; c += 1 {
		s.cells[row_base + c] = s.cells[row_base + c + count]
	}
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	for c in (end - count) ..< end {
		if c < 0 { continue }
		s.cells[row_base + c] = blank
	}
}

@(private)
screen_insert_chars :: proc(s: ^Screen, n: i32) {
	count := n; if count < 1 { count = 1 }
	row_base := s.cursor_row * s.cols
	for c := s.cols - 1; c >= s.cursor_col + count; c -= 1 {
		s.cells[row_base + c] = s.cells[row_base + c - count]
	}
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	end := s.cursor_col + count
	if end > s.cols { end = s.cols }
	for c in s.cursor_col ..< end {
		s.cells[row_base + c] = blank
	}
}

@(private)
screen_erase_chars :: proc(s: ^Screen, n: i32) {
	count := n; if count < 1 { count = 1 }
	row_base := s.cursor_row * s.cols
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	for k in 0..<count {
		c := s.cursor_col + k
		if c >= s.cols { break }
		s.cells[row_base + c] = blank
	}
}
