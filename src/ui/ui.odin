package ui

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

// Drawing context — bundles the renderer plus font metrics the caller has
// already measured. Generic UI procs operate against this; they know nothing
// about the editor that owns the state.
Context :: struct {
	renderer:        ^sdl3.Renderer,
	font:            ^ttf.Font,
	engine:          ^ttf.TextEngine,
	character_width: i32,
	line_height:     i32,
}

Theme :: struct {
	overlay:           sdl3.FColor, // dim layer drawn behind dialogs
	shadow:            sdl3.FColor, // dialog drop-shadow
	panel_background: sdl3.FColor,
	border:            sdl3.FColor,
	title_background: sdl3.FColor, // background of the title strip
	title_foreground: sdl3.FColor,
	text_foreground:  sdl3.FColor,
	accent_foreground: sdl3.FColor, // section headers, keys
	dim_foreground:   sdl3.FColor, // footer hints, secondary text
}

default_theme :: proc() -> Theme {
	return Theme{
		overlay            = {0.00, 0.00, 0.00, 0.55},
		shadow             = {0.00, 0.00, 0.00, 0.45},
		panel_background  = {0.10, 0.11, 0.16, 1.00},
		border             = {0.50, 0.70, 0.92, 1.00},
		title_background  = {0.16, 0.20, 0.28, 1.00},
		title_foreground  = {0.96, 0.96, 0.98, 1.00},
		text_foreground   = {0.85, 0.86, 0.90, 1.00},
		accent_foreground = {0.95, 0.78, 0.42, 1.00},
		dim_foreground    = {0.55, 0.60, 0.66, 1.00},
	}
}

// Translucent fill across the whole framebuffer — call before drawing a modal
// so the editor underneath is visibly de-emphasized.
draw_dim_overlay :: proc(ui_context: ^Context, width, height: i32, color: sdl3.FColor) {
	renderer := ui_context.renderer
	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_BLEND)
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, 0, f32(width), f32(height)})
	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_NONE)
}

// Draw a TUI-styled window: drop shadow, filled panel, title bar, single-line
// border, and a separator line under the title. Returns the inner content
// rectangle (already padded) so callers can lay out content without recomputing
// border math.
draw_window :: proc(ui_context: ^Context, window_rectangle: sdl3.FRect, title: string, theme: Theme, content_padding: f32 = 12) -> (content_rectangle: sdl3.FRect) {
	renderer := ui_context.renderer

	// Drop shadow
	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_BLEND)
	sdl3.SetRenderDrawColorFloat(renderer, theme.shadow.r, theme.shadow.g, theme.shadow.b, theme.shadow.a)
	shadow_rectangle := sdl3.FRect{window_rectangle.x + 6, window_rectangle.y + 8, window_rectangle.w, window_rectangle.h}
	sdl3.RenderFillRect(renderer, &shadow_rectangle)
	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_NONE)

	// Panel fill
	panel_rectangle := window_rectangle
	sdl3.SetRenderDrawColorFloat(renderer, theme.panel_background.r, theme.panel_background.g, theme.panel_background.b, theme.panel_background.a)
	sdl3.RenderFillRect(renderer, &panel_rectangle)

	// Title strip
	title_height := f32(ui_context.line_height) + 8
	title_rectangle := sdl3.FRect{window_rectangle.x, window_rectangle.y, window_rectangle.w, title_height}
	sdl3.SetRenderDrawColorFloat(renderer, theme.title_background.r, theme.title_background.g, theme.title_background.b, theme.title_background.a)
	sdl3.RenderFillRect(renderer, &title_rectangle)

	if len(title) > 0 {
		title_width, _ := text_size(ui_context, title)
		title_position_x := window_rectangle.x + (window_rectangle.w - f32(title_width)) / 2
		title_position_y := window_rectangle.y + (title_height - f32(ui_context.line_height)) / 2
		draw_text(ui_context, title, i32(title_position_x), i32(title_position_y), theme.title_foreground)
	}

	// Border + title separator (line drawing)
	sdl3.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
	border_rectangle := window_rectangle
	sdl3.RenderRect(renderer, &border_rectangle)
	separator_y := window_rectangle.y + title_height
	sdl3.RenderLine(renderer, window_rectangle.x, separator_y, window_rectangle.x + window_rectangle.w - 1, separator_y)

	content_rectangle = sdl3.FRect{
		x = window_rectangle.x + content_padding,
		y = separator_y + content_padding,
		w = window_rectangle.w - content_padding * 2,
		h = window_rectangle.h - title_height - content_padding * 2,
	}
	return
}

