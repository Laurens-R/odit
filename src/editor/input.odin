package editor

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../dap"
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

	// Stamp the last-known mouse position *before* any modal short-circuits
	// — otherwise hover-aware UI primitives (buttons, scrollbars) inside
	// modal dialogs would never see fresh coordinates and would stay frozen
	// at whatever the cursor was when the modal opened.
	#partial switch event.type {
	case .MOUSE_MOTION:
		editor.last_mouse_x = event.motion.x
		editor.last_mouse_y = event.motion.y
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		editor.last_mouse_x = event.button.x
		editor.last_mouse_y = event.button.y
	}

	// Any user input is reason enough to repaint next frame. Cheap and
	// covers all the keyboard / mouse / wheel paths in one place.
	editor_mark_dirty(editor)

	// Menu bar gets first crack at events. When a dropdown is open it
	// behaves as a modal and consumes everything; when nothing is open it
	// only consumes clicks on the menu-bar strip itself and lets the rest
	// pass through to the panes / modals below.
	if menu_bar_handle_event(editor, event) { return }

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
		case .MOUSE_MOTION:
			help_handle_mouse_motion(editor, event.motion.x, event.motion.y)
		case .MOUSE_BUTTON_DOWN:
			if event.button.button == sdl3.BUTTON_LEFT {
				help_handle_mouse_down(editor, event.button.x, event.button.y)
			}
		case .MOUSE_BUTTON_UP:
			if event.button.button == sdl3.BUTTON_LEFT {
				help_handle_mouse_up(editor)
			}
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
	if editor.show_open_docs {
		open_docs_dialog_handle_event(editor, event)
		return
	}
	if editor.show_terminal_picker {
		terminal_picker_handle_event(editor, event)
		return
	}
	if editor.show_tasks_dialog {
		tasks_dialog_handle_event(editor, event)
		return
	}
	if editor.show_breakpoint_condition {
		breakpoint_condition_dialog_handle_event(editor, event)
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
		// SDL fires TEXT_INPUT for some Ctrl combos (e.g. Ctrl+Space inserts
		// a literal " "). Those need to stay out of the document — KEY_DOWN
		// has already routed the combo as a hotkey.
		{
			modifiers_now := sdl3.GetModState()
			if .LCTRL in modifiers_now || .RCTRL in modifiers_now { return }
		}
		// Route TEXT_INPUT to the active pane's content type.
		#partial switch &content_value in editor_active_pane(editor).content {
		case EditorPane:
			input_text := string(event.text.text)
			if len(input_text) > 0 {
				// Typing in the document dismisses the hover popup — it
				// only makes sense as long as the cursor sits on the
				// symbol it was anchored to.
				if editor.hover_popup.is_visible { hover_popup_close(editor) }
				// Mirror keystrokes into the completion popup filter when it's open.
				_ = completion_popup_consume_text(editor, input_text)
				editor_insert_text(editor, input_text)
				// Fire completion automatically on LSP trigger characters
				// (`.`, `"` inside `import`). Has to run AFTER the insert
				// so the LSP sees the just-typed character in its content.
				editor_lsp_maybe_trigger_completion(editor, input_text)
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
		if pressed_key == sdl3.K_F4 && !ctrl_held {
			open_docs_dialog_open(editor)
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
		if pressed_key == sdl3.K_F7 {
			// Shift+F7 toggles the debug panel; plain F7 opens the Tasks
			// dialog over the project's build / debug profiles.
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			if shift_held {
				debug_panel_toggle(editor)
			} else {
				tasks_dialog_open(editor)
			}
			return
		}
		if pressed_key == sdl3.K_F8 {
			diff_toggle(editor)
			return
		}
		if pressed_key == sdl3.K_F10 {
			// Step over the next source line. No-op when no active session,
			// so it's safe to mash even when no debugger is attached.
			dap.client_step_over(editor.active_dap_client)
			return
		}
		if pressed_key == sdl3.K_F11 {
			dap.client_step_in(editor.active_dap_client)
			return
		}
		if pressed_key == sdl3.K_F9 {
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			switch {
			case ctrl_held && shift_held:
				// Ctrl+Shift+F9 — picker over all open terminal sessions.
				terminal_picker_open(editor)
			case ctrl_held:
				// Ctrl+F9 — always spawn a new session and activate it.
				editor_terminal_create_new(editor)
			case:
				// Plain F9 — show/hide toggle (creates first session if none).
				editor_toggle_terminal(editor)
			}
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
		if ctrl_held && pressed_key == sdl3.K_K {
			hover_popup_request_at_cursor(editor)
			return
		}
		if ctrl_held && pressed_key == sdl3.K_SPACE {
			completion_popup_trigger_at_cursor(editor)
			return
		}
		if pressed_key == sdl3.K_ESCAPE && editor.hover_popup.is_visible {
			hover_popup_close(editor)
			return
		}
		if pressed_key == sdl3.K_ESCAPE && editor.signature_popup.is_visible {
			signature_popup_close(editor)
			return
		}

		// Completion popup intercepts navigation + Enter/Tab while open. It
		// passes text-input events through so the user can keep typing —
		// the filter is updated via the consume_text hook below.
		if editor.completion_popup.is_visible {
			if completion_popup_handle_key(editor, event) { return }
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
			// Ctrl+F4 closes whatever is in the active pane. Terminal panes
			// kill the active session; the output pane is intentionally
			// off-limits here — it's grouped with the right-side debug
			// panel and the only way to dismiss the pair is Shift+F7, so
			// the two halves can't drift out of sync. Everything else
			// falls back to the regular close-active-file flow.
			if _, is_terminal_pane := editor.panes[editor.active_pane_index].content.(TerminalPane); is_terminal_pane {
				editor_terminal_destroy_active(editor)
			} else if _, is_output_pane := editor.panes[editor.active_pane_index].content.(OutputPane); is_output_pane {
				// no-op: use Shift+F7 to toggle the debug UI as a unit.
			} else {
				editor_close_active_file(editor)
			}
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
				shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
				// Ctrl+Shift+C / Ctrl+Shift+V are the terminal's copy/paste —
				// plain Ctrl+C goes through to the shell as SIGINT, so we
				// can't shadow it. Page Up/Down with no modifiers scroll
				// scrollback rather than sending PgUp/PgDn to the shell.
				if ctrl_held && shift_held && pressed_key == sdl3.K_C {
					terminal.terminal_copy_selection_to_clipboard(content_value.terminal)
					return
				}
				if ctrl_held && shift_held && pressed_key == sdl3.K_V {
					terminal.terminal_paste_from_clipboard(content_value.terminal)
					return
				}
				if !ctrl_held && !shift_held && pressed_key == sdl3.K_PAGEUP {
					if terminal.terminal_scroll(content_value.terminal, i32(content_value.terminal.screen.rows - 1)) {
						editor_mark_dirty(editor)
					}
					return
				}
				if !ctrl_held && !shift_held && pressed_key == sdl3.K_PAGEDOWN {
					if terminal.terminal_scroll(content_value.terminal, -i32(content_value.terminal.screen.rows - 1)) {
						editor_mark_dirty(editor)
					}
					return
				}
				terminal.terminal_handle_event(content_value.terminal, event)
			}
		case MarkdownPreviewPane:
			markdown_preview_handle_key(editor, &content_value, event)
		case OutputPane:
			output_pane_handle_key(editor, &content_value, event)
		}

	case .MOUSE_WHEEL:
		key_modifiers := sdl3.GetModState()
		ctrl_held  := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
		if ctrl_held {
			editor_zoom(editor, event.wheel.y)
		} else {
			// Debug panel claims the wheel when the cursor is over it so its
			// scrollable sub-sections work like every other scroll viewport.
			if debug_panel_handle_wheel(editor, event.wheel.mouse_x, event.wheel.mouse_y, event.wheel.y) { return }
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
			case TerminalPane:
				if content_value.terminal != nil {
					// Positive wheel.y = wheel rolled up (intuitive scroll up
					// in scrollback). Step of 3 rows matches editor panes.
					if terminal.terminal_scroll(content_value.terminal, i32(event.wheel.y * 3)) {
						editor_mark_dirty(editor)
					}
				}
			case MarkdownPreviewPane:
				markdown_preview_pane_scroll(editor, &content_value, -i32(event.wheel.y * 3))
			case OutputPane:
				output_pane_scroll(editor, &content_value, -i32(event.wheel.y * 3))
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			key_modifiers := sdl3.GetModState()
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			editor_mouse_down(editor, event.button.x, event.button.y, shift_held, i32(event.button.clicks))
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
			if shift_held { editor_redo_active(editor) } else { editor_undo_active(editor) }
			return
		case sdl3.K_Y:
			if is_diff_mode { return }
			editor_redo_active(editor)
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
		_ = completion_popup_consume_backspace(editor)
		if delete_selection(editor) { return }
		if editor_pane.cursor_offset > 0 {
			deletion_length := prev_char_len(editor)
			document.document_delete(&editor_pane.document, editor_pane.cursor_offset - deletion_length, deletion_length)
			editor_pane.cursor_offset -= deletion_length
			pane_mark_document_modified(editor, editor_pane)
			sync_cursor_from_offset(editor)
		}

	case sdl3.K_DELETE:
		if is_diff_mode { return }
		if delete_selection(editor) { return }
		document_length := document.document_length(&editor_pane.document)
		if editor_pane.cursor_offset < document_length {
			deletion_length := next_char_len(editor)
			document.document_delete(&editor_pane.document, editor_pane.cursor_offset, deletion_length)
			pane_mark_document_modified(editor, editor_pane)
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

// Undo a single edit on the active editor pane. Diff mode is read-only so
// the call is silently dropped there. Shared by the Ctrl+Z hotkey and the
// Edit menu — they need identical behavior, including the cursor sync.
@(private)
editor_undo_active :: proc(editor: ^Editor) {
	if editor.diff_state.active { return }
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if new_offset, ok := document.document_undo(&editor_pane.document); ok {
		editor_pane.cursor_offset = new_offset
	}
	editor_pane.selection_active = false
	sync_cursor_from_offset(editor)
}

// Symmetric counterpart for Ctrl+Shift+Z / Ctrl+Y / Edit > Redo.
@(private)
editor_redo_active :: proc(editor: ^Editor) {
	if editor.diff_state.active { return }
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if new_offset, ok := document.document_redo(&editor_pane.document); ok {
		editor_pane.cursor_offset = new_offset
	}
	editor_pane.selection_active = false
	sync_cursor_from_offset(editor)
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

	// Markdown preview / hover popup / signature popup all share the same
	// font set. Order matters: drop the layout caches FIRST (they hold
	// `^ttf.Text*` bound to the about-to-be-closed font handles), THEN
	// reload the markdown fonts at the new scale. The next render
	// re-lays-out at the new metrics.
	editor_invalidate_markdown_caches(editor)
	markdown_fonts_apply_zoom(&editor.markdown_fonts, editor.font_size)
}
