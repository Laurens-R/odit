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

// Handle representing an in-progress scrollable region. Returned by
// `scroll_view_begin` and passed to `scroll_view_end` to close it.
ScrollView :: struct {
	ctx:            ^Context,
	viewport:       sdl3.FRect,
	scroll_value:   i32, // already clamped
	content_height: i32,
}

// Begin a scrollable region inside `viewport`. Clamps `scroll^` to the valid
// range `[0, max(0, content_height - viewport.h)]`, installs a clip rect, and
// returns the *content origin* where the caller should start drawing. The
// returned `origin_y` already includes the scroll offset, so content laid out
// from `origin_y` downward at natural intervals will scroll for free.
//
// Pair with `scroll_view_end` to drop the clip rect and draw a scrollbar.
scroll_view_begin :: proc(ctx: ^Context, viewport: sdl3.FRect, scroll: ^i32, content_height: i32) -> (origin_x, origin_y: i32, view: ScrollView) {
	max_scroll := max(i32(0), content_height - i32(viewport.h))
	if scroll^ < 0          { scroll^ = 0 }
	if scroll^ > max_scroll { scroll^ = max_scroll }

	clip := sdl3.Rect{i32(viewport.x), i32(viewport.y), i32(viewport.w), i32(viewport.h)}
	sdl3.SetRenderClipRect(ctx.renderer, &clip)

	origin_x = i32(viewport.x)
	origin_y = i32(viewport.y) - scroll^

	view = ScrollView{
		ctx            = ctx,
		viewport       = viewport,
		scroll_value   = scroll^,
		content_height = content_height,
	}
	return
}

// Finish a scrollable region: clear the clip rect and draw a scrollbar on the
// right edge of the viewport. Safe to call even when content fits — the
// scrollbar simply isn't drawn in that case.
scroll_view_end :: proc(view: ScrollView, theme: Theme) {
	sdl3.SetRenderClipRect(view.ctx.renderer, nil)

	sb_x := i32(view.viewport.x + view.viewport.w) + 2
	_, _ = draw_scrollbar(view.ctx, sb_x, i32(view.viewport.y), i32(view.viewport.h),
		f32(view.content_height), f32(view.viewport.h), f32(view.scroll_value), 6, theme)
}

// Draw a vertical scrollbar (track + thumb) on the right edge of a content
// area. `track_x` is the left edge of the track, `track_y` is its top, and
// `track_h` is its height. `content_h` is the total scrollable content size;
// `viewport_h` is the visible portion; `scroll` is the current scroll offset
// from the top of the content. No-op if the content fits in the viewport.
// Draw a vertical scrollbar inside `track_h` pixels starting at (track_x,
// track_y). Returns the painted track and thumb rects so callers can use
// them for hit-testing. Caller controls `width` so it can widen on hover.
// Returns zero-rects (both width/height = 0) when the content fits in the
// viewport — interactive code should treat that as "no scrollbar".
draw_scrollbar :: proc(ctx: ^Context, track_x, track_y, track_h: i32, content_h, viewport_h, scroll: f32, width: i32, theme: Theme) -> (track_rect: sdl3.FRect, thumb_rect: sdl3.FRect) {
	if content_h <= viewport_h { return }

	r := ctx.renderer

	track_rect = sdl3.FRect{f32(track_x), f32(track_y), f32(width), f32(track_h)}
	sdl3.SetRenderDrawColorFloat(r, theme.title_bg.r, theme.title_bg.g, theme.title_bg.b, theme.title_bg.a)
	sdl3.RenderFillRect(r, &track_rect)

	thumb_h := max(f32(20), f32(track_h) * viewport_h / content_h)
	max_scroll := content_h - viewport_h
	frac := scroll / max_scroll
	if frac < 0 { frac = 0 }
	if frac > 1 { frac = 1 }
	thumb_y := f32(track_y) + (f32(track_h) - thumb_h) * frac

	thumb_rect = sdl3.FRect{f32(track_x) + 1, thumb_y, f32(width) - 2, thumb_h}
	sdl3.SetRenderDrawColorFloat(r, theme.accent_fg.r, theme.accent_fg.g, theme.accent_fg.b, theme.accent_fg.a)
	sdl3.RenderFillRect(r, &thumb_rect)
	return
}