// Handle representing an in-progress scrollable region. Returned by
// `scroll_view_begin` and passed to `scroll_view_end` to close it.
ScrollView :: struct {
	ui_context:     ^Context,
	viewport:       sdl3.FRect,
	scroll_value:   i32, // already clamped
	content_height: i32,
}

// Begin a scrollable region inside `viewport`. Clamps `scroll_value^` to the
// valid range `[0, max(0, content_height - viewport.h)]`, installs a clip
// rect, and returns the *content origin* where the caller should start
// drawing. The returned `origin_y` already includes the scroll offset, so
// content laid out from `origin_y` downward at natural intervals will scroll
// for free.
//
// Pair with `scroll_view_end` to drop the clip rect and draw a scrollbar.
scroll_view_begin :: proc(ui_context: ^Context, viewport: sdl3.FRect, scroll_value: ^i32, content_height: i32) -> (origin_x, origin_y: i32, scroll_view: ScrollView) {
	max_scroll := max(i32(0), content_height - i32(viewport.h))
	if scroll_value^ < 0          { scroll_value^ = 0 }
	if scroll_value^ > max_scroll { scroll_value^ = max_scroll }

	clip_rectangle := sdl3.Rect{i32(viewport.x), i32(viewport.y), i32(viewport.w), i32(viewport.h)}
	sdl3.SetRenderClipRect(ui_context.renderer, &clip_rectangle)

	origin_x = i32(viewport.x)
	origin_y = i32(viewport.y) - scroll_value^

	scroll_view = ScrollView{
		ui_context     = ui_context,
		viewport       = viewport,
		scroll_value   = scroll_value^,
		content_height = content_height,
	}
	return
}

// Finish a scrollable region: clear the clip rect and draw a scrollbar on the
// right edge of the viewport. Safe to call even when content fits — the
// scrollbar simply isn't drawn in that case.
scroll_view_end :: proc(scroll_view: ScrollView, theme: Theme) {
	sdl3.SetRenderClipRect(scroll_view.ui_context.renderer, nil)

	scrollbar_x := i32(scroll_view.viewport.x + scroll_view.viewport.w) + 2
	_, _ = draw_scrollbar(scroll_view.ui_context, scrollbar_x, i32(scroll_view.viewport.y), i32(scroll_view.viewport.h),
		f32(scroll_view.content_height), f32(scroll_view.viewport.h), f32(scroll_view.scroll_value), 6, theme)
}

