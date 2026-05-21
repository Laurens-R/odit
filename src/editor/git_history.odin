package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../syntax"
import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
GitHistoryFocus :: enum {
	List,
	OkButton,
	CancelButton,
}

// One row in the history dialog. We retain the full hash for `git show` and
// also a short hash for compact display. `date`/`author`/`subject` are
// already-trimmed strings as they came out of git log.
@(private)
GitHistoryEntry :: struct {
	hash:       string, // owned, full SHA
	short_hash: string, // owned, first 7 chars
	date:       string, // owned, ISO-8601 with timezone (we display a prefix)
	author:     string, // owned, %an
	subject:    string, // owned, %s
}

@(private)
GitHistoryDialog :: struct {
	focus:             GitHistoryFocus,
	source_pane_index: int,
	file_path:         string, // owned, absolute path of the file we're listing
	relative_path:     string, // owned, repo-root-relative path used by `git show`
	entries:           [dynamic]GitHistoryEntry,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	error_message:     string, // owned

	list_rectangle:   sdl3.FRect,
	ok_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

// --- Lifecycle -------------------------------------------------------------

@(private)
git_history_dialog_destroy :: proc(state: ^GitHistoryDialog) {
	git_history_clear_entries(state)
	delete(state.entries)
	if len(state.file_path)     > 0 { delete(state.file_path)     }
	if len(state.relative_path) > 0 { delete(state.relative_path) }
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = GitHistoryDialog{}
}

@(private="file")
git_history_clear_entries :: proc(state: ^GitHistoryDialog) {
	for entry in state.entries {
		if len(entry.hash)       > 0 { delete(entry.hash)       }
		if len(entry.short_hash) > 0 { delete(entry.short_hash) }
		if len(entry.date)       > 0 { delete(entry.date)       }
		if len(entry.author)     > 0 { delete(entry.author)     }
		if len(entry.subject)    > 0 { delete(entry.subject)    }
	}
	clear(&state.entries)
}

@(private="file")
git_history_set_error :: proc(state: ^GitHistoryDialog, message: string) {
	if len(state.error_message) > 0 { delete(state.error_message) }
	state.error_message = strings.clone(message)
}

// Open the dialog for the active pane's file. Walks: git availability →
// repo lookup → file's repo-relative path → `git log` of that path. Any
// failure surfaces as an error inside the modal rather than a silent
// no-op so the user always knows why nothing happened.
@(private)
git_history_dialog_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	state := &editor.git_history_dialog
	git_history_clear_entries(state)
	if len(state.file_path)     > 0 { delete(state.file_path);     state.file_path     = "" }
	if len(state.relative_path) > 0 { delete(state.relative_path); state.relative_path = "" }
	if len(state.error_message) > 0 { delete(state.error_message); state.error_message = "" }

	state.source_pane_index = editor.active_pane_index
	state.focus             = .List
	state.selected_index    = 0
	state.scroll_offset     = 0

	// Untitled docs (no path) can't have any git history. Surface it as
	// an error so the dialog still opens and gives the user feedback.
	if len(editor_pane.file_path) == 0 {
		editor.show_git_history = true
		git_history_set_error(state, "Save the file first — untitled documents have no git history")
		return
	}
	state.file_path = strings.clone(editor_pane.file_path)

	if !git_is_available() {
		editor.show_git_history = true
		git_history_set_error(state, "git is not on PATH")
		return
	}

	file_directory := os.dir(state.file_path)

	repo_root_path, repository_found := git_get_repo_root(file_directory)
	if !repository_found {
		editor.show_git_history = true
		git_history_set_error(state, "This file is not inside a git repository")
		return
	}

	relative_path, relative_error := filepath.rel(repo_root_path, state.file_path, context.temp_allocator)
	if relative_error != .None {
		editor.show_git_history = true
		git_history_set_error(state, "Could not compute repo-relative path")
		return
	}
	// Git wants forward slashes regardless of OS.
	forward_slashed_relative, _ := strings.replace_all(relative_path, "\\", "/", context.temp_allocator)
	state.relative_path = strings.clone(forward_slashed_relative)

	git_history_populate(state, file_directory)

	editor.show_git_history = true
}

