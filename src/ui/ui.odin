package ui

import "core:math"
import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

// Drawing context — bundles the renderer plus font metrics the caller has
// already measured. Generic UI procs operate against this; they know nothing
// about the editor that owns the state. Mouse position is included so
// interactive primitives (buttons, list rows) can auto-detect hover
// without callers threading it through separately.
Context :: struct {
	renderer:        ^sdl3.Renderer,
	font:            ^ttf.Font,
	engine:          ^ttf.TextEngine,
	character_width: i32,
	line_height:     i32,
	mouse_x:         f32,
	mouse_y:         f32,
}

Theme :: struct {
	overlay:           sdl3.FColor, // dim layer drawn behind dialogs
	shadow:            sdl3.FColor, // dialog drop-shadow
	panel_background:  sdl3.FColor,
	border:            sdl3.FColor,
	title_background:  sdl3.FColor, // background of the title strip
	title_foreground:  sdl3.FColor,
	text_foreground:   sdl3.FColor,
	accent_foreground: sdl3.FColor, // section headers, keys
	dim_foreground:    sdl3.FColor, // footer hints, secondary text
	// Background fill used for the hover state on interactive controls
	// (buttons, eventually list rows). Sits between panel_background and
	// title_background brightness-wise so hover reads as "warmer" without
	// pretending the control is focused.
	hover_background:  sdl3.FColor,
}

default_theme :: proc() -> Theme {
	return Theme {
		overlay = {0.00, 0.00, 0.00, 0.55},
		shadow = {0.00, 0.00, 0.00, 0.45},
		panel_background = {0.10, 0.11, 0.16, 1.00},
		border = {0.50, 0.70, 0.92, 1.00},
		title_background = {0.16, 0.20, 0.28, 1.00},
		title_foreground = {0.96, 0.96, 0.98, 1.00},
		text_foreground = {0.85, 0.86, 0.90, 1.00},
		accent_foreground = {0.95, 0.78, 0.42, 1.00},
		dim_foreground = {0.55, 0.60, 0.66, 1.00},
		hover_background = {0.22, 0.28, 0.38, 1.00},
	}
}

// --- Rounded-rect primitives ----------------------------------------------

// Default corner radius applied to all interactive controls (buttons today,
// more later). Picked to read as "rounded" at the usual ~24-30 px button
// height without overwhelming the body of the control.
ROUNDED_CONTROL_RADIUS: f32 : 4

// Filled rounded rectangle. Approximates corners with a per-row scanline
// trim — every row near the top/bottom gets its left/right edges pulled in
// by the local arc radius, producing four quarter-circle corners without
// needing a polygon primitive. Falls back to a plain RenderFillRect when
// the radius is zero or larger than half the smaller dimension (which
// would produce nonsense math).
draw_filled_rounded_rect :: proc(
	renderer: ^sdl3.Renderer,
	rectangle: sdl3.FRect,
	radius: f32,
	color: sdl3.FColor,
) {
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	r := radius
	if r <= 0 || rectangle.w < 2 * r || rectangle.h < 2 * r {
		rect := rectangle
		sdl3.RenderFillRect(renderer, &rect)
		return
	}

	// Center strip — full width, height = rect.h - 2r.
	center := sdl3.FRect{rectangle.x, rectangle.y + r, rectangle.w, rectangle.h - 2 * r}
	sdl3.RenderFillRect(renderer, &center)

	// Top + bottom rows: shorten each scanline by the corner inset.
	radius_squared := r * r
	for y_offset_int in 0 ..< i32(r) {
		y_offset := f32(y_offset_int)
		// Distance from the row to the arc-center row.
		dy := r - y_offset - 0.5
		if dy < 0 {dy = 0}
		x_inset_squared := radius_squared - dy * dy
		if x_inset_squared < 0 {x_inset_squared = 0}
		x_inset := r - math.sqrt_f32(x_inset_squared)

		row_width := rectangle.w - 2 * x_inset
		if row_width <= 0 {continue}

		top := sdl3.FRect{rectangle.x + x_inset, rectangle.y + y_offset, row_width, 1}
		sdl3.RenderFillRect(renderer, &top)
		bottom := sdl3.FRect {
			rectangle.x + x_inset,
			rectangle.y + rectangle.h - 1 - y_offset,
			row_width,
			1,
		}
		sdl3.RenderFillRect(renderer, &bottom)
	}
}

