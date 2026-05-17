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
			switch key {
			case sdl3.K_F1, sdl3.K_ESCAPE:
				help_close(ed)
			case sdl3.K_UP:
				help_scroll_by(ed, -ed.line_height)
			case sdl3.K_DOWN:
				help_scroll_by(ed, ed.line_height)
			case sdl3.K_PAGEUP:
				step := max(i32(1), ed.line_height * 8)
				help_scroll_by(ed, -step)
			case sdl3.K_PAGEDOWN:
				step := max(i32(1), ed.line_height * 8)
				help_scroll_by(ed, step)
			case sdl3.K_HOME:
				help_scroll_to_top(ed)
			case sdl3.K_END:
				help_scroll_to_bottom(ed)
			}
		case .MOUSE_WHEEL:
			help_scroll_by(ed, -i32(event.wheel.y * f32(ed.line_height) * 3))
		}
		return
	}
	if ed.show_browse {
		browse_handle_event(ed, event)
		return
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		if ed.diff_state.active { return }
		// Route TEXT_INPUT to the active pane's content type.
		#partial switch &c in editor_active_pane(ed).content {
		case EditorPane:
			input_text := string(event.text.text)
			if len(input_text) > 0 {
				editor_insert_text(ed, input_text)
			}
		}

	case .KEY_DOWN:
		// Global hotkeys checked before pane dispatch.
		key := event.key.key
		mod := event.key.mod
		ctrl := .LCTRL in mod || .RCTRL in mod

		if key == sdl3.K_F1 {
			help_toggle(ed)
			return
		}
		if key == sdl3.K_F2 {
			browse_open(ed)
			return
		}
		if key == sdl3.K_F8 {
			diff_toggle(ed)
			return
		}
		if ctrl && key == sdl3.K_TAB {
			editor_focus_other_pane(ed)
			return
		}

		// Route remaining keys to the active pane.
		#partial switch &c in editor_active_pane(ed).content {
		case EditorPane:
			editor_handle_key(ed, event)
		}

	case .MOUSE_WHEEL:
		mod := sdl3.GetModState()
		ctrl := .LCTRL in mod || .RCTRL in mod
		if ctrl {
			editor_zoom(ed, event.wheel.y)
		} else {
			hit := editor_pane_at(ed, event.wheel.mouse_x, event.wheel.mouse_y)
			if hit >= 0 { ed.active = hit }
			// Each pane content type can scroll its own way. For editor panes,
			// editor_scroll handles it.
			#partial switch &c in editor_active_pane(ed).content {
			case EditorPane:
				editor_scroll(ed, -i32(event.wheel.y * 3))
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			mod := sdl3.GetModState()
			shift := .LSHIFT in mod || .RSHIFT in mod
			editor_mouse_down(ed, event.button.x, event.button.y, shift)
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT {
			editor_mouse_up(ed)
		}

	case .MOUSE_MOTION:
		editor_mouse_drag(ed, event.motion.x, event.motion.y)
	}
}