@(private)
git_history_dialog_close :: proc(editor: ^Editor) {
	editor.show_git_history = false
}

// Resolve the repo root for `directory_path`. Same shape as the helper in
// browse.odin's git_query_status — duplicated here to avoid exporting a
// porcelain-only API for one extra caller.
@(private="file")
git_get_repo_root :: proc(directory_path: string) -> (root: string, ok: bool) {
	command_arguments := [?]string{"git", "-C", directory_path, "rev-parse", "--show-toplevel"}
	process_description := os.Process_Desc{ command = command_arguments[:] }
	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 { return "", false }
	return strings.trim_space(string(stdout_bytes)), true
}

// Populate `state.entries` from `git log`. Uses 0x1F (Unit Separator) as
// the field delimiter so subjects containing `|`, tabs, etc. parse safely.
@(private="file")
git_history_populate :: proc(state: ^GitHistoryDialog, file_directory: string) {
	// Format: full-hash US author-iso-date US author-name US subject
	format_argument := "--pretty=format:%H%x1f%aI%x1f%an%x1f%s"
	command_arguments := [?]string{"git", "-C", file_directory, "log", format_argument, "--", state.file_path}
	process_description := os.Process_Desc{ command = command_arguments[:] }
	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 {
		git_history_set_error(state, "git log failed for this file")
		return
	}

	log_output := string(stdout_bytes)
	for log_line in strings.split_lines_iterator(&log_output) {
		if len(log_line) == 0 { continue }
		fields := strings.split(log_line, "\x1f", context.temp_allocator)
		if len(fields) < 4 { continue }

		full_hash := fields[0]
		commit_date := fields[1]
		author_name := fields[2]
		commit_subject := fields[3]

		short_hash_length := 7
		if len(full_hash) < short_hash_length { short_hash_length = len(full_hash) }

		append(&state.entries, GitHistoryEntry{
			hash       = strings.clone(full_hash),
			short_hash = strings.clone(full_hash[:short_hash_length]),
			date       = strings.clone(commit_date),
			author     = strings.clone(author_name),
			subject    = strings.clone(commit_subject),
		})
	}

	if len(state.entries) == 0 {
		git_history_set_error(state, "No commits found for this file")
	}
}

// --- Selection / activation ---------------------------------------------

@(private="file")
git_history_move_selection :: proc(state: ^GitHistoryDialog, delta: int) {
	entry_count := len(state.entries)
	if entry_count == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0           { new_index = 0 }
	if new_index >= entry_count { new_index = entry_count - 1 }
	state.selected_index = new_index

	if state.visible_row_count > 0 {
		if state.selected_index < state.scroll_offset {
			state.scroll_offset = state.selected_index
		} else if state.selected_index >= state.scroll_offset + state.visible_row_count {
			state.scroll_offset = state.selected_index - state.visible_row_count + 1
		}
		if state.scroll_offset < 0 { state.scroll_offset = 0 }
	}
}