// Draw a single horizontal rule inside a content area — useful for separating
// sections within a window.
draw_hrule :: proc(ctx: ^Context, x, y, length: i32, color: sdl3.FColor) {
	sdl3.SetRenderDrawColorFloat(ctx.renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderLine(ctx.renderer, f32(x), f32(y), f32(x + length - 1), f32(y))
}

// Icon kinds usable as a row prefix on `draw_list_row`. Keep this enum small
// — the renderer dispatches on it.
ListRowIcon :: enum {
	None,
	Folder,
	File,
}

// Draws a small folder glyph using line primitives — a tab on top-left and a
// body underneath. Sizes scale from the `size` argument; pass roughly
// `line_height - 6` for icons that align with text rows.
draw_folder_icon :: proc(ctx: ^Context, x, y, size: i32, color: sdl3.FColor) {
	r := ctx.renderer
	sdl3.SetRenderDrawColorFloat(r, color.r, color.g, color.b, color.a)

	tab_w := size * 5 / 12
	tab_h := size / 4
	bottom := y + size - 1
	right  := x + size - 1

	// Outline: top of tab → right of tab → top of body → right → bottom → left
	sdl3.RenderLine(r, f32(x),         f32(y),          f32(x + tab_w), f32(y))
	sdl3.RenderLine(r, f32(x + tab_w), f32(y),          f32(x + tab_w), f32(y + tab_h))
	sdl3.RenderLine(r, f32(x + tab_w), f32(y + tab_h),  f32(right),     f32(y + tab_h))
	sdl3.RenderLine(r, f32(right),     f32(y + tab_h),  f32(right),     f32(bottom))
	sdl3.RenderLine(r, f32(right),     f32(bottom),     f32(x),         f32(bottom))
	sdl3.RenderLine(r, f32(x),         f32(bottom),     f32(x),         f32(y))
}

// Draws a small file/page glyph with a dog-eared top-right corner.
draw_file_icon :: proc(ctx: ^Context, x, y, size: i32, color: sdl3.FColor) {
	r := ctx.renderer
	sdl3.SetRenderDrawColorFloat(r, color.r, color.g, color.b, color.a)

	w    := size * 3 / 4
	fold := size / 4
	right  := x + w
	bottom := y + size - 1

	// Outline: top edge stops short of corner, diagonal, right edge, bottom, left
	sdl3.RenderLine(r, f32(x),            f32(y),          f32(right - fold), f32(y))
	sdl3.RenderLine(r, f32(right - fold), f32(y),          f32(right),        f32(y + fold))
	sdl3.RenderLine(r, f32(right),        f32(y + fold),   f32(right),        f32(bottom))
	sdl3.RenderLine(r, f32(right),        f32(bottom),     f32(x),            f32(bottom))
	sdl3.RenderLine(r, f32(x),            f32(bottom),     f32(x),            f32(y))

	// Dog-ear fold detail: a small inset square at the corner
	sdl3.RenderLine(r, f32(right - fold), f32(y),          f32(right - fold), f32(y + fold))
	sdl3.RenderLine(r, f32(right - fold), f32(y + fold),   f32(right),        f32(y + fold))
}

// Single selectable list row. When `selected`, draws a highlight background and
// an accent stripe on the left edge. Optionally prefixed with a small icon. If
// `label_color_override` is non-nil it replaces the default fg colour for the
// label (typically used to tint git-modified entries, errors, etc.).
draw_list_row :: proc(
	ctx: ^Context, x, y, width: i32, label: string, selected: bool, theme: Theme,
	icon: ListRowIcon = .None,
	label_color_override: Maybe(sdl3.FColor) = nil,
) {
	if selected {
		bg := sdl3.FRect{f32(x), f32(y), f32(width), f32(ctx.line_height)}
		sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.title_bg.r, theme.title_bg.g, theme.title_bg.b, theme.title_bg.a)
		sdl3.RenderFillRect(ctx.renderer, &bg)

		stripe := sdl3.FRect{f32(x), f32(y), 2, f32(ctx.line_height)}
		sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.accent_fg.r, theme.accent_fg.g, theme.accent_fg.b, theme.accent_fg.a)
		sdl3.RenderFillRect(ctx.renderer, &stripe)
	}

	label_x := x + 8

	if icon != .None {
		icon_size := ctx.line_height - 6
		icon_x := x + 10
		icon_y := y + 3
		icon_color: sdl3.FColor
		switch icon {
		case .Folder: icon_color = theme.accent_fg
		case .File:   icon_color = selected ? theme.title_fg : theme.dim_fg
		case .None:   // unreachable
		}
		switch icon {
		case .Folder: draw_folder_icon(ctx, icon_x, icon_y, icon_size, icon_color)
		case .File:   draw_file_icon(ctx, icon_x, icon_y, icon_size, icon_color)
		case .None:   // unreachable
		}
		label_x = icon_x + icon_size + 6
	}

	text_color := selected ? theme.title_fg : theme.text_fg
	if override, ok := label_color_override.?; ok {
		text_color = override
	}
	draw_text(ctx, label, label_x, y, text_color)
}

