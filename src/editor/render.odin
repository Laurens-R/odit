package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"

editor_update :: proc(ed: ^Editor, dt: f64) {
	// Smooth scroll animation toward target
	if ed.scroll_y != ed.scroll_y_target {
		factor := f32(dt * SCROLL_SMOOTHNESS)
		if factor > 1.0 { factor = 1.0 }
		ed.scroll_y += (ed.scroll_y_target - ed.scroll_y) * factor
		if abs(ed.scroll_y_target - ed.scroll_y) < 0.5 {
			ed.scroll_y = ed.scroll_y_target
		}
		if ed.line_height > 0 {
			ed.scroll_line = u32(ed.scroll_y / f32(ed.line_height))
		}
	}

	ed.cursor_timer += dt
	if ed.cursor_timer >= CURSOR_BLINK_RATE {
		ed.cursor_timer -= CURSOR_BLINK_RATE
		ed.cursor_visible = !ed.cursor_visible
	}
}

editor_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width: i32, height: i32) {
	// Calculate visible area
	status_height: i32 = ed.line_height + 4
	text_area_height := height - status_height
	ed.visible_lines = u32(text_area_height / ed.line_height)
	if ed.visible_lines == 0 { ed.visible_lines = 1 }

	// Line number gutter width (enough for 4+ digit line numbers)
	line_count := document.document_line_count(&ed.doc)
	gutter_chars := max(digit_count(line_count), 3)
	gutter_width := i32(gutter_chars + 1) * ed.char_width
	ed.gutter_width = gutter_width

	// Draw background
	sdl3.SetRenderDrawColorFloat(renderer, ed.bg_color.r, ed.bg_color.g, ed.bg_color.b, ed.bg_color.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, 0, f32(width), f32(height)})

	// Clip text rendering to the text area so partial lines don't bleed into the status bar
	text_clip := sdl3.Rect{0, 0, width, height - status_height}
	sdl3.SetRenderClipRect(renderer, &text_clip)

	// Render visible lines (+2 for partial top/bottom during smooth scroll)
	end_line := min(ed.scroll_line + ed.visible_lines + 2, line_count)

	sel_lo, sel_hi, has_sel := selection_range(ed)

	scroll_y_px := i32(ed.scroll_y)

	for line_idx := ed.scroll_line; line_idx < end_line; line_idx += 1 {
		screen_y := ed.padding_y + i32(line_idx) * ed.line_height - scroll_y_px

		// Draw line number
		line_num_str := fmt.tprintf("%*d", gutter_chars, line_idx + 1)
		render_string(ed, renderer, line_num_str, ed.padding_x, screen_y, ed.line_num_color)

		// Draw line content
		line_text := document.document_get_line(&ed.doc, line_idx)
		text_x := ed.padding_x + gutter_width

		// Draw selection highlight for this line (behind text/cursor)
		if has_sel {
			line_byte_start := document.document_line_start(&ed.doc, line_idx)
			line_byte_end := line_byte_start + u32(len(line_text)) // position of newline (or EOF)
			if sel_hi > line_byte_start && sel_lo <= line_byte_end {
				lo_col := i32(sel_lo > line_byte_start ? sel_lo - line_byte_start : 0)
				hi_col: i32
				if sel_hi > line_byte_end {
					// Selection continues past EOL — extend one char to indicate newline included
					hi_col = i32(len(line_text)) + 1
				} else {
					hi_col = i32(sel_hi - line_byte_start)
				}
				if hi_col > lo_col {
					rect := sdl3.FRect{
						f32(text_x + lo_col * ed.char_width),
						f32(screen_y),
						f32((hi_col - lo_col) * ed.char_width),
						f32(ed.line_height),
					}
					sdl3.SetRenderDrawColorFloat(renderer, ed.sel_color.r, ed.sel_color.g, ed.sel_color.b, ed.sel_color.a)
					sdl3.RenderFillRect(renderer, &rect)
				}
			}
		}

		is_cursor_line := line_idx == ed.cursor_line && ed.cursor_visible
		cursor_col_byte := int(ed.cursor_col)

		if len(line_text) > 0 {
			if is_cursor_line && cursor_col_byte < len(line_text) {
				// Render text before cursor
				if cursor_col_byte > 0 {
					render_string(ed, renderer, line_text[:cursor_col_byte], text_x, screen_y, ed.fg_color)
				}
				// Render text after cursor char
				char_end := cursor_col_byte + 1
				// Handle UTF-8: find the end of the rune
				if line_text[cursor_col_byte] >= 0xC0 {
					if line_text[cursor_col_byte] < 0xE0 { char_end = cursor_col_byte + 2 }
					else if line_text[cursor_col_byte] < 0xF0 { char_end = cursor_col_byte + 3 }
					else { char_end = cursor_col_byte + 4 }
				}
				char_end = min(char_end, len(line_text))

				if char_end < len(line_text) {
					after_x := text_x + i32(char_end) * ed.char_width
					render_string(ed, renderer, line_text[char_end:], after_x, screen_y, ed.fg_color)
				}

				// Draw block cursor
				cursor_x := text_x + i32(cursor_col_byte) * ed.char_width
				cursor_rect := sdl3.FRect{
					f32(cursor_x), f32(screen_y),
					f32(ed.char_width), f32(ed.line_height),
				}
				sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
				sdl3.RenderFillRect(renderer, &cursor_rect)

				// Draw the character under cursor with inverted color (background color)
				render_string(ed, renderer, line_text[cursor_col_byte:char_end], i32(cursor_x), screen_y, ed.bg_color)
			} else {
				render_string(ed, renderer, line_text, text_x, screen_y, ed.fg_color)
				if is_cursor_line {
					// Cursor is past end of line
					cursor_x := text_x + i32(cursor_col_byte) * ed.char_width
					cursor_rect := sdl3.FRect{
						f32(cursor_x), f32(screen_y),
						f32(ed.char_width), f32(ed.line_height),
					}
					sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
					sdl3.RenderFillRect(renderer, &cursor_rect)
				}
			}
		} else if is_cursor_line {
			// Empty line, just draw block cursor
			cursor_x := text_x
			cursor_rect := sdl3.FRect{
				f32(cursor_x), f32(screen_y),
				f32(ed.char_width), f32(ed.line_height),
			}
			sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
			sdl3.RenderFillRect(renderer, &cursor_rect)
		}
	}

	// Release the text-area clip before drawing the status bar
	sdl3.SetRenderClipRect(renderer, nil)

	// Draw status bar
	status_y := height - status_height
	sdl3.SetRenderDrawColorFloat(renderer, ed.status_bg.r, ed.status_bg.g, ed.status_bg.b, ed.status_bg.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, f32(status_y), f32(width), f32(status_height)})

	dirty_indicator := document.document_is_dirty(&ed.doc) ? "[+] " : ""
	status_text := fmt.tprintf("%sLn %d, Col %d | %d lines | %d bytes  (F1 help, F2 browse)",
		dirty_indicator,
		ed.cursor_line + 1,
		ed.cursor_col + 1,
		line_count,
		document.document_length(&ed.doc),
	)
	render_string(ed, renderer, status_text, ed.padding_x, status_y + 2, ed.status_fg)

	// Modal overlays render on top of everything else.
	if ed.show_browse {
		browse_render(ed, renderer, width, height)
	}
	if ed.show_help {
		help_render(ed, renderer, width, height)
	}
}

@(private="file")
render_string :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, str: string, x: i32, y: i32, color: sdl3.FColor) {
	if len(str) == 0 { return }

	cstr := strings.clone_to_cstring(str, context.temp_allocator)

	text_obj := ttf.CreateText(ed.engine, ed.font, cstr, 0)
	if text_obj == nil { return }
	defer ttf.DestroyText(text_obj)

	_ = ttf.SetTextColorFloat(text_obj, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_obj, f32(x), f32(y))
}

@(private="file")
digit_count :: proc(n: u32) -> u32 {
	if n == 0 { return 1 }
	count: u32 = 0
	val := n
	for val > 0 {
		count += 1
		val /= 10
	}
	return count
}
