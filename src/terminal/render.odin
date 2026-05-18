package terminal

import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../ui"

// Paint the terminal into its rect: fill background, draw a background-colored
// rectangle for each non-default cell, then draw a single text run per row so
// SDL_ttf doesn't pay the per-glyph submission cost for every cell. Finally
// draw a block cursor on top.
//
// `text_cache` is the editor's shared `ui.TextCache`. Going through it
// instead of `ttf.CreateText` / `ttf.DestroyText` cuts per-frame GPU texture
// churn dramatically — most rows repeat unchanged frame-to-frame.
terminal_render :: proc(terminal: ^Terminal, renderer: ^sdl3.Renderer, font: ^ttf.Font, engine: ^ttf.TextEngine, text_cache: ^ui.TextCache) {
	if terminal == nil { return }
	screen := &terminal.screen
	if terminal.character_width <= 0 || terminal.line_height <= 0 { return }

	// Solid background.
	background_color := screen.default_background_color
	sdl3.SetRenderDrawColorFloat(renderer, background_color.red, background_color.green, background_color.blue, background_color.alpha)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{
		f32(terminal.rectangle.x), f32(terminal.rectangle.y), f32(terminal.rectangle.w), f32(terminal.rectangle.h),
	})

	// Per-row pass: contiguous runs of cells that share fg/bg/attrs render
	// together as one text-call. This keeps per-frame work tied to the
	// number of *spans* on screen, not to columns*rows.
	character_width := terminal.character_width
	line_height     := terminal.line_height
	for row_index in 0..<screen.rows {
		row_y_position := i32(terminal.rectangle.y) + row_index * line_height

		// First pass: paint background rectangles for any cell whose bg
		// differs from the screen default. Coalesce adjacent equal-bg
		// cells into one rect.
		background_run_start := i32(-1)
		background_run_color := background_color
		for column_index in 0..<screen.columns {
			cell := screen.cells[row_index*screen.columns + column_index]
			effective_cell_background := effective_background(cell)
			if !colors_are_equal(effective_cell_background, background_color) {
				if background_run_start < 0 || !colors_are_equal(effective_cell_background, background_run_color) {
					if background_run_start >= 0 { fill_background_run(renderer, terminal.rectangle.x, row_y_position, background_run_start, column_index, character_width, line_height, background_run_color) }
					background_run_start = column_index
					background_run_color = effective_cell_background
				}
			} else if background_run_start >= 0 {
				fill_background_run(renderer, terminal.rectangle.x, row_y_position, background_run_start, column_index, character_width, line_height, background_run_color)
				background_run_start = -1
			}
		}
		if background_run_start >= 0 { fill_background_run(renderer, terminal.rectangle.x, row_y_position, background_run_start, screen.columns, character_width, line_height, background_run_color) }

		// Second pass: glyphs. Build runes per fg-run and submit each run
		// as one CreateText/Draw pair.
		text_run_builder: strings.Builder
		strings.builder_init(&text_run_builder, 0, int(screen.columns)*4, context.temp_allocator)

		text_run_start_column := i32(0)
		text_run_color        := screen.default_foreground_color
		text_run_length       := 0
		for column_index in 0..<screen.columns {
			cell := screen.cells[row_index*screen.columns + column_index]
			effective_cell_foreground := effective_foreground(cell)
			if text_run_length == 0 {
				text_run_start_column = column_index
				text_run_color        = effective_cell_foreground
				strings.builder_reset(&text_run_builder)
			} else if !colors_are_equal(effective_cell_foreground, text_run_color) {
				draw_text_run(renderer, text_cache, &text_run_builder, terminal.rectangle.x + text_run_start_column*character_width, row_y_position, text_run_color)
				text_run_start_column = column_index
				text_run_color        = effective_cell_foreground
				text_run_length       = 0
				strings.builder_reset(&text_run_builder)
			}
			cell_character := cell.character
			if cell_character == 0 || cell_character == ' ' {
				strings.write_byte(&text_run_builder, ' ')
			} else {
				rune_bytes, rune_byte_count := utf8.encode_rune(cell_character)
				for byte_index in 0..<rune_byte_count { strings.write_byte(&text_run_builder, rune_bytes[byte_index]) }
			}
			text_run_length += 1
		}
		if text_run_length > 0 {
			draw_text_run(renderer, text_cache, &text_run_builder, terminal.rectangle.x + text_run_start_column*character_width, row_y_position, text_run_color)
		}
	}

	// Block cursor (filled rectangle over the cell at the cursor position).
	if screen.cursor_visible && terminal.cursor_visible {
		cursor_pixel_x := i32(terminal.rectangle.x) + screen.cursor_column * character_width
		cursor_pixel_y := i32(terminal.rectangle.y) + screen.cursor_row * line_height
		cursor_foreground_color := screen.default_foreground_color
		sdl3.SetRenderDrawColorFloat(renderer, cursor_foreground_color.red, cursor_foreground_color.green, cursor_foreground_color.blue, 0.6)
		sdl3.RenderFillRect(renderer, &sdl3.FRect{ f32(cursor_pixel_x), f32(cursor_pixel_y), f32(character_width), f32(line_height) })

		// Re-render the cell glyph in the background color on top of the
		// cursor so the character stays visible.
		cursor_cell := screen.cells[screen.cursor_row*screen.columns + screen.cursor_column]
		if cursor_cell.character != 0 && cursor_cell.character != ' ' {
			cursor_glyph_builder: strings.Builder
			strings.builder_init(&cursor_glyph_builder, 0, 4, context.temp_allocator)
			rune_bytes, rune_byte_count := utf8.encode_rune(cursor_cell.character)
			for byte_index in 0..<rune_byte_count { strings.write_byte(&cursor_glyph_builder, rune_bytes[byte_index]) }
			draw_text_run(renderer, text_cache, &cursor_glyph_builder, cursor_pixel_x, cursor_pixel_y, screen.default_background_color)
		}
	}
}

