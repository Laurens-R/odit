// Block rendering. Takes a previously laid-out `LayoutedBlock` and paints
// it onto `ctx.renderer` at `(x_start, y_start)`. Reads colors from
// `ctx.theme` so the host controls the palette — the markdown package
// doesn't bake any color choices in beyond the heading shading curve
// (which still varies by level and is intentionally consistent across
// callers; see `heading_color`).
package markdown

import "vendor:sdl3"
import "vendor:sdl3/ttf"

// Pixel radius for rounded code-block backgrounds.
@(private="file")
CODE_CORNER_RADIUS_BLOCK  :: 5
@(private="file")
CODE_CORNER_RADIUS_INLINE :: 3

// Paint one previously laid-out block. `usable_text_pixels` is the same
// value the caller passed to `layout_block` and bounds underlines,
// horizontal rules, and the code-block slab.
render_layouted_block :: proc(ctx: ^Context, layouted: ^LayoutedBlock, x_start, y_start, usable_text_pixels: i32) {
	block    := layouted.block
	renderer := ctx.renderer
	if renderer == nil { return }

	step := body_line_step(ctx)

	switch block.kind {
	case .BlankLine:
		return

	case .HorizontalRule:
		rule_y := y_start + step / 2
		c := ctx.theme.horizontal_rule
		sdl3.SetRenderDrawColorFloat(renderer, c.r, c.g, c.b, c.a)
		sdl3.RenderLine(renderer, f32(x_start), f32(rule_y), f32(x_start + usable_text_pixels), f32(rule_y))
		return

	case .Heading:
		level_index := block.level - 1
		if level_index < 0 { level_index = 0 }
		if level_index > 5 { level_index = 5 }
		heading_line_height := ctx.fonts.heading_line_heights[level_index]
		if heading_line_height <= 0 { heading_line_height = step + 4 }
		hc := heading_color(block.level)

		// Top padding pushes the first heading line away from the previous block.
		top_padding: i32 = 10
		current_y := y_start + top_padding

		for visual_line in layouted.visual_lines {
			render_visual_line(ctx, visual_line, x_start, current_y, hc)
			current_y += heading_line_height
		}

		// Full-width underline beneath the last rendered line.
		underline_y := current_y + 2
		sdl3.SetRenderDrawColorFloat(renderer, hc.r, hc.g, hc.b, hc.a)
		// Make the underline noticeable on H1/H2 (2 px), thin (1 px) on lower levels.
		thickness: i32 = block.level <= 2 ? 2 : 1
		for offset_index in 0..<thickness {
			sdl3.RenderLine(renderer, f32(x_start), f32(underline_y + offset_index), f32(x_start + usable_text_pixels), f32(underline_y + offset_index))
		}
		return

	case .CodeBlock:
		code_line_height := ctx.fonts.code_line_height
		if code_line_height <= 0 { code_line_height = step }

		code_line_count := len(layouted.code_lines)
		if code_line_count < 1 { code_line_count = 1 }

		// Slab spans the same horizontal margins as a horizontal rule so
		// code blocks line up vertically with every other body block.
		// Text inside is inset a few pixels so glyphs don't graze the
		// rounded corners.
		code_text_inset: i32 = 8
		background_rectangle := sdl3.FRect{
			f32(x_start),
			f32(y_start),
			f32(usable_text_pixels),
			f32(code_line_count * int(code_line_height) + 12),
		}
		draw_rounded_filled_rect(renderer, background_rectangle, CODE_CORNER_RADIUS_BLOCK, ctx.theme.code_block_bg)

		code_color := ctx.theme.code_block
		current_y := y_start + 6
		for code_line in layouted.code_lines {
			draw_cached_text(code_line.text_object, x_start + code_text_inset, current_y, code_color)
			current_y += code_line_height
		}
		return

	case .BlockQuote:
		quote_indent: i32 = 16
		quote_text_x := x_start + quote_indent
		bar_height_pixels: i32 = step
		if len(layouted.visual_lines) > 0 { bar_height_pixels = i32(len(layouted.visual_lines)) * step }
		bar := ctx.theme.quote_bar
		bar_rectangle := sdl3.FRect{f32(x_start + 4), f32(y_start), 3, f32(bar_height_pixels)}
		sdl3.SetRenderDrawColorFloat(renderer, bar.r, bar.g, bar.b, bar.a)
		sdl3.RenderFillRect(renderer, &bar_rectangle)

		quote_default_color := ctx.theme.quote_text
		current_y := y_start
		for visual_line in layouted.visual_lines {
			render_visual_line(ctx, visual_line, quote_text_x, current_y, quote_default_color)
			current_y += step
		}
		return

	case .ListItem:
		marker_color := ctx.theme.list_marker
		// Push nested bullets further right.
		marker_x := x_start + i32(block.list_depth) * i32(LIST_DEPTH_INDENT)
		draw_cached_text(layouted.marker_text_object, marker_x, y_start, marker_color)
		text_left_x := marker_x + layouted.marker_width + 4

		current_y := y_start
		for visual_line in layouted.visual_lines {
			render_visual_line(ctx, visual_line, text_left_x, current_y, ctx.theme.text)
			current_y += step
		}
		return

	case .Paragraph:
		current_y := y_start
		for visual_line in layouted.visual_lines {
			render_visual_line(ctx, visual_line, x_start, current_y, ctx.theme.text)
			current_y += step
		}
		return
	}
}