// Single-line text input: label (in dim color), value (in primary color),
// a block cursor at the end when focused, and an underline rule. When
// `focused` is false, the cursor is hidden and the underline uses the
// neutral border color instead of the accent color.
draw_input_field :: proc(ctx: ^Context, x, y, width: i32, label, value: string, theme: Theme, focused := true) {
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

	if focused {
		cursor_rect := sdl3.FRect{f32(cursor_x), f32(y), f32(ctx.char_width), f32(ctx.line_height)}
		sdl3.SetRenderDrawColorFloat(ctx.renderer, theme.accent_fg.r, theme.accent_fg.g, theme.accent_fg.b, theme.accent_fg.a)
		sdl3.RenderFillRect(ctx.renderer, &cursor_rect)
	}

	rule_color := focused ? theme.accent_fg : theme.border
	underline_y := y + ctx.line_height + 2
	sdl3.SetRenderDrawColorFloat(ctx.renderer, rule_color.r, rule_color.g, rule_color.b, rule_color.a)
	sdl3.RenderLine(ctx.renderer, f32(x), f32(underline_y), f32(x + width - 1), f32(underline_y))
}

// Draws a labelled, optionally-focused rectangular button. The caller owns
// the rect (typically stored as state from frame to frame so mouse hits can
// be tested against the same coordinates that were rendered).
draw_button :: proc(ctx: ^Context, rect: sdl3.FRect, label: string, focused: bool, theme: Theme) {
	r := ctx.renderer

	// Background fill
	bg := focused ? theme.title_bg : theme.panel_bg
	sdl3.SetRenderDrawColorFloat(r, bg.r, bg.g, bg.b, bg.a)
	bg_rect := rect
	sdl3.RenderFillRect(r, &bg_rect)

	// Border — accent when focused, neutral otherwise. Double-stroke the
	// focused state for a thicker, unmissable outline.
	border := focused ? theme.accent_fg : theme.border
	sdl3.SetRenderDrawColorFloat(r, border.r, border.g, border.b, border.a)
	br := rect
	sdl3.RenderRect(r, &br)
	if focused {
		inner := sdl3.FRect{rect.x + 1, rect.y + 1, rect.w - 2, rect.h - 2}
		sdl3.RenderRect(r, &inner)
	}

	// Centered label
	label_w, _ := text_size(ctx, label)
	label_x := i32(rect.x + (rect.w - f32(label_w)) / 2)
	label_y := i32(rect.y + (rect.h - f32(ctx.line_height)) / 2)
	draw_text(ctx, label, label_x, label_y, theme.title_fg)
}

// Geometric hit-test used by callers to decide which widget a click landed in.
point_in_rect :: proc(rect: sdl3.FRect, x, y: f32) -> bool {
	return x >= rect.x && x < rect.x + rect.w &&
	       y >= rect.y && y < rect.y + rect.h
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