// Draw a vertical scrollbar (track + thumb) on the right edge of a content
// area. `track_x` is the left edge of the track, `track_y` is its top, and
// `track_height` is its height. `content_height` is the total scrollable
// content size; `viewport_height` is the visible portion; `scroll_value` is
// the current scroll offset from the top of the content. No-op if the
// content fits in the viewport. Returns the painted track and thumb rects so
// callers can use them for hit-testing. Caller controls `track_width` so it
// can widen on hover. Returns zero-rects (both width/height = 0) when the
// content fits in the viewport — interactive code should treat that as "no
// scrollbar".
draw_scrollbar :: proc(ui_context: ^Context, track_x, track_y, track_height: i32, content_height, viewport_height, scroll_value: f32, track_width: i32, theme: Theme) -> (track_rectangle: sdl3.FRect, thumb_rectangle: sdl3.FRect) {
	if content_height <= viewport_height { return }

	renderer := ui_context.renderer

	track_rectangle = sdl3.FRect{f32(track_x), f32(track_y), f32(track_width), f32(track_height)}
	sdl3.SetRenderDrawColorFloat(renderer, theme.title_background.r, theme.title_background.g, theme.title_background.b, theme.title_background.a)
	sdl3.RenderFillRect(renderer, &track_rectangle)

	thumb_height := max(f32(20), f32(track_height) * viewport_height / content_height)
	max_scroll := content_height - viewport_height
	scroll_fraction := scroll_value / max_scroll
	if scroll_fraction < 0 { scroll_fraction = 0 }
	if scroll_fraction > 1 { scroll_fraction = 1 }
	thumb_y := f32(track_y) + (f32(track_height) - thumb_height) * scroll_fraction

	thumb_rectangle = sdl3.FRect{f32(track_x) + 1, thumb_y, f32(track_width) - 2, thumb_height}
	sdl3.SetRenderDrawColorFloat(renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
	sdl3.RenderFillRect(renderer, &thumb_rectangle)
	return
}

// Draw a single horizontal rule inside a content area — useful for separating
// sections within a window.
draw_hrule :: proc(ui_context: ^Context, x_position, y_position, length: i32, color: sdl3.FColor) {
	sdl3.SetRenderDrawColorFloat(ui_context.renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderLine(ui_context.renderer, f32(x_position), f32(y_position), f32(x_position + length - 1), f32(y_position))
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
draw_folder_icon :: proc(ui_context: ^Context, x_position, y_position, size: i32, color: sdl3.FColor) {
	renderer := ui_context.renderer
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)

	tab_width := size * 5 / 12
	tab_height := size / 4
	bottom_y := y_position + size - 1
	right_x  := x_position + size - 1

	// Outline: top of tab → right of tab → top of body → right → bottom → left
	sdl3.RenderLine(renderer, f32(x_position),              f32(y_position),                f32(x_position + tab_width), f32(y_position))
	sdl3.RenderLine(renderer, f32(x_position + tab_width),  f32(y_position),                f32(x_position + tab_width), f32(y_position + tab_height))
	sdl3.RenderLine(renderer, f32(x_position + tab_width),  f32(y_position + tab_height),   f32(right_x),                f32(y_position + tab_height))
	sdl3.RenderLine(renderer, f32(right_x),                 f32(y_position + tab_height),   f32(right_x),                f32(bottom_y))
	sdl3.RenderLine(renderer, f32(right_x),                 f32(bottom_y),                  f32(x_position),             f32(bottom_y))
	sdl3.RenderLine(renderer, f32(x_position),              f32(bottom_y),                  f32(x_position),             f32(y_position))
}

// Draws a small file/page glyph with a dog-eared top-right corner.
draw_file_icon :: proc(ui_context: ^Context, x_position, y_position, size: i32, color: sdl3.FColor) {
	renderer := ui_context.renderer
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)

	icon_width := size * 3 / 4
	fold_size  := size / 4
	right_x    := x_position + icon_width
	bottom_y   := y_position + size - 1

	// Outline: top edge stops short of corner, diagonal, right edge, bottom, left
	sdl3.RenderLine(renderer, f32(x_position),             f32(y_position),                f32(right_x - fold_size), f32(y_position))
	sdl3.RenderLine(renderer, f32(right_x - fold_size),    f32(y_position),                f32(right_x),             f32(y_position + fold_size))
	sdl3.RenderLine(renderer, f32(right_x),                f32(y_position + fold_size),    f32(right_x),             f32(bottom_y))
	sdl3.RenderLine(renderer, f32(right_x),                f32(bottom_y),                  f32(x_position),          f32(bottom_y))
	sdl3.RenderLine(renderer, f32(x_position),             f32(bottom_y),                  f32(x_position),          f32(y_position))

	// Dog-ear fold detail: a small inset square at the corner
	sdl3.RenderLine(renderer, f32(right_x - fold_size),    f32(y_position),                f32(right_x - fold_size), f32(y_position + fold_size))
	sdl3.RenderLine(renderer, f32(right_x - fold_size),    f32(y_position + fold_size),    f32(right_x),             f32(y_position + fold_size))
}

// Single selectable list row. When `is_selected`, draws a highlight background
// and an accent stripe on the left edge. Optionally prefixed with a small
// icon. If `label_color_override` is non-nil it replaces the default fg colour
// for the label (typically used to tint git-modified entries, errors, etc.).
draw_list_row :: proc(
	ui_context: ^Context, x_position, y_position, row_width: i32, label: string, is_selected: bool, theme: Theme,
	icon: ListRowIcon = .None,
	label_color_override: Maybe(sdl3.FColor) = nil,
) {
	if is_selected {
		background_rectangle := sdl3.FRect{f32(x_position), f32(y_position), f32(row_width), f32(ui_context.line_height)}
		sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.title_background.r, theme.title_background.g, theme.title_background.b, theme.title_background.a)
		sdl3.RenderFillRect(ui_context.renderer, &background_rectangle)

		stripe_rectangle := sdl3.FRect{f32(x_position), f32(y_position), 2, f32(ui_context.line_height)}
		sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
		sdl3.RenderFillRect(ui_context.renderer, &stripe_rectangle)
	}

	label_x := x_position + 8

	if icon != .None {
		icon_size := ui_context.line_height - 6
		icon_x := x_position + 10
		icon_y := y_position + 3
		icon_color: sdl3.FColor
		switch icon {
		case .Folder: icon_color = theme.accent_foreground
		case .File:   icon_color = is_selected ? theme.title_foreground : theme.dim_foreground
		case .None:   // unreachable
		}
		switch icon {
		case .Folder: draw_folder_icon(ui_context, icon_x, icon_y, icon_size, icon_color)
		case .File:   draw_file_icon(ui_context, icon_x, icon_y, icon_size, icon_color)
		case .None:   // unreachable
		}
		label_x = icon_x + icon_size + 6
	}

	text_color := is_selected ? theme.title_foreground : theme.text_foreground
	if override_color, has_override := label_color_override.?; has_override {
		text_color = override_color
	}
	draw_text(ui_context, label, label_x, y_position, text_color)
}

