package editor

import "../document"

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

	v := editor_active_editor_pane(ed); if v == nil { return }
	line_count := i32(document.document_line_count(&v.doc))
	visible := i32(v.visible_lines)
	if visible == 0 { visible = 1 }
	max_scroll_lines := max(i32(0), line_count - visible)
	max_scroll_y := f32(max_scroll_lines * ed.line_height)
	new_target := v.scroll_y_target + f32(delta_lines * ed.line_height)
	v.scroll_y_target = clamp(new_target, 0, max_scroll_y)
}

@(private)
editor_mouse_down :: proc(ed: ^Editor, x: f32, y: f32, shift: bool) {
	hit := editor_pane_at(ed, x, y)
	if hit < 0 { return }
	ed.active = hit

	pane := &ed.panes[hit]
	#partial switch &c in pane.content {
	case EditorPane:
		editor_pane_mouse_down(ed, pane, &c, x, y, shift)
	}
}

@(private="file")
editor_pane_mouse_down :: proc(ed: ^Editor, pane: ^Pane, v: ^EditorPane, x: f32, y: f32, shift: bool) {
	offset := screen_to_offset(ed, pane, v, x, y)

	if shift {
		if !v.sel_active {
			v.sel_anchor = v.cursor_offset
			v.sel_active = true
		}
	} else {
		v.sel_anchor = offset
		v.sel_active = true
	}
	v.cursor_offset = offset
	v.mouse_dragging = true
	ed.cursor_visible = true
	ed.cursor_timer = 0
	sync_cursor_from_offset(ed)
}

@(private)
editor_mouse_drag :: proc(ed: ^Editor, x: f32, y: f32) {
	// Drag stays locked to the pane that started the drag.
	for i in 0..<editor_visible_pane_count(ed) {
		pane := &ed.panes[i]
		#partial switch &c in pane.content {
		case EditorPane:
			if c.mouse_dragging {
				ed.active = i
				editor_pane_mouse_drag(ed, pane, &c, x, y)
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
editor_mouse_up :: proc(ed: ^Editor) {
	for i in 0..<len(ed.panes) {
		#partial switch &c in ed.panes[i].content {
		case EditorPane:
			c.mouse_dragging = false
		}
	}
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
