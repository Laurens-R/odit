package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:sdl3"

import "../git"
import "../keybindings"
import "../ui"

@(private)
BrowseEntry :: struct {
	name:       string, // owned
	is_dir:     bool,
	git_status: git.Status, // .None if not in a git repo or unchanged
}

@(private)
BrowseState :: struct {
	current_working_directory: string, // owned
	entries:                   [dynamic]BrowseEntry,
	filtered_indices:          [dynamic]int,
	filter_buffer:             [dynamic]u8,
	selected_index:            int, // index into filtered_indices
	scroll_offset:             int, // first visible row in filtered list
	visible_row_count:         int, // set during render
	error_message:             string, // owned; "" when no error
	flat_mode:                 bool, // when true, the listing is a recursive file walk

	// Rename / new-file popup. `.None` when no popup is showing.
	prompt_state:              BrowsePrompt,
	// File-system change history. Each rename/create pushes one entry that
	// Ctrl+Z can reverse. Persists across browser open/close.
	undo_stack:                [dynamic]BrowseUndoEntry,
}

// Caps for the recursive walk so flat mode stays usable in large trees.
@(private="file")
FLAT_MAX_DEPTH   :: 10
@(private="file")
FLAT_MAX_ENTRIES :: 5000

// Directory names we always skip when recursing (huge, almost never useful to
// pick from in an editor's file finder).
@(private="file")
FLAT_SKIP_DIRS := [?]string{
	".git", "node_modules", "target", "build", "dist", ".cache", ".idea", ".vscode",
}

// --- Lifecycle ---

@(private)
browse_state_destroy :: proc(editor: ^Editor) {
	for entry in editor.browse_state.entries {
		delete(entry.name)
	}
	delete(editor.browse_state.entries)
	delete(editor.browse_state.filtered_indices)
	delete(editor.browse_state.filter_buffer)
	if len(editor.browse_state.current_working_directory) > 0 {
		delete(editor.browse_state.current_working_directory)
		editor.browse_state.current_working_directory = ""
	}
	if len(editor.browse_state.error_message) > 0 {
		delete(editor.browse_state.error_message)
		editor.browse_state.error_message = ""
	}
	browse_prompt_destroy(&editor.browse_state.prompt_state)
	browse_undo_stack_destroy(&editor.browse_state.undo_stack)
}

@(private)
browse_open :: proc(editor: ^Editor) {
	if editor.show_browse { return }

	// Decide the directory to land on. Precedence:
	//   1. Cached browser cwd from a previous open, IF either no project root
	//      is set or the cached cwd sits inside the project root.
	//   2. Project root, if one is set (so the user lands at the top of their
	//      project after wandering elsewhere in a previous open).
	//   3. The process's current working directory.
	start_directory_path: string
	cached_cwd := editor.browse_state.current_working_directory

	use_cached_cwd := false
	if len(cached_cwd) > 0 {
		if len(editor.project_root) == 0 || editor_path_inside_project_root(editor, cached_cwd) {
			use_cached_cwd = true
		}
	}

	switch {
	case use_cached_cwd:
		// Clone to a temp buffer because browse_load_directory frees the
		// editor.browse_state.current_working_directory string before taking
		// ownership of its argument.
		start_directory_path = strings.clone(cached_cwd, context.temp_allocator)
	case len(editor.project_root) > 0:
		start_directory_path = strings.clone(editor.project_root, context.temp_allocator)
	case:
		working_directory, get_directory_error := os.get_working_directory(context.temp_allocator)
		if get_directory_error != nil {
			start_directory_path = "."
		} else {
			start_directory_path = working_directory
		}
	}

	editor.show_browse = true
	browse_load_directory(editor, start_directory_path)
}

// Bound to Ctrl+P inside the file browser. Snapshots the browser's current
// directory as the editor's project root; subsequent terminal spawns and
// browser opens will anchor against it.
@(private="file")
browse_set_project_root_to_current :: proc(editor: ^Editor) {
	current_directory := editor.browse_state.current_working_directory
	if len(current_directory) == 0 { return }
	cleaned_directory, _ := filepath.clean(current_directory, context.temp_allocator)
	editor_set_project_root(editor, cleaned_directory)
	// No popup confirmation — the status bar at the bottom of the screen
	// shows the project root persistently, so the user can see the change
	// took effect as soon as they close the browser (and even before, by
	// peeking past the dialog).
}

@(private)
browse_close :: proc(editor: ^Editor) {
	editor.show_browse = false
}