// One-pixel-thick rounded rectangle outline. The straight edges use
// RenderLine; each corner is approximated with 8 line segments (looks
// continuous at the radii we use without overspending on draw calls).
draw_rounded_rect_outline :: proc(
	renderer: ^sdl3.Renderer,
	rectangle: sdl3.FRect,
	radius: f32,
	color: sdl3.FColor,
) {
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	r := radius
	if r <= 0 || rectangle.w < 2 * r || rectangle.h < 2 * r {
		rect := rectangle
		sdl3.RenderRect(renderer, &rect)
		return
	}

	right_x := rectangle.x + rectangle.w - 1
	bottom_y := rectangle.y + rectangle.h - 1

	// Four straight edges (between the corner arcs).
	sdl3.RenderLine(renderer, rectangle.x + r, rectangle.y, right_x - r, rectangle.y)
	sdl3.RenderLine(renderer, rectangle.x + r, bottom_y, right_x - r, bottom_y)
	sdl3.RenderLine(renderer, rectangle.x, rectangle.y + r, rectangle.x, bottom_y - r)
	sdl3.RenderLine(renderer, right_x, rectangle.y + r, right_x, bottom_y - r)

	// Four corner arcs. Each arc sweeps PI/2 radians; 8 line segments is
	// smooth enough at the radii we use without overspending on draw calls.
	rounded_rect_corner_arc(renderer, rectangle.x + r, rectangle.y + r, r, math.PI, 1.5 * math.PI)
	rounded_rect_corner_arc(
		renderer,
		right_x - r,
		rectangle.y + r,
		r,
		1.5 * math.PI,
		2.0 * math.PI,
	)
	rounded_rect_corner_arc(renderer, right_x - r, bottom_y - r, r, 0.0, 0.5 * math.PI)
	rounded_rect_corner_arc(renderer, rectangle.x + r, bottom_y - r, r, 0.5 * math.PI, math.PI)
}

@(private = "file")
rounded_rect_corner_arc :: proc(
	renderer: ^sdl3.Renderer,
	center_x, center_y, radius, start_angle, end_angle: f32,
) {
	segments :: 8
	previous_x := center_x + radius * math.cos_f32(start_angle)
	previous_y := center_y + radius * math.sin_f32(start_angle)
	for segment in 1 ..= segments {
		t := f32(segment) / f32(segments)
		angle := start_angle + t * (end_angle - start_angle)
		next_x := center_x + radius * math.cos_f32(angle)
		next_y := center_y + radius * math.sin_f32(angle)
		sdl3.RenderLine(renderer, previous_x, previous_y, next_x, next_y)
		previous_x = next_x
		previous_y = next_y
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
draw_window :: proc(
	ui_context: ^Context,
	window_rectangle: sdl3.FRect,
	title: string,
	theme: Theme,
	content_padding: f32 = 12,
) -> (
	content_rectangle: sdl3.FRect,
) {
	renderer := ui_context.renderer

	// Drop shadow
	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_BLEND)
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.shadow.r,
		theme.shadow.g,
		theme.shadow.b,
		theme.shadow.a,
	)
	shadow_rectangle := sdl3.FRect {
		window_rectangle.x + 6,
		window_rectangle.y + 8,
		window_rectangle.w,
		window_rectangle.h,
	}
	sdl3.RenderFillRect(renderer, &shadow_rectangle)
	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_NONE)

	// Panel fill
	panel_rectangle := window_rectangle
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.panel_background.r,
		theme.panel_background.g,
		theme.panel_background.b,
		theme.panel_background.a,
	)
	sdl3.RenderFillRect(renderer, &panel_rectangle)

	// Title strip
	title_height := f32(ui_context.line_height) + 8
	title_rectangle := sdl3.FRect {
		window_rectangle.x,
		window_rectangle.y,
		window_rectangle.w,
		title_height,
	}
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.title_background.r,
		theme.title_background.g,
		theme.title_background.b,
		theme.title_background.a,
	)
	sdl3.RenderFillRect(renderer, &title_rectangle)

	if len(title) > 0 {
		title_width, _ := text_size(ui_context, title)
		title_position_x := window_rectangle.x + (window_rectangle.w - f32(title_width)) / 2
		title_position_y := window_rectangle.y + (title_height - f32(ui_context.line_height)) / 2
		draw_text(
			ui_context,
			title,
			i32(title_position_x),
			i32(title_position_y),
			theme.title_foreground,
		)
	}

	// Border + title separator (line drawing)
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.border.r,
		theme.border.g,
		theme.border.b,
		theme.border.a,
	)
	border_rectangle := window_rectangle
	sdl3.RenderRect(renderer, &border_rectangle)
	separator_y := window_rectangle.y + title_height
	sdl3.RenderLine(
		renderer,
		window_rectangle.x,
		separator_y,
		window_rectangle.x + window_rectangle.w - 1,
		separator_y,
	)

	content_rectangle = sdl3.FRect {
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
	scrollbar:      ^Scrollbar,
	viewport:       sdl3.FRect,
	scroll_value:   i32, // already clamped
	content_height: i32,
}

