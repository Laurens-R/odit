package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../document"
import "../syntax"
import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
SaveAsFocus :: enum {
	PathInput,
	OkButton,
	CancelButton,
}

// Save-As text-input modal. Used directly by Ctrl+Shift+S, indirectly by
// Ctrl+S on an untitled doc, and chained from the Yes branch of the close
// confirmation dialog. `close_after_save` flips the post-success behavior to
// also close the pane's file (i.e. the "Yes → save → close" flow).
//
// `pane_index` is captured at open time so the dialog operates on the pane
// that originated the save, even if focus moves between frames.
@(private)
SaveAsDialog :: struct {
	focus:            SaveAsFocus,
	pane_index:       int,
	path_buffer:      [dynamic]u8,
	error_message:    string, // owned
	close_after_save: bool,

	input_rectangle:  sdl3.FRect,
	ok_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

@(private)
CloseConfirmFocus :: enum {
	YesButton,
	NoButton,
	CancelButton,
}

// "You have unsaved changes — save before closing?" prompt fired by Ctrl+F4
// when the active pane's document is dirty.
@(private)
CloseConfirmDialog :: struct {
	focus:            CloseConfirmFocus,
	pane_index:       int,

	yes_rectangle:    sdl3.FRect,
	no_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

// --- Lifecycle -------------------------------------------------------------

@(private)
save_as_dialog_destroy :: proc(state: ^SaveAsDialog) {
	delete(state.path_buffer)
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = SaveAsDialog{}
}

@(private="file")
save_as_dialog_clear_error :: proc(editor: ^Editor) {
	if len(editor.save_as_dialog.error_message) > 0 {
		delete(editor.save_as_dialog.error_message)
		editor.save_as_dialog.error_message = ""
	}
}

@(private="file")
save_as_dialog_set_error :: proc(editor: ^Editor, message: string) {
	save_as_dialog_clear_error(editor)
	editor.save_as_dialog.error_message = strings.clone(message)
}

// Open the Save-As modal seeded with a sensible default path for the active
// pane. `close_after_save` chains a close on successful write — used by the
// Yes branch of the close-confirmation flow.
@(private)
save_as_dialog_open :: proc(editor: ^Editor, close_after_save: bool = false) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	state := &editor.save_as_dialog
	clear(&state.path_buffer)
	save_as_dialog_clear_error(editor)
	state.pane_index       = editor.active_pane_index
	state.close_after_save = close_after_save
	state.focus            = .PathInput

	default_path := save_as_compute_default_path(editor, editor_pane)
	for byte_value in transmute([]u8)default_path { append(&state.path_buffer, byte_value) }

	editor.show_save_as = true
}

@(private)
save_as_dialog_close :: proc(editor: ^Editor) {
	editor.show_save_as = false
}

// Pre-fill heuristic. If the doc already has a path we keep it (Save As on
// an existing file is a "save a copy" gesture; user edits the filename).
// For untitled docs we synthesize <project-root|cwd>/untitled.txt.
@(private="file")
save_as_compute_default_path :: proc(editor: ^Editor, editor_pane: ^EditorPane) -> string {
	if len(editor_pane.file_path) > 0 {
		return strings.clone(editor_pane.file_path, context.temp_allocator)
	}
	parent_directory: string
	if len(editor.project_root) > 0 {
		parent_directory = editor.project_root
	} else {
		cwd, err := os.get_working_directory(context.temp_allocator)
		parent_directory = err == nil ? cwd : "."
	}
	return strings.concatenate({parent_directory, "/", "untitled.txt"}, context.temp_allocator)
}

@(private="file")
save_as_focus_next :: proc(state: ^SaveAsDialog) {
	switch state.focus {
	case .PathInput:    state.focus = .OkButton
	case .OkButton:     state.focus = .CancelButton
	case .CancelButton: state.focus = .PathInput
	}
}

@(private="file")
save_as_focus_prev :: proc(state: ^SaveAsDialog) {
	switch state.focus {
	case .PathInput:    state.focus = .CancelButton
	case .OkButton:     state.focus = .PathInput
	case .CancelButton: state.focus = .OkButton
	}
}

// Write the active pane's document to the path currently in the input
// field, retarget the pane to point at it, refresh language + symbols, and
// mark the document saved. Returns false (and sets the dialog's error
// message) if the write fails — the dialog stays open so the user can retry.
@(private="file")
save_as_dialog_commit :: proc(editor: ^Editor) -> bool {
	state := &editor.save_as_dialog

	path_text := strings.trim_space(string(state.path_buffer[:]))
	if len(path_text) == 0 {
		save_as_dialog_set_error(editor, "Enter a file path")
		return false
	}

	if state.pane_index < 0 || state.pane_index >= len(editor.panes) { return false }
	editor_pane := pane_as_editor(&editor.panes[state.pane_index]); if editor_pane == nil { return false }

	cleaned_path, _ := filepath.clean(path_text, context.temp_allocator)

	content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
	write_error  := os.write_entire_file(cleaned_path, transmute([]byte)content_text)
	if write_error != nil {
		save_as_dialog_set_error(editor, fmt.tprintf("Cannot write %s: %v", cleaned_path, write_error))
		return false
	}

	// Retarget the pane at the new on-disk path: free the prior owned string,
	// clone the new one, redetect the language for the new extension, mark
	// the doc clean, and rebuild the per-pane symbol index (the language may
	// have changed, which changes what counts as a symbol).
	if len(editor_pane.file_path) > 0 { delete(editor_pane.file_path) }
	editor_pane.file_path = strings.clone(cleaned_path)
	editor_pane.language  = syntax.get_definition_for_path(cleaned_path)
	document.document_mark_saved(&editor_pane.document)
	pane_rebuild_symbols(editor_pane)
	editor_pane.symbols_dirty      = false
	editor_pane.last_analysis_time = editor.clock

	return true
}

// --- Save-As event handling ----------------------------------------------

@(private)
save_as_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	state := &editor.save_as_dialog

	#partial switch event.type {
	case .TEXT_INPUT:
		if state.focus == .PathInput {
			input_text := string(event.text.text)
			for byte_value in transmute([]u8)input_text {
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(&state.path_buffer, byte_value)
			}
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			save_as_dialog_close(editor)

		case sdl3.K_TAB:
			if shift_held { save_as_focus_prev(state) } else { save_as_focus_next(state) }

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .PathInput, .OkButton:
				close_after := state.close_after_save
				if save_as_dialog_commit(editor) {
					save_as_dialog_close(editor)
					if close_after { editor_close_active_pane_content(editor) }
				}
			case .CancelButton:
				save_as_dialog_close(editor)
			}

		case sdl3.K_BACKSPACE:
			if state.focus == .PathInput {
				buffer_length := len(state.path_buffer)
				if buffer_length > 0 {
					new_end := buffer_length - 1
					for new_end > 0 && (state.path_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
					resize(&state.path_buffer, new_end)
				}
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.input_rectangle,  mouse_x, mouse_y):
			state.focus = .PathInput
		case ui.point_in_rect(state.ok_rectangle,     mouse_x, mouse_y):
			state.focus = .OkButton
			close_after := state.close_after_save
			if save_as_dialog_commit(editor) {
				save_as_dialog_close(editor)
				if close_after { editor_close_active_pane_content(editor) }
			}
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			save_as_dialog_close(editor)
		}
	}
}