// Toggle between tree (current directory only) and flat (recursive file list)
// views, then reload so the change is visible immediately.
@(private="file")
browse_toggle_flat :: proc(editor: ^Editor) {
	editor.browse_state.flat_mode = !editor.browse_state.flat_mode
	// Clone cwd to temp because browse_load_directory replaces it
	// before reading its argument.
	directory_path := strings.clone(editor.browse_state.current_working_directory, context.temp_allocator)
	browse_load_directory(editor, directory_path)
}

// --- Directory loading ---

@(private)
browse_set_error :: proc(editor: ^Editor, error_message: string) {
	if len(editor.browse_state.error_message) > 0 {
		delete(editor.browse_state.error_message)
	}
	editor.browse_state.error_message = strings.clone(error_message)
}

@(private="file")
browse_clear_error :: proc(editor: ^Editor) {
	if len(editor.browse_state.error_message) > 0 {
		delete(editor.browse_state.error_message)
		editor.browse_state.error_message = ""
	}
}

@(private="file")
entry_less :: proc(first_entry, second_entry: BrowseEntry) -> bool {
	// Folders first; then alphabetical (case-sensitive — good enough for now).
	if first_entry.is_dir != second_entry.is_dir { return first_entry.is_dir }
	return first_entry.name < second_entry.name
}

@(private="file")
flat_skip_dir :: proc(directory_name: string) -> bool {
	if strings.has_prefix(directory_name, ".") { return true } // dotfile dirs
	for skipped_directory in FLAT_SKIP_DIRS {
		if directory_name == skipped_directory { return true }
	}
	return false
}

// Recursively walk `root_directory + sub_relative_path`, appending every
// regular file we find to `output_entries` with its path *relative to
// root_directory*. Subdirectories aren't appended (the flat view is
// files-only). Bounded by FLAT_MAX_DEPTH and FLAT_MAX_ENTRIES.
@(private="file")
flat_walk :: proc(root_directory: string, sub_relative_path: string, current_depth: int, output_entries: ^[dynamic]BrowseEntry) {
	if current_depth > FLAT_MAX_DEPTH { return }
	if len(output_entries^) >= FLAT_MAX_ENTRIES { return }

	full_directory_path: string
	if len(sub_relative_path) == 0 {
		full_directory_path = root_directory
	} else {
		full_directory_path = path_join({root_directory, sub_relative_path}, context.temp_allocator)
	}

	directory_entries, read_directory_error := os.read_all_directory_by_path(full_directory_path, context.temp_allocator)
	if read_directory_error != nil { return }

	for entry_info in directory_entries {
		if len(output_entries^) >= FLAT_MAX_ENTRIES { return }
		if entry_info.name == "." || entry_info.name == ".." { continue }

		entry_is_directory := entry_info.type == .Directory
		if !entry_is_directory && entry_info.type != .Regular && entry_info.type != .Symlink { continue }

		entry_relative_path: string
		if len(sub_relative_path) == 0 {
			entry_relative_path = entry_info.name
		} else {
			entry_relative_path = path_join({sub_relative_path, entry_info.name}, context.temp_allocator)
		}

		if entry_is_directory {
			if flat_skip_dir(entry_info.name) { continue }
			flat_walk(root_directory, entry_relative_path, current_depth + 1, output_entries)
		} else {
			append(output_entries, BrowseEntry{name = strings.clone(entry_relative_path), is_dir = false})
		}
	}
}