// Begin a scrollable region inside `viewport`. Clamps `scroll_value^` to the
// valid range `[0, max(0, content_height - viewport.h)]`, installs a clip
// rect, and returns the *content origin* where the caller should start
// drawing. The returned `origin_y` already includes the scroll offset, so
// content laid out from `origin_y` downward at natural intervals will scroll
// for free. `scrollbar` is the persistent widget state that backs the
// hover / drag behavior; pass the same pointer every frame.
//
// Pair with `scroll_view_end` to drop the clip rect and draw a scrollbar.
scroll_view_begin :: proc(
	ui_context: ^Context,
	scrollbar: ^Scrollbar,
	viewport: sdl3.FRect,
	scroll_value: ^i32,
	content_height: i32,
) -> (
	origin_x, origin_y: i32,
	scroll_view: ScrollView,
) {
	max_scroll := max(i32(0), content_height - i32(viewport.h))
	if scroll_value^ < 0 {scroll_value^ = 0}
	if scroll_value^ > max_scroll {scroll_value^ = max_scroll}

	clip_rectangle := sdl3.Rect{i32(viewport.x), i32(viewport.y), i32(viewport.w), i32(viewport.h)}
	sdl3.SetRenderClipRect(ui_context.renderer, &clip_rectangle)

	origin_x = i32(viewport.x)
	origin_y = i32(viewport.y) - scroll_value^

	scroll_view = ScrollView {
		ui_context     = ui_context,
		scrollbar      = scrollbar,
		viewport       = viewport,
		scroll_value   = scroll_value^,
		content_height = content_height,
	}
	return
}

// Finish a scrollable region: clear the clip rect and draw the shared
// `Scrollbar` widget on the right edge of the viewport. Track + thumb
// rects are written back into the scrollbar so the caller's mouse
// dispatch can hit-test against the same pixels next frame. The narrow
// track sits 2 px to the right of the viewport; on hover the widget
// widens leftward INTO the viewport (same behavior as the editor pane).
scroll_view_end :: proc(scroll_view: ScrollView, theme: Theme) {
	sdl3.SetRenderClipRect(scroll_view.ui_context.renderer, nil)
	right_edge_x :=
		i32(scroll_view.viewport.x + scroll_view.viewport.w) + 2 + SCROLLBAR_NARROW_WIDTH
	scrollbar_render(
		scroll_view.ui_context,
		scroll_view.scrollbar,
		right_edge_x,
		i32(scroll_view.viewport.y),
		i32(scroll_view.viewport.h),
		f32(scroll_view.viewport.h),
		f32(scroll_view.content_height),
		f32(scroll_view.scroll_value),
		theme,
	)
}

// --- Vertical scrollbar widget --------------------------------------------
//
// Self-contained scrollbar — owns its rect / hover / drag state so every
// pane and modal in the app shares one implementation.
//
// Usage:
//   1. Hold a `ui.Scrollbar` field on your pane state.
//   2. Each render: call `scrollbar_render(...)`.
//   3. Mouse down: check `scrollbar_thumb_hit` (start drag), then
//      `scrollbar_track_hit` (jump-then-drag).
//   4. Mouse drag (while `scrollbar.is_dragging`): call `scrollbar_drag_to`
//      and apply the returned scroll value to your pane's scroll variable.
//   5. Mouse up: `scrollbar_end_drag`.
//   6. Mouse motion (any pane): `scrollbar_update_hover`.

