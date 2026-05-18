package editor

import "vendor:sdl3"

import "../document"

// Set the OS cursor to `c` if it's not already the active one. Centralised so
// hover, drag, and release paths don't fight each other over the cursor.
@(private="file")
set_cursor :: proc(ed: ^Editor, c: ^sdl3.Cursor) {
	if c == nil || ed.current_cursor == c { return }
	_ = sdl3.SetCursor(c)
	ed.current_cursor = c
}

// Pick a cursor shape based on what (x,y) is over right now plus the active
// drag state. EW-resize on the divider hot-zone or whenever a divider drag is
// in progress; default arrow otherwise.
@(private)
editor_update_cursor :: proc(ed: ^Editor, x, y: f32) {
	if ed.divider_dragging || divider_hit_test(ed, x, y) {
		set_cursor(ed, ed.cursor_resize_ew)
	} else {
		set_cursor(ed, ed.cursor_default)
	}
}

// Pan the active pane horizontally by `delta_chars` columns. No-op when the
// pane is in wrap mode (the model says wrap and horizontal scroll are
// mutually exclusive — Ctrl+W toggles between them) or when there's no
// editor pane focused.
@(private)
editor_scroll_horizontal :: proc(ed: ^Editor, delta_chars: i32) {
	if delta_chars == 0 || ed.char_width == 0 { return }
	v := editor_active_editor_pane(ed); if v == nil { return }
	if v.wrap_mode { return }
	step    := f32(delta_chars * ed.char_width)
	new_tgt := v.scroll_x_target + step
	if new_tgt < 0 { new_tgt = 0 }
	v.scroll_x_target = new_tgt
}

// Flip wrap-mode for the active pane. Horizontal scroll resets to zero on
// entering wrap (since the pane is now obligated to fit lines within the
// width). Cursor visibility is re-evaluated so the cursor stays on screen
// either way.
@(private)
editor_toggle_wrap :: proc(ed: ^Editor) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	v.wrap_mode = !v.wrap_mode
	if v.wrap_mode {
		v.scroll_x        = 0
		v.scroll_x_target = 0
	}
	ensure_cursor_visible(ed)
	ed.cursor_visible = true
	ed.cursor_timer   = 0
}

// Scroll the active pane (if it's an editor pane) by `delta_lines`. In diff
// mode the shared diff-state scroll is moved instead so both panes stay in
// lockstep.
@(private)
editor_scroll :: proc(ed: ^Editor, delta_lines: i32) {
	if delta_lines == 0 || ed.line_height == 0 { return }

	if ed.diff_state.active {
		visible_lines := i32(ed.panes[ed.active].rect.h / ed.line_height)
		if visible_lines == 0 { visible_lines = 1 }
		max_scroll_rows := max(i32(0), i32(len(ed.diff_state.rows)) - visible_lines)
		max_scroll_y := f32(max_scroll_rows * ed.line_height)
		new_target := ed.diff_state.scroll_y_target + f32(delta_lines * ed.line_height)
		ed.diff_state.scroll_y_target = clamp(new_target, 0, max_scroll_y)
		return
	}

	active_editor_pane := editor_active_editor_pane(ed); if active_editor_pane == nil { return }
	line_count := i32(document.document_line_count(&active_editor_pane.doc))
	visible := i32(active_editor_pane.visible_lines)
	if visible == 0 { visible = 1 }
	max_scroll_lines := max(i32(0), line_count - visible)
	max_scroll_y := f32(max_scroll_lines * ed.line_height)
	new_target := active_editor_pane.scroll_y_target + f32(delta_lines * ed.line_height)
	active_editor_pane.scroll_y_target = clamp(new_target, 0, max_scroll_y)
}

@(private)
editor_mouse_down :: proc(editor: ^Editor, x: f32, y: f32, shift: bool) {
	// Grab the divider first when both panes are showing — the hit zone is
	// generous (a few pixels either side of the 2-px line) because the line
	// itself is hard to hit precisely.
	if divider_hit_test(editor, x, y) {
		editor.divider_dragging = true
		return
	}

	hit := editor_pane_at(editor, x, y)
	if hit < 0 { return }
	editor.active = hit

	pane := &editor.panes[hit]
	#partial switch &c in pane.content {
	case EditorPane:
		editor_pane_mouse_down(editor, pane, &c, x, y, shift)
	}
}