@(private)
browse_load_directory :: proc(editor: ^Editor, directory_path: string) {
	// Replace owned entries
	for entry in editor.browse_state.entries {
		delete(entry.name)
	}
	clear(&editor.browse_state.entries)

	new_working_directory := strings.clone(directory_path)
	if len(editor.browse_state.current_working_directory) > 0 {
		delete(editor.browse_state.current_working_directory)
	}
	editor.browse_state.current_working_directory = new_working_directory

	browse_clear_error(editor)

	// Always offer ".." (works in both tree and flat views — lets the user
	// re-anchor the listing one level up).
	append(&editor.browse_state.entries, BrowseEntry{name = strings.clone(".."), is_dir = true})

	if editor.browse_state.flat_mode {
		// Files-only recursive walk.
		flat_walk(directory_path, "", 0, &editor.browse_state.entries)
		// Sort the appended files (preserve the ".." entry at index 0).
		if len(editor.browse_state.entries) > 1 {
			slice.sort_by(editor.browse_state.entries[1:], entry_less)
		}
	} else {
		directory_entries, read_directory_error := os.read_all_directory_by_path(directory_path, context.allocator)
		if read_directory_error != nil {
			browse_set_error(editor, fmt.tprintf("Cannot read directory: %v", read_directory_error))
		} else {
			defer os.file_info_slice_delete(directory_entries, context.allocator)

			sorted_entries := make([dynamic]BrowseEntry, 0, len(directory_entries), context.temp_allocator)
			for entry_info in directory_entries {
				if entry_info.name == "." || entry_info.name == ".." { continue }
				entry_is_directory := entry_info.type == .Directory
				if !entry_is_directory && entry_info.type != .Regular && entry_info.type != .Symlink {
					continue
				}
				append(&sorted_entries, BrowseEntry{name = strings.clone(entry_info.name), is_dir = entry_is_directory})
			}
			slice.sort_by(sorted_entries[:], entry_less)
			for sorted_entry in sorted_entries {
				append(&editor.browse_state.entries, sorted_entry)
			}
		}
	}

	// Annotate entries with their git status. The status map keys are full
	// paths relative to `directory_path`; for tree-view folders we roll up
	// the highest-priority status across the subtree, for files / flat-mode
	// entries we look up by exact name.
	{
		git_status_map := git.query_status(directory_path)
		for &entry in editor.browse_state.entries {
			entry.git_status = git.status_for_entry(git_status_map, entry.name, entry.is_dir)
		}
	}

	clear(&editor.browse_state.filter_buffer)
	editor.browse_state.selected_index = 0
	editor.browse_state.scroll_offset  = 0
	browse_apply_filter(editor)
}

// --- Filtering ---

