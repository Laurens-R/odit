package editor

import "../document"

@(private)
editor_insert_text :: proc(editor: ^Editor, text_to_insert: string) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	delete_selection(editor)
	document.document_insert(&editor_pane.document, editor_pane.cursor_offset, text_to_insert)
	editor_pane.cursor_offset += u32(len(text_to_insert))
	editor_pane.symbols_dirty = true
	sync_cursor_from_offset(editor)
}

// Remove one "tab's worth" of leading whitespace from the current line of the
// active editor pane.
@(private)
editor_outdent_line :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	line_start_offset := document.document_line_start(&editor_pane.document, editor_pane.cursor_line)
	line_text := document.document_get_line(&editor_pane.document, editor_pane.cursor_line, context.temp_allocator)

	if len(line_text) == 0 { return }

	bytes_to_remove: u32 = 0
	switch line_text[0] {
	case '\t':
		bytes_to_remove = 1
	case ' ':
		for int(bytes_to_remove) < len(line_text) && bytes_to_remove < u32(TAB_WIDTH) && line_text[bytes_to_remove] == ' ' {
			bytes_to_remove += 1
		}
	}

	if bytes_to_remove == 0 { return }

	document.document_delete(&editor_pane.document, line_start_offset, bytes_to_remove)
	editor_pane.symbols_dirty = true

	if editor_pane.cursor_offset >= line_start_offset + bytes_to_remove {
		editor_pane.cursor_offset -= bytes_to_remove
	} else if editor_pane.cursor_offset > line_start_offset {
		editor_pane.cursor_offset = line_start_offset
	}

	editor_pane.selection_active = false

	sync_cursor_from_offset(editor)
}

@(private)
editor_insert_newline_with_indent :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	indent_source_line := editor_pane.cursor_line
	if editor_pane.selection_active {
		low_offset := min(editor_pane.selection_anchor, editor_pane.cursor_offset)
		indent_source_line = document.document_offset_to_line(&editor_pane.document, low_offset)
	}

	source_line_text := document.document_get_line(&editor_pane.document, indent_source_line, context.temp_allocator)

	indent_end_index := 0
	for indent_end_index < len(source_line_text) {
		character_value := source_line_text[indent_end_index]
		if character_value != ' ' && character_value != '\t' { break }
		indent_end_index += 1
	}

	if indent_end_index == 0 {
		editor_insert_text(editor, "\n")
		return
	}

	newline_with_indent_buffer := make([]byte, 1 + indent_end_index, context.temp_allocator)
	newline_with_indent_buffer[0] = '\n'
	copy(newline_with_indent_buffer[1:], source_line_text[:indent_end_index])
	editor_insert_text(editor, string(newline_with_indent_buffer))
}

@(private)
sync_cursor_from_offset :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	editor_pane.cursor_line = document.document_offset_to_line(&editor_pane.document, editor_pane.cursor_offset)
	line_start_offset := document.document_line_start(&editor_pane.document, editor_pane.cursor_line)
	editor_pane.cursor_column = editor_pane.cursor_offset - line_start_offset
	ensure_cursor_visible(editor)
}

@(private)
move_cursor_vertical :: proc(editor: ^Editor, line_delta: i32) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	new_line_signed := i32(editor_pane.cursor_line) + line_delta
	total_line_count := i32(document.document_line_count(&editor_pane.document))
	new_line_signed = clamp(new_line_signed, 0, total_line_count - 1)

	target_line := u32(new_line_signed)
	line_start_offset := document.document_line_start(&editor_pane.document, target_line)
	target_line_text := document.document_get_line(&editor_pane.document, target_line, context.temp_allocator)
	target_line_length := u32(len(target_line_text))

	clamped_column := min(editor_pane.cursor_column, target_line_length)

	editor_pane.cursor_line = target_line
	editor_pane.cursor_column = clamped_column
	editor_pane.cursor_offset = line_start_offset + clamped_column
	ensure_cursor_visible(editor)
}

