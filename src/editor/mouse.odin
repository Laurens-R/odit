package editor

import "vendor:sdl3"

import "../document"
import "../ui"

// Set the OS cursor to `target_cursor` if it's not already the active one.
// Centralised so hover, drag, and release paths don't fight each other over
// the cursor.
@(private="file")
set_cursor :: proc(editor: ^Editor, target_cursor: ^sdl3.Cursor) {
	if target_cursor == nil || editor.current_cursor == target_cursor { return }
	_ = sdl3.SetCursor(target_cursor)
	editor.current_cursor = target_cursor
}

// Pick a cursor shape based on what (mouse_x, mouse_y) is over right now
// plus the active drag state. EW-resize on the divider hot-zone or whenever
// a divider drag is in progress; default arrow otherwise.
@(private)
editor_update_cursor :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	if editor.divider_dragging || divider_hit_test(editor, mouse_x, mouse_y) {
		set_cursor(editor, editor.cursor_resize_ew)
	} else {
		set_cursor(editor, editor.cursor_default)
	}
}

// Pan the active pane horizontally by `column_delta` columns. No-op when the
// pane is in wrap mode (the model says wrap and horizontal scroll are
// mutually exclusive — Ctrl+W toggles between them) or when there's no
// editor pane focused.
@(private)
editor_scroll_horizontal :: proc(editor: ^Editor, column_delta: i32) {
	if column_delta == 0 || editor.character_width == 0 { return }
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if editor_pane.wrap_mode { return }
	scroll_step_pixels := f32(column_delta * editor.character_width)
	new_scroll_target  := editor_pane.scroll_x_target + scroll_step_pixels
	if new_scroll_target < 0 { new_scroll_target = 0 }
	editor_pane.scroll_x_target = new_scroll_target
}

// Flip wrap-mode for the active pane. Horizontal scroll resets to zero on
// entering wrap (since the pane is now obligated to fit lines within the
// width). Cursor visibility is re-evaluated so the cursor stays on screen
// either way.
@(private)
editor_toggle_wrap :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	editor_pane.wrap_mode = !editor_pane.wrap_mode
	if editor_pane.wrap_mode {
		editor_pane.scroll_x        = 0
		editor_pane.scroll_x_target = 0
	}
	ensure_cursor_visible(editor)
	editor.cursor_visible = true
	editor.cursor_timer   = 0
}

// Scroll the active pane (if it's an editor pane) by `line_delta`. In diff
// mode the shared diff-state scroll is moved instead so both panes stay in
// lockstep.
@(private)
editor_scroll :: proc(editor: ^Editor, line_delta: i32) {
	if line_delta == 0 || editor.line_height == 0 { return }

	if editor.diff_state.active {
		active_pane_visible_lines := i32(editor.panes[editor.active_pane_index].rectangle.h / editor.line_height)
		if active_pane_visible_lines == 0 { active_pane_visible_lines = 1 }
		max_scroll_row_count := max(i32(0), i32(len(editor.diff_state.rows)) - active_pane_visible_lines)
		max_scroll_y := f32(max_scroll_row_count * editor.line_height)
		new_scroll_target := editor.diff_state.scroll_y_target + f32(line_delta * editor.line_height)
		editor.diff_state.scroll_y_target = clamp(new_scroll_target, 0, max_scroll_y)
		return
	}

	active_editor_pane := editor_active_editor_pane(editor); if active_editor_pane == nil { return }
	total_line_count := i32(document.document_line_count(&active_editor_pane.document))
	visible_line_count := i32(active_editor_pane.visible_lines)
	if visible_line_count == 0 { visible_line_count = 1 }
	max_scroll_line_count := max(i32(0), total_line_count - visible_line_count)
	max_scroll_y := f32(max_scroll_line_count * editor.line_height)
	new_scroll_target := active_editor_pane.scroll_y_target + f32(line_delta * editor.line_height)
	active_editor_pane.scroll_y_target = clamp(new_scroll_target, 0, max_scroll_y)
}

@(private)
editor_mouse_down :: proc(editor: ^Editor, mouse_x: f32, mouse_y: f32, shift_held: bool) {
	// Grab the divider first when both panes are showing — the hit zone is
	// generous (a few pixels either side of the 2-px line) because the line
	// itself is hard to hit precisely.
	if divider_hit_test(editor, mouse_x, mouse_y) {
		editor.divider_dragging = true
		return
	}

	pane_hit_index := editor_pane_at(editor, mouse_x, mouse_y)
	if pane_hit_index < 0 { return }
	editor.active_pane_index = pane_hit_index

	pane := &editor.panes[pane_hit_index]
	#partial switch &content_value in pane.content {
	case EditorPane:
		// Scrollbar takes priority over text selection — clicking the thumb
		// (or anywhere on the track) latches a drag instead of moving the
		// cursor. Track-but-not-thumb is a page-jump for now (sets target
		// scroll, smooth animator handles the rest).
		if scrollbar_thumb_hit(&content_value, mouse_x, mouse_y) {
			content_value.scrollbar.is_dragging  = true
			content_value.scrollbar.drag_delta_y = mouse_y - content_value.scrollbar.thumb_rectangle.y
			return
		}
		if ui.point_in_rect(content_value.scrollbar.track_rectangle, mouse_x, mouse_y) {
			scrollbar_jump_to(editor, &content_value, mouse_y)
			content_value.scrollbar.is_dragging = true
			// Center the thumb under the cursor for the rest of the drag.
			content_value.scrollbar.drag_delta_y = content_value.scrollbar.thumb_rectangle.h / 2
			return
		}
		editor_pane_mouse_down(editor, pane, &content_value, mouse_x, mouse_y, shift_held)
	}
}