// Fetch the selected revision via `git show <hash>:<rel-path>` and open it
// in the pane opposite the source. The snapshot pane is left with an empty
// `file_path` so Ctrl+S won't accidentally write the old revision back over
// the current working copy; the title bar uses `display_title_override` to
// surface "filename @ short-hash" instead.
@(private="file")
git_history_activate :: proc(editor: ^Editor) {
	state := &editor.git_history_dialog
	if state.selected_index < 0 || state.selected_index >= len(state.entries) { return }
	if len(state.relative_path) == 0 { return }

	selected_entry := state.entries[state.selected_index]
	file_directory := os.dir(state.file_path)

	hash_colon_path := fmt.tprintf("%s:%s", selected_entry.hash, state.relative_path)
	command_arguments := [?]string{"git", "-C", file_directory, "show", hash_colon_path}
	process_description := os.Process_Desc{ command = command_arguments[:] }
	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 {
		git_history_set_error(state, fmt.tprintf("Cannot fetch revision %s", selected_entry.short_hash))
		return
	}

	revision_text := strings.clone(string(stdout_bytes))

	// "Opposite pane": pane 1 when the source was pane 0, pane 0 otherwise.
	// Force the split on so both panes are visible — the whole point is
	// side-by-side comparison.
	opposite_pane_index := 1 - state.source_pane_index
	if opposite_pane_index < 0 || opposite_pane_index >= len(editor.panes) { return }

	editor.split_active = true

	// Drop the revision into an untitled pane, then fix up the language
	// (so syntax highlighting still works for the snapshot) and the title
	// (so the user sees the revision marker). Symbol rebuild happens so
	// F6 on the snapshot pane jumps inside its content, not the current one.
	editor_open_string_in_pane(editor, opposite_pane_index, revision_text, "")
	if opposite_pane := pane_as_editor(&editor.panes[opposite_pane_index]); opposite_pane != nil {
		opposite_pane.language = syntax.get_definition_for_path(state.file_path)

		display_basename := git_history_filepath_base(state.file_path)
		opposite_pane.display_title_override = strings.clone(fmt.tprintf("%s @ %s", display_basename, selected_entry.short_hash))

		pane_rebuild_symbols(opposite_pane)
		opposite_pane.symbols_dirty      = false
		opposite_pane.last_analysis_time = editor.clock
	}

	editor.active_pane_index = opposite_pane_index

	git_history_dialog_close(editor)
}

// Local basename helper — keeps git_history.odin independent of the one in
// render.odin (which is `@(private="file")`).
@(private="file")
git_history_filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

// --- Focus --------------------------------------------------------------

@(private="file")
git_history_focus_next :: proc(state: ^GitHistoryDialog) {
	switch state.focus {
	case .List:         state.focus = .OkButton
	case .OkButton:     state.focus = .CancelButton
	case .CancelButton: state.focus = .List
	}
}

@(private="file")
git_history_focus_prev :: proc(state: ^GitHistoryDialog) {
	switch state.focus {
	case .List:         state.focus = .CancelButton
	case .OkButton:     state.focus = .List
	case .CancelButton: state.focus = .OkButton
	}
}

// --- Event handling ----------------------------------------------------

@(private)
git_history_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	state := &editor.git_history_dialog

	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F3:
			git_history_dialog_close(editor)

		case sdl3.K_TAB:
			if shift_held { git_history_focus_prev(state) } else { git_history_focus_next(state) }

		case sdl3.K_UP:        if state.focus == .List { git_history_move_selection(state, -1) }
		case sdl3.K_DOWN:      if state.focus == .List { git_history_move_selection(state, +1) }
		case sdl3.K_PAGEUP:
			if state.focus == .List {
				step := state.visible_row_count; if step < 1 { step = 1 }
				git_history_move_selection(state, -step)
			}
		case sdl3.K_PAGEDOWN:
			if state.focus == .List {
				step := state.visible_row_count; if step < 1 { step = 1 }
				git_history_move_selection(state, +step)
			}
		case sdl3.K_HOME: if state.focus == .List { git_history_move_selection(state, -len(state.entries)) }
		case sdl3.K_END:  if state.focus == .List { git_history_move_selection(state, +len(state.entries)) }

		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			switch state.focus {
			case .List, .OkButton: git_history_activate(editor)
			case .CancelButton:    git_history_dialog_close(editor)
			}
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.list_rectangle, mouse_x, mouse_y):
			state.focus = .List
			if editor.line_height > 0 {
				row_height := f32(editor.line_height)
				relative_y := mouse_y - state.list_rectangle.y
				if relative_y >= 0 {
					row_index_in_view := int(relative_y / row_height)
					target_index := state.scroll_offset + row_index_in_view
					if target_index >= 0 && target_index < len(state.entries) {
						state.selected_index = target_index
					}
				}
			}
		case ui.point_in_rect(state.ok_rectangle,     mouse_x, mouse_y):
			state.focus = .OkButton
			git_history_activate(editor)
		case ui.point_in_rect(state.cancel_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			git_history_dialog_close(editor)
		}

	case .MOUSE_WHEEL:
		if state.visible_row_count > 0 && len(state.entries) > 0 {
			scroll_delta := -int(event.wheel.y * 3)
			max_offset   := max(0, len(state.entries) - state.visible_row_count)
			new_offset   := state.scroll_offset + scroll_delta
			if new_offset < 0          { new_offset = 0 }
			if new_offset > max_offset { new_offset = max_offset }
			state.scroll_offset = new_offset
		}
	}
}