// True when (x,y) is inside the resize-handle zone around the divider. The
// physical divider is 2 px wide; we accept ±4 px on either side so the user
// can actually grab it. Only applicable when a split is currently active.
@(private="file")
divider_hit_test :: proc(ed: ^Editor, x, y: f32) -> bool {
	if !ed.split_active                    { return false }
	if editor_visible_pane_count(ed) != 2  { return false }
	// Divider runs vertically between the two pane rects.
	left_rect  := ed.panes[0].rect
	right_rect := ed.panes[1].rect
	divider_x := f32(left_rect.x + left_rect.w)
	divider_w := f32(right_rect.x) - divider_x
	if divider_w <= 0 { return false }
	pad: f32 = 4
	return x >= divider_x - pad && x < divider_x + divider_w + pad &&
	       y >= f32(left_rect.y) && y < f32(left_rect.y + left_rect.h)
}

@(private="file")
editor_pane_mouse_down :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, x: f32, y: f32, shift: bool) {
	offset := screen_to_offset(editor, pane, editor_pane, x, y)

	if shift {
		if !editor_pane.sel_active {
			editor_pane.sel_anchor = editor_pane.cursor_offset
			editor_pane.sel_active = true
		}
	} else {
		editor_pane.sel_anchor = offset
		editor_pane.sel_active = true
	}
	editor_pane.cursor_offset = offset
	editor_pane.mouse_dragging = true
	editor.cursor_visible = true
	editor.cursor_timer = 0
	sync_cursor_from_offset(editor)
}

@(private)
editor_mouse_drag :: proc(editor: ^Editor, x: f32, y: f32) {
	// Divider drag takes priority — once it's grabbed, the cursor owns the
	// split position until release. Update `split_ratio` from the current
	// mouse x; render's clamp keeps both panes above the usable minimum.
	if editor.divider_dragging {
		total_w := editor.panes[0].rect.w + editor.panes[1].rect.w
		// The divider itself is 2 px; account for it so the math matches
		// what `editor_render` uses to lay out the panes.
		divider_w: i32 = 2
		usable := total_w + divider_w
		if usable <= 0 { return }
		ratio := x / f32(usable)
		if ratio < 0.05 { ratio = 0.05 }
		if ratio > 0.95 { ratio = 0.95 }
		editor.split_ratio = ratio
		return
	}

	// Drag stays locked to the pane that started the drag.
	for i in 0..<editor_visible_pane_count(editor) {
		pane := &editor.panes[i]
		#partial switch &c in pane.content {
		case EditorPane:
			if c.mouse_dragging {
				editor.active = i
				editor_pane_mouse_drag(editor, pane, &c, x, y)
				return
			}
		}
	}
}

@(private="file")
editor_pane_mouse_drag :: proc(ed: ^Editor, pane: ^Pane, v: ^EditorPane, x: f32, y: f32) {
	offset := screen_to_offset(ed, pane, v, x, y)
	if offset == v.cursor_offset { return }
	v.cursor_offset = offset
	v.sel_active = true
	ed.cursor_visible = true
	ed.cursor_timer = 0
	sync_cursor_from_offset(ed)
}

@(private)
editor_mouse_up :: proc(ed: ^Editor, x, y: f32) {
	ed.divider_dragging = false
	for i in 0..<len(ed.panes) {
		#partial switch &c in ed.panes[i].content {
		case EditorPane:
			c.mouse_dragging = false
		}
	}
	// Update cursor based on the release position so it snaps back to the
	// default arrow if the user has moved off the divider while dragging.
	editor_update_cursor(ed, x, y)
}

@(private="file")
screen_to_offset :: proc(ed: ^Editor, pane: ^Pane, v: ^EditorPane, x: f32, y: f32) -> u32 {
	line_count := document.document_line_count(&v.doc)
	if line_count == 0 { return 0 }

	// Y → line, using fractional scroll offset for accurate mid-animation
	// clicks. The text area begins below the title bar at the top of the pane.
	title_h := f32(editor_title_bar_height(ed))
	doc_y := y - f32(pane.rect.y) - title_h - f32(ed.padding_y) + v.scroll_y
	if doc_y < 0 { doc_y = 0 }
	target_line: u32 = 0
	if ed.line_height > 0 {
		target_line = u32(doc_y / f32(ed.line_height))
	}
	if target_line >= line_count { target_line = line_count - 1 }

	// X → byte column within the line, measured from the pane's text origin.
	rel_x := i32(x) - pane.rect.x - ed.padding_x - v.gutter_width
	col: i32 = 0
	if rel_x > 0 && ed.char_width > 0 {
		col = (rel_x + ed.char_width / 2) / ed.char_width
	}
	line_start := document.document_line_start(&v.doc, target_line)
	line_text := document.document_get_line(&v.doc, target_line)
	line_len := i32(len(line_text))
	if col > line_len { col = line_len }
	if col < 0 { col = 0 }

	return line_start + u32(col)
}