// Hit-test the scrollbar thumb. We pad the thumb a couple of pixels
// horizontally so a hover near the edge still latches the drag.
@(private="file")
scrollbar_thumb_hit :: proc(editor_pane: ^EditorPane, mouse_x, mouse_y: f32) -> bool {
	thumb_rectangle := editor_pane.scrollbar.thumb_rectangle
	if thumb_rectangle.w <= 0 || thumb_rectangle.h <= 0 { return false }
	horizontal_padding: f32 = 2
	return mouse_x >= thumb_rectangle.x - horizontal_padding && mouse_x < thumb_rectangle.x + thumb_rectangle.w + horizontal_padding &&
	       mouse_y >= thumb_rectangle.y                      && mouse_y < thumb_rectangle.y + thumb_rectangle.h
}

// Translate a mouse-y on the track into a scroll value and apply it. Used
// both by drag-motion and by track-click-to-jump.
@(private="file")
scrollbar_jump_to :: proc(editor: ^Editor, editor_pane: ^EditorPane, mouse_y: f32) {
	track_rectangle := editor_pane.scrollbar.track_rectangle
	thumb_rectangle := editor_pane.scrollbar.thumb_rectangle
	if track_rectangle.h <= 0 || thumb_rectangle.h <= 0 || editor.line_height == 0 { return }

	travel_distance := track_rectangle.h - thumb_rectangle.h
	target_thumb_y := clamp(mouse_y - editor_pane.scrollbar.drag_delta_y, track_rectangle.y, track_rectangle.y + travel_distance)
	travel_fraction := f32(0)
	if travel_distance > 0 { travel_fraction = (target_thumb_y - track_rectangle.y) / travel_distance }

	total_line_count := f32(document.document_line_count(&editor_pane.document))

	if editor.diff_state.active {
		diff_row_count := f32(len(editor.diff_state.rows))
		content_height  := diff_row_count * f32(editor.line_height)
		viewport_height := f32(editor_pane.visible_lines) * f32(editor.line_height)
		max_scroll := max(f32(0), content_height - viewport_height)
		editor.diff_state.scroll_y        = travel_fraction * max_scroll
		editor.diff_state.scroll_y_target = editor.diff_state.scroll_y
		return
	}

	content_height  := total_line_count * f32(editor.line_height)
	viewport_height := f32(editor_pane.visible_lines) * f32(editor.line_height)
	max_scroll := max(f32(0), content_height - viewport_height)
	editor_pane.scroll_y        = travel_fraction * max_scroll
	editor_pane.scroll_y_target = editor_pane.scroll_y
	if editor.line_height > 0 { editor_pane.scroll_line = u32(editor_pane.scroll_y / f32(editor.line_height)) }
}

// Update the per-pane scrollbar hover flag from the current mouse position.
// Called on every MOUSE_MOTION so the next frame paints a widened scrollbar
// while the cursor is over it.
@(private)
editor_scrollbar_update_hover :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	for pane_index in 0..<editor_visible_pane_count(editor) {
		if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
			is_over_track := ui.point_in_rect(editor_pane.scrollbar.track_rectangle, mouse_x, mouse_y)
			if is_over_track != editor_pane.scrollbar.is_hovered {
				editor_pane.scrollbar.is_hovered = is_over_track
				editor_mark_dirty(editor)
			}
		}
	}
}

// True when (mouse_x,mouse_y) is inside the resize-handle zone around the
// divider. The physical divider is 2 px wide; we accept ±4 px on either side
// so the user can actually grab it. Only applicable when a split is
// currently active.
@(private="file")
divider_hit_test :: proc(editor: ^Editor, mouse_x, mouse_y: f32) -> bool {
	if !editor.split_active                    { return false }
	if editor_visible_pane_count(editor) != 2  { return false }
	// Divider runs vertically between the two pane rects.
	left_pane_rectangle  := editor.panes[0].rectangle
	right_pane_rectangle := editor.panes[1].rectangle
	divider_x := f32(left_pane_rectangle.x + left_pane_rectangle.w)
	divider_width := f32(right_pane_rectangle.x) - divider_x
	if divider_width <= 0 { return false }
	horizontal_padding: f32 = 4
	return mouse_x >= divider_x - horizontal_padding && mouse_x < divider_x + divider_width + horizontal_padding &&
	       mouse_y >= f32(left_pane_rectangle.y)     && mouse_y < f32(left_pane_rectangle.y + left_pane_rectangle.h)
}