Scrollbar :: struct {
	track_rectangle: sdl3.FRect,
	thumb_rectangle: sdl3.FRect,
	is_hovered:      bool,
	is_dragging:     bool,
	drag_delta_y:    f32, // mouse-y offset within the thumb at drag start (vertical bars)
	drag_delta_x:    f32, // mouse-x offset within the thumb at drag start (horizontal bars)
}

// Cosmetic constants. Lifted from the editor pane's original scrollbar so
// every pane gets the same look.
SCROLLBAR_NARROW_WIDTH: i32 : 6
SCROLLBAR_WIDE_WIDTH: i32 : 14
SCROLLBAR_MIN_THUMB: f32 : 20
SCROLLBAR_THUMB_HIT_PAD: f32 : 2

// Render the scrollbar on the right edge of a content area. `right_edge_x`
// is the x-coordinate where the scrollbar's right side sits (typically the
// pane's right edge minus a 2-px margin); the track widens leftward on
// hover/drag so a wider thumb doesn't intrude past `right_edge_x`. Writes
// the painted track + thumb rects back into `scrollbar` for subsequent
// hit-testing. Both rects are zeroed if the content fits in the viewport.
scrollbar_render :: proc(
	ui_context: ^Context,
	scrollbar: ^Scrollbar,
	right_edge_x: i32,
	track_y: i32,
	track_height: i32,
	viewport_height: f32,
	content_height: f32,
	current_scroll: f32,
	theme: Theme,
) {
	if content_height <= viewport_height || track_height <= 0 {
		scrollbar.track_rectangle = sdl3.FRect{}
		scrollbar.thumb_rectangle = sdl3.FRect{}
		return
	}

	track_width := SCROLLBAR_NARROW_WIDTH
	if scrollbar.is_hovered || scrollbar.is_dragging {track_width = SCROLLBAR_WIDE_WIDTH}
	track_x := right_edge_x - track_width

	renderer := ui_context.renderer

	track_rectangle := sdl3.FRect{f32(track_x), f32(track_y), f32(track_width), f32(track_height)}
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.title_background.r,
		theme.title_background.g,
		theme.title_background.b,
		theme.title_background.a,
	)
	sdl3.RenderFillRect(renderer, &track_rectangle)

	thumb_height := max(SCROLLBAR_MIN_THUMB, f32(track_height) * viewport_height / content_height)
	max_scroll := content_height - viewport_height
	scroll_fraction := current_scroll / max_scroll
	if scroll_fraction < 0 {scroll_fraction = 0}
	if scroll_fraction > 1 {scroll_fraction = 1}
	thumb_y := f32(track_y) + (f32(track_height) - thumb_height) * scroll_fraction

	thumb_rectangle := sdl3.FRect{f32(track_x) + 1, thumb_y, f32(track_width) - 2, thumb_height}
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.accent_foreground.r,
		theme.accent_foreground.g,
		theme.accent_foreground.b,
		theme.accent_foreground.a,
	)
	sdl3.RenderFillRect(renderer, &thumb_rectangle)

	scrollbar.track_rectangle = track_rectangle
	scrollbar.thumb_rectangle = thumb_rectangle
}

// True when the mouse is over the thumb (with a few pixels of horizontal
// padding so the cursor doesn't have to be pixel-perfect to latch a drag).
scrollbar_thumb_hit :: proc(scrollbar: ^Scrollbar, mouse_x, mouse_y: f32) -> bool {
	thumb := scrollbar.thumb_rectangle
	if thumb.w <= 0 || thumb.h <= 0 {return false}
	return(
		mouse_x >= thumb.x - SCROLLBAR_THUMB_HIT_PAD &&
		mouse_x < thumb.x + thumb.w + SCROLLBAR_THUMB_HIT_PAD &&
		mouse_y >= thumb.y &&
		mouse_y < thumb.y + thumb.h \
	)
}

// True when the mouse is anywhere on the track (thumb or empty space). The
// caller typically tests `scrollbar_thumb_hit` first and falls through to
// this for the "click in the empty track" jump-to-position case.
scrollbar_track_hit :: proc(scrollbar: ^Scrollbar, mouse_x, mouse_y: f32) -> bool {
	return point_in_rect(scrollbar.track_rectangle, mouse_x, mouse_y)
}