@(private)
ensure_cursor_visible :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if editor_pane.visible_lines == 0 { return }

	// In diff mode, the cursor lives at a doc line but is rendered at a
	// diff-row index. Resolve that mapping and scroll the shared diff view.
	if editor.diff_state.active {
		line_to_row_map: []i32
		if editor.active_pane_index == 0 {
			line_to_row_map = editor.diff_state.left_line_to_row[:]
		} else {
			line_to_row_map = editor.diff_state.right_line_to_row[:]
		}

		if int(editor_pane.cursor_line) >= len(line_to_row_map) { return }
		row_index := line_to_row_map[editor_pane.cursor_line]
		if row_index < 0 { return }

		row_top_y    := f32(row_index) * f32(editor.line_height)
		row_bottom_y := row_top_y + f32(editor.line_height)
		viewport_height := f32(editor_pane.visible_lines) * f32(editor.line_height)

		if row_top_y < editor.diff_state.scroll_y {
			editor.diff_state.scroll_y = row_top_y
			editor.diff_state.scroll_y_target = row_top_y
		} else if row_bottom_y > editor.diff_state.scroll_y + viewport_height {
			new_scroll := row_bottom_y - viewport_height
			editor.diff_state.scroll_y = new_scroll
			editor.diff_state.scroll_y_target = new_scroll
		}
		return
	}

	new_scroll_line := editor_pane.scroll_line
	if editor_pane.cursor_line < editor_pane.scroll_line {
		new_scroll_line = editor_pane.cursor_line
	} else if editor_pane.cursor_line >= editor_pane.scroll_line + editor_pane.visible_lines {
		new_scroll_line = editor_pane.cursor_line - editor_pane.visible_lines + 1
	}
	if new_scroll_line != editor_pane.scroll_line {
		editor_pane.scroll_line = new_scroll_line
		editor_pane.scroll_y = f32(new_scroll_line) * f32(editor.line_height)
		editor_pane.scroll_y_target = editor_pane.scroll_y
	}

	// Horizontal scroll only matters when wrap is off — otherwise every
	// column is by definition on screen.
	if !editor_pane.wrap_mode && editor.character_width > 0 {
		pane := &editor.panes[editor.active_pane_index]
		cursor_pixel_x := f32(editor_pane.cursor_column) * f32(editor.character_width)
		text_area_width := f32(pane.rectangle.w - editor.padding_x - editor_pane.gutter_width)
		if text_area_width < f32(editor.character_width) { text_area_width = f32(editor.character_width) }

		// A small slop column so the cursor isn't pasted against the very
		// edge of the pane after a horizontal jump.
		horizontal_slop := f32(editor.character_width * 2)

		if cursor_pixel_x < editor_pane.scroll_x_target + horizontal_slop {
			editor_pane.scroll_x_target = max(f32(0), cursor_pixel_x - horizontal_slop)
			editor_pane.scroll_x        = editor_pane.scroll_x_target
		} else if cursor_pixel_x + f32(editor.character_width) > editor_pane.scroll_x_target + text_area_width - horizontal_slop {
			editor_pane.scroll_x_target = cursor_pixel_x + f32(editor.character_width) - text_area_width + horizontal_slop
			editor_pane.scroll_x        = editor_pane.scroll_x_target
		}
	}
}

@(private)
prev_char_len :: proc(editor: ^Editor) -> u32 {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return 0 }
	if editor_pane.cursor_offset == 0 { return 0 }
	look_back_bytes := min(editor_pane.cursor_offset, 4)
	look_back_slice := document.document_get_slice(&editor_pane.document, editor_pane.cursor_offset - look_back_bytes, look_back_bytes)
	if len(look_back_slice) == 0 { return 1 }

	last_byte_index := len(look_back_slice) - 1
	for last_byte_index > 0 && (look_back_slice[last_byte_index] & 0xC0) == 0x80 {
		last_byte_index -= 1
	}
	return u32(len(look_back_slice) - last_byte_index)
}

@(private)
next_char_len :: proc(editor: ^Editor) -> u32 {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return 0 }
	document_length := document.document_length(&editor_pane.document)
	if editor_pane.cursor_offset >= document_length { return 0 }
	look_ahead_bytes := min(document_length - editor_pane.cursor_offset, 4)
	look_ahead_slice := document.document_get_slice(&editor_pane.document, editor_pane.cursor_offset, look_ahead_bytes)
	if len(look_ahead_slice) == 0 { return 1 }

	first_byte := look_ahead_slice[0]
	if first_byte < 0x80      { return 1 }
	else if first_byte < 0xE0 { return 2 }
	else if first_byte < 0xF0 { return 3 }
	else                       { return 4 }
}