// --- Save-As render ------------------------------------------------------

@(private)
save_as_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	state := &editor.save_as_dialog

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := editor.character_width
	line_height     := editor.line_height

	dialog_width  := min(80 * character_width + 32, viewport_width  - 40)
	dialog_height := min(10 * line_height     + 60, viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title := state.close_after_save ? "Save before closing" : "Save As"
	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, title, theme)

	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	ui.draw_text(&ui_context, "File path:", content_x, content_y, theme.text_foreground)
	content_y += line_height + 6

	state.input_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_height + 4)}
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "", string(state.path_buffer[:]), theme, state.focus == .PathInput)
	content_y += line_height + 14

	if len(state.error_message) > 0 {
		ui.draw_text(&ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_height + 4
	}

	// Right-aligned OK + Cancel near the bottom of the dialog.
	button_width:  i32 = 14 * character_width
	button_height: i32 = line_height + 12
	button_gap:    i32 = 8
	buttons_total_width := button_width * 2 + button_gap
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2
	button_y := i32(dialog_rectangle.y + dialog_rectangle.h) - button_height - 16

	state.ok_rectangle     = sdl3.FRect{f32(buttons_start_x),                              f32(button_y), f32(button_width), f32(button_height)}
	state.cancel_rectangle = sdl3.FRect{f32(buttons_start_x + button_width + button_gap), f32(button_y), f32(button_width), f32(button_height)}

	ui.draw_button(&ui_context, state.ok_rectangle,     "OK",     state.focus == .OkButton,     theme)
	ui.draw_button(&ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)
}

