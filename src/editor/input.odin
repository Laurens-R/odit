package editor

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"
import "../terminal"
import "../ui"

editor_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	// Stamp the "last keystroke" clock on any key activity so the
	// symbol-reanalyze gate in editor_update can debounce around active
	// typing. We do this before any modal-dialog dispatch so that pressing
	// keys inside the browse / help / symbols dialogs also resets the timer.
	#partial switch event.type {
	case .KEY_DOWN, .KEY_UP, .TEXT_INPUT:
		editor.last_keystroke_time = editor.clock
	}

	// Any user input is reason enough to repaint next frame. Cheap and
	// covers all the keyboard / mouse / wheel paths in one place.
	editor_mark_dirty(editor)

	// Modal dialogs intercept input.
	if editor.show_help {
		#partial switch event.type {
		case .KEY_DOWN:
			pressed_key := event.key.key
			switch pressed_key {
			case sdl3.K_F1, sdl3.K_ESCAPE:
				help_close(editor)
			case sdl3.K_UP:
				help_scroll_by(editor, -editor.line_height)
			case sdl3.K_DOWN:
				help_scroll_by(editor, editor.line_height)
			case sdl3.K_PAGEUP:
				page_step := max(i32(1), editor.line_height * 8)
				help_scroll_by(editor, -page_step)
			case sdl3.K_PAGEDOWN:
				page_step := max(i32(1), editor.line_height * 8)
				help_scroll_by(editor, page_step)
			case sdl3.K_HOME:
				help_scroll_to_top(editor)
			case sdl3.K_END:
				help_scroll_to_bottom(editor)
			}
		case .MOUSE_WHEEL:
			help_scroll_by(editor, -i32(event.wheel.y * f32(editor.line_height) * 3))
		}
		return
	}
	if editor.show_browse {
		browse_handle_event(editor, event)
		return
	}
	if editor.show_symbols {
		symbols_dialog_handle_event(editor, event)
		return
	}
	if editor.show_terminal_close_confirm {
		terminal_close_confirm_handle_event(editor, event)
		return
	}
	if editor.show_find_in_files {
		find_in_files_handle_event(editor, event)
		return
	}
	if editor.show_replace_in_files {
		replace_in_files_handle_event(editor, event)
		return
	}
	if editor.show_save_as {
		save_as_dialog_handle_event(editor, event)
		return
	}
	if editor.show_close_confirm {
		close_confirm_dialog_handle_event(editor, event)
		return
	}
	if editor.show_git_history {
		git_history_dialog_handle_event(editor, event)
		return
	}

	// Find mode intercepts text + key events but lets mouse wheel and mouse
	// buttons fall through (so the user can still scroll, and a click outside
	// the bar exits find while also placing the cursor — handled in mouse.odin).
	if find_active(editor) {
		if find_handle_event(editor, event) { return }
	}
	// Same contract for replace — it owns text/keys, scroll falls through.
	if replace_active(editor) {
		if replace_handle_event(editor, event) { return }
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		if editor.diff_state.active { return }
		// Route TEXT_INPUT to the active pane's content type.
		#partial switch &content_value in editor_active_pane(editor).content {
		case EditorPane:
			input_text := string(event.text.text)
			if len(input_text) > 0 {
				editor_insert_text(editor, input_text)
			}
		case TerminalPane:
			if content_value.terminal != nil {
				terminal.terminal_handle_event(content_value.terminal, event)
			}
		}

	case .KEY_DOWN:
		// Global hotkeys checked before pane dispatch.
		pressed_key := event.key.key
		key_modifiers := event.key.mod
		ctrl_held := .LCTRL in key_modifiers || .RCTRL in key_modifiers

		if pressed_key == sdl3.K_F1 {
			help_toggle(editor)
			return
		}
		if pressed_key == sdl3.K_F2 {
			browse_open(editor)
			return
		}
		if pressed_key == sdl3.K_F3 {
			git_history_dialog_open(editor)
			return
		}
		if pressed_key == sdl3.K_F5 {
			markdown_preview_open(editor)
			return
		}
		if pressed_key == sdl3.K_F6 {
			symbols_dialog_open(editor)
			return
		}
		if pressed_key == sdl3.K_F8 {
			diff_toggle(editor)
			return
		}
		if pressed_key == sdl3.K_F9 {
			editor_toggle_terminal(editor)
			return
		}
		if ctrl_held && pressed_key == sdl3.K_TAB {
			find_close(editor)
			replace_close(editor, false)
			editor_focus_other_pane(editor)
			return
		}
		if ctrl_held && pressed_key == sdl3.K_W {
			editor_toggle_wrap(editor)
			return
		}
		if ctrl_held && pressed_key == sdl3.K_S {
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			if shift_held {
				editor_save_as_active_file(editor)
			} else {
				editor_save_active_file(editor)
			}
			return
		}
		if ctrl_held && pressed_key == sdl3.K_F4 {
			editor_close_active_file(editor)
			return
		}
		if ctrl_held && pressed_key == sdl3.K_F {
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			if shift_held {
				// Ctrl+Shift+F opens the find-in-files dialog.
				find_in_files_open(editor)
				return
			}
			// Toggle: a second Ctrl+F closes the bar. Otherwise open on the
			// active pane (no-op when the active pane isn't an editor).
			if find_active(editor) {
				find_close(editor)
			} else {
				find_open(editor)
			}
			return
		}
		if ctrl_held && pressed_key == sdl3.K_R {
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			if shift_held {
				// Ctrl+Shift+R opens the replace-in-files dialog (mirrors the
				// Ctrl+Shift+F find-in-files dialog).
				replace_in_files_open(editor)
				return
			}
			// Toggle replace bar. Cancels any in-progress preview if already open.
			if replace_active(editor) {
				replace_close(editor, false)
			} else {
				replace_open(editor)
			}
			return
		}

		// Route remaining keys to the active pane.
		#partial switch &content_value in editor_active_pane(editor).content {
		case EditorPane:
			editor_handle_key(editor, event)
		case TerminalPane:
			if content_value.terminal != nil {
				terminal.terminal_handle_event(content_value.terminal, event)
			}
		case MarkdownPreviewPane:
			markdown_preview_handle_key(editor, &content_value, event)
		}

	case .MOUSE_WHEEL:
		key_modifiers := sdl3.GetModState()
		ctrl_held  := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
		if ctrl_held {
			editor_zoom(editor, event.wheel.y)
		} else {
			pane_hit_index := editor_pane_at(editor, event.wheel.mouse_x, event.wheel.mouse_y)
			if pane_hit_index >= 0 { editor.active_pane_index = pane_hit_index }
			// Each pane content type can scroll its own way. For editor panes,
			// `shift` flips the wheel to horizontal scroll when wrap is off.
			#partial switch &content_value in editor_active_pane(editor).content {
			case EditorPane:
				if shift_held && !content_value.wrap_mode {
					editor_scroll_horizontal(editor, -i32(event.wheel.y * 3))
				} else {
					editor_scroll(editor, -i32(event.wheel.y * 3))
				}
			case MarkdownPreviewPane:
				markdown_preview_pane_scroll(editor, &content_value, -i32(event.wheel.y * 3))
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			key_modifiers := sdl3.GetModState()
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			editor_mouse_down(editor, event.button.x, event.button.y, shift_held)
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT {
			editor_mouse_up(editor, event.button.x, event.button.y)
		}

	case .MOUSE_MOTION:
		editor_update_cursor(editor, event.motion.x, event.motion.y)
		editor_scrollbar_update_hover(editor, event.motion.x, event.motion.y)
		editor_mouse_drag(editor, event.motion.x, event.motion.y)
	}
}

