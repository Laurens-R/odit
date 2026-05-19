package terminal

import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

// --- Hit testing -----------------------------------------------------------

// Translate a pixel position inside the terminal's rectangle into virtual-
// row / column coordinates. Returns `out_of_bounds=true` when the point is
// outside the terminal's pane; callers can treat that as "drag in progress
// but cursor moved off the viewport" and clamp to the nearest edge.
@(private)
terminal_pixel_to_cell :: proc(terminal: ^Terminal, pixel_x, pixel_y: f32) -> (virtual_row: i32, column: i32, out_of_bounds: bool) {
	out_of_bounds = false
	if terminal == nil || terminal.character_width <= 0 || terminal.line_height <= 0 {
		out_of_bounds = true
		return
	}

	local_x := pixel_x - f32(terminal.rectangle.x)
	local_y := pixel_y - f32(terminal.rectangle.y)
	if local_x < 0 || local_y < 0 || local_x >= f32(terminal.rectangle.w) || local_y >= f32(terminal.rectangle.h) {
		out_of_bounds = true
	}

	visible_row := i32(local_y / f32(terminal.line_height))
	if visible_row < 0                  { visible_row = 0 }
	if visible_row >= terminal.screen.rows { visible_row = terminal.screen.rows - 1 }

	column = i32(local_x / f32(terminal.character_width))
	if column < 0                        { column = 0 }
	if column > terminal.screen.columns  { column = terminal.screen.columns }

	scrollback_count := i32(len(terminal.screen.scrollback_rows))
	total_virtual_rows := scrollback_count + terminal.screen.rows
	viewport_top_virtual_row := total_virtual_rows - terminal.screen.rows - terminal.scroll_offset
	if viewport_top_virtual_row < 0 { viewport_top_virtual_row = 0 }
	virtual_row = viewport_top_virtual_row + visible_row
	if virtual_row < 0                       { virtual_row = 0 }
	if virtual_row >= total_virtual_rows     { virtual_row = total_virtual_rows - 1 }
	return
}

// --- Selection lifecycle ---------------------------------------------------

@(private)
terminal_selection_begin :: proc(terminal: ^Terminal, virtual_row, column: i32) {
	terminal.selection = TerminalSelection{
		is_active      = true,
		is_dragging    = true,
		anchor_row     = virtual_row,
		anchor_column  = column,
		current_row    = virtual_row,
		current_column = column,
	}
}

@(private)
terminal_selection_update :: proc(terminal: ^Terminal, virtual_row, column: i32) {
	if !terminal.selection.is_dragging { return }
	terminal.selection.current_row    = virtual_row
	terminal.selection.current_column = column
}

@(private)
terminal_selection_end :: proc(terminal: ^Terminal) {
	terminal.selection.is_dragging = false
	// If the user clicked without dragging the selection is empty — drop it
	// so we don't render a zero-width highlight.
	if terminal.selection.anchor_row == terminal.selection.current_row && terminal.selection.anchor_column == terminal.selection.current_column {
		terminal.selection.is_active = false
	}
}

@(private)
terminal_selection_clear :: proc(terminal: ^Terminal) {
	terminal.selection = TerminalSelection{}
}

// --- Normalization ---------------------------------------------------------

// Sort `anchor` and `current` into row-major order so the renderer doesn't
// have to care which end of the drag came first.
@(private)
selection_normalized_range :: proc(selection: ^TerminalSelection) -> (start_row, start_column, end_row, end_column: i32) {
	if selection.anchor_row < selection.current_row ||
	   (selection.anchor_row == selection.current_row && selection.anchor_column <= selection.current_column) {
		start_row, start_column = selection.anchor_row,  selection.anchor_column
		end_row,   end_column   = selection.current_row, selection.current_column
	} else {
		start_row, start_column = selection.current_row, selection.current_column
		end_row,   end_column   = selection.anchor_row,  selection.anchor_column
	}
	return
}

// --- Copy ------------------------------------------------------------------