// --- Close-confirm lifecycle / events -----------------------------------

@(private)
close_confirm_dialog_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	state := &editor.close_confirm_dialog
	state.focus      = .YesButton
	state.pane_index = editor.active_pane_index
	editor.show_close_confirm = true
}

@(private)
close_confirm_dialog_close :: proc(editor: ^Editor) {
	editor.show_close_confirm = false
}

@(private)
close_confirm_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	state := &editor.close_confirm_dialog

	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			close_confirm_dialog_close(editor)

		case sdl3.K_LEFT:
			switch state.focus {
			case .YesButton:    state.focus = .CancelButton
			case .NoButton:     state.focus = .YesButton
			case .CancelButton: state.focus = .NoButton
			}

		case sdl3.K_RIGHT:
			switch state.focus {
			case .YesButton:    state.focus = .NoButton
			case .NoButton:     state.focus = .CancelButton
			case .CancelButton: state.focus = .YesButton
			}

		case sdl3.K_TAB:
			if shift_held {
				switch state.focus {
				case .YesButton:    state.focus = .CancelButton
				case .NoButton:     state.focus = .YesButton
				case .CancelButton: state.focus = .NoButton
				}
			} else {
				switch state.focus {
				case .YesButton:    state.focus = .NoButton
				case .NoButton:     state.focus = .CancelButton
				case .CancelButton: state.focus = .YesButton
				}
			}

		case sdl3.K_Y:
			close_confirm_save_and_close(editor)
		case sdl3.K_N:
			close_confirm_discard_and_close(editor)
		case sdl3.K_C:
			close_confirm_dialog_close(editor)

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .YesButton:    close_confirm_save_and_close(editor)
			case .NoButton:     close_confirm_discard_and_close(editor)
			case .CancelButton: close_confirm_dialog_close(editor)
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.yes_rectangle,    mouse_x, mouse_y):
			close_confirm_save_and_close(editor)
		case ui.point_in_rect(state.no_rectangle,     mouse_x, mouse_y):
			close_confirm_discard_and_close(editor)
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			close_confirm_dialog_close(editor)
		}

	case .MOUSE_MOTION:
		mouse_x, mouse_y := event.motion.x, event.motion.y
		if ui.point_in_rect(state.yes_rectangle,    mouse_x, mouse_y) { state.focus = .YesButton    }
		if ui.point_in_rect(state.no_rectangle,     mouse_x, mouse_y) { state.focus = .NoButton     }
		if ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y) { state.focus = .CancelButton }
	}
}

// Yes branch: save then close. If the file has a known path we write to it
// directly and close immediately; otherwise we hand off to the Save-As modal
// with `close_after_save = true` so the close fires on a successful write.
@(private="file")
close_confirm_save_and_close :: proc(editor: ^Editor) {
	state := &editor.close_confirm_dialog
	pane_index := state.pane_index
	close_confirm_dialog_close(editor)

	if pane_index < 0 || pane_index >= len(editor.panes) { return }
	editor_pane := pane_as_editor(&editor.panes[pane_index]); if editor_pane == nil { return }

	if len(editor_pane.file_path) == 0 {
		save_as_dialog_open(editor, close_after_save = true)
		return
	}

	if save_pane_to_existing_path(editor, editor_pane) {
		editor_close_active_pane_content(editor)
	} else {
		// Direct save failed — fall back to Save-As so the user can pick
		// a different path and still complete the close they asked for.
		save_as_dialog_open(editor, close_after_save = true)
		save_as_dialog_set_error(editor, fmt.tprintf("Could not write %s — choose a different path", editor_pane.file_path))
	}
}

