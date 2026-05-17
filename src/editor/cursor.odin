package editor

import "../document"

@(private)
editor_insert_text :: proc(ed: ^Editor, text: string) {
	delete_selection(ed)
	document.document_insert(&ed.doc, ed.cursor_offset, text)
	ed.cursor_offset += u32(len(text))
	sync_cursor_from_offset(ed)
}

@(private)
sync_cursor_from_offset :: proc(ed: ^Editor) {
	ed.cursor_line = document.document_offset_to_line(&ed.doc, ed.cursor_offset)
	line_start := document.document_line_start(&ed.doc, ed.cursor_line)
	ed.cursor_col = ed.cursor_offset - line_start
	ensure_cursor_visible(ed)
}

@(private)
move_cursor_vertical :: proc(ed: ^Editor, delta: i32) {
	new_line := i32(ed.cursor_line) + delta
	line_count := i32(document.document_line_count(&ed.doc))
	new_line = clamp(new_line, 0, line_count - 1)

	target_line := u32(new_line)
	line_start := document.document_line_start(&ed.doc, target_line)
	line_text := document.document_get_line(&ed.doc, target_line)
	line_len := u32(len(line_text))

	// Preserve column position, clamp to line length
	col := min(ed.cursor_col, line_len)

	ed.cursor_line = target_line
	ed.cursor_col = col
	ed.cursor_offset = line_start + col
	ensure_cursor_visible(ed)
}

@(private="file")
ensure_cursor_visible :: proc(ed: ^Editor) {
	if ed.visible_lines == 0 { return }

	new_scroll_line := ed.scroll_line
	if ed.cursor_line < ed.scroll_line {
		new_scroll_line = ed.cursor_line
	} else if ed.cursor_line >= ed.scroll_line + ed.visible_lines {
		new_scroll_line = ed.cursor_line - ed.visible_lines + 1
	}
	if new_scroll_line != ed.scroll_line {
		// Cursor moved off-screen — snap instantly, no smooth animation.
		ed.scroll_line = new_scroll_line
		ed.scroll_y = f32(new_scroll_line) * f32(ed.line_height)
		ed.scroll_y_target = ed.scroll_y
	}
}

@(private)
prev_char_len :: proc(ed: ^Editor) -> u32 {
	if ed.cursor_offset == 0 { return 0 }
	// Read up to 4 bytes before cursor to find UTF-8 char boundary
	look_back := min(ed.cursor_offset, 4)
	slice := document.document_get_slice(&ed.doc, ed.cursor_offset - look_back, look_back)
	if len(slice) == 0 { return 1 }

	// Walk backwards to find the start of the last rune
	i := len(slice) - 1
	for i > 0 && (slice[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return u32(len(slice) - i)
}

@(private)
next_char_len :: proc(ed: ^Editor) -> u32 {
	doc_len := document.document_length(&ed.doc)
	if ed.cursor_offset >= doc_len { return 0 }
	look_ahead := min(doc_len - ed.cursor_offset, 4)
	slice := document.document_get_slice(&ed.doc, ed.cursor_offset, look_ahead)
	if len(slice) == 0 { return 1 }

	// First byte tells us the rune length
	b := slice[0]
	if b < 0x80      { return 1 }
	else if b < 0xE0 { return 2 }
	else if b < 0xF0 { return 3 }
	else             { return 4 }
}
