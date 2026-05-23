package editor

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import browse_pkg "./browse"
import "../dap"
import "../document"
import find_in_files_pkg "./find_in_files"
import replace_in_files_pkg "./replace_in_files"
import git_history_pkg "./git_history"
import help_pkg "./help"
import completion_popup_pkg "./completion_popup"
import hover_pkg "./hover"
import signature_popup_pkg "./signature_popup"
import tasks_dialog_pkg "./tasks_dialog"
import "../markdown"
import open_docs_pkg "./open_docs"
import terminal_picker_pkg "./terminal_picker"
import "../keybindings"
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
	// Menu bar is the first binding in `editor.bindings` so it
	// gets first crack at every event via the iteration below.


	// Modal dialogs intercept input.
	//
	// Each modal handler reports back whether it changed anything visible
	// via a `needs_redraw` bool; we funnel that through `editor_mark_dirty`
	// so the modal package stays unaware of the editor's dirty-tracking.
	// Plugin-style bindings are tried first, in registration order.
	// The first one whose `visible` returns true takes the event.
	for &registered_binding in editor.bindings {
		if registered_binding.visible == nil || !registered_binding.visible(registered_binding.state) { continue }
		consumed, needs_redraw := registered_binding.handle_event(registered_binding.state, &editor.editor_api, event)
		if needs_redraw { editor_mark_dirty(editor) }
		if consumed { return }
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
				if editor.hover_popup.visible { hover_pkg.close(&editor.hover_popup) }
				// completion_popup mirrors keystrokes into its filter via
				// its binding's handle_event (called earlier in the dispatch
				// loop) — no explicit call needed here.
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
		// Global hotkeys checked before pane dispatch. Chord→action mapping
		// is driven by the keybindings table loaded at startup from
		// `src/keybindings/defaults/<os>.json` — edit that file to remap
		// shortcuts. Escape-based modal dismissals and the completion-popup
		// passthrough below stay raw-key so the JSON can't accidentally
		// rebind them out of existence.
		pressed_key   := event.key.key
		key_modifiers := event.key.mod

		if pressed_key == sdl3.K_ESCAPE && editor.hover_popup.visible {
			hover_pkg.close(&editor.hover_popup)
			return
		}
		if pressed_key == sdl3.K_ESCAPE && editor.signature_popup.visible {
			signature_popup_pkg.close(&editor.signature_popup)
			return
		}

		// Escape collapses additional cursors back to the primary
		// before anything else gets a crack at it. Has to run before the
		// shortcut dispatch (Escape itself isn't a binding) and before
		// per-pane key handling so the next keystroke acts on the
		// surviving single caret.
		if pressed_key == sdl3.K_ESCAPE {
			if active_pane := editor_active_editor_pane(editor); active_pane != nil && pane_has_multiple_cursors(active_pane) {
				pane_collapse_to_primary(active_pane)
				return
			}
		}

		if editor_dispatch_shortcut(editor, pressed_key, key_modifiers) { return }

		// Route remaining keys to the active pane.
		#partial switch &content_value in editor_active_pane(editor).content {
		case EditorPane:
			editor_handle_key(editor, event)
		case TerminalPane:
			if content_value.terminal != nil {
				// TerminalCopy / TerminalPaste are configurable (defaults to
				// Ctrl+Shift+C / Ctrl+Shift+V) — plain Ctrl+C has to keep
				// going through to the shell as SIGINT, so we can't shadow
				// it. Page Up/Down with no modifiers scroll scrollback rather
				// than sending PgUp/PgDn to the shell; those stay raw-key
				// since they're terminal-specific scroll affordances, not
				// general shortcuts.
				#partial switch keybindings.lookup(&editor.keybindings, pressed_key, key_modifiers, .Global) {
				case .TerminalCopy:
					terminal.terminal_copy_selection_to_clipboard(content_value.terminal)
					return
				case .TerminalPaste:
					terminal.terminal_paste_from_clipboard(content_value.terminal)
					return
				}
				// "Bare" = no Ctrl/Shift/Alt/Gui. Lock keys (Num/Caps/Scroll)
				// don't change whether Page Up should scroll scrollback.
				ctrl_held  := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
				shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
				alt_held   := .LALT   in key_modifiers || .RALT   in key_modifiers
				gui_held   := .LGUI   in key_modifiers || .RGUI   in key_modifiers
				bare_keypress := !ctrl_held && !shift_held && !alt_held && !gui_held
				if bare_keypress && pressed_key == sdl3.K_PAGEUP {
					if terminal.terminal_scroll(content_value.terminal, i32(content_value.terminal.screen.rows - 1)) {
						editor_mark_dirty(editor)
					}
					return
				}
				if bare_keypress && pressed_key == sdl3.K_PAGEDOWN {
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
			// Debug panel wheel is handled by its binding's
			// handle_event (registered earlier in this event loop).

			pane_hit_index := editor_pane_at(editor, event.wheel.mouse_x, event.wheel.mouse_y)
			if pane_hit_index >= 0 { editor.active_pane_index = pane_hit_index }
			// Each pane content type can scroll its own way. For editor panes,
			// `shift` flips the wheel to horizontal scroll when wrap is off.
			#partial switch &content_value in editor_active_pane(editor).content {
			case EditorPane:
				// `wheel.x` is the trackpad's horizontal swipe (and a
				// horizontal-wheel mouse's tilt). Apply it on every wheel
				// event so two-finger panning feels native. Sign is flipped
				// to match the OS convention — swiping right reveals more
				// of the right side.
				if event.wheel.x != 0 && !content_value.wrap_mode {
					editor_scroll_horizontal(editor, i32(event.wheel.x * 3))
				}
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
			ctrl_held  := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
			gui_held   := .LGUI   in key_modifiers || .RGUI   in key_modifiers
			alt_held   := .LALT   in key_modifiers || .RALT   in key_modifiers
			// Cmd on macOS, Ctrl on other platforms: spawn an additional
			// caret at the click point instead of moving the primary.
			when ODIN_OS == .Darwin {
				add_cursor_modifier_held := gui_held
			} else {
				add_cursor_modifier_held := ctrl_held
			}
			editor_mouse_down(editor, event.button.x, event.button.y, shift_held, i32(event.button.clicks), add_cursor_modifier_held, alt_held)
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

// Resolve `(key, modifiers)` against the active keybindings table and run
// the matching action. Returns true when an action fired (caller should
// stop processing the event); false when the chord wasn't bound to anything
// the editor cares about at the global scope. Modal-internal handlers
// (browse, find, …) do their own scoped lookups elsewhere.
//
// Some actions still consult raw modifier state to decide between
// sub-behaviors (e.g. `CloseFile` cleans up a terminal pane instead of
// closing a document) — that pane-aware branching used to live inline in
// the if-chain and stays here so we don't have to invent per-content
// Action variants just to express it.
@(private="file")
editor_dispatch_shortcut :: proc(editor: ^Editor, pressed_key: sdl3.Keycode, key_modifiers: sdl3.Keymod) -> bool {
	action := keybindings.lookup(&editor.keybindings, pressed_key, key_modifiers, .Global)

	#partial switch action {
	case .Help:               if help_pkg.toggle(&editor.help) { editor_mark_dirty(editor) }
	case .FileBrowser:        browse_pkg.open(&editor.browse_view, &editor.editor_api)
	case .GitHistory:         git_history_pkg.open_via_api(&editor.git_history_dialog, &editor.editor_api)
	case .OpenDocs:           if editor_active_editor_pane(editor) != nil { open_docs_pkg.open_with_hooks(&editor.open_docs_dialog, editor.open_docs_hooks, editor.active_pane_index) }
	case .MarkdownPreview:    markdown_preview_open(editor)
	case .Symbols:            symbols_open(editor)
	case .Tasks:              tasks_dialog_pkg.open_via_api(&editor.tasks_dialog, &editor.editor_api)
	case .ToggleDebugPanel:   debug_panel_toggle(editor)
	case .ToggleDiff:         diff_toggle(editor)
	case .StepOver:           dap.client_step_over(editor.active_dap_client)
	case .StepIn:             dap.client_step_in(editor.active_dap_client)
	case .ToggleTerminal:     editor_toggle_terminal(editor)
	case .NewTerminal:        editor_terminal_create_new(editor)
	case .PickTerminal:       terminal_picker_pkg.open_with_hooks(&editor.terminal_picker, editor.terminal_picker_hooks)
	case .SwapPanes:
		find_close(editor)
		replace_close(editor, false)
		editor_focus_other_pane(editor)
	case .FocusLeftPane:
		find_close(editor); replace_close(editor, false); editor_focus_pane(editor, 0)
	case .FocusRightPane:
		find_close(editor); replace_close(editor, false); editor_focus_pane(editor, 1)
	case .MoveToLeftPane:
		find_close(editor); replace_close(editor, false); editor_move_active_to_pane(editor, 0)
	case .MoveToRightPane:
		find_close(editor); replace_close(editor, false); editor_move_active_to_pane(editor, 1)
	case .ToggleWrap:         editor_toggle_wrap(editor)
	case .AddCursorAbove:     editor_add_cursor_above(editor)
	case .AddCursorBelow:     editor_add_cursor_below(editor)
	case .AddCursorAtNextMatch: editor_add_cursor_at_next_match(editor)
	case .Hover:              hover_pkg.request_at_cursor_via_api(&editor.hover_popup, &editor.editor_api)
	case .TriggerCompletion:  completion_popup_pkg.trigger_at_cursor_via_api(&editor.completion_popup, &editor.editor_api)
	case .SaveFile:           editor_save_active_file(editor)
	case .SaveFileAs:         editor_save_as_active_file(editor)
	case .CloseFile:
		// Closes whatever is in the active pane. Terminal panes kill the
		// active session; the output pane is intentionally off-limits — it's
		// grouped with the right-side debug panel and the only way to
		// dismiss the pair is the ToggleDebugPanel shortcut, so the two
		// halves can't drift out of sync.
		if _, is_terminal_pane := editor.panes[editor.active_pane_index].content.(TerminalPane); is_terminal_pane {
			editor_terminal_destroy_active(editor)
		} else if _, is_output_pane := editor.panes[editor.active_pane_index].content.(OutputPane); is_output_pane {
			return true // no-op, but still consume the chord
		} else {
			editor_close_active_file(editor)
		}
	case .FindToggle:
		// Toggle: a second press closes the bar. No-op when the active pane
		// isn't an editor.
		if find_active(editor) { find_close(editor) } else { find_open(editor) }
	case .FindInFiles:        find_in_files_pkg.open_via_api(&editor.find_in_files, &editor.editor_api)
	case .ReplaceToggle:
		if replace_active(editor) { replace_close(editor, false) } else { replace_open(editor) }
	case .ReplaceInFiles:     replace_in_files_pkg.open_via_api(&editor.replace_in_files, &editor.editor_api)
	case .None:
		return false
	case:
		// An action that the global scope doesn't service (e.g. .Quit is
		// handled by `main.odin`; per-pane actions like .Copy/.Paste fall
		// through to `editor_handle_key`). Treat as unhandled so the caller
		// can keep going.
		return false
	}
	return true
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

	// Edit shortcuts inside an editor pane (undo/redo/copy/paste/select-all)
	// route through the same keybindings table the global handler uses, so
	// rebinding Ctrl+Z in `defaults/<os>.json` Just Works here too. Every
	// other action either fired at the global scope or doesn't apply here;
	// `#partial switch` lets us list only the ones we care about.
	#partial switch keybindings.lookup(&editor.keybindings, pressed_key, key_modifiers, .Global) {
	case .Undo:
		if is_diff_mode { return }
		editor_undo_active(editor)
		return
	case .Redo:
		if is_diff_mode { return }
		editor_redo_active(editor)
		return
	case .Copy:
		clipboard_copy(editor)
		return
	case .Cut:
		if is_diff_mode { return }
		clipboard_cut(editor)
		return
	case .Paste:
		if is_diff_mode { return }
		clipboard_paste(editor)
		return
	case .SelectAll:
		// Select all (future)
		return
	}

	switch pressed_key {
	case sdl3.K_RETURN:
		if is_diff_mode { return }
		editor_insert_newline_with_indent(editor)

	case sdl3.K_TAB:
		if is_diff_mode { return }
		if shift_held {
			multi_outdent_selection(editor)
		} else {
			multi_indent_selection(editor)
		}

	case sdl3.K_BACKSPACE:
		if is_diff_mode { return }
		// completion_popup mirrors backspace into its filter via the
		// binding's handle_event (called earlier).
		multi_backspace(editor)

	case sdl3.K_DELETE:
		if is_diff_mode { return }
		multi_delete_forward(editor)

	case sdl3.K_LEFT:
		move_all_cursors_horizontal(editor, -1, shift_held)

	case sdl3.K_RIGHT:
		move_all_cursors_horizontal(editor, +1, shift_held)

	case sdl3.K_UP:
		move_all_cursors_vertical(editor, -1, shift_held)

	case sdl3.K_DOWN:
		move_all_cursors_vertical(editor, +1, shift_held)

	case sdl3.K_HOME:
		pane_collapse_to_primary(editor_pane)
		update_selection_for_nav(editor, shift_held)
		if ctrl_held {
			editor_pane.cursor_offset = 0
		} else {
			editor_pane.cursor_offset = document.document_line_start(&editor_pane.document, editor_pane.cursor_line)
		}
		sync_cursor_from_offset(editor)

	case sdl3.K_END:
		pane_collapse_to_primary(editor_pane)
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
		pane_collapse_to_primary(editor_pane)
		update_selection_for_nav(editor, shift_held)
		lines_to_move := editor_pane.visible_lines > 1 ? editor_pane.visible_lines - 1 : 1
		if editor_pane.cursor_line >= lines_to_move {
			move_cursor_vertical(editor, -i32(lines_to_move))
		} else {
			move_cursor_vertical(editor, -i32(editor_pane.cursor_line))
		}

	case sdl3.K_PAGEDOWN:
		pane_collapse_to_primary(editor_pane)
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
	pane_collapse_to_primary(editor_pane)
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
	pane_collapse_to_primary(editor_pane)
	if new_offset, ok := document.document_redo(&editor_pane.document); ok {
		editor_pane.cursor_offset = new_offset
	}
	editor_pane.selection_active = false
	sync_cursor_from_offset(editor)
}

@(private="file")
editor_zoom :: proc(editor: ^Editor, wheel_direction: f32) {
	zoom_step: f32 = 2.0
	new_font_size := editor.font_size + (wheel_direction > 0 ? zoom_step : -zoom_step)
	editor_apply_font_size(editor, new_font_size)
}

@(private)
FONT_SIZE_MIN: f32 : 8.0
@(private)
FONT_SIZE_MAX: f32 : 72.0

// Apply a new font size and refresh every cache that depends on it (text
// cache, markdown layout / fonts). Shared by the Ctrl+Wheel zoom path and
// by `editor_persistence_load` (so restored zoom takes effect immediately
// on startup). Idempotent: no work if the size hasn't actually changed.
@(private)
editor_apply_font_size :: proc(editor: ^Editor, requested_size: f32) {
	new_font_size := clamp(requested_size, FONT_SIZE_MIN, FONT_SIZE_MAX)
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
	markdown.fonts_apply_zoom(&editor.markdown_fonts, editor.font_size)

	// Persist so the next session opens at the same zoom level. Tiny JSON
	// write; happens at most every couple of wheel ticks.
	editor_persistence_save(editor)
}
