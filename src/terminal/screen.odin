package terminal

// Initialize a fresh blank screen of the requested size. Default colors are
// taken from `s.default_fg`/`default_bg` which the caller must have set.
@(private)
screen_init :: proc(s: ^Screen, cols_in, rows_in: i32) {
	cols := cols_in; if cols < 1 { cols = 1 }
	rows := rows_in; if rows < 1 { rows = 1 }
	s.cols = cols
	s.rows = rows
	s.cells = make([]Cell, int(cols * rows))
	s.fg = s.default_fg
	s.bg = s.default_bg
	s.attrs = 0
	s.cursor_row = 0
	s.cursor_col = 0
	s.saved_row  = 0
	s.saved_col  = 0
	s.scroll_top    = 0
	s.scroll_bottom = rows - 1
	s.cursor_visible = true
	screen_clear(s)
}

@(private)
screen_destroy :: proc(s: ^Screen) {
	delete(s.cells)
	s.cells = nil
}

// Resize the grid, preserving as much of the existing content as fits in
// the new size. Cursor clamps inside the new bounds.
@(private)
screen_resize :: proc(s: ^Screen, cols_in, rows_in: i32) {
	cols := cols_in; if cols < 1 { cols = 1 }
	rows := rows_in; if rows < 1 { rows = 1 }
	if cols == s.cols && rows == s.rows { return }

	old := s.cells
	old_cols, old_rows := s.cols, s.rows

	s.cells = make([]Cell, int(cols * rows))
	s.cols  = cols
	s.rows  = rows
	screen_clear(s)

	copy_rows := min(old_rows, rows)
	copy_cols := min(old_cols, cols)
	for r in 0..<copy_rows {
		for c in 0..<copy_cols {
			s.cells[r*cols + c] = old[r*old_cols + c]
		}
	}
	delete(old)

	if s.cursor_col >= cols { s.cursor_col = cols - 1 }
	if s.cursor_row >= rows { s.cursor_row = rows - 1 }
	s.scroll_top = 0
	s.scroll_bottom = rows - 1
}

@(private)
screen_clear :: proc(s: ^Screen) {
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.default_bg }
	for i in 0..<len(s.cells) { s.cells[i] = blank }
}

@(private="file")
screen_cell_at :: #force_inline proc(s: ^Screen, row, col: i32) -> ^Cell {
	if row < 0 || col < 0 || row >= s.rows || col >= s.cols { return nil }
	return &s.cells[row*s.cols + col]
}

// Write one rune at the cursor and advance. Wraps to the next line at the
// right margin and triggers a scroll if the cursor falls off the bottom of
// the active scroll region.
@(private)
screen_put_rune :: proc(s: ^Screen, r: rune) {
	if s.cursor_col >= s.cols {
		// Pending wrap from a write that hit the right edge.
		s.cursor_col = 0
		screen_line_feed(s)
	}
	if cell := screen_cell_at(s, s.cursor_row, s.cursor_col); cell != nil {
		cell.ch    = r
		cell.fg    = s.fg
		cell.bg    = s.bg
		cell.attrs = s.attrs
	}
	s.cursor_col += 1
}

// CR — carriage return.
@(private)
screen_carriage_return :: proc(s: ^Screen) {
	s.cursor_col = 0
}

// LF — line feed. Within the scroll region, scrolls up when the cursor
// would fall off the bottom. Outside it just advances unless clamped.
@(private)
screen_line_feed :: proc(s: ^Screen) {
	if s.cursor_row == s.scroll_bottom {
		screen_scroll_up(s, 1)
		return
	}
	s.cursor_row += 1
	if s.cursor_row >= s.rows { s.cursor_row = s.rows - 1 }
}

// Backspace — leftward cursor only, no erase (DEC convention).
@(private)
screen_backspace :: proc(s: ^Screen) {
	if s.cursor_col > 0 { s.cursor_col -= 1 }
}

// Horizontal tab — advance the cursor to the next 8-column tab stop.
@(private)
screen_tab :: proc(s: ^Screen) {
	next := ((s.cursor_col / 8) + 1) * 8
	if next >= s.cols { next = s.cols - 1 }
	s.cursor_col = next
}

// Scroll the active region up by `n` lines, filling vacated rows at the
// bottom with blanks colored with the current background.
@(private)
screen_scroll_up :: proc(s: ^Screen, n: i32) {
	if n <= 0 { return }
	top, bot := s.scroll_top, s.scroll_bottom
	if top >= bot { return }

	region_rows := bot - top + 1
	shift := n
	if shift > region_rows { shift = region_rows }

	for r in top ..< (bot - shift + 1) {
		src := (r + shift) * s.cols
		dst := r * s.cols
		for c in 0..<s.cols { s.cells[dst + c] = s.cells[src + c] }
	}
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	for r in (bot - shift + 1) ..= bot {
		base := r * s.cols
		for c in 0..<s.cols { s.cells[base + c] = blank }
	}
}