@(private="file")
editor_pane_mouse_down :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x: f32, mouse_y: f32, shift_held: bool) {
	clicked_offset := screen_to_offset(editor, pane, editor_pane, mouse_x, mouse_y)

	if shift_held {
		if !editor_pane.selection_active {
			editor_pane.selection_anchor = editor_pane.cursor_offset
			editor_pane.selection_active = true
		}
	} else {
		editor_pane.selection_anchor = clicked_offset
		editor_pane.selection_active = true
	}
	editor_pane.cursor_offset  = clicked_offset
	editor_pane.mouse_dragging = true
	editor.cursor_visible = true
	editor.cursor_timer = 0
	sync_cursor_from_offset(editor)
}

@(private)
editor_mouse_drag :: proc(editor: ^Editor, mouse_x: f32, mouse_y: f32) {
	// Scrollbar drag takes top priority — once latched, every motion event
	// just maps to a new scroll position until the user releases the
	// button.
	for pane_index in 0..<editor_visible_pane_count(editor) {
		if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil && editor_pane.scrollbar.is_dragging {
			scrollbar_jump_to(editor, editor_pane, mouse_y)
			editor_mark_dirty(editor)
			return
		}
	}

	// Divider drag takes priority — once it's grabbed, the cursor owns the
	// split position until release. Update `split_ratio` from the current
	// mouse x; render's clamp keeps both panes above the usable minimum.
	if editor.divider_dragging {
		total_pane_width := editor.panes[0].rectangle.w + editor.panes[1].rectangle.w
		// The divider itself is 2 px; account for it so the math matches
		// what `editor_render` uses to lay out the panes.
		divider_width: i32 = 2
		usable_width := total_pane_width + divider_width
		if usable_width <= 0 { return }
		new_ratio := mouse_x / f32(usable_width)
		if new_ratio < 0.05 { new_ratio = 0.05 }
		if new_ratio > 0.95 { new_ratio = 0.95 }
		editor.split_ratio = new_ratio
		return
	}

	// Drag stays locked to the pane that started the drag.
	for pane_index in 0..<editor_visible_pane_count(editor) {
		pane := &editor.panes[pane_index]
		#partial switch &content_value in pane.content {
		case EditorPane:
			if content_value.mouse_dragging {
				editor.active_pane_index = pane_index
				editor_pane_mouse_drag(editor, pane, &content_value, mouse_x, mouse_y)
				return
			}
		}
	}
}

@(private="file")
editor_pane_mouse_drag :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x: f32, mouse_y: f32) {
	new_offset := screen_to_offset(editor, pane, editor_pane, mouse_x, mouse_y)
	if new_offset == editor_pane.cursor_offset { return }
	editor_pane.cursor_offset = new_offset
	editor_pane.selection_active = true
	editor.cursor_visible = true
	editor.cursor_timer = 0
	sync_cursor_from_offset(editor)
}

@(private)
editor_mouse_up :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	editor.divider_dragging = false
	for pane_index in 0..<len(editor.panes) {
		#partial switch &content_value in editor.panes[pane_index].content {
		case EditorPane:
			content_value.mouse_dragging         = false
			content_value.scrollbar.is_dragging  = false
		}
	}
	// Update cursor based on the release position so it snaps back to the
	// default arrow if the user has moved off the divider while dragging.
	editor_update_cursor(editor, mouse_x, mouse_y)
}

@(private="file")
screen_to_offset :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x: f32, mouse_y: f32) -> u32 {
	total_line_count := document.document_line_count(&editor_pane.document)
	if total_line_count == 0 { return 0 }

	// Y → line, using fractional scroll offset for accurate mid-animation
	// clicks. The text area begins below the title bar at the top of the pane.
	title_bar_height := f32(editor_title_bar_height(editor))
	document_y := mouse_y - f32(pane.rectangle.y) - title_bar_height - f32(editor.padding_y) + editor_pane.scroll_y
	if document_y < 0 { document_y = 0 }
	target_line: u32 = 0
	if editor.line_height > 0 {
		target_line = u32(document_y / f32(editor.line_height))
	}
	if target_line >= total_line_count { target_line = total_line_count - 1 }

	// X → byte column within the line, measured from the pane's text origin.
	relative_x := i32(mouse_x) - pane.rectangle.x - editor.padding_x - editor_pane.gutter_width
	column_index: i32 = 0
	if relative_x > 0 && editor.character_width > 0 {
		column_index = (relative_x + editor.character_width / 2) / editor.character_width
	}
	line_start_offset := document.document_line_start(&editor_pane.document, target_line)
	target_line_text := document.document_get_line(&editor_pane.document, target_line, context.temp_allocator)
	line_length := i32(len(target_line_text))
	if column_index > line_length { column_index = line_length }
	if column_index < 0 { column_index = 0 }

	return line_start_offset + u32(column_index)
}