// --- Rendering ---------------------------------------------------------

@(private)
git_history_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	state := &editor.git_history_dialog

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := editor.character_width
	line_height     := editor.line_height

	dialog_width  := min(110 * character_width + 32, viewport_width  - 40)
	dialog_height := min(30  * line_height     + 60, viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 240 { dialog_height = min(viewport_height - 16, 240) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title: string
	if len(state.file_path) > 0 {
		title = fmt.tprintf("Git History — %s", git_history_filepath_base(state.file_path))
	} else {
		title = "Git History"
	}
	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, title, theme)

	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	if len(state.error_message) > 0 {
		ui.draw_text(&ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_height + 6
	}

	// Reserve space for the buttons row at the bottom + a footer hint line.
	button_width:  i32 = 14 * character_width
	button_height: i32 = line_height + 12
	button_gap:    i32 = 8
	button_y := i32(dialog_rectangle.y + dialog_rectangle.h) - button_height - line_height - 22

	buttons_total_width := button_width * 2 + button_gap
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2
	state.ok_rectangle     = sdl3.FRect{f32(buttons_start_x),                              f32(button_y), f32(button_width), f32(button_height)}
	state.cancel_rectangle = sdl3.FRect{f32(buttons_start_x + button_width + button_gap), f32(button_y), f32(button_width), f32(button_height)}

	// List viewport — everything between the (optional) error line and the
	// buttons.
	list_top_y    := content_y
	list_bottom_y := button_y - 12
	list_area_height := list_bottom_y - list_top_y
	if list_area_height < line_height { list_area_height = line_height }
	visible_rows := int(list_area_height / line_height)
	if visible_rows < 1 { visible_rows = 1 }
	state.visible_row_count = visible_rows
	state.list_rectangle = sdl3.FRect{f32(content_x), f32(list_top_y), f32(content_width), f32(list_area_height)}

	max_scroll_offset := max(0, len(state.entries) - visible_rows)
	if state.scroll_offset > max_scroll_offset { state.scroll_offset = max_scroll_offset }
	if state.scroll_offset < 0                 { state.scroll_offset = 0 }

	if len(state.entries) == 0 {
		if len(state.error_message) == 0 {
			ui.draw_text(&ui_context, "(no commits)", content_x + 8, list_top_y, theme.dim_foreground)
		}
	} else {
		end_row_index := min(state.scroll_offset + visible_rows, len(state.entries))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry := state.entries[row_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_height
			is_selected := row_index == state.selected_index && state.focus == .List

			// Trim ISO date to "YYYY-MM-DD HH:MM" — that's enough resolution
			// to disambiguate commits and keeps the row readable.
			date_display := entry.date
			if len(date_display) > 16 {
				date_display = date_display[:16]
			}
			date_display, _ = strings.replace_all(date_display, "T", " ", context.temp_allocator)

			row_label := fmt.tprintf("%s  %s  %-20s  %s", entry.short_hash, date_display, entry.author, entry.subject)
			ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	ui.draw_button(&ui_context, state.ok_rectangle,     "OK",     state.focus == .OkButton,     theme)
	ui.draw_button(&ui_context, state.cancel_rectangle, "Cancel", state.focus == .CancelButton, theme)

	footer_text := "↑/↓ navigate    Enter open in opposite pane    Esc cancel"
	footer_width, _ := ui.text_size(&ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_height - 8
	ui.draw_text(&ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}