// No branch: discard pending edits and close.
@(private="file")
close_confirm_discard_and_close :: proc(editor: ^Editor) {
	close_confirm_dialog_close(editor)
	editor_close_active_pane_content(editor)
}

// --- Close-confirm render ------------------------------------------------

@(private)
close_confirm_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	state := &editor.close_confirm_dialog

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	character_width_f, line_height_f := f32(editor.character_width), f32(editor.line_height)

	dialog_width := f32(70) * character_width_f
	if dialog_width > f32(viewport_width) - 60 { dialog_width = f32(viewport_width) - 60 }
	if dialog_width < 360                      { dialog_width = 360 }
	dialog_height := line_height_f * 3 + 36 + 36 + 60
	if dialog_height > f32(viewport_height) - 60 { dialog_height = f32(viewport_height) - 60 }
	dialog_x := (f32(viewport_width)  - dialog_width)  / 2
	dialog_y := (f32(viewport_height) - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{ dialog_x, dialog_y, dialog_width, dialog_height }

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Close file", theme)

	// Question text, using the pane's filename when we have one so the user
	// knows exactly which file they're being asked about.
	subject_name := "this file"
	if state.pane_index >= 0 && state.pane_index < len(editor.panes) {
		if editor_pane := pane_as_editor(&editor.panes[state.pane_index]); editor_pane != nil {
			if len(editor_pane.file_path) > 0 {
				subject_name = filepath_base_for_close(editor_pane.file_path)
			} else {
				subject_name = "this untitled file"
			}
		}
	}

	question_text := fmt.tprintf("Save changes to %s before closing?", subject_name)
	ui.draw_text(&ui_context, question_text, i32(content_rectangle.x), i32(content_rectangle.y), theme.text_foreground)

	// Three buttons: Yes / No / Cancel, centered.
	button_width  := f32(96)
	button_height := f32(32)
	button_gap    := f32(12)
	buttons_total := button_width * 3 + button_gap * 2
	start_x := content_rectangle.x + (content_rectangle.w - buttons_total) / 2
	button_y := content_rectangle.y + content_rectangle.h - button_height - 32

	state.yes_rectangle    = sdl3.FRect{ start_x,                                      button_y, button_width, button_height }
	state.no_rectangle     = sdl3.FRect{ start_x + button_width + button_gap,          button_y, button_width, button_height }
	state.cancel_rectangle = sdl3.FRect{ start_x + (button_width + button_gap) * 2,    button_y, button_width, button_height }

	ui.draw_button(&ui_context, state.yes_rectangle,    "Yes",    state.focus == .YesButton,    theme)
	ui.draw_button(&ui_context, state.no_rectangle,     "No",     state.focus == .NoButton,     theme)
	ui.draw_button(&ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)

	footer_text := "Y save • N discard • C / Esc cancel    ←/→ or Tab switch    Enter confirms"
	footer_width, _ := ui.text_size(&ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - editor.line_height - 8
	ui.draw_text(&ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}

// Local basename helper — render.odin's copy is `@(private="file")`, so it's
// not visible from here. Same logic.
@(private="file")
filepath_base_for_close :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

// --- Public actions wired to the hotkeys --------------------------------

// Ctrl+S — direct save when the active pane already has a path, otherwise
// fall through to the Save-As modal. If the direct write fails we open
// Save-As so the user gets a usable retry surface (and sees the error).
@(private)
editor_save_active_file :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 {
		save_as_dialog_open(editor, close_after_save = false)
		return
	}
	if !save_pane_to_existing_path(editor, editor_pane) {
		save_as_dialog_open(editor, close_after_save = false)
		save_as_dialog_set_error(editor, fmt.tprintf("Could not write %s — choose a different path", editor_pane.file_path))
	}
}

// Ctrl+Shift+S — always pop the modal even when the file already has a
// path, so the user can save a copy under a new name.
@(private)
editor_save_as_active_file :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	save_as_dialog_open(editor, close_after_save = false)
}