@(private="file")
fill_background_run :: proc(renderer: ^sdl3.Renderer, origin_x, origin_y, start_column, end_column, character_width, line_height: i32, color: Color) {
	run_rectangle := sdl3.FRect{
		f32(origin_x + start_column*character_width), f32(origin_y),
		f32((end_column - start_column) * character_width), f32(line_height),
	}
	sdl3.SetRenderDrawColorFloat(renderer, color.red, color.green, color.blue, color.alpha)
	sdl3.RenderFillRect(renderer, &run_rectangle)
}

@(private="file")
draw_text_run :: proc(renderer: ^sdl3.Renderer, text_cache: ^ui.TextCache, builder: ^strings.Builder, x_position, y_position: i32, color: Color) {
	built_text := strings.to_string(builder^)
	if len(built_text) == 0 { return }
	text_object := ui.text_cache_get(text_cache, built_text)
	if text_object == nil { return }
	_ = ttf.SetTextColorFloat(text_object, color.red, color.green, color.blue, color.alpha)
	_ = ttf.DrawRendererText(text_object, f32(x_position), f32(y_position))
}

@(private="file")
colors_are_equal :: #force_inline proc(first_color, second_color: Color) -> bool {
	return first_color.red == second_color.red && first_color.green == second_color.green && first_color.blue == second_color.blue && first_color.alpha == second_color.alpha
}

@(private="file")
effective_foreground :: #force_inline proc(cell: Cell) -> Color {
	if cell.attributes & ATTRIBUTE_REVERSE != 0 { return cell.background_color }
	return cell.foreground_color
}

@(private="file")
effective_background :: #force_inline proc(cell: Cell) -> Color {
	if cell.attributes & ATTRIBUTE_REVERSE != 0 { return cell.foreground_color }
	return cell.background_color
}