@(private)
browse_apply_filter :: proc(editor: ^Editor) {
	clear(&editor.browse_state.filtered_indices)

	filter_lowercase := strings.to_lower(string(editor.browse_state.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in editor.browse_state.entries {
		if len(filter_lowercase) == 0 {
			append(&editor.browse_state.filtered_indices, entry_index)
			continue
		}
		// ".." is special — always show it regardless of filter so the user can
		// always escape upward.
		if entry.name == ".." {
			append(&editor.browse_state.filtered_indices, entry_index)
			continue
		}
		entry_name_lowercase := strings.to_lower(entry.name, context.temp_allocator)
		if strings.contains(entry_name_lowercase, filter_lowercase) {
			append(&editor.browse_state.filtered_indices, entry_index)
		}
	}

	// Clamp selection
	filtered_entry_count := len(editor.browse_state.filtered_indices)
	if filtered_entry_count == 0 {
		editor.browse_state.selected_index = 0
	} else if editor.browse_state.selected_index >= filtered_entry_count {
		editor.browse_state.selected_index = filtered_entry_count - 1
	}
	if editor.browse_state.selected_index < 0 { editor.browse_state.selected_index = 0 }
}

@(private="file")
browse_filter_append :: proc(editor: ^Editor, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		append(&editor.browse_state.filter_buffer, byte_value)
	}
	browse_apply_filter(editor)
}

@(private="file")
browse_filter_backspace :: proc(editor: ^Editor) {
	filter_length := len(editor.browse_state.filter_buffer)
	if filter_length == 0 { return }
	new_end_index := filter_length - 1
	// Walk back over UTF-8 continuation bytes
	for new_end_index > 0 && (editor.browse_state.filter_buffer[new_end_index] & 0xC0) == 0x80 {
		new_end_index -= 1
	}
	resize(&editor.browse_state.filter_buffer, new_end_index)
	browse_apply_filter(editor)
}

// --- Navigation ---

@(private="file")
browse_move_selection :: proc(editor: ^Editor, selection_delta: int) {
	filtered_entry_count := len(editor.browse_state.filtered_indices)
	if filtered_entry_count == 0 { return }
	new_selection := editor.browse_state.selected_index + selection_delta
	if new_selection < 0 { new_selection = 0 }
	if new_selection >= filtered_entry_count { new_selection = filtered_entry_count - 1 }
	editor.browse_state.selected_index = new_selection
}

// Maximum file size we'll load into the editor. Anything larger is rejected
// up-front rather than handed to the piece tree (which would otherwise try to
// allocate the entire file in its source buffer).
@(private="file")
MAX_FILE_BYTES :: 256 * 1024 * 1024 // 256 MiB

// `target` selects where to open a chosen file. `.Active` opens in whatever
// view currently has focus; `.SplitSecondary` opens in view 1 (creating the
// split if it wasn't already active).
@(private="file")
OpenTarget :: enum {
	Active,
	SplitSecondary,
}

@(private="file")
browse_activate :: proc(editor: ^Editor, open_target: OpenTarget = .Active) {
	filtered_entry_count := len(editor.browse_state.filtered_indices)
	if filtered_entry_count == 0 { return }
	if editor.browse_state.selected_index < 0 || editor.browse_state.selected_index >= filtered_entry_count { return }

	source_entry_index := editor.browse_state.filtered_indices[editor.browse_state.selected_index]
	entry := editor.browse_state.entries[source_entry_index]

	path_parts := [2]string{editor.browse_state.current_working_directory, entry.name}
	joined_path, _ := filepath.join(path_parts[:], context.temp_allocator)
	full_path, _ := filepath.clean(joined_path, context.temp_allocator)

	if entry.is_dir {
		browse_load_directory(editor, full_path)
		return
	}

	// Dedupe: if the picked file is already loaded (visible pane or stashed in
	// background_documents) we don't want to read it from disk again — that
	// would create a second copy and silently throw away the user's unsaved
	// edits on the existing one. Switch to the existing copy instead.
	existing_pane_index, existing_background_index := editor_find_open_document(editor, full_path)
	if existing_pane_index >= 0 {
		// .SplitSecondary on an already-visible file is treated as "focus
		// where the file lives" rather than forcing a split that would push
		// the file into the other pane — too disruptive for what's really a
		// navigation gesture.
		editor.active_pane_index = existing_pane_index
		browse_close(editor)
		return
	}
	if existing_background_index >= 0 {
		target_pane_index := editor.active_pane_index
		if open_target == .SplitSecondary {
			editor.split_active = true
			target_pane_index   = 1
			editor.active_pane_index = 1
		}
		editor_swap_background_into_pane(editor, target_pane_index, existing_background_index)
		browse_close(editor)
		return
	}

	file_data, read_file_error := os.read_entire_file_from_path(full_path, context.allocator)
	if read_file_error != nil {
		browse_set_error(editor, fmt.tprintf("Cannot open %s: %v", entry.name, read_file_error))
		return
	}
	defer delete(file_data)

	if len(file_data) < 0 || len(file_data) > MAX_FILE_BYTES {
		browse_set_error(editor, fmt.tprintf("File %s is too large (%d bytes)", entry.name, len(file_data)))
		return
	}

	file_content := strings.clone(string(file_data))
	//defer delete(file_content)

	// Pick destination pane based on the requested open target.
	target_pane_index := editor.active_pane_index
	if open_target == .SplitSecondary {
		editor.split_active = true
		target_pane_index = 1
		editor.active_pane_index = 1 // focus follows the new content
	}

	editor_open_string_in_pane(editor, target_pane_index, file_content, full_path)
	browse_close(editor)
}

// --- Input ---

@(private)
browse_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	// While a rename/new-file popup is open, every event goes to it.
	if browse_prompt_active(editor) {
		browse_prompt_handle_event(editor, event)
		return
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			browse_filter_append(editor, input_text)
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod

		// Browse-scoped shortcuts: rename, new file, undo last fs change,
		// set project root. Looked up with `.Browse` so they can share
		// chords (Ctrl+R, Ctrl+Z, Ctrl+P) with global actions without
		// fighting them — `editor_handle_event` already short-circuits to
		// us while the browser is open, so the global bindings can't fire.
		#partial switch keybindings.lookup(&editor.keybindings, pressed_key, key_modifiers, .Browse) {
		case .BrowseRename:           browse_prompt_open_rename(editor); return
		case .BrowseNewFile:          browse_prompt_open_new_file(editor); return
		case .BrowseUndo:             browse_undo(editor); return
		case .BrowseSetProjectRoot:   browse_set_project_root_to_current(editor); return
		}

		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F2:
			browse_close(editor)
		case sdl3.K_UP:
			browse_move_selection(editor, -1)
		case sdl3.K_DOWN:
			browse_move_selection(editor, 1)
		case sdl3.K_PAGEUP:
			page_step := editor.browse_state.visible_row_count
			if page_step < 1 { page_step = 1 }
			browse_move_selection(editor, -page_step)
		case sdl3.K_PAGEDOWN:
			page_step := editor.browse_state.visible_row_count
			if page_step < 1 { page_step = 1 }
			browse_move_selection(editor, page_step)
		case sdl3.K_HOME:
			browse_move_selection(editor, -len(editor.browse_state.filtered_indices))
		case sdl3.K_END:
			browse_move_selection(editor, len(editor.browse_state.filtered_indices))
		case sdl3.K_RETURN:
			shift_held := .LSHIFT in event.key.mod || .RSHIFT in event.key.mod
			browse_activate(editor, .SplitSecondary if shift_held else .Active)
		case sdl3.K_BACKSPACE:
			browse_filter_backspace(editor)
		case sdl3.K_F3:
			browse_toggle_flat(editor)
		}
	}
}