// Single-line text input: label (in dim color), value (in primary color),
// a block cursor at the end when focused, and an underline rule. When
// `is_focused` is false, the cursor is hidden and the underline uses the
// neutral border color instead of the accent color.
draw_input_field :: proc(ui_context: ^Context, x_position, y_position, field_width: i32, label, value: string, theme: Theme, is_focused := true) {
	cursor_x := x_position
	if len(label) > 0 {
		draw_text(ui_context, label, x_position, y_position, theme.dim_foreground)
		label_width, _ := text_size(ui_context, label)
		cursor_x += label_width
	}

	if len(value) > 0 {
		draw_text(ui_context, value, cursor_x, y_position, theme.text_foreground)
		value_width, _ := text_size(ui_context, value)
		cursor_x += value_width
	}

	if is_focused {
		cursor_rectangle := sdl3.FRect{f32(cursor_x), f32(y_position), f32(ui_context.character_width), f32(ui_context.line_height)}
		sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
		sdl3.RenderFillRect(ui_context.renderer, &cursor_rectangle)
	}

	rule_color := is_focused ? theme.accent_foreground : theme.border
	underline_y := y_position + ui_context.line_height + 2
	sdl3.SetRenderDrawColorFloat(ui_context.renderer, rule_color.r, rule_color.g, rule_color.b, rule_color.a)
	sdl3.RenderLine(ui_context.renderer, f32(x_position), f32(underline_y), f32(x_position + field_width - 1), f32(underline_y))
}

// Draws a labelled, optionally-focused rectangular button. The caller owns
// the rect (typically stored as state from frame to frame so mouse hits can
// be tested against the same coordinates that were rendered).
draw_button :: proc(ui_context: ^Context, button_rectangle: sdl3.FRect, label: string, is_focused: bool, theme: Theme) {
	renderer := ui_context.renderer

	// Background fill
	background_color := is_focused ? theme.title_background : theme.panel_background
	sdl3.SetRenderDrawColorFloat(renderer, background_color.r, background_color.g, background_color.b, background_color.a)
	background_rectangle := button_rectangle
	sdl3.RenderFillRect(renderer, &background_rectangle)

	// Border — accent when focused, neutral otherwise. Double-stroke the
	// focused state for a thicker, unmissable outline.
	border_color := is_focused ? theme.accent_foreground : theme.border
	sdl3.SetRenderDrawColorFloat(renderer, border_color.r, border_color.g, border_color.b, border_color.a)
	border_rectangle := button_rectangle
	sdl3.RenderRect(renderer, &border_rectangle)
	if is_focused {
		inner_border_rectangle := sdl3.FRect{button_rectangle.x + 1, button_rectangle.y + 1, button_rectangle.w - 2, button_rectangle.h - 2}
		sdl3.RenderRect(renderer, &inner_border_rectangle)
	}

	// Centered label
	label_width, _ := text_size(ui_context, label)
	label_x := i32(button_rectangle.x + (button_rectangle.w - f32(label_width)) / 2)
	label_y := i32(button_rectangle.y + (button_rectangle.h - f32(ui_context.line_height)) / 2)
	draw_text(ui_context, label, label_x, label_y, theme.title_foreground)
}

// Geometric hit-test used by callers to decide which widget a click landed in.
point_in_rect :: proc(rectangle: sdl3.FRect, point_x, point_y: f32) -> bool {
	return point_x >= rectangle.x && point_x < rectangle.x + rectangle.w &&
	       point_y >= rectangle.y && point_y < rectangle.y + rectangle.h
}

draw_text :: proc(ui_context: ^Context, text: string, x_position, y_position: i32, color: sdl3.FColor) {
	if len(text) == 0 { return }
	text_as_c_string := strings.clone_to_cstring(text, context.temp_allocator)
	text_object := ttf.CreateText(ui_context.engine, ui_context.font, text_as_c_string, 0)
	if text_object == nil { return }
	defer ttf.DestroyText(text_object)
	_ = ttf.SetTextColorFloat(text_object, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_object, f32(x_position), f32(y_position))
}

text_size :: proc(ui_context: ^Context, text: string) -> (width: i32, height: i32) {
	if len(text) == 0 { return 0, 0 }
	text_as_c_string := strings.clone_to_cstring(text, context.temp_allocator)
	ttf.GetStringSize(ui_context.font, text_as_c_string, 0, &width, &height)
	return
}
