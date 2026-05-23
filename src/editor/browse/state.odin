// Package `browse` is the F2 file-browser modal. It owns the filterable
// list view, the rename / new-file sub-popup, the directory-listing
// + git-status pipeline, the rename/create filesystem operations, and
// the small undo stack that lets plain Ctrl+Z reverse the last fs
// change.
//
// Structure:
//   * `state.odin`    — types (State, Entry, EntrySource, Chrome,
//                       UndoEntry, Intent, Host), lifecycle, filter /
//                       selection helpers.
//   * `view.odin`     — handle_event + render.
//   * `dispatch.odin` — dispatch_event glue, directory loading + flat
//                       walk, rename / create / undo, and the
//                       embedded prompt host trampolines.
//
// The host (the editor) handles only the things that genuinely require
// editor state: opening a file into a pane (with dedupe against
// background documents), setting the project root, and answering two
// project-root queries used by `open` to pick a sensible initial
// directory.
package browse

import "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:sdl3"

import "../../git"
import browse_prompt "../browse_prompt"

State :: struct {
	visible:           bool,
	current_working_directory: string, // owned, displayed in the dialog title
	entries:           [dynamic]Entry,
	filtered_indices:  [dynamic]int,
	filter_buffer:     [dynamic]u8,
	selected_index:    int, // index into filtered_indices
	scroll_offset:     int, // first visible row in the filtered list
	visible_row_count: int, // refreshed during render
	error_message:     string, // owned, "" when no error
	flat_mode:         bool, // tree (false) vs recursive file-walk (true)

	// Embedded sub-popup for rename / new-file. While `prompt.kind != .None`
	// the browse view forwards all input to the prompt.
	prompt:            browse_prompt.State,

	// Reversible fs changes from inside the modal. Ctrl+Z (without an
	// active prompt) pops the top entry. Owned strings are freed on
	// pop or `destroy`.
	undo_stack:        [dynamic]UndoEntry,
}

Entry :: struct {
	name:       string, // owned
	is_dir:     bool,
	git_status: git.Status,
}

// Internal source-side struct used while building a fresh listing.
// Strings live in `context.temp_allocator` for the duration of the
// load; `set_entries_internal` clones into `entries` storage.
@(private)
EntrySource :: struct {
	name:       string,
	is_dir:     bool,
	git_status: git.Status,
}

// Per-status label tint colors. Caller builds this from its theme
// palette and passes it on each render.
Chrome :: struct {
	git_modified:  sdl3.FColor,
	git_added:     sdl3.FColor,
	git_untracked: sdl3.FColor,
	git_renamed:   sdl3.FColor,
	git_deleted:   sdl3.FColor,
	error_text:    sdl3.FColor,
}

UndoOp :: enum {
	Rename,       // path_a = old absolute path, path_b = new absolute path
	Create,       // path_a = created absolute path (path_b unused)
	CreateFolder, // path_a = created absolute path (path_b unused)
}

UndoEntry :: struct {
	operation: UndoOp,
	path_a:    string,
	path_b:    string,
}

// Browse-level intent surfaced from `handle_event`. Routed through
// `Host` (open_file, set_project_root) or handled in-package
// (Undo, ToggleFlat, OpenDirectory) by `dispatch_event`.
//
// Strings inside intent variants live in `context.temp_allocator`.
Intent :: union {
	OpenDirectory,
	OpenFile,
	ToggleFlat,
	SetProjectRoot,
	Undo,
}
OpenDirectory  :: struct { path: string }
OpenFile       :: struct { path: string, split_secondary: bool }
ToggleFlat     :: struct {}
SetProjectRoot :: struct { path: string }
Undo           :: struct {}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	clear_entries(state)
	if cap(state.entries)          > 0 { delete(state.entries)          }
	if cap(state.filtered_indices) > 0 { delete(state.filtered_indices) }
	if cap(state.filter_buffer)    > 0 { delete(state.filter_buffer)    }
	if len(state.current_working_directory) > 0 { delete(state.current_working_directory) }
	if len(state.error_message)             > 0 { delete(state.error_message) }
	browse_prompt.destroy(&state.prompt)
	undo_stack_destroy(state)
	state^ = State{}
}

// Just flip visibility off. Doesn't touch entries / filter / scroll —
// the next open reuses them. Closes any active sub-popup first.
close :: proc(state: ^State) {
	state.visible = false
	browse_prompt.close(&state.prompt)
}

// Snapshot of the cached working directory (read-only; subpackage still
// owns the string).
cached_directory :: proc(state: ^State) -> string {
	return state.current_working_directory
}

set_error :: proc(state: ^State, message: string) {
	if len(state.error_message) > 0 { delete(state.error_message) }
	state.error_message = strings.clone(message)
}

@(private)
clear_error :: proc(state: ^State) {
	if len(state.error_message) > 0 {
		delete(state.error_message)
		state.error_message = ""
	}
}

