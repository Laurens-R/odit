package terminal

// Initialize a fresh blank screen of the requested size. Default colors are
// taken from `screen.default_foreground_color` / `default_background_color`
// which the caller must have set.
@(private)
screen_init :: proc(screen: ^Screen, requested_columns, requested_rows: i32) {
	resolved_columns := requested_columns; if resolved_columns < 1 { resolved_columns = 1 }
	resolved_rows    := requested_rows;    if resolved_rows    < 1 { resolved_rows    = 1 }
	screen.columns = resolved_columns
	screen.rows    = resolved_rows
	screen.cells   = make([]Cell, int(resolved_columns * resolved_rows))
	screen.current_foreground_color = screen.default_foreground_color
	screen.current_background_color = screen.default_background_color
	screen.current_attributes       = 0
	screen.cursor_row               = 0
	screen.cursor_column            = 0
	screen.saved_cursor_row         = 0
	screen.saved_cursor_column      = 0
	screen.scroll_region_top        = 0
	screen.scroll_region_bottom     = resolved_rows - 1
	screen.cursor_visible           = true
	screen_clear(screen)
}

@(private)
screen_destroy :: proc(screen: ^Screen) {
	delete(screen.cells)
	screen.cells = nil
}

// Resize the grid, preserving as much of the existing content as fits in
// the new size. Cursor clamps inside the new bounds.
@(private)
screen_resize :: proc(screen: ^Screen, requested_columns, requested_rows: i32) {
	resolved_columns := requested_columns; if resolved_columns < 1 { resolved_columns = 1 }
	resolved_rows    := requested_rows;    if resolved_rows    < 1 { resolved_rows    = 1 }
	if resolved_columns == screen.columns && resolved_rows == screen.rows { return }

	old_cells   := screen.cells
	old_columns := screen.columns
	old_rows    := screen.rows

	screen.cells   = make([]Cell, int(resolved_columns * resolved_rows))
	screen.columns = resolved_columns
	screen.rows    = resolved_rows
	screen_clear(screen)

	rows_to_copy    := min(old_rows,    resolved_rows)
	columns_to_copy := min(old_columns, resolved_columns)
	for row_index in 0..<rows_to_copy {
		for column_index in 0..<columns_to_copy {
			screen.cells[row_index*resolved_columns + column_index] = old_cells[row_index*old_columns + column_index]
		}
	}
	delete(old_cells)

	if screen.cursor_column >= resolved_columns { screen.cursor_column = resolved_columns - 1 }
	if screen.cursor_row    >= resolved_rows    { screen.cursor_row    = resolved_rows - 1 }
	screen.scroll_region_top    = 0
	screen.scroll_region_bottom = resolved_rows - 1
}

@(private)
screen_clear :: proc(screen: ^Screen) {
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.default_background_color }
	for cell_index in 0..<len(screen.cells) { screen.cells[cell_index] = blank_cell }
}

@(private="file")
screen_cell_at :: #force_inline proc(screen: ^Screen, row, column: i32) -> ^Cell {
	if row < 0 || column < 0 || row >= screen.rows || column >= screen.columns { return nil }
	return &screen.cells[row*screen.columns + column]
}

// Write one rune at the cursor and advance. Wraps to the next line at the
// right margin and triggers a scroll if the cursor falls off the bottom of
// the active scroll region.
@(private)
screen_put_rune :: proc(screen: ^Screen, rune_value: rune) {
	if screen.cursor_column >= screen.columns {
		// Pending wrap from a write that hit the right edge.
		screen.cursor_column = 0
		screen_line_feed(screen)
	}
	if target_cell := screen_cell_at(screen, screen.cursor_row, screen.cursor_column); target_cell != nil {
		target_cell.character        = rune_value
		target_cell.foreground_color = screen.current_foreground_color
		target_cell.background_color = screen.current_background_color
		target_cell.attributes       = screen.current_attributes
	}
	screen.cursor_column += 1
}

// CR — carriage return.
@(private)
screen_carriage_return :: proc(screen: ^Screen) {
	screen.cursor_column = 0
}

// LF — line feed. Within the scroll region, scrolls up when the cursor
// would fall off the bottom. Outside it just advances unless clamped.
@(private)
screen_line_feed :: proc(screen: ^Screen) {
	if screen.cursor_row == screen.scroll_region_bottom {
		screen_scroll_up(screen, 1)
		return
	}
	screen.cursor_row += 1
	if screen.cursor_row >= screen.rows { screen.cursor_row = screen.rows - 1 }
}

// Backspace — leftward cursor only, no erase (DEC convention).
@(private)
screen_backspace :: proc(screen: ^Screen) {
	if screen.cursor_column > 0 { screen.cursor_column -= 1 }
}

// Horizontal tab — advance the cursor to the next 8-column tab stop.
@(private)
screen_tab :: proc(screen: ^Screen) {
	next_tab_stop_column := ((screen.cursor_column / 8) + 1) * 8
	if next_tab_stop_column >= screen.columns { next_tab_stop_column = screen.columns - 1 }
	screen.cursor_column = next_tab_stop_column
}