// Begin a thumb drag. Captures the y-offset within the thumb so the thumb
// doesn't snap to the cursor on the first motion event.
scrollbar_begin_thumb_drag :: proc(scrollbar: ^Scrollbar, mouse_y: f32) {
	scrollbar.is_dragging = true
	scrollbar.drag_delta_y = mouse_y - scrollbar.thumb_rectangle.y
}

// Begin a track-click drag — same as a thumb drag but the cursor lands at
// the thumb's center so subsequent motion immediately scrolls relative.
scrollbar_begin_track_drag :: proc(scrollbar: ^Scrollbar) {
	scrollbar.is_dragging = true
	scrollbar.drag_delta_y = scrollbar.thumb_rectangle.h / 2
}

// While dragging, translate the current mouse_y into a new scroll value in
// the same units as `max_scroll`. Caller assigns the returned value to its
// own scroll variable. Returns the existing scroll position when the track
// is too short to meaningfully drag against.
scrollbar_drag_to :: proc(scrollbar: ^Scrollbar, mouse_y: f32, max_scroll: f32) -> f32 {
	track := scrollbar.track_rectangle
	thumb := scrollbar.thumb_rectangle
	if track.h <= 0 || thumb.h <= 0 || max_scroll <= 0 {return 0}
	travel_distance := track.h - thumb.h
	if travel_distance <= 0 {return 0}
	target_thumb_y := mouse_y - scrollbar.drag_delta_y
	if target_thumb_y < track.y {target_thumb_y = track.y}
	if target_thumb_y > track.y + travel_distance {target_thumb_y = track.y + travel_distance}
	travel_fraction := (target_thumb_y - track.y) / travel_distance
	return travel_fraction * max_scroll
}

// Release the drag latch. Idempotent.
scrollbar_end_drag :: proc(scrollbar: ^Scrollbar) {
	scrollbar.is_dragging = false
	scrollbar.drag_delta_y = 0
	scrollbar.drag_delta_x = 0
}

// --- Horizontal scrollbar (mirror of the vertical bar above) -------------
//
// Same `Scrollbar` struct holds the state, the orthogonal one of
// `drag_delta_x` / `drag_delta_y` is the live one depending on which
// orientation this widget is. Hit-test, hover, and end-drag procs are
// shared with the vertical bar (they're orientation-agnostic).

// Render the scrollbar along the bottom edge of a content area.
// `bottom_edge_y` is the y-coordinate where the track's bottom side
// sits; the track grows upward on hover/drag so a wider thumb doesn't
// spill past `bottom_edge_y`. Writes the painted rects back into
// `scrollbar`. Both rects are zeroed if the content fits in the
// viewport.
scrollbar_render_horizontal :: proc(
	ui_context: ^Context,
	scrollbar: ^Scrollbar,
	track_x: i32,
	bottom_edge_y: i32,
	track_width: i32,
	viewport_width: f32,
	content_width: f32,
	current_scroll: f32,
	theme: Theme,
) {
	if content_width <= viewport_width || track_width <= 0 {
		scrollbar.track_rectangle = sdl3.FRect{}
		scrollbar.thumb_rectangle = sdl3.FRect{}
		return
	}

	track_height := SCROLLBAR_NARROW_WIDTH
	if scrollbar.is_hovered || scrollbar.is_dragging { track_height = SCROLLBAR_WIDE_WIDTH }
	track_y := bottom_edge_y - track_height

	renderer := ui_context.renderer

	track_rectangle := sdl3.FRect{f32(track_x), f32(track_y), f32(track_width), f32(track_height)}
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.title_background.r,
		theme.title_background.g,
		theme.title_background.b,
		theme.title_background.a,
	)
	sdl3.RenderFillRect(renderer, &track_rectangle)

	thumb_width := max(SCROLLBAR_MIN_THUMB, f32(track_width) * viewport_width / content_width)
	max_scroll := content_width - viewport_width
	scroll_fraction := current_scroll / max_scroll
	if scroll_fraction < 0 { scroll_fraction = 0 }
	if scroll_fraction > 1 { scroll_fraction = 1 }
	thumb_x := f32(track_x) + (f32(track_width) - thumb_width) * scroll_fraction

	thumb_rectangle := sdl3.FRect{thumb_x, f32(track_y) + 1, thumb_width, f32(track_height) - 2}
	sdl3.SetRenderDrawColorFloat(
		renderer,
		theme.accent_foreground.r,
		theme.accent_foreground.g,
		theme.accent_foreground.b,
		theme.accent_foreground.a,
	)
	sdl3.RenderFillRect(renderer, &thumb_rectangle)

	scrollbar.track_rectangle = track_rectangle
	scrollbar.thumb_rectangle = thumb_rectangle
}

