package editor

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"

editor_handle_event :: proc(ed: ^Editor, event: ^sdl3.Event) {
	// Modal dialogs intercept input.
	if ed.show_help {
		#partial switch event.type {
		case .KEY_DOWN:
			key := event.key.key
			if key == sdl3.K_F1 || key == sdl3.K_ESCAPE {
				help_close(ed)
			}
		}
		return
	}
	if ed.show_browse {
		browse_handle_event(ed, event)
		return
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			editor_insert_text(ed, input_text)
		}

	case .KEY_DOWN:
		if event.key.key == sdl3.K_F1 {
			help_toggle(ed)
			return
		}
		if event.key.key == sdl3.K_F2 {
			browse_open(ed)
			return
		}
		editor_handle_key(ed, event)

	case .MOUSE_WHEEL:
		mod := sdl3.GetModState()
		ctrl := .LCTRL in mod || .RCTRL in mod
		if ctrl {
			editor_zoom(ed, event.wheel.y)
		} else {
			editor_scroll(ed, -i32(event.wheel.y * 3))
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			mod := sdl3.GetModState()
			shift := .LSHIFT in mod || .RSHIFT in mod
			editor_mouse_down(ed, event.button.x, event.button.y, shift)
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT {
			ed.mouse_dragging = false
		}

	case .MOUSE_MOTION:
		if ed.mouse_dragging {
			editor_mouse_drag(ed, event.motion.x, event.motion.y)
		}
	}
}

@(private="file")
editor_handle_key :: proc(ed: ^Editor, event: ^sdl3.Event) {
	key := event.key.key
	mod := event.key.mod

	ctrl  := .LCTRL  in mod || .RCTRL  in mod
	shift := .LSHIFT in mod || .RSHIFT in mod

	// Reset cursor blink on any keypress
	ed.cursor_visible = true
	ed.cursor_timer = 0

	if ctrl {
		switch key {
		case sdl3.K_Z:
			if shift {
				if new_offset, ok := document.document_redo(&ed.doc); ok {
					ed.cursor_offset = new_offset
				}
			} else {
				if new_offset, ok := document.document_undo(&ed.doc); ok {
					ed.cursor_offset = new_offset
				}
			}
			ed.sel_active = false
			sync_cursor_from_offset(ed)
			return
		case sdl3.K_Y:
			if new_offset, ok := document.document_redo(&ed.doc); ok {
				ed.cursor_offset = new_offset
			}
			ed.sel_active = false
			sync_cursor_from_offset(ed)
			return
		case sdl3.K_A:
			// Select all (future)
			return
		case sdl3.K_C:
			clipboard_copy(ed)
			return
		case sdl3.K_V:
			clipboard_paste(ed)
			return
		}
	}

	switch key {
	case sdl3.K_RETURN:
		editor_insert_text(ed, "\n")

	case sdl3.K_TAB:
		editor_insert_text(ed, "    ") // 4 spaces, terminal style

	case sdl3.K_BACKSPACE:
		if delete_selection(ed) { return }
		if ed.cursor_offset > 0 {
			// Delete one character (handle UTF-8 backwards)
			del_len := prev_char_len(ed)
			document.document_delete(&ed.doc, ed.cursor_offset - del_len, del_len)
			ed.cursor_offset -= del_len
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_DELETE:
		if delete_selection(ed) { return }
		doc_len := document.document_length(&ed.doc)
		if ed.cursor_offset < doc_len {
			del_len := next_char_len(ed)
			document.document_delete(&ed.doc, ed.cursor_offset, del_len)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_LEFT:
		if !shift && collapse_selection(ed, false) { return }
		update_selection_for_nav(ed, shift)
		if ed.cursor_offset > 0 {
			ed.cursor_offset -= prev_char_len(ed)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_RIGHT:
		if !shift && collapse_selection(ed, true) { return }
		update_selection_for_nav(ed, shift)
		doc_len := document.document_length(&ed.doc)
		if ed.cursor_offset < doc_len {
			ed.cursor_offset += next_char_len(ed)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_UP:
		update_selection_for_nav(ed, shift)
		if ed.cursor_line > 0 {
			move_cursor_vertical(ed, -1)
		}

	case sdl3.K_DOWN:
		update_selection_for_nav(ed, shift)
		line_count := document.document_line_count(&ed.doc)
		if ed.cursor_line < line_count - 1 {
			move_cursor_vertical(ed, 1)
		}

	case sdl3.K_HOME:
		update_selection_for_nav(ed, shift)
		if ctrl {
			ed.cursor_offset = 0
		} else {
			ed.cursor_offset = document.document_line_start(&ed.doc, ed.cursor_line)
		}
		sync_cursor_from_offset(ed)

	case sdl3.K_END:
		update_selection_for_nav(ed, shift)
		if ctrl {
			ed.cursor_offset = document.document_length(&ed.doc)
		} else {
			line_start := document.document_line_start(&ed.doc, ed.cursor_line)
			line_text := document.document_get_line(&ed.doc, ed.cursor_line)
			ed.cursor_offset = line_start + u32(len(line_text))
		}
		sync_cursor_from_offset(ed)

	case sdl3.K_PAGEUP:
		update_selection_for_nav(ed, shift)
		lines_to_move := ed.visible_lines > 1 ? ed.visible_lines - 1 : 1
		if ed.cursor_line >= lines_to_move {
			move_cursor_vertical(ed, -i32(lines_to_move))
		} else {
			move_cursor_vertical(ed, -i32(ed.cursor_line))
		}

	case sdl3.K_PAGEDOWN:
		update_selection_for_nav(ed, shift)
		line_count := document.document_line_count(&ed.doc)
		lines_to_move := ed.visible_lines > 1 ? ed.visible_lines - 1 : 1
		remaining := line_count - 1 - ed.cursor_line
		if remaining >= lines_to_move {
			move_cursor_vertical(ed, i32(lines_to_move))
		} else {
			move_cursor_vertical(ed, i32(remaining))
		}
	}
}

@(private="file")
editor_zoom :: proc(ed: ^Editor, direction: f32) {
	FONT_SIZE_MIN :: 8.0
	FONT_SIZE_MAX :: 72.0
	step: f32 = 2.0

	new_size := ed.font_size + (direction > 0 ? step : -step)
	new_size = clamp(new_size, FONT_SIZE_MIN, FONT_SIZE_MAX)
	if new_size == ed.font_size { return }

	ed.font_size = new_size
	_ = ttf.SetFontSize(ed.font, new_size)

	// Recalculate metrics
	ed.line_height = i32(ttf.GetFontLineSkip(ed.font))
	w: i32
	ttf.GetStringSize(ed.font, "M", 1, &w, nil)
	ed.char_width = w
}
