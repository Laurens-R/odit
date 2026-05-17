package ui

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

// Drawing context — bundles the renderer plus font metrics the caller has
// already measured. Generic UI procs operate against this; they know nothing
// about the editor that owns the state.
Context :: struct {
	renderer:    ^sdl3.Renderer,
	font:        ^ttf.Font,
	engine:      ^ttf.TextEngine,
	char_width:  i32,
	line_height: i32,
}

Theme :: struct {
	overlay:    sdl3.FColor, // dim layer drawn behind dialogs
	shadow:     sdl3.FColor, // dialog drop-shadow
	panel_bg:   sdl3.FColor,
	border:     sdl3.FColor,
	title_bg:   sdl3.FColor, // background of the title strip
	title_fg:   sdl3.FColor,
	text_fg:    sdl3.FColor,
	accent_fg:  sdl3.FColor, // section headers, keys
	dim_fg:     sdl3.FColor, // footer hints, secondary text
}

default_theme :: proc() -> Theme {
	return Theme{
		overlay   = {0.00, 0.00, 0.00, 0.55},
		shadow    = {0.00, 0.00, 0.00, 0.45},
		panel_bg  = {0.10, 0.11, 0.16, 1.00},
		border    = {0.50, 0.70, 0.92, 1.00},
		title_bg  = {0.16, 0.20, 0.28, 1.00},
		title_fg  = {0.96, 0.96, 0.98, 1.00},
		text_fg   = {0.85, 0.86, 0.90, 1.00},
		accent_fg = {0.95, 0.78, 0.42, 1.00},
		dim_fg    = {0.55, 0.60, 0.66, 1.00},
	}
}

// Translucent fill across the whole framebuffer — call before drawing a modal
// so the editor underneath is visibly de-emphasized.
draw_dim_overlay :: proc(ctx: ^Context, width, height: i32, color: sdl3.FColor) {
	r := ctx.renderer
	sdl3.SetRenderDrawBlendMode(r, sdl3.BLENDMODE_BLEND)
	sdl3.SetRenderDrawColorFloat(r, color.r, color.g, color.b, color.a)
	sdl3.RenderFillRect(r, &sdl3.FRect{0, 0, f32(width), f32(height)})
	sdl3.SetRenderDrawBlendMode(r, sdl3.BLENDMODE_NONE)
}

