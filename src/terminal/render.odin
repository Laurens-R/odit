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
// `cache` is the editor's shared `ui.TextCache`. Going through it instead of
// `ttf.CreateText` / `ttf.DestroyText` cuts per-frame GPU texture churn
// dramatically — most rows repeat unchanged frame-to-frame.
terminal_render :: proc(t: ^Terminal, renderer: ^sdl3.Renderer, font: ^ttf.Font, engine: ^ttf.TextEngine, cache: ^ui.TextCache) {
	if t == nil { return }
	s := &t.screen
	if t.char_width <= 0 || t.line_height <= 0 { return }

	// Solid background.
	bg := s.default_bg
	sdl3.SetRenderDrawColorFloat(renderer, bg.r, bg.g, bg.b, bg.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{
		f32(t.rect.x), f32(t.rect.y), f32(t.rect.w), f32(t.rect.h),
	})

	// Per-row pass: contiguous runs of cells that share fg/bg/attrs render
	// together as one text-call. This keeps per-frame work tied to the
	// number of *spans* on screen, not to cols*rows.
	cw, lh := t.char_width, t.line_height
	for row in 0..<s.rows {
		y := i32(t.rect.y) + row * lh

		// First pass: paint background rectangles for any cell whose bg
		// differs from the screen default. Coalesce adjacent equal-bg
		// cells into one rect.
		run_start := i32(-1)
		run_bg    := bg
		for col in 0..<s.cols {
			cell := s.cells[row*s.cols + col]
			cb := effective_bg(cell)
			if !color_equal(cb, bg) {
				if run_start < 0 || !color_equal(cb, run_bg) {
					if run_start >= 0 { fill_run(renderer, t.rect.x, y, run_start, col, cw, lh, run_bg) }
					run_start = col
					run_bg    = cb
				}
			} else if run_start >= 0 {
				fill_run(renderer, t.rect.x, y, run_start, col, cw, lh, run_bg)
				run_start = -1
			}
		}
		if run_start >= 0 { fill_run(renderer, t.rect.x, y, run_start, s.cols, cw, lh, run_bg) }

		// Second pass: glyphs. Build runes per fg-run and submit each run
		// as one CreateText/Draw pair.
		sb: strings.Builder
		strings.builder_init(&sb, 0, int(s.cols)*4, context.temp_allocator)

		run_col   := i32(0)
		run_fg    := s.default_fg
		run_len   := 0
		for col in 0..<s.cols {
			cell := s.cells[row*s.cols + col]
			cf := effective_fg(cell)
			if run_len == 0 {
				run_col = col
				run_fg  = cf
				strings.builder_reset(&sb)
			} else if !color_equal(cf, run_fg) {
				draw_run(renderer, cache, &sb, t.rect.x + run_col*cw, y, run_fg)
				run_col = col
				run_fg  = cf
				run_len = 0
				strings.builder_reset(&sb)
			}
			r := cell.ch
			if r == 0 || r == ' ' {
				strings.write_byte(&sb, ' ')
			} else {
				bytes, sz := utf8.encode_rune(r)
				for k in 0..<sz { strings.write_byte(&sb, bytes[k]) }
			}
			run_len += 1
		}
		if run_len > 0 {
			draw_run(renderer, cache, &sb, t.rect.x + run_col*cw, y, run_fg)
		}
	}

	// Block cursor (filled rectangle over the cell at the cursor position).
	if s.cursor_visible && t.cursor_visible {
		cx := i32(t.rect.x) + s.cursor_col * cw
		cy := i32(t.rect.y) + s.cursor_row * lh
		fg := s.default_fg
		sdl3.SetRenderDrawColorFloat(renderer, fg.r, fg.g, fg.b, 0.6)
		sdl3.RenderFillRect(renderer, &sdl3.FRect{ f32(cx), f32(cy), f32(cw), f32(lh) })

		// Re-render the cell glyph in the background color on top of the
		// cursor so the character stays visible.
		cell := s.cells[s.cursor_row*s.cols + s.cursor_col]
		if cell.ch != 0 && cell.ch != ' ' {
			sb: strings.Builder
			strings.builder_init(&sb, 0, 4, context.temp_allocator)
			bytes, sz := utf8.encode_rune(cell.ch)
			for k in 0..<sz { strings.write_byte(&sb, bytes[k]) }
			draw_run(renderer, cache, &sb, cx, cy, s.default_bg)
		}
	}
}

@(private="file")
fill_run :: proc(renderer: ^sdl3.Renderer, ox, oy, start_col, end_col, cw, lh: i32, color: Color) {
	rect := sdl3.FRect{
		f32(ox + start_col*cw), f32(oy),
		f32((end_col - start_col) * cw), f32(lh),
	}
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderFillRect(renderer, &rect)
}

@(private="file")
draw_run :: proc(renderer: ^sdl3.Renderer, cache: ^ui.TextCache, sb: ^strings.Builder, x, y: i32, color: Color) {
	s := strings.to_string(sb^)
	if len(s) == 0 { return }
	text_obj := ui.text_cache_get(cache, s)
	if text_obj == nil { return }
	_ = ttf.SetTextColorFloat(text_obj, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_obj, f32(x), f32(y))
}

@(private="file")
color_equal :: #force_inline proc(a, b: Color) -> bool {
	return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
}

@(private="file")
effective_fg :: #force_inline proc(c: Cell) -> Color {
	if c.attrs & ATTR_REVERSE != 0 { return c.bg }
	return c.fg
}

@(private="file")
effective_bg :: #force_inline proc(c: Cell) -> Color {
	if c.attrs & ATTR_REVERSE != 0 { return c.fg }
	return c.bg
}