// Ctrl+F4 — close the active file. Dirty docs route through the confirm
// dialog; clean docs close immediately.
@(private)
editor_close_active_file :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if document.document_is_dirty(&editor_pane.document) {
		close_confirm_dialog_open(editor)
		return
	}
	editor_close_active_pane_content(editor)
}

// Close the active pane's file. Behavior depends on the surrounding panes:
//
//   * Single-pane mode (split off): replace the active pane's content with a
//     fresh untitled doc — there's nowhere else to fall back to.
//   * Split with both sides editors: collapse the split so the surviving
//     editor goes full-screen in pane[0] (the canonical home for single-
//     pane mode). The closed file's pane is torn down.
//   * Split with the other side a terminal (or anything non-editor): keep
//     the split, replace the active pane's content with untitled. We don't
//     drop the terminal out from under the user.
//
// Refuses to act when the active pane isn't an editor pane (Ctrl+F4 over a
// terminal is a no-op).
@(private)
editor_close_active_pane_content :: proc(editor: ^Editor) {
	if editor.active_pane_index < 0 || editor.active_pane_index >= len(editor.panes) { return }
	active_pane := &editor.panes[editor.active_pane_index]
	if _, active_is_editor := active_pane.content.(EditorPane); !active_is_editor { return }

	// Find/Replace bars are pinned to a specific pane index. Closing or
	// moving panes around invalidates those associations; tearing them down
	// up-front avoids the renderer painting them in the wrong place next
	// frame.
	if find_active(editor) {
		find_close(editor)
	}
	if replace_active(editor) {
		replace_close(editor, false)
	}

	// Notify the LSP layer that the active document is going away. Safe to
	// call when the doc wasn't LSP-tracked — short-circuits inside.
	if editor_pane := pane_as_editor(active_pane); editor_pane != nil {
		editor_lsp_pane_closing(editor, editor_pane)
	}

	// Easy case: no split. Just blank the file we were on. We DON'T route
	// through `editor_open_string_in_pane` here because that would stash the
	// doc into background_documents — but the user explicitly asked to close
	// it, not switch away from it.
	if !editor.split_active {
		editor_replace_pane_with_empty_editor(editor, editor.active_pane_index)
		return
	}

	other_pane_index := 1 - editor.active_pane_index
	other_pane := &editor.panes[other_pane_index]
	_, other_is_editor := other_pane.content.(EditorPane)

	if !other_is_editor {
		// The other side is a terminal (only other content kind today). We
		// don't want closing a file to also kill an in-flight shell, so just
		// blank the active pane and keep the split going.
		editor_replace_pane_with_empty_editor(editor, editor.active_pane_index)
		return
	}

	// Both panes are editors — collapse. Diff mode is a two-pane-only feature
	// so it dies with the split.
	if editor.diff_state.active {
		diff_state_destroy(&editor.diff_state)
	}

	if editor.active_pane_index == 0 {
		// Closing pane[0]: free its content, then move pane[1] into pane[0]
		// via a shallow PaneContent copy. Zero out pane[1] without destroying
		// the union (the data is now owned by pane[0]).
		pane_content_destroy(&editor.panes[0].content)
		editor.panes[0].content = editor.panes[1].content
		editor.panes[1].content = PaneContent{}
		if editor.panes[1].has_saved_content {
			pane_content_destroy(&editor.panes[1].saved_content)
			editor.panes[1].saved_content = PaneContent{}
			editor.panes[1].has_saved_content = false
		}
	} else {
		// Closing pane[1]: pane[0] is already in its single-pane position;
		// just destroy the pane we're closing.
		pane_destroy(&editor.panes[1])
	}

	editor.split_active      = false
	editor.active_pane_index = 0
}

// Write the pane's document to its known on-disk path. Returns false on
// any IO failure; callers that care about the error message should look
// at the dialog they then surface (Save-As, in practice).
@(private="file")
save_pane_to_existing_path :: proc(editor: ^Editor, editor_pane: ^EditorPane) -> bool {
	if len(editor_pane.file_path) == 0 { return false }
	content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
	write_error  := os.write_entire_file(editor_pane.file_path, transmute([]byte)content_text)
	if write_error != nil { return false }
	document.document_mark_saved(&editor_pane.document)
	return true
}