// Begin a thumb drag for a horizontal bar. Captures the x-offset
// within the thumb so the thumb doesn't snap to the cursor on the
// first motion event.
scrollbar_begin_thumb_drag_horizontal :: proc(scrollbar: ^Scrollbar, mouse_x: f32) {
	scrollbar.is_dragging = true
	scrollbar.drag_delta_x = mouse_x - scrollbar.thumb_rectangle.x
}

// Begin a track-click drag — same as a thumb drag but the cursor
// lands at the thumb's center so subsequent motion immediately
// scrolls relative.
scrollbar_begin_track_drag_horizontal :: proc(scrollbar: ^Scrollbar) {
	scrollbar.is_dragging = true
	scrollbar.drag_delta_x = scrollbar.thumb_rectangle.w / 2
}

// While dragging, translate the current `mouse_x` into a new scroll
// value in the same units as `max_scroll`.
scrollbar_drag_to_horizontal :: proc(scrollbar: ^Scrollbar, mouse_x: f32, max_scroll: f32) -> f32 {
	track := scrollbar.track_rectangle
	thumb := scrollbar.thumb_rectangle
	if track.w <= 0 || thumb.w <= 0 || max_scroll <= 0 { return 0 }
	travel_distance := track.w - thumb.w
	if travel_distance <= 0 { return 0 }
	target_thumb_x := mouse_x - scrollbar.drag_delta_x
	if target_thumb_x < track.x                       { target_thumb_x = track.x }
	if target_thumb_x > track.x + travel_distance     { target_thumb_x = track.x + travel_distance }
	travel_fraction := (target_thumb_x - track.x) / travel_distance
	return travel_fraction * max_scroll
}

// Recompute `is_hovered` from the current mouse position. Returns true when
// the flag flipped so callers can mark the editor dirty for a repaint.
scrollbar_update_hover :: proc(scrollbar: ^Scrollbar, mouse_x, mouse_y: f32) -> (changed: bool) {
	is_over_track := point_in_rect(scrollbar.track_rectangle, mouse_x, mouse_y)
	if is_over_track == scrollbar.is_hovered {return false}
	scrollbar.is_hovered = is_over_track
	return true
}