// Build a UTF-8 string from the currently-selected cells. Trailing whitespace
// on each row is trimmed (otherwise paste-back recreates an awkward column of
// padding). Rows are joined with '\n' regardless of platform — the OS
// clipboard layer normalizes if needed.
//
// Allocates into `allocator` and returns the string with `ok=true`. Returns
// ok=false when there's no active selection or the selection is empty.
@(private)
terminal_selection_to_text :: proc(terminal: ^Terminal, allocator := context.allocator) -> (text: string, ok: bool) {
	if terminal == nil || !terminal.selection.is_active { return "", false }

	start_row, start_column, end_row, end_column := selection_normalized_range(&terminal.selection)

	scrollback_count   := i32(len(terminal.screen.scrollback_rows))
	total_virtual_rows := scrollback_count + terminal.screen.rows

	output_builder: strings.Builder
	strings.builder_init(&output_builder, 0, 256, allocator)

	for virtual_row in start_row..=end_row {
		if virtual_row < 0 || virtual_row >= total_virtual_rows { continue }

		row_cells:   []Cell
		row_columns: i32
		if virtual_row < scrollback_count {
			row_cells   = terminal.screen.scrollback_rows[virtual_row]
			row_columns = i32(len(row_cells))
		} else {
			live_row_index := virtual_row - scrollback_count
			row_cells   = terminal.screen.cells[live_row_index*terminal.screen.columns : (live_row_index+1)*terminal.screen.columns]
			row_columns = terminal.screen.columns
		}

		column_low:  i32 = 0
		column_high: i32 = row_columns
		if virtual_row == start_row { column_low  = clamp_column(start_column, 0, row_columns) }
		if virtual_row == end_row   { column_high = clamp_column(end_column,   0, row_columns) }
		if column_high <= column_low { continue }

		// Trim trailing whitespace on the slice so a copy of "ls<spaces>"
		// doesn't drag empty padding into the clipboard.
		trim_end := column_high
		for trim_end > column_low {
			candidate_cell := row_cells[trim_end - 1]
			if candidate_cell.character != 0 && candidate_cell.character != ' ' { break }
			trim_end -= 1
		}

		for column_index in column_low..<trim_end {
			cell := row_cells[column_index]
			rune_value := cell.character
			if rune_value == 0 { rune_value = ' ' }
			rune_bytes, rune_byte_count := utf8.encode_rune(rune_value)
			for byte_index in 0..<rune_byte_count { strings.write_byte(&output_builder, rune_bytes[byte_index]) }
		}

		// Newline between rows except after the final one.
		if virtual_row != end_row { strings.write_byte(&output_builder, '\n') }
	}

	built_text := strings.to_string(output_builder)
	if len(built_text) == 0 { return "", false }
	return built_text, true
}

@(private="file")
clamp_column :: #force_inline proc(value, low_inclusive, high_inclusive: i32) -> i32 {
	if value < low_inclusive  { return low_inclusive }
	if value > high_inclusive { return high_inclusive }
	return value
}

// --- Mouse entry points (called from the editor's mouse dispatch) ----------

// Begin a selection at the cell under the given pixel. Coordinates are in
// window space (same as SDL mouse events).
terminal_mouse_down :: proc(terminal: ^Terminal, pixel_x, pixel_y: f32) {
	virtual_row, column, _ := terminal_pixel_to_cell(terminal, pixel_x, pixel_y)
	terminal_selection_begin(terminal, virtual_row, column)
}

terminal_mouse_drag :: proc(terminal: ^Terminal, pixel_x, pixel_y: f32) {
	if terminal == nil || !terminal.selection.is_dragging { return }
	virtual_row, column, _ := terminal_pixel_to_cell(terminal, pixel_x, pixel_y)
	terminal_selection_update(terminal, virtual_row, column)
}

terminal_mouse_up :: proc(terminal: ^Terminal, pixel_x, pixel_y: f32) {
	if terminal == nil { return }
	terminal_selection_end(terminal)
}

// Set the SDL clipboard to the current selection's text. No-op if nothing's
// selected. Returns true on success so callers can decide whether to clear
// the highlight afterwards.
terminal_copy_selection_to_clipboard :: proc(terminal: ^Terminal) -> bool {
	if terminal == nil { return false }
	selected_text, ok := terminal_selection_to_text(terminal, context.temp_allocator)
	if !ok { return false }
	c_string_text := strings.clone_to_cstring(selected_text, context.temp_allocator)
	_ = sdl3.SetClipboardText(c_string_text)
	return true
}

// Read the SDL clipboard and write it to the shell. Multi-line content is
// wrapped in bracketed-paste sequence so PSReadLine (and bash/zsh with
// bracketed-paste enabled) treat it as a single paste rather than a series
// of typed lines that each trigger Enter.
terminal_paste_from_clipboard :: proc(terminal: ^Terminal) {
	if terminal == nil { return }
	raw_clipboard_pointer := sdl3.GetClipboardText()
	if raw_clipboard_pointer == nil { return }
	defer sdl3.free(rawptr(raw_clipboard_pointer))
	clipboard_text := string(cstring(raw_clipboard_pointer))
	if len(clipboard_text) == 0 { return }

	contains_newline := false
	for byte_index in 0..<len(clipboard_text) {
		if clipboard_text[byte_index] == '\n' || clipboard_text[byte_index] == '\r' { contains_newline = true; break }
	}

	if contains_newline {
		terminal_write_string(terminal, "\x1B[200~")
		terminal_write_string(terminal, clipboard_text)
		terminal_write_string(terminal, "\x1B[201~")
	} else {
		terminal_write_string(terminal, clipboard_text)
	}
}