// CSI [n J — erase in display. Mode 0: cursor → end; 1: start → cursor;
// 2: whole screen.
@(private)
screen_erase_display :: proc(s: ^Screen, mode: i32) {
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	switch mode {
	case 0:
		start := s.cursor_row * s.cols + s.cursor_col
		for i in int(start) ..< len(s.cells) { s.cells[i] = blank }
	case 1:
		end := int(s.cursor_row * s.cols + s.cursor_col + 1)
		for i in 0 ..< end { s.cells[i] = blank }
	case 2, 3:
		// Mode 3 (scrollback erase) collapses to "clear visible" since we
		// don't yet keep a scrollback buffer.
		for i in 0 ..< len(s.cells) { s.cells[i] = blank }
	}
}

// CSI [n K — erase in line.
@(private)
screen_erase_line :: proc(s: ^Screen, mode: i32) {
	blank := Cell{ ch = ' ', fg = s.default_fg, bg = s.bg }
	row_base := s.cursor_row * s.cols
	switch mode {
	case 0: // cursor → end of line
		for c in s.cursor_col ..< s.cols { s.cells[row_base + c] = blank }
	case 1: // start of line → cursor
		for c in i32(0) ..= s.cursor_col {
			if c >= s.cols { break }
			s.cells[row_base + c] = blank
		}
	case 2: // whole line
		for c in 0 ..< s.cols { s.cells[row_base + c] = blank }
	}
}

// Cursor positioning (1-based row/col, clamped).
@(private)
screen_set_cursor :: proc(s: ^Screen, row, col: i32) {
	r := row - 1; if r < 0 { r = 0 }; if r >= s.rows { r = s.rows - 1 }
	c := col - 1; if c < 0 { c = 0 }; if c >= s.cols { c = s.cols - 1 }
	s.cursor_row = r
	s.cursor_col = c
}

@(private)
screen_move_cursor :: proc(s: ^Screen, drow, dcol: i32) {
	r := s.cursor_row + drow
	c := s.cursor_col + dcol
	if r < 0 { r = 0 }; if r >= s.rows { r = s.rows - 1 }
	if c < 0 { c = 0 }; if c >= s.cols { c = s.cols - 1 }
	s.cursor_row = r
	s.cursor_col = c
}

// --- Palette ------------------------------------------------------------

// Standard xterm 256-color palette. The first 16 entries cover the SGR
// 30-37 / 90-97 base colors and their bright variants, the next 216 are
// the 6x6x6 cube and the final 24 are the grayscale ramp.
@(private)
palette_init :: proc(p: ^[256]Color) {
	base := [16][3]u8{
		{ 0x00, 0x00, 0x00 }, // 0  black
		{ 0xCD, 0x00, 0x00 }, // 1  red
		{ 0x00, 0xCD, 0x00 }, // 2  green
		{ 0xCD, 0xCD, 0x00 }, // 3  yellow
		{ 0x1E, 0x90, 0xFF }, // 4  blue
		{ 0xCD, 0x00, 0xCD }, // 5  magenta
		{ 0x00, 0xCD, 0xCD }, // 6  cyan
		{ 0xE5, 0xE5, 0xE5 }, // 7  white (light gray)
		{ 0x7F, 0x7F, 0x7F }, // 8  bright black (gray)
		{ 0xFF, 0x00, 0x00 }, // 9  bright red
		{ 0x00, 0xFF, 0x00 }, // 10 bright green
		{ 0xFF, 0xFF, 0x00 }, // 11 bright yellow
		{ 0x5C, 0x5C, 0xFF }, // 12 bright blue
		{ 0xFF, 0x00, 0xFF }, // 13 bright magenta
		{ 0x00, 0xFF, 0xFF }, // 14 bright cyan
		{ 0xFF, 0xFF, 0xFF }, // 15 bright white
	}
	for i in 0..<16 {
		p[i] = Color{ f32(base[i][0])/255.0, f32(base[i][1])/255.0, f32(base[i][2])/255.0, 1.0 }
	}
	ramp := [6]u8{ 0, 95, 135, 175, 215, 255 }
	for r in 0..<6 {
		for g in 0..<6 {
			for b in 0..<6 {
				idx := 16 + r*36 + g*6 + b
				p[idx] = Color{ f32(ramp[r])/255.0, f32(ramp[g])/255.0, f32(ramp[b])/255.0, 1.0 }
			}
		}
	}
	for i in 0..<24 {
		v := u8(8 + i*10)
		p[232 + i] = Color{ f32(v)/255.0, f32(v)/255.0, f32(v)/255.0, 1.0 }
	}
}