@(private)
undo_stack_destroy :: proc(state: ^State) {
	for entry in state.undo_stack {
		if len(entry.path_a) > 0 { delete(entry.path_a) }
		if len(entry.path_b) > 0 { delete(entry.path_b) }
	}
	if cap(state.undo_stack) > 0 { delete(state.undo_stack) }
	state.undo_stack = nil
}

// --- Listing ingestion (internal) ----------------------------------------

// Replace the entry list with a freshly-read directory listing. Resets
// filter / scroll / selection so the new listing starts at the top.
@(private)
set_entries_internal :: proc(state: ^State, sources: []EntrySource, current_working_directory: string) {
	clear_entries(state)
	for source in sources {
		append(&state.entries, Entry{
			name       = strings.clone(source.name),
			is_dir     = source.is_dir,
			git_status = source.git_status,
		})
	}
	if len(state.current_working_directory) > 0 { delete(state.current_working_directory) }
	state.current_working_directory = strings.clone(current_working_directory)
	clear_error(state)

	clear(&state.filter_buffer)
	state.selected_index = 0
	state.scroll_offset  = 0
	apply_filter(state)
}

// --- Internal helpers (used by view + dispatch) -------------------------

@(private)
clear_entries :: proc(state: ^State) {
	for entry in state.entries {
		if len(entry.name) > 0 { delete(entry.name) }
	}
	clear(&state.entries)
}

@(private)
apply_filter :: proc(state: ^State) {
	clear(&state.filtered_indices)

	filter_lowercase := strings.to_lower(string(state.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in state.entries {
		if len(filter_lowercase) == 0 {
			append(&state.filtered_indices, entry_index)
			continue
		}
		// ".." is special — always show it regardless of filter so the
		// user can always escape upward.
		if entry.name == ".." {
			append(&state.filtered_indices, entry_index)
			continue
		}
		entry_name_lowercase := strings.to_lower(entry.name, context.temp_allocator)
		if strings.contains(entry_name_lowercase, filter_lowercase) {
			append(&state.filtered_indices, entry_index)
		}
	}

	filtered_entry_count := len(state.filtered_indices)
	if filtered_entry_count == 0 {
		state.selected_index = 0
	} else if state.selected_index >= filtered_entry_count {
		state.selected_index = filtered_entry_count - 1
	}
	if state.selected_index < 0 { state.selected_index = 0 }
}

@(private)
filter_append :: proc(state: ^State, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		append(&state.filter_buffer, byte_value)
	}
	apply_filter(state)
}

@(private)
filter_backspace :: proc(state: ^State) -> (changed: bool) {
	filter_length := len(state.filter_buffer)
	if filter_length == 0 { return false }
	new_end_index := filter_length - 1
	for new_end_index > 0 && (state.filter_buffer[new_end_index] & 0xC0) == 0x80 {
		new_end_index -= 1
	}
	resize(&state.filter_buffer, new_end_index)
	apply_filter(state)
	return true
}

@(private)
move_selection :: proc(state: ^State, selection_delta: int) {
	filtered_entry_count := len(state.filtered_indices)
	if filtered_entry_count == 0 { return }
	new_selection := state.selected_index + selection_delta
	if new_selection < 0 { new_selection = 0 }
	if new_selection >= filtered_entry_count { new_selection = filtered_entry_count - 1 }
	state.selected_index = new_selection
}

@(private)
current_entry :: proc(state: ^State) -> ^Entry {
	if state.selected_index < 0 || state.selected_index >= len(state.filtered_indices) { return nil }
	source_entry_index := state.filtered_indices[state.selected_index]
	if source_entry_index < 0 || source_entry_index >= len(state.entries) { return nil }
	return &state.entries[source_entry_index]
}

@(private)
open_rename_at_selection :: proc(state: ^State) {
	selected_entry := current_entry(state)
	if selected_entry == nil       { return }
	if selected_entry.name == ".." { return }
	browse_prompt.open_rename(&state.prompt, selected_entry.name)
}

// Build the intent for the currently-selected entry. Directories return
// OpenDirectory; files return OpenFile. The host decides what "open"
// actually means for files; directory loads stay in-package.
@(private)
try_activate :: proc(state: ^State, split_secondary: bool) -> (intent: Intent, ok: bool) {
	selected_entry := current_entry(state)
	if selected_entry == nil { return nil, false }

	path_parts := [2]string{state.current_working_directory, selected_entry.name}
	joined_path, _ := filepath.join(path_parts[:], context.temp_allocator)
	full_path, _   := filepath.clean(joined_path, context.temp_allocator)
	cloned_path := strings.clone(full_path, context.temp_allocator)

	if selected_entry.is_dir {
		return OpenDirectory{ path = cloned_path }, true
	}
	return OpenFile{ path = cloned_path, split_secondary = split_secondary }, true
}

@(private)
entry_source_less :: proc(first, second: EntrySource) -> bool {
	if first.is_dir != second.is_dir { return first.is_dir }
	return first.name < second.name
}

@(private)
sort_entry_sources :: proc(sources: []EntrySource) {
	slice.sort_by(sources, entry_source_less)
}