// --- Rendering ---

@(private)
browse_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	// Dialog rect
	desired_columns: i32 = 100
	desired_rows: i32 = 40
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * editor.line_height + 40, viewport_height - 40)
	if dialog_width  < 240 { dialog_width  = min(viewport_width  - 16, 240) }
	if dialog_height < 240 { dialog_height = min(viewport_height - 16, 240) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	mode_tag := editor.browse_state.flat_mode ? "  (flat)" : ""
	title := fmt.tprintf("Browse — %s%s", editor.browse_state.current_working_directory, mode_tag)
	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, title, theme)

	line_step := editor.line_height
	content_x := i32(content_rectangle.x)
	content_y := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	// Filter field
	filter_string := string(editor.browse_state.filter_buffer[:])
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8 // include underline gap

	// Footer reservation
	footer_height: i32 = line_step + 12
	list_top_y := content_y
	list_bottom_y := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12

	// Reserve a line for the error message, if any.
	if len(editor.browse_state.error_message) > 0 {
		list_bottom_y -= line_step
	}

	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	editor.browse_state.visible_row_count = computed_visible_rows

	// Adjust scroll so the selected row is in view.
	if editor.browse_state.selected_index < editor.browse_state.scroll_offset {
		editor.browse_state.scroll_offset = editor.browse_state.selected_index
	} else if editor.browse_state.selected_index >= editor.browse_state.scroll_offset + computed_visible_rows {
		editor.browse_state.scroll_offset = editor.browse_state.selected_index - computed_visible_rows + 1
	}
	if editor.browse_state.scroll_offset < 0 { editor.browse_state.scroll_offset = 0 }

	// Draw entries
	end_row_index := min(editor.browse_state.scroll_offset + computed_visible_rows, len(editor.browse_state.filtered_indices))
	for row_index := editor.browse_state.scroll_offset; row_index < end_row_index; row_index += 1 {
		entry := editor.browse_state.entries[editor.browse_state.filtered_indices[row_index]]
		row_y_position := list_top_y + i32(row_index - editor.browse_state.scroll_offset) * line_step
		row_icon: ui.ListRowIcon = entry.is_dir ? .Folder : .File

		// Git status tints the label color; selection still wins for visual
		// emphasis (we keep the brighter title_foreground on the selected
		// row so the selection is unambiguous even on already-tinted entries).
		label_color_override: Maybe(sdl3.FColor)
		if row_index != editor.browse_state.selected_index {
			switch entry.git_status {
			case .None:                                                                  // no tint
			case .Modified:  label_color_override = editor.git_modified_foreground
			case .Added:     label_color_override = editor.git_added_foreground
			case .Untracked: label_color_override = editor.git_untracked_foreground
			case .Renamed:   label_color_override = editor.git_renamed_foreground
			case .Deleted:   label_color_override = editor.git_deleted_foreground
			}
		}

		// Reserve a 3-character slot between the icon and the name for the
		// git status tag. The slot is filled with [N]/[M]/[D]/[R] when the
		// entry has a status and left blank otherwise, so names line up in
		// the same column regardless of whether they have a tag.
		git_status_tag_string := git.status_tag(entry.git_status)
		if len(git_status_tag_string) == 0 { git_status_tag_string = "   " }
		row_label := fmt.tprintf("%s %s", git_status_tag_string, entry.name)

		ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, row_label, row_index == editor.browse_state.selected_index, theme, row_icon, label_color_override)
	}

	if len(editor.browse_state.filtered_indices) == 0 {
		empty_message := len(editor.browse_state.filter_buffer) > 0 ? "(no matches)" : "(empty)"
		ui.draw_text(&ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	}

	// Error line (if any), drawn just below the list area.
	if len(editor.browse_state.error_message) > 0 {
		error_y := list_bottom_y
		ui.draw_text(&ui_context, editor.browse_state.error_message, content_x, error_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
	}

	// Footer hint
	hint_text := "Enter open  Ctrl+P set project root  Ctrl+R rename  Ctrl+N new  Ctrl+Z undo  F3 flat  Esc"
	hint_width, _ := ui.text_size(&ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(&ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)

	// Rename / new-file popup, if any, on top of the browse modal.
	if browse_prompt_active(editor) {
		browse_prompt_render(editor, renderer, viewport_width, viewport_height)
	}
}
