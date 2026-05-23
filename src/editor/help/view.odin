// Event dispatch + render for the help modal.
package help

import "vendor:sdl3"

import "../../ui"

// One-call event dispatch. Returns `needs_redraw=true` when anything
// visible changed. `line_height` is the host's monospace line height,
// used for keyboard scroll step sizing — caller passes its current
// value so the modal doesn't need to plumb it through a separate
// initializer.
dispatch_event :: proc(state: ^State, event: ^sdl3.Event, line_height: i32) -> (needs_redraw: bool) {
	if !state.visible { return false }

	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_F1, sdl3.K_ESCAPE:
			return close(state)
		case sdl3.K_UP:
			scroll_by(state, -line_height)
			return true
		case sdl3.K_DOWN:
			scroll_by(state, line_height)
			return true
		case sdl3.K_PAGEUP:
			page_step := max(i32(1), line_height * 8)
			scroll_by(state, -page_step)
			return true
		case sdl3.K_PAGEDOWN:
			page_step := max(i32(1), line_height * 8)
			scroll_by(state, page_step)
			return true
		case sdl3.K_HOME:
			scroll_to_top(state)
			return true
		case sdl3.K_END:
			scroll_to_bottom(state)
			return true
		}

	case .MOUSE_WHEEL:
		scroll_by(state, -i32(event.wheel.y * f32(line_height) * 3))
		return true

	case .MOUSE_MOTION:
		if state.scrollbar.is_dragging {
			apply_scrollbar_drag(state, event.motion.y)
			return true
		}
		return ui.scrollbar_update_hover(&state.scrollbar, event.motion.x, event.motion.y)

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return false }
		if ui.scrollbar_thumb_hit(&state.scrollbar, event.button.x, event.button.y) {
			ui.scrollbar_begin_thumb_drag(&state.scrollbar, event.button.y)
			return false
		}
		if ui.scrollbar_track_hit(&state.scrollbar, event.button.x, event.button.y) {
			ui.scrollbar_begin_track_drag(&state.scrollbar)
			apply_scrollbar_drag(state, event.button.y)
			return true
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT && state.scrollbar.is_dragging {
			ui.scrollbar_end_drag(&state.scrollbar)
			return true
		}
	}
	return false
}

// Paint the modal at the centre of the given viewport. Caller checks
// `state.visible` first; this proc does no visibility check so it can
// be composed against test harnesses without the modal having to be
// open.
render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 56
	desired_rows: i32 = 34
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 40, viewport_height - 40)
	if dialog_width  < 200 { dialog_width  = min(viewport_width  - 16, 200) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Help — odit", theme)

	line_step := ui_context.line_height

	// Carve out a footer strip at the bottom of the dialog; everything
	// above it is the scrollable viewport.
	footer_reservation_height: f32 = f32(line_step) + 18
	viewport_rectangle := sdl3.FRect{
		x = content_rectangle.x,
		y = content_rectangle.y,
		w = content_rectangle.w - 12, // leave room for the scrollbar on the right
		h = (dialog_rectangle.y + dialog_rectangle.h - footer_reservation_height) - content_rectangle.y,
	}
	if viewport_rectangle.h < f32(line_step) { viewport_rectangle.h = f32(line_step) }

	total_content_height := content_height(line_step)

	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.scrollbar, viewport_rectangle, &state.scroll, total_content_height)

	ui.draw_text(ui_context, "Welcome to odit — a terminal-inspired text editor.", origin_x, origin_y, theme.text_foreground)
	origin_y += line_step
	ui.draw_text(ui_context, "Every shortcut currently wired up is listed below.", origin_x, origin_y, theme.dim_foreground)
	origin_y += line_step + 6

	ui.draw_hrule(ui_context, origin_x, origin_y, i32(viewport_rectangle.w), theme.border)
	origin_y += 8

	keybinding_column_x  := origin_x + 2 * ui_context.character_width
	description_column_x := origin_x + 18 * ui_context.character_width

	for section, section_index in help_sections {
		if section_index > 0 { origin_y += line_step / 2 }
		ui.draw_text(ui_context, section.title, origin_x, origin_y, theme.accent_foreground)
		origin_y += line_step + 2

		for help_item in section.items {
			ui.draw_text(ui_context, help_item.keybinding,  keybinding_column_x,  origin_y, theme.title_foreground)
			ui.draw_text(ui_context, help_item.description, description_column_x, origin_y, theme.text_foreground)
			origin_y += line_step
		}
	}

	ui.scroll_view_end(scroll_view, theme)

	// Footer hint, anchored to the bottom of the dialog (outside the viewport).
	footer_text := "Press F1 or Esc to close"
	footer_width, _ := ui.text_size(ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}