// Heading shading curve, indexed by level. Hardcoded across callers
// (preview, hover, signature popup) so headings read consistently in
// every markdown surface.
@(private="file")
heading_color :: proc(level: int) -> sdl3.FColor {
	switch level {
	case 1: return sdl3.FColor{0.96, 0.86, 0.60, 1.0}
	case 2: return sdl3.FColor{0.92, 0.82, 0.58, 1.0}
	case 3: return sdl3.FColor{0.86, 0.78, 0.58, 1.0}
	case 4: return sdl3.FColor{0.80, 0.74, 0.60, 1.0}
	case 5: return sdl3.FColor{0.76, 0.72, 0.62, 1.0}
	}
	return sdl3.FColor{0.72, 0.70, 0.64, 1.0}
}

@(private="file")
render_visual_line :: proc(ctx: ^Context, visual_line: VisualLine, x_start, y: i32, default_color: sdl3.FColor) {
	renderer := ctx.renderer
	// Hoist line-height lookups out of the inner loop — these are
	// pane-wide and only need to be resolved once per visual line, not
	// per atom.
	body_line_height := ctx.fonts.body_line_height
	if body_line_height <= 0 { body_line_height = ctx.monospace_line_height }
	code_line_height := ctx.fonts.code_line_height
	if code_line_height <= 0 { code_line_height = ctx.monospace_line_height }
	code_background_color := ctx.theme.code_inline_bg

	current_x := x_start
	for atom in visual_line.atoms {
		span_pixel_width := atom.pixel_width

		if atom.is_space {
			current_x += span_pixel_width
			continue
		}

		// Inline code spans get a faint background slab with subtle
		// rounded corners so they read as code chips against the
		// surrounding text.
		if atom.kind == .Code {
			code_bg_rectangle := sdl3.FRect{f32(current_x - 3), f32(y), f32(span_pixel_width + 6), f32(code_line_height)}
			draw_rounded_filled_rect(renderer, code_bg_rectangle, CODE_CORNER_RADIUS_INLINE, code_background_color)
		}

		atom_color := default_color
		switch atom.kind {
		case .Plain:  // default_color (per-block: paragraph color, quote color, etc.)
		case .Bold:   atom_color = ctx.theme.bold
		case .Italic: atom_color = ctx.theme.italic
		case .Code:   atom_color = ctx.theme.code_inline
		case .Link:   atom_color = ctx.theme.link
		}

		draw_cached_text(atom.text_object, current_x, y, atom_color)

		if atom.kind == .Link {
			underline_y := y + body_line_height - 2
			sdl3.SetRenderDrawColorFloat(renderer, atom_color.r, atom_color.g, atom_color.b, atom_color.a)
			sdl3.RenderLine(renderer, f32(current_x), f32(underline_y), f32(current_x + span_pixel_width - 1), f32(underline_y))
		}

		current_x += span_pixel_width
	}
}

// Draw a cached text object at (x, y) in `color`. SetTextColorFloat
// mutates the object, so atoms shared across colors would corrupt each
// other — every atom owns its own object, so this is safe.
@(private="file")
draw_cached_text :: proc(text_object: ^ttf.Text, x, y: i32, color: sdl3.FColor) {
	if text_object == nil { return }
	_ = ttf.SetTextColorFloat(text_object, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_object, f32(x), f32(y))
}

// Paint a filled rectangle with circular corners of radius
// `corner_radius`. Falls back to a normal RenderFillRect when the radius
// is small enough that rounding would be invisible. Uses the
// SDL_RenderFillRect path for the body + per-row horizontal strips on
// top/bottom; each strip's width follows a circular profile so the
// corners look smooth rather than chamfered.
@(private="file")
draw_rounded_filled_rect :: proc(renderer: ^sdl3.Renderer, rect: sdl3.FRect, corner_radius: f32, color: sdl3.FColor) {
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	radius := corner_radius
	rect_local := rect
	if radius < 1 || rect.w < 2*radius || rect.h < 2*radius {
		sdl3.RenderFillRect(renderer, &rect_local)
		return
	}
	radius_i := i32(radius)

	body_rect := sdl3.FRect{rect.x, rect.y + f32(radius_i), rect.w, rect.h - 2 * f32(radius_i)}
	sdl3.RenderFillRect(renderer, &body_rect)

	for row_offset in 0..<radius_i {
		dy := f32(radius_i) - f32(row_offset) - 0.5
		dx_max_sq := f32(radius_i)*f32(radius_i) - dy*dy
		if dx_max_sq < 0 { dx_max_sq = 0 }
		inset := f32(radius_i) - sqrt_f32(dx_max_sq)
		if inset > f32(radius_i) { inset = f32(radius_i) }

		strip_y_top := rect.y + f32(row_offset)
		strip_y_bot := rect.y + rect.h - 1 - f32(row_offset)
		strip_x     := rect.x + inset
		strip_width := rect.w - 2 * inset
		if strip_width < 1 { continue }

		top_strip := sdl3.FRect{strip_x, strip_y_top, strip_width, 1}
		bot_strip := sdl3.FRect{strip_x, strip_y_bot, strip_width, 1}
		sdl3.RenderFillRect(renderer, &top_strip)
		sdl3.RenderFillRect(renderer, &bot_strip)
	}
}

// Tiny dependency-free sqrt — keeps the package off `core:math`. Eight
// Newton iterations is good to ~1e-10 for the small radii we use here.
@(private="file")
sqrt_f32 :: proc(value: f32) -> f32 {
	if value <= 0 { return 0 }
	guess := value * 0.5
	for _ in 0..<8 { guess = 0.5 * (guess + value / guess) }
	return guess
}
