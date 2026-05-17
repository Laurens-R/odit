package editor

import "../document"

@(private)
editor_scroll :: proc(ed: ^Editor, delta_lines: i32) {
	if delta_lines == 0 || ed.line_height == 0 { return }
	line_count := i32(document.document_line_count(&ed.doc))
	visible := i32(ed.visible_lines)
	if visible == 0 { visible = 1 }
	max_scroll_lines := max(i32(0), line_count - visible)
	max_scroll_y := f32(max_scroll_lines * ed.line_height)
	new_target := ed.scroll_y_target + f32(delta_lines * ed.line_height)
	ed.scroll_y_target = clamp(new_target, 0, max_scroll_y)
}

@(private)
editor_mouse_down :: proc(ed: ^Editor, x: f32, y: f32, shift: bool) {
	offset := screen_to_offset(ed, x, y)

	if shift {
		if !ed.sel_active {
			ed.sel_anchor = ed.cursor_offset
			ed.sel_active = true
		}
	} else {
		ed.sel_anchor = offset
		ed.sel_active = true // empty range; promoted to a real selection on drag
	}
	ed.cursor_offset = offset
	ed.mouse_dragging = true
	ed.cursor_visible = true
	ed.cursor_timer = 0
	sync_cursor_from_offset(ed)
}

@(private)
editor_mouse_drag :: proc(ed: ^Editor, x: f32, y: f32) {
	offset := screen_to_offset(ed, x, y)
	if offset == ed.cursor_offset { return }
	ed.cursor_offset = offset
	ed.sel_active = true
	ed.cursor_visible = true
	ed.cursor_timer = 0
	sync_cursor_from_offset(ed)
}

@(private="file")
screen_to_offset :: proc(ed: ^Editor, x: f32, y: f32) -> u32 {
	line_count := document.document_line_count(&ed.doc)
	if line_count == 0 { return 0 }

	// Y → line, using fractional scroll offset for accurate mid-animation clicks
	doc_y := y - f32(ed.padding_y) + ed.scroll_y
	if doc_y < 0 { doc_y = 0 }
	target_line: u32 = 0
	if ed.line_height > 0 {
		target_line = u32(doc_y / f32(ed.line_height))
	}
	if target_line >= line_count { target_line = line_count - 1 }

	// X → byte column within the line
	rel_x := i32(x) - ed.padding_x - ed.gutter_width
	col: i32 = 0
	if rel_x > 0 && ed.char_width > 0 {
		// Round to nearest char boundary for natural click feel
		col = (rel_x + ed.char_width / 2) / ed.char_width
	}
	line_start := document.document_line_start(&ed.doc, target_line)
	line_text := document.document_get_line(&ed.doc, target_line)
	line_len := i32(len(line_text))
	if col > line_len { col = line_len }
	if col < 0 { col = 0 }

	return line_start + u32(col)
}