// Scroll the active region up by `line_count` lines, filling vacated rows at
// the bottom with blanks colored with the current background.
@(private)
screen_scroll_up :: proc(screen: ^Screen, line_count: i32) {
	if line_count <= 0 { return }
	region_top    := screen.scroll_region_top
	region_bottom := screen.scroll_region_bottom
	if region_top >= region_bottom { return }

	region_row_count := region_bottom - region_top + 1
	shift_amount := line_count
	if shift_amount > region_row_count { shift_amount = region_row_count }

	for row_index in region_top ..< (region_bottom - shift_amount + 1) {
		source_row_base      := (row_index + shift_amount) * screen.columns
		destination_row_base := row_index * screen.columns
		for column_index in 0..<screen.columns { screen.cells[destination_row_base + column_index] = screen.cells[source_row_base + column_index] }
	}
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	for row_index in (region_bottom - shift_amount + 1) ..= region_bottom {
		row_base := row_index * screen.columns
		for column_index in 0..<screen.columns { screen.cells[row_base + column_index] = blank_cell }
	}
}

// CSI [n J — erase in display. Mode 0: cursor → end; 1: start → cursor;
// 2: whole screen.
@(private)
screen_erase_display :: proc(screen: ^Screen, erase_mode: i32) {
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	switch erase_mode {
	case 0:
		start_cell_index := screen.cursor_row * screen.columns + screen.cursor_column
		for cell_index in int(start_cell_index) ..< len(screen.cells) { screen.cells[cell_index] = blank_cell }
	case 1:
		end_cell_index := int(screen.cursor_row * screen.columns + screen.cursor_column + 1)
		for cell_index in 0 ..< end_cell_index { screen.cells[cell_index] = blank_cell }
	case 2, 3:
		// Mode 3 (scrollback erase) collapses to "clear visible" since we
		// don't yet keep a scrollback buffer.
		for cell_index in 0 ..< len(screen.cells) { screen.cells[cell_index] = blank_cell }
	}
}

// CSI [n K — erase in line.
@(private)
screen_erase_line :: proc(screen: ^Screen, erase_mode: i32) {
	blank_cell := Cell{ character = ' ', foreground_color = screen.default_foreground_color, background_color = screen.current_background_color }
	row_base := screen.cursor_row * screen.columns
	switch erase_mode {
	case 0: // cursor → end of line
		for column_index in screen.cursor_column ..< screen.columns { screen.cells[row_base + column_index] = blank_cell }
	case 1: // start of line → cursor
		for column_index in i32(0) ..= screen.cursor_column {
			if column_index >= screen.columns { break }
			screen.cells[row_base + column_index] = blank_cell
		}
	case 2: // whole line
		for column_index in 0 ..< screen.columns { screen.cells[row_base + column_index] = blank_cell }
	}
}

// Cursor positioning (1-based row/col, clamped).
@(private)
screen_set_cursor :: proc(screen: ^Screen, row, column: i32) {
	clamped_row    := row - 1;    if clamped_row    < 0 { clamped_row    = 0 }; if clamped_row    >= screen.rows    { clamped_row    = screen.rows - 1 }
	clamped_column := column - 1; if clamped_column < 0 { clamped_column = 0 }; if clamped_column >= screen.columns { clamped_column = screen.columns - 1 }
	screen.cursor_row    = clamped_row
	screen.cursor_column = clamped_column
}

@(private)
screen_move_cursor :: proc(screen: ^Screen, delta_row, delta_column: i32) {
	new_row    := screen.cursor_row + delta_row
	new_column := screen.cursor_column + delta_column
	if new_row    < 0 { new_row    = 0 }; if new_row    >= screen.rows    { new_row    = screen.rows - 1 }
	if new_column < 0 { new_column = 0 }; if new_column >= screen.columns { new_column = screen.columns - 1 }
	screen.cursor_row    = new_row
	screen.cursor_column = new_column
}

// --- Palette ------------------------------------------------------------

// Standard xterm 256-color palette. The first 16 entries cover the SGR
// 30-37 / 90-97 base colors and their bright variants, the next 216 are
// the 6x6x6 cube and the final 24 are the grayscale ramp.
@(private)
palette_init :: proc(palette: ^[256]Color) {
	base_color_table := [16][3]u8{
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
	for base_color_index in 0..<16 {
		palette[base_color_index] = Color{ red = f32(base_color_table[base_color_index][0])/255.0, green = f32(base_color_table[base_color_index][1])/255.0, blue = f32(base_color_table[base_color_index][2])/255.0, alpha = 1.0 }
	}
	cube_ramp_values := [6]u8{ 0, 95, 135, 175, 215, 255 }
	for red_step_index in 0..<6 {
		for green_step_index in 0..<6 {
			for blue_step_index in 0..<6 {
				palette_index := 16 + red_step_index*36 + green_step_index*6 + blue_step_index
				palette[palette_index] = Color{ red = f32(cube_ramp_values[red_step_index])/255.0, green = f32(cube_ramp_values[green_step_index])/255.0, blue = f32(cube_ramp_values[blue_step_index])/255.0, alpha = 1.0 }
			}
		}
	}
	for grayscale_step_index in 0..<24 {
		gray_value := u8(8 + grayscale_step_index*10)
		palette[232 + grayscale_step_index] = Color{ red = f32(gray_value)/255.0, green = f32(gray_value)/255.0, blue = f32(gray_value)/255.0, alpha = 1.0 }
	}
}