@(private="file")
editor_handle_key :: proc(editor: ^Editor, event: ^sdl3.Event) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	pressed_key := event.key.key
	key_modifiers := event.key.mod

	ctrl_held  := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
	shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

	// Reset cursor blink on any keypress
	editor.cursor_visible = true
	editor.cursor_timer = 0

	// Diff mode is read-only — block edits/undo/redo/paste.
	is_diff_mode := editor.diff_state.active

	if ctrl_held {
		switch pressed_key {
		case sdl3.K_Z:
			if is_diff_mode { return }
			if shift_held {
				if new_offset, redo_succeeded := document.document_redo(&editor_pane.document); redo_succeeded {
					editor_pane.cursor_offset = new_offset
				}
			} else {
				if new_offset, undo_succeeded := document.document_undo(&editor_pane.document); undo_succeeded {
					editor_pane.cursor_offset = new_offset
				}
			}
			editor_pane.selection_active = false
			sync_cursor_from_offset(editor)
			return
		case sdl3.K_Y:
			if is_diff_mode { return }
			if new_offset, redo_succeeded := document.document_redo(&editor_pane.document); redo_succeeded {
				editor_pane.cursor_offset = new_offset
			}
			editor_pane.selection_active = false
			sync_cursor_from_offset(editor)
			return
		case sdl3.K_A:
			// Select all (future)
			return
		case sdl3.K_C:
			clipboard_copy(editor)
			return
		case sdl3.K_V:
			if is_diff_mode { return }
			clipboard_paste(editor)
			return
		}
	}

	switch pressed_key {
	case sdl3.K_RETURN:
		if is_diff_mode { return }
		editor_insert_newline_with_indent(editor)

	case sdl3.K_TAB:
		if is_diff_mode { return }
		if shift_held {
			editor_outdent_line(editor)
		} else {
			editor_insert_text(editor, "    ")
		}

	case sdl3.K_BACKSPACE:
		if is_diff_mode { return }
		if delete_selection(editor) { return }
		if editor_pane.cursor_offset > 0 {
			deletion_length := prev_char_len(editor)
			document.document_delete(&editor_pane.document, editor_pane.cursor_offset - deletion_length, deletion_length)
			editor_pane.cursor_offset -= deletion_length
			pane_mark_document_modified(editor_pane)
			sync_cursor_from_offset(editor)
		}

	case sdl3.K_DELETE:
		if is_diff_mode { return }
		if delete_selection(editor) { return }
		document_length := document.document_length(&editor_pane.document)
		if editor_pane.cursor_offset < document_length {
			deletion_length := next_char_len(editor)
			document.document_delete(&editor_pane.document, editor_pane.cursor_offset, deletion_length)
			pane_mark_document_modified(editor_pane)
			sync_cursor_from_offset(editor)
		}

	case sdl3.K_LEFT:
		if !shift_held && collapse_selection(editor, false) { return }
		update_selection_for_nav(editor, shift_held)
		if editor_pane.cursor_offset > 0 {
			editor_pane.cursor_offset -= prev_char_len(editor)
			sync_cursor_from_offset(editor)
		}

	case sdl3.K_RIGHT:
		if !shift_held && collapse_selection(editor, true) { return }
		update_selection_for_nav(editor, shift_held)
		document_length := document.document_length(&editor_pane.document)
		if editor_pane.cursor_offset < document_length {
			editor_pane.cursor_offset += next_char_len(editor)
			sync_cursor_from_offset(editor)
		}

	case sdl3.K_UP:
		update_selection_for_nav(editor, shift_held)
		if editor_pane.cursor_line > 0 {
			move_cursor_vertical(editor, -1)
		}

	case sdl3.K_DOWN:
		update_selection_for_nav(editor, shift_held)
		total_line_count := document.document_line_count(&editor_pane.document)
		if editor_pane.cursor_line < total_line_count - 1 {
			move_cursor_vertical(editor, 1)
		}

	case sdl3.K_HOME:
		update_selection_for_nav(editor, shift_held)
		if ctrl_held {
			editor_pane.cursor_offset = 0
		} else {
			editor_pane.cursor_offset = document.document_line_start(&editor_pane.document, editor_pane.cursor_line)
		}
		sync_cursor_from_offset(editor)

	case sdl3.K_END:
		update_selection_for_nav(editor, shift_held)
		if ctrl_held {
			editor_pane.cursor_offset = document.document_length(&editor_pane.document)
		} else {
			line_start_offset := document.document_line_start(&editor_pane.document, editor_pane.cursor_line)
			line_text := document.document_get_line(&editor_pane.document, editor_pane.cursor_line, context.temp_allocator)
			editor_pane.cursor_offset = line_start_offset + u32(len(line_text))
		}
		sync_cursor_from_offset(editor)

	case sdl3.K_PAGEUP:
		update_selection_for_nav(editor, shift_held)
		lines_to_move := editor_pane.visible_lines > 1 ? editor_pane.visible_lines - 1 : 1
		if editor_pane.cursor_line >= lines_to_move {
			move_cursor_vertical(editor, -i32(lines_to_move))
		} else {
			move_cursor_vertical(editor, -i32(editor_pane.cursor_line))
		}

	case sdl3.K_PAGEDOWN:
		update_selection_for_nav(editor, shift_held)
		total_line_count := document.document_line_count(&editor_pane.document)
		lines_to_move := editor_pane.visible_lines > 1 ? editor_pane.visible_lines - 1 : 1
		remaining_lines := total_line_count - 1 - editor_pane.cursor_line
		if remaining_lines >= lines_to_move {
			move_cursor_vertical(editor, i32(lines_to_move))
		} else {
			move_cursor_vertical(editor, i32(remaining_lines))
		}
	}
}

@(private="file")
editor_zoom :: proc(editor: ^Editor, wheel_direction: f32) {
	FONT_SIZE_MIN :: 8.0
	FONT_SIZE_MAX :: 72.0
	zoom_step: f32 = 2.0

	new_font_size := editor.font_size + (wheel_direction > 0 ? zoom_step : -zoom_step)
	new_font_size = clamp(new_font_size, FONT_SIZE_MIN, FONT_SIZE_MAX)
	if new_font_size == editor.font_size { return }

	editor.font_size = new_font_size
	_ = ttf.SetFontSize(editor.font, new_font_size)

	editor.line_height = i32(ttf.GetFontLineSkip(editor.font))
	measured_width: i32
	ttf.GetStringSize(editor.font, "M", 1, &measured_width, nil)
	editor.character_width = measured_width

	// Invalidate the text cache so previously-shaped runs don't render at
	// the old size on the next frame.
	ui.text_cache_clear(&editor.text_cache)
}