// Draw a TUI-styled window: drop shadow, filled panel, title bar, single-line
// border, and a separator line under the title. Returns the inner content
// rectangle (already padded) so callers can lay out content without recomputing
// border math.
draw_window :: proc(ctx: ^Context, rect: sdl3.FRect, title: string, theme: Theme, content_padding: f32 = 12) -> (content: sdl3.FRect) {
	r := ctx.renderer

	// Drop shadow
	sdl3.SetRenderDrawBlendMode(r, sdl3.BLENDMODE_BLEND)
	sdl3.SetRenderDrawColorFloat(r, theme.shadow.r, theme.shadow.g, theme.shadow.b, theme.shadow.a)
	shadow_rect := sdl3.FRect{rect.x + 6, rect.y + 8, rect.w, rect.h}
	sdl3.RenderFillRect(r, &shadow_rect)
	sdl3.SetRenderDrawBlendMode(r, sdl3.BLENDMODE_NONE)

	// Panel fill
	panel_rect := rect
	sdl3.SetRenderDrawColorFloat(r, theme.panel_bg.r, theme.panel_bg.g, theme.panel_bg.b, theme.panel_bg.a)
	sdl3.RenderFillRect(r, &panel_rect)

	// Title strip
	title_h := f32(ctx.line_height) + 8
	title_rect := sdl3.FRect{rect.x, rect.y, rect.w, title_h}
	sdl3.SetRenderDrawColorFloat(r, theme.title_bg.r, theme.title_bg.g, theme.title_bg.b, theme.title_bg.a)
	sdl3.RenderFillRect(r, &title_rect)

	if len(title) > 0 {
		title_w, _ := text_size(ctx, title)
		title_x := rect.x + (rect.w - f32(title_w)) / 2
		title_y := rect.y + (title_h - f32(ctx.line_height)) / 2
		draw_text(ctx, title, i32(title_x), i32(title_y), theme.title_fg)
	}

	// Border + title separator (line drawing)
	sdl3.SetRenderDrawColorFloat(r, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
	border_rect := rect
	sdl3.RenderRect(r, &border_rect)
	sep_y := rect.y + title_h
	sdl3.RenderLine(r, rect.x, sep_y, rect.x + rect.w - 1, sep_y)

	content = sdl3.FRect{
		x = rect.x + content_padding,
		y = sep_y + content_padding,
		w = rect.w - content_padding * 2,
		h = rect.h - title_h - content_padding * 2,
	}
	return
}

// Draw a single horizontal rule inside a content area — useful for separating
// sections within a window.
draw_hrule :: proc(ctx: ^Context, x, y, length: i32, color: sdl3.FColor) {
	sdl3.SetRenderDrawColorFloat(ctx.renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderLine(ctx.renderer, f32(x), f32(y), f32(x + length - 1), f32(y))
}

// Single selectable list row. When `selected`, draws a highlight background and
// an accent stripe on the left edge; otherwise draws plain text. `width` is the
// pixel width of the row area.
draw_list_row :: proc(ctx: ^Context, x, y, width: i32, label: string, selected: bool, theme: Theme) {
	if selected {
		bg := sdl3.FRect{f32(x), f32(y), f32(width), f32(ctx.line_height)}
		sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.title_bg.r, theme.title_bg.g, theme.title_bg.b, theme.title_bg.a)
		sdl3.RenderFillRect(ctx.renderer, &bg)

		stripe := sdl3.FRect{f32(x), f32(y), 2, f32(ctx.line_height)}
		sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.accent_fg.r, theme.accent_fg.g, theme.accent_fg.b, theme.accent_fg.a)
		sdl3.RenderFillRect(ctx.renderer, &stripe)
	}

	text_color := selected ? theme.title_fg : theme.text_fg
	draw_text(ctx, label, x + 8, y, text_color)
}

// Single-line read-only display of a text field: label (in dim color), value
// (in primary color), a block cursor at the end, and an underline rule across
// the field's width.
draw_input_field :: proc(ctx: ^Context, x, y, width: i32, label, value: string, theme: Theme) {
	cursor_x := x
	if len(label) > 0 {
		draw_text(ctx, label, x, y, theme.dim_fg)
		lw, _ := text_size(ctx, label)
		cursor_x += lw
	}

	if len(value) > 0 {
		draw_text(ctx, value, cursor_x, y, theme.text_fg)
		vw, _ := text_size(ctx, value)
		cursor_x += vw
	}

	// Block cursor at end of value
	cursor_rect := sdl3.FRect{f32(cursor_x), f32(y), f32(ctx.char_width), f32(ctx.line_height)}
	sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.accent_fg.r, theme.accent_fg.g, theme.accent_fg.b, theme.accent_fg.a)
	sdl3.RenderFillRect(ctx.renderer, &cursor_rect)

	// Underline rule
	underline_y := y + ctx.line_height + 2
	sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
	sdl3.RenderLine(ctx.renderer, f32(x), f32(underline_y), f32(x + width - 1), f32(underline_y))
}

draw_text :: proc(ctx: ^Context, str: string, x, y: i32, color: sdl3.FColor) {
	if len(str) == 0 { return }
	cstr := strings.clone_to_cstring(str, context.temp_allocator)
	text_obj := ttf.CreateText(ctx.engine, ctx.font, cstr, 0)
	if text_obj == nil { return }
	defer ttf.DestroyText(text_obj)
	_ = ttf.SetTextColorFloat(text_obj, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_obj, f32(x), f32(y))
}

text_size :: proc(ctx: ^Context, str: string) -> (w: i32, h: i32) {
	if len(str) == 0 { return 0, 0 }
	cstr := strings.clone_to_cstring(str, context.temp_allocator)
	ttf.GetStringSize(ctx.font, cstr, 0, &w, &h)
	return
}