// Draw a single horizontal rule inside a content area — useful for separating
// sections within a window.
draw_hrule :: proc(ui_context: ^Context, x_position, y_position, length: i32, color: sdl3.FColor) {
	sdl3.SetRenderDrawColorFloat(ui_context.renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderLine(
		ui_context.renderer,
		f32(x_position),
		f32(y_position),
		f32(x_position + length - 1),
		f32(y_position),
	)
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
draw_folder_icon :: proc(
	ui_context: ^Context,
	x_position, y_position, size: i32,
	color: sdl3.FColor,
) {
	renderer := ui_context.renderer
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)

	tab_width := size * 5 / 12
	tab_height := size / 4
	bottom_y := y_position + size - 1
	right_x := x_position + size - 1

	// Outline: top of tab → right of tab → top of body → right → bottom → left
	sdl3.RenderLine(
		renderer,
		f32(x_position),
		f32(y_position),
		f32(x_position + tab_width),
		f32(y_position),
	)
	sdl3.RenderLine(
		renderer,
		f32(x_position + tab_width),
		f32(y_position),
		f32(x_position + tab_width),
		f32(y_position + tab_height),
	)
	sdl3.RenderLine(
		renderer,
		f32(x_position + tab_width),
		f32(y_position + tab_height),
		f32(right_x),
		f32(y_position + tab_height),
	)
	sdl3.RenderLine(
		renderer,
		f32(right_x),
		f32(y_position + tab_height),
		f32(right_x),
		f32(bottom_y),
	)
	sdl3.RenderLine(renderer, f32(right_x), f32(bottom_y), f32(x_position), f32(bottom_y))
	sdl3.RenderLine(renderer, f32(x_position), f32(bottom_y), f32(x_position), f32(y_position))
}

// Draws a small file/page glyph with a dog-eared top-right corner.
draw_file_icon :: proc(
	ui_context: ^Context,
	x_position, y_position, size: i32,
	color: sdl3.FColor,
) {
	renderer := ui_context.renderer
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)

	icon_width := size * 3 / 4
	fold_size := size / 4
	right_x := x_position + icon_width
	bottom_y := y_position + size - 1

	// Outline: top edge stops short of corner, diagonal, right edge, bottom, left
	sdl3.RenderLine(
		renderer,
		f32(x_position),
		f32(y_position),
		f32(right_x - fold_size),
		f32(y_position),
	)
	sdl3.RenderLine(
		renderer,
		f32(right_x - fold_size),
		f32(y_position),
		f32(right_x),
		f32(y_position + fold_size),
	)
	sdl3.RenderLine(
		renderer,
		f32(right_x),
		f32(y_position + fold_size),
		f32(right_x),
		f32(bottom_y),
	)
	sdl3.RenderLine(renderer, f32(right_x), f32(bottom_y), f32(x_position), f32(bottom_y))
	sdl3.RenderLine(renderer, f32(x_position), f32(bottom_y), f32(x_position), f32(y_position))

	// Dog-ear fold detail: a small inset square at the corner
	sdl3.RenderLine(
		renderer,
		f32(right_x - fold_size),
		f32(y_position),
		f32(right_x - fold_size),
		f32(y_position + fold_size),
	)
	sdl3.RenderLine(
		renderer,
		f32(right_x - fold_size),
		f32(y_position + fold_size),
		f32(right_x),
		f32(y_position + fold_size),
	)
}