@(private="file")
editor_handle_key :: proc(ed: ^Editor, event: ^sdl3.Event) {
	v := editor_active_editor_pane(ed); if v == nil { return }

	key := event.key.key
	mod := event.key.mod

	ctrl  := .LCTRL  in mod || .RCTRL  in mod
	shift := .LSHIFT in mod || .RSHIFT in mod

	// Reset cursor blink on any keypress
	ed.cursor_visible = true
	ed.cursor_timer = 0

	// Diff mode is read-only — block edits/undo/redo/paste.
	in_diff := ed.diff_state.active

	if ctrl {
		switch key {
		case sdl3.K_Z:
			if in_diff { return }
			if shift {
				if new_offset, ok := document.document_redo(&v.doc); ok {
					v.cursor_offset = new_offset
				}
			} else {
				if new_offset, ok := document.document_undo(&v.doc); ok {
					v.cursor_offset = new_offset
				}
			}
			v.sel_active = false
			sync_cursor_from_offset(ed)
			return
		case sdl3.K_Y:
			if in_diff { return }
			if new_offset, ok := document.document_redo(&v.doc); ok {
				v.cursor_offset = new_offset
			}
			v.sel_active = false
			sync_cursor_from_offset(ed)
			return
		case sdl3.K_A:
			// Select all (future)
			return
		case sdl3.K_C:
			clipboard_copy(ed)
			return
		case sdl3.K_V:
			if in_diff { return }
			clipboard_paste(ed)
			return
		}
	}

	switch key {
	case sdl3.K_RETURN:
		if in_diff { return }
		editor_insert_newline_with_indent(ed)

	case sdl3.K_TAB:
		if in_diff { return }
		if shift {
			editor_outdent_line(ed)
		} else {
			editor_insert_text(ed, "    ")
		}

	case sdl3.K_BACKSPACE:
		if in_diff { return }
		if delete_selection(ed) { return }
		if v.cursor_offset > 0 {
			del_len := prev_char_len(ed)
			document.document_delete(&v.doc, v.cursor_offset - del_len, del_len)
			v.cursor_offset -= del_len
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_DELETE:
		if in_diff { return }
		if delete_selection(ed) { return }
		doc_len := document.document_length(&v.doc)
		if v.cursor_offset < doc_len {
			del_len := next_char_len(ed)
			document.document_delete(&v.doc, v.cursor_offset, del_len)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_LEFT:
		if !shift && collapse_selection(ed, false) { return }
		update_selection_for_nav(ed, shift)
		if v.cursor_offset > 0 {
			v.cursor_offset -= prev_char_len(ed)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_RIGHT:
		if !shift && collapse_selection(ed, true) { return }
		update_selection_for_nav(ed, shift)
		doc_len := document.document_length(&v.doc)
		if v.cursor_offset < doc_len {
			v.cursor_offset += next_char_len(ed)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_UP:
		update_selection_for_nav(ed, shift)
		if v.cursor_line > 0 {
			move_cursor_vertical(ed, -1)
		}

	case sdl3.K_DOWN:
		update_selection_for_nav(ed, shift)
		line_count := document.document_line_count(&v.doc)
		if v.cursor_line < line_count - 1 {
			move_cursor_vertical(ed, 1)
		}

	case sdl3.K_HOME:
		update_selection_for_nav(ed, shift)
		if ctrl {
			v.cursor_offset = 0
		} else {
			v.cursor_offset = document.document_line_start(&v.doc, v.cursor_line)
		}
		sync_cursor_from_offset(ed)

	case sdl3.K_END:
		update_selection_for_nav(ed, shift)
		if ctrl {
			v.cursor_offset = document.document_length(&v.doc)
		} else {
			line_start := document.document_line_start(&v.doc, v.cursor_line)
			line_text := document.document_get_line(&v.doc, v.cursor_line)
			v.cursor_offset = line_start + u32(len(line_text))
		}
		sync_cursor_from_offset(ed)

	case sdl3.K_PAGEUP:
		update_selection_for_nav(ed, shift)
		lines_to_move := v.visible_lines > 1 ? v.visible_lines - 1 : 1
		if v.cursor_line >= lines_to_move {
			move_cursor_vertical(ed, -i32(lines_to_move))
		} else {
			move_cursor_vertical(ed, -i32(v.cursor_line))
		}

	case sdl3.K_PAGEDOWN:
		update_selection_for_nav(ed, shift)
		line_count := document.document_line_count(&v.doc)
		lines_to_move := v.visible_lines > 1 ? v.visible_lines - 1 : 1
		remaining := line_count - 1 - v.cursor_line
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

	ed.line_height = i32(ttf.GetFontLineSkip(ed.font))
	w: i32
	ttf.GetStringSize(ed.font, "M", 1, &w, nil)
	ed.char_width = w
}
