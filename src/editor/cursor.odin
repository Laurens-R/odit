package editor

import "../document"

@(private)
editor_insert_text :: proc(ed: ^Editor, text: string) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	delete_selection(ed)
	document.document_insert(&v.doc, v.cursor_offset, text)
	v.cursor_offset += u32(len(text))
	v.symbols_dirty = true
	sync_cursor_from_offset(ed)
}

// Remove one "tab's worth" of leading whitespace from the current line of the
// active editor pane.
@(private)
editor_outdent_line :: proc(ed: ^Editor) {
	v := editor_active_editor_pane(ed); if v == nil { return }

	line_start := document.document_line_start(&v.doc, v.cursor_line)
	line := document.document_get_line(&v.doc, v.cursor_line, context.temp_allocator)

	if len(line) == 0 { return }

	remove_count: u32 = 0
	switch line[0] {
	case '\t':
		remove_count = 1
	case ' ':
		for int(remove_count) < len(line) && remove_count < u32(TAB_WIDTH) && line[remove_count] == ' ' {
			remove_count += 1
		}
	}

	if remove_count == 0 { return }

	document.document_delete(&v.doc, line_start, remove_count)
	v.symbols_dirty = true

	if v.cursor_offset >= line_start + remove_count {
		v.cursor_offset -= remove_count
	} else if v.cursor_offset > line_start {
		v.cursor_offset = line_start
	}

	v.sel_active = false

	sync_cursor_from_offset(ed)
}

@(private)
editor_insert_newline_with_indent :: proc(ed: ^Editor) {
	v := editor_active_editor_pane(ed); if v == nil { return }

	line_for_indent := v.cursor_line
	if v.sel_active {
		lo := min(v.sel_anchor, v.cursor_offset)
		line_for_indent = document.document_offset_to_line(&v.doc, lo)
	}

	line := document.document_get_line(&v.doc, line_for_indent, context.temp_allocator)

	indent_end := 0
	for indent_end < len(line) {
		c := line[indent_end]
		if c != ' ' && c != '\t' { break }
		indent_end += 1
	}

	if indent_end == 0 {
		editor_insert_text(ed, "\n")
		return
	}

	buf := make([]byte, 1 + indent_end, context.temp_allocator)
	buf[0] = '\n'
	copy(buf[1:], line[:indent_end])
	editor_insert_text(ed, string(buf))
}

@(private)
sync_cursor_from_offset :: proc(ed: ^Editor) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	v.cursor_line = document.document_offset_to_line(&v.doc, v.cursor_offset)
	line_start := document.document_line_start(&v.doc, v.cursor_line)
	v.cursor_col = v.cursor_offset - line_start
	ensure_cursor_visible(ed)
}

@(private)
move_cursor_vertical :: proc(ed: ^Editor, delta: i32) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	new_line := i32(v.cursor_line) + delta
	line_count := i32(document.document_line_count(&v.doc))
	new_line = clamp(new_line, 0, line_count - 1)

	target_line := u32(new_line)
	line_start := document.document_line_start(&v.doc, target_line)
	line_text := document.document_get_line(&v.doc, target_line)
	line_len := u32(len(line_text))

	col := min(v.cursor_col, line_len)

	v.cursor_line = target_line
	v.cursor_col = col
	v.cursor_offset = line_start + col
	ensure_cursor_visible(ed)
}

@(private)
ensure_cursor_visible :: proc(ed: ^Editor) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	if v.visible_lines == 0 { return }

	// In diff mode, the cursor lives at a doc line but is rendered at a
	// diff-row index. Resolve that mapping and scroll the shared diff view.
	if ed.diff_state.active {
		map_arr: []i32
		if ed.active == 0 {
			map_arr = ed.diff_state.left_line_to_row[:]
		} else {
			map_arr = ed.diff_state.right_line_to_row[:]
		}

		if int(v.cursor_line) >= len(map_arr) { return }
		row_idx := map_arr[v.cursor_line]
		if row_idx < 0 { return }

		row_top    := f32(row_idx) * f32(ed.line_height)
		row_bottom := row_top + f32(ed.line_height)
		viewport_h := f32(v.visible_lines) * f32(ed.line_height)

		if row_top < ed.diff_state.scroll_y {
			ed.diff_state.scroll_y = row_top
			ed.diff_state.scroll_y_target = row_top
		} else if row_bottom > ed.diff_state.scroll_y + viewport_h {
			new_scroll := row_bottom - viewport_h
			ed.diff_state.scroll_y = new_scroll
			ed.diff_state.scroll_y_target = new_scroll
		}
		return
	}

	new_scroll_line := v.scroll_line
	if v.cursor_line < v.scroll_line {
		new_scroll_line = v.cursor_line
	} else if v.cursor_line >= v.scroll_line + v.visible_lines {
		new_scroll_line = v.cursor_line - v.visible_lines + 1
	}
	if new_scroll_line != v.scroll_line {
		v.scroll_line = new_scroll_line
		v.scroll_y = f32(new_scroll_line) * f32(ed.line_height)
		v.scroll_y_target = v.scroll_y
	}

	// Horizontal scroll only matters when wrap is off — otherwise every
	// column is by definition on screen.
	if !v.wrap_mode && ed.char_width > 0 {
		pane := &ed.panes[ed.active]
		cursor_x_px := f32(v.cursor_col) * f32(ed.char_width)
		text_w      := f32(pane.rect.w - ed.padding_x - v.gutter_width)
		if text_w < f32(ed.char_width) { text_w = f32(ed.char_width) }

		// A small slop column so the cursor isn't pasted against the very
		// edge of the pane after a horizontal jump.
		slop := f32(ed.char_width * 2)

		if cursor_x_px < v.scroll_x_target + slop {
			v.scroll_x_target = max(f32(0), cursor_x_px - slop)
			v.scroll_x        = v.scroll_x_target
		} else if cursor_x_px + f32(ed.char_width) > v.scroll_x_target + text_w - slop {
			v.scroll_x_target = cursor_x_px + f32(ed.char_width) - text_w + slop
			v.scroll_x        = v.scroll_x_target
		}
	}
}

@(private)
prev_char_len :: proc(ed: ^Editor) -> u32 {
	v := editor_active_editor_pane(ed); if v == nil { return 0 }
	if v.cursor_offset == 0 { return 0 }
	look_back := min(v.cursor_offset, 4)
	slice := document.document_get_slice(&v.doc, v.cursor_offset - look_back, look_back)
	if len(slice) == 0 { return 1 }

	i := len(slice) - 1
	for i > 0 && (slice[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return u32(len(slice) - i)
}

@(private)
next_char_len :: proc(ed: ^Editor) -> u32 {
	v := editor_active_editor_pane(ed); if v == nil { return 0 }
	doc_len := document.document_length(&v.doc)
	if v.cursor_offset >= doc_len { return 0 }
	look_ahead := min(doc_len - v.cursor_offset, 4)
	slice := document.document_get_slice(&v.doc, v.cursor_offset, look_ahead)
	if len(slice) == 0 { return 1 }

	b := slice[0]
	if b < 0x80      { return 1 }
	else if b < 0xE0 { return 2 }
	else if b < 0xF0 { return 3 }
	else             { return 4 }
}