// Single selectable list row. When `is_selected`, draws a highlight background
// and an accent stripe on the left edge. Optionally prefixed with a small
// icon. If `label_color_override` is non-nil it replaces the default fg colour
// for the label (typically used to tint git-modified entries, errors, etc.).
draw_list_row :: proc(
	ui_context: ^Context,
	x_position, y_position, row_width: i32,
	label: string,
	is_selected: bool,
	theme: Theme,
	icon: ListRowIcon = .None,
	label_color_override: Maybe(sdl3.FColor) = nil,
) {
	if is_selected {
		background_rectangle := sdl3.FRect {
			f32(x_position),
			f32(y_position),
			f32(row_width),
			f32(ui_context.line_height),
		}
		sdl3.SetRenderDrawColorFloat(
			ui_context.renderer,
			theme.title_background.r,
			theme.title_background.g,
			theme.title_background.b,
			theme.title_background.a,
		)
		sdl3.RenderFillRect(ui_context.renderer, &background_rectangle)

		stripe_rectangle := sdl3.FRect {
			f32(x_position),
			f32(y_position),
			2,
			f32(ui_context.line_height),
		}
		sdl3.SetRenderDrawColorFloat(
			ui_context.renderer,
			theme.accent_foreground.r,
			theme.accent_foreground.g,
			theme.accent_foreground.b,
			theme.accent_foreground.a,
		)
		sdl3.RenderFillRect(ui_context.renderer, &stripe_rectangle)
	}

	label_x := x_position + 8

	if icon != .None {
		icon_size := ui_context.line_height - 6
		icon_x := x_position + 10
		icon_y := y_position + 3
		icon_color: sdl3.FColor
		switch icon {
		case .Folder:
			icon_color = theme.accent_foreground
		case .File:
			icon_color = is_selected ? theme.title_foreground : theme.dim_foreground
		case .None: // unreachable
		}
		switch icon {
		case .Folder:
			draw_folder_icon(ui_context, icon_x, icon_y, icon_size, icon_color)
		case .File:
			draw_file_icon(ui_context, icon_x, icon_y, icon_size, icon_color)
		case .None: // unreachable
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
draw_input_field :: proc(
	ui_context: ^Context,
	x_position, y_position, field_width: i32,
	label, value: string,
	theme: Theme,
	is_focused := true,
) {
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
		cursor_rectangle := sdl3.FRect {
			f32(cursor_x),
			f32(y_position),
			f32(ui_context.character_width),
			f32(ui_context.line_height),
		}
		sdl3.SetRenderDrawColorFloat(
			ui_context.renderer,
			theme.accent_foreground.r,
			theme.accent_foreground.g,
			theme.accent_foreground.b,
			theme.accent_foreground.a,
		)
		sdl3.RenderFillRect(ui_context.renderer, &cursor_rectangle)
	}

	rule_color := is_focused ? theme.accent_foreground : theme.border
	underline_y := y_position + ui_context.line_height + 2
	sdl3.SetRenderDrawColorFloat(
		ui_context.renderer,
		rule_color.r,
		rule_color.g,
		rule_color.b,
		rule_color.a,
	)
	sdl3.RenderLine(
		ui_context.renderer,
		f32(x_position),
		f32(underline_y),
		f32(x_position + field_width - 1),
		f32(underline_y),
	)
}

// Draws a labelled rectangular button with rounded corners. `is_focused`
// thickens the border (keyboard focus / current default action); hover is
// auto-detected from `ui_context.mouse_x` / `mouse_y` so callers don't
// have to track it themselves. The caller owns the rect (typically stored
// as state from frame to frame so mouse hits can be tested against the
// same coordinates that were rendered).
draw_button :: proc(
	ui_context: ^Context,
	button_rectangle: sdl3.FRect,
	label: string,
	is_focused: bool,
	theme: Theme,
) {
	renderer := ui_context.renderer
	corner_radius := ROUNDED_CONTROL_RADIUS
	is_hovered := point_in_rect(button_rectangle, ui_context.mouse_x, ui_context.mouse_y)

	// Background fill — picks the brightest applicable state.
	background_color := theme.panel_background
	if is_focused {background_color = theme.title_background} else if is_hovered {background_color = theme.hover_background}
	draw_filled_rounded_rect(renderer, button_rectangle, corner_radius, background_color)

	// Border — accent when focused, neutral otherwise. Double-stroke the
	// focused state for a thicker, unmissable outline.
	border_color := is_focused ? theme.accent_foreground : theme.border
	draw_rounded_rect_outline(renderer, button_rectangle, corner_radius, border_color)
	if is_focused {
		inner_border := sdl3.FRect {
			button_rectangle.x + 1,
			button_rectangle.y + 1,
			button_rectangle.w - 2,
			button_rectangle.h - 2,
		}
		draw_rounded_rect_outline(renderer, inner_border, corner_radius - 1, border_color)
	}

	// Centered label
	label_width, _ := text_size(ui_context, label)
	label_x := i32(button_rectangle.x + (button_rectangle.w - f32(label_width)) / 2)
	label_y := i32(button_rectangle.y + (button_rectangle.h - f32(ui_context.line_height)) / 2)
	draw_text(ui_context, label, label_x, label_y, theme.title_foreground)
}

// Geometric hit-test used by callers to decide which widget a click landed in.
point_in_rect :: proc(rectangle: sdl3.FRect, point_x, point_y: f32) -> bool {
	return(
		point_x >= rectangle.x &&
		point_x < rectangle.x + rectangle.w &&
		point_y >= rectangle.y &&
		point_y < rectangle.y + rectangle.h \
	)
}

draw_text :: proc(
	ui_context: ^Context,
	text: string,
	x_position, y_position: i32,
	color: sdl3.FColor,
) {
	if len(text) == 0 {return}
	text_as_c_string := strings.clone_to_cstring(text, context.temp_allocator)
	text_object := ttf.CreateText(ui_context.engine, ui_context.font, text_as_c_string, 0)
	if text_object == nil {return}
	defer ttf.DestroyText(text_object)
	_ = ttf.SetTextColorFloat(text_object, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_object, f32(x_position), f32(y_position))
}

text_size :: proc(ui_context: ^Context, text: string) -> (width: i32, height: i32) {
	if len(text) == 0 {return 0, 0}
	text_as_c_string := strings.clone_to_cstring(text, context.temp_allocator)
	ttf.GetStringSize(ui_context.font, text_as_c_string, 0, &width, &height)
	return
}
