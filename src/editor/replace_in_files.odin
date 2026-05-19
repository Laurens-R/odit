package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import "../document"
import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
ReplaceInFilesFocus :: enum {
	PathInput,
	SearchInput,
	ReplaceInput,
	FindAllButton,
	ReplaceNextButton,
	ReplaceAllButton,
	ClearButton,
	CancelButton,
	Results,
}

@(private)
ReplaceInFilesStatus :: enum {
	Pending,  // matched but not yet replaced — drawn normally
	Replaced, // committed to disk — drawn with a green row tint
}

// One pending or completed replacement. `column` and `match_length` are byte
// offsets within `line`. After a per-match replacement we update the columns
// of any other Pending matches on the same line so subsequent operations land
// on the right bytes; the line itself is fixed (the replace text is forbidden
// from containing newlines, so line numbers never shift).
@(private)
ReplaceInFilesResult :: struct {
	file_path:     string, // absolute, owned
	relative_path: string, // owned
	line:          u32,
	column:        u32,    // byte column within the line at the time of match
	match_length:  u32,    // bytes the match consumes (variable for glob queries)
	snippet:       string, // owned, sanitized for display — frozen at scan time
	status:        ReplaceInFilesStatus,
}

@(private)
ReplaceInFilesState :: struct {
	focus:             ReplaceInFilesFocus,
	path_buffer:       [dynamic]u8,
	search_buffer:     [dynamic]u8,
	replace_buffer:    [dynamic]u8,
	results:           [dynamic]ReplaceInFilesResult,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	error_message:     string, // owned
	max_prefix_chars:  int,    // see find_in_files.odin for the alignment scheme

	// After a Replace All run we surface a small confirmation popup over the
	// main dialog. Persists across frames; the user must dismiss it explicitly.
	show_completion:   bool,
	completion_count:  int,

	path_field_rectangle:           sdl3.FRect,
	search_field_rectangle:         sdl3.FRect,
	replace_field_rectangle:        sdl3.FRect,
	find_all_button_rectangle:      sdl3.FRect,
	replace_next_button_rectangle:  sdl3.FRect,
	replace_all_button_rectangle:   sdl3.FRect,
	clear_button_rectangle:         sdl3.FRect,
	cancel_button_rectangle:        sdl3.FRect,
	results_list_rectangle:         sdl3.FRect,
	completion_ok_button_rectangle: sdl3.FRect,
}

// Caps parallel the find-in-files dialog's. Intentionally separate constants
// so this dialog can tune them independently (e.g. lowering the file-size cap
// to keep destructive writes bounded).
@(private="file")
RIF_MAX_DEPTH         :: 12
@(private="file")
RIF_MAX_RESULTS       :: 5000
@(private="file")
RIF_MAX_FILE_BYTES    :: 4 * 1024 * 1024 // 4 MiB
@(private="file")
RIF_SNIPPET_MAX_BYTES :: 200
@(private="file")
RIF_SKIP_DIRS := [?]string{
	".git", "node_modules", "target", "build", "dist", ".cache", ".idea", ".vscode", "out",
}

// --- Lifecycle -------------------------------------------------------------

@(private)
replace_in_files_destroy :: proc(state: ^ReplaceInFilesState) {
	delete(state.path_buffer)
	delete(state.search_buffer)
	delete(state.replace_buffer)
	replace_in_files_clear_results_internal(state)
	delete(state.results)
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = ReplaceInFilesState{}
}

@(private="file")
replace_in_files_clear_results_internal :: proc(state: ^ReplaceInFilesState) {
	for result in state.results {
		if len(result.file_path)     > 0 { delete(result.file_path)     }
		if len(result.relative_path) > 0 { delete(result.relative_path) }
		if len(result.snippet)       > 0 { delete(result.snippet)       }
	}
	clear(&state.results)
}

@(private="file")
replace_in_files_clear_error :: proc(editor: ^Editor) {
	if len(editor.replace_in_files.error_message) > 0 {
		delete(editor.replace_in_files.error_message)
		editor.replace_in_files.error_message = ""
	}
}

@(private="file")
replace_in_files_set_error :: proc(editor: ^Editor, message: string) {
	replace_in_files_clear_error(editor)
	editor.replace_in_files.error_message = strings.clone(message)
}

@(private)
replace_in_files_open :: proc(editor: ^Editor) {
	state := &editor.replace_in_files
	replace_in_files_clear_error(editor)

	// Same persistence model as Find-in-Files: keep path/search/replace and
	// the result list intact across close→reopen so the user can leave to
	// inspect a hit (e.g. after Replace Next) and come back.
	if len(state.path_buffer) == 0 {
		default_path := replace_in_files_default_path(editor)
		for byte_value in transmute([]u8)default_path { append(&state.path_buffer, byte_value) }
	}

	// Override any prior search query when the user has a selection — this is
	// almost always what they meant by "select X, hit Ctrl+Shift+R".
	if editor_pane := editor_active_editor_pane(editor); editor_pane != nil && editor_pane.selection_active {
		low_offset, high_offset, has_selection := editor_pane_selection_range(editor_pane)
		if has_selection && high_offset - low_offset <= 256 {
			selection_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
			contains_newline := false
			for byte_value in transmute([]u8)selection_text {
				if byte_value == '\n' { contains_newline = true; break }
			}
			if !contains_newline {
				clear(&state.search_buffer)
				for byte_value in transmute([]u8)selection_text { append(&state.search_buffer, byte_value) }
			}
		}
	}

	// Land on the results when we have some, otherwise on the search field
	// (which is the field the user almost always needs to touch first).
	state.focus = len(state.results) > 0 ? .Results : .SearchInput

	editor.show_replace_in_files = true
}

@(private)
replace_in_files_close :: proc(editor: ^Editor) {
	editor.show_replace_in_files = false
	editor.replace_in_files.show_completion = false
}

// Empty every input field and the result list — invoked by the Clear button.
// Drops focus back to the path so the user can start from scratch.
@(private="file")
replace_in_files_clear_action :: proc(editor: ^Editor) {
	state := &editor.replace_in_files
	clear(&state.search_buffer)
	clear(&state.replace_buffer)
	replace_in_files_clear_results_internal(state)
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = 0
	replace_in_files_clear_error(editor)
	state.focus = .PathInput
}

@(private="file")
replace_in_files_default_path :: proc(editor: ^Editor) -> string {
	if len(editor.project_root) > 0 { return editor.project_root }
	if editor_pane := editor_active_editor_pane(editor); editor_pane != nil && len(editor_pane.file_path) > 0 {
		return os.dir(editor_pane.file_path)
	}
	working_directory, get_directory_error := os.get_working_directory(context.temp_allocator)
	if get_directory_error != nil { return "." }
	return working_directory
}

// --- Focus ---------------------------------------------------------------

@(private="file")
replace_in_files_focus_next :: proc(state: ^ReplaceInFilesState) {
	switch state.focus {
	case .PathInput:         state.focus = .SearchInput
	case .SearchInput:       state.focus = .ReplaceInput
	case .ReplaceInput:      state.focus = .FindAllButton
	case .FindAllButton:     state.focus = .ReplaceNextButton
	case .ReplaceNextButton: state.focus = .ReplaceAllButton
	case .ReplaceAllButton:  state.focus = .ClearButton
	case .ClearButton:       state.focus = .CancelButton
	case .CancelButton:      state.focus = .Results
	case .Results:           state.focus = .PathInput
	}
}

@(private="file")
replace_in_files_focus_prev :: proc(state: ^ReplaceInFilesState) {
	switch state.focus {
	case .PathInput:         state.focus = .Results
	case .SearchInput:       state.focus = .PathInput
	case .ReplaceInput:      state.focus = .SearchInput
	case .FindAllButton:     state.focus = .ReplaceInput
	case .ReplaceNextButton: state.focus = .FindAllButton
	case .ReplaceAllButton:  state.focus = .ReplaceNextButton
	case .ClearButton:       state.focus = .ReplaceAllButton
	case .CancelButton:      state.focus = .ClearButton
	case .Results:           state.focus = .CancelButton
	}
}

// --- Find All (recursive search) ------------------------------------------

@(private="file")
replace_in_files_find_all :: proc(editor: ^Editor) {
	state := &editor.replace_in_files
	replace_in_files_clear_results_internal(state)
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = 0
	replace_in_files_clear_error(editor)

	query_string := string(state.search_buffer[:])
	if len(query_string) == 0 {
		replace_in_files_set_error(editor, "Enter a search query")
		return
	}

	path_string := string(state.path_buffer[:])
	if len(path_string) == 0 {
		replace_in_files_set_error(editor, "Enter a search path")
		return
	}

	cleaned_path, _ := filepath.clean(path_string, context.temp_allocator)
	file_info, stat_error := os.stat(cleaned_path, context.temp_allocator)
	if stat_error != nil {
		replace_in_files_set_error(editor, fmt.tprintf("Cannot access path: %v", stat_error))
		return
	}

	query_bytes := transmute([]u8)query_string
	if file_info.type == .Directory {
		replace_in_files_walk(editor, cleaned_path, "", 0, query_bytes)
	} else {
		replace_in_files_scan_file(editor, cleaned_path, file_info.name, query_bytes)
	}

	state.max_prefix_chars = compute_max_prefix_chars(state.results[:])

	if len(state.results) > 0 {
		state.focus = .Results
	}
}

@(private="file")
replace_in_files_walk :: proc(editor: ^Editor, root_directory, sub_relative_path: string, current_depth: int, query_bytes: []u8) {
	state := &editor.replace_in_files
	if current_depth > RIF_MAX_DEPTH         { return }
	if len(state.results) >= RIF_MAX_RESULTS { return }

	full_directory: string
	if len(sub_relative_path) == 0 {
		full_directory = root_directory
	} else {
		full_directory = strings.concatenate({root_directory, "/", sub_relative_path}, context.temp_allocator)
	}

	directory_entries, read_directory_error := os.read_all_directory_by_path(full_directory, context.temp_allocator)
	if read_directory_error != nil { return }

	for entry_info in directory_entries {
		if len(state.results) >= RIF_MAX_RESULTS              { return }
		if entry_info.name == "." || entry_info.name == ".."  { continue }

		entry_relative_path: string
		if len(sub_relative_path) == 0 {
			entry_relative_path = entry_info.name
		} else {
			entry_relative_path = strings.concatenate({sub_relative_path, "/", entry_info.name}, context.temp_allocator)
		}

		if entry_info.type == .Directory {
			if rif_skip_dir(entry_info.name) { continue }
			replace_in_files_walk(editor, root_directory, entry_relative_path, current_depth + 1, query_bytes)
		} else if entry_info.type == .Regular || entry_info.type == .Symlink {
			full_file_path := strings.concatenate({root_directory, "/", entry_relative_path}, context.temp_allocator)
			replace_in_files_scan_file(editor, full_file_path, entry_relative_path, query_bytes)
		}
	}
}

@(private="file")
rif_skip_dir :: proc(directory_name: string) -> bool {
	if strings.has_prefix(directory_name, ".") { return true }
	for skipped in RIF_SKIP_DIRS {
		if directory_name == skipped { return true }
	}
	return false
}

@(private="file")
replace_in_files_scan_file :: proc(editor: ^Editor, full_file_path, relative_path: string, query_bytes: []u8) {
	state := &editor.replace_in_files
	file_data, read_error := os.read_entire_file_from_path(full_file_path, context.temp_allocator)
	if read_error != nil                    { return }
	if len(file_data) > RIF_MAX_FILE_BYTES  { return }

	check_byte_count := min(len(file_data), 1024)
	for byte_index in 0..<check_byte_count {
		if file_data[byte_index] == 0 { return }
	}

	line_index: u32 = 0
	line_start := 0
	current_end := 0
	for {
		is_terminator := current_end == len(file_data) || file_data[current_end] == '\n'
		if !is_terminator {
			current_end += 1
			continue
		}

		line_bytes := file_data[line_start:current_end]
		if len(line_bytes) > 0 && line_bytes[len(line_bytes)-1] == '\r' {
			line_bytes = line_bytes[:len(line_bytes)-1]
		}

		search_position := 0
		for search_position <= len(line_bytes) {
			if len(state.results) >= RIF_MAX_RESULTS { return }
			consumed_byte_count, matched := glob_match_at(line_bytes[search_position:], query_bytes)
			if !matched {
				search_position += 1
				continue
			}

			snippet_bytes := line_bytes
			if len(snippet_bytes) > RIF_SNIPPET_MAX_BYTES { snippet_bytes = snippet_bytes[:RIF_SNIPPET_MAX_BYTES] }

			append(&state.results, ReplaceInFilesResult{
				file_path     = strings.clone(full_file_path),
				relative_path = strings.clone(relative_path),
				line          = line_index,
				column        = u32(search_position),
				match_length  = u32(consumed_byte_count),
				snippet       = sanitize_snippet(snippet_bytes),
				status        = .Pending,
			})

			advance_step := consumed_byte_count
			if advance_step < 1 { advance_step = 1 }
			search_position += advance_step
		}

		if current_end == len(file_data) { break }
		line_index += 1
		current_end += 1
		line_start = current_end
	}
}

// Recompute the snippet-column alignment width over the full result set.
// Called after Find All and after Replace All (which may shift columns).
@(private="file")
compute_max_prefix_chars :: proc(results: []ReplaceInFilesResult) -> int {
	max_prefix_chars := 0
	for result in results {
		prefix_chars := utf8.rune_count_in_string(result.relative_path) + 2 +
			digit_count_u32(result.line   + 1) +
			digit_count_u32(result.column + 1)
		if prefix_chars > max_prefix_chars { max_prefix_chars = prefix_chars }
	}
	return max_prefix_chars
}

// --- Replace operations --------------------------------------------------

// Find a line's byte offset within `file_data`. Returns -1 if the file has
// fewer than `line_index + 1` lines.
@(private="file")
find_line_start_offset_in_bytes :: proc(file_data: []byte, line_index: u32) -> int {
	if line_index == 0 { return 0 }
	current_line: u32 = 0
	for byte_index in 0..<len(file_data) {
		if file_data[byte_index] == '\n' {
			current_line += 1
			if current_line == line_index { return byte_index + 1 }
		}
	}
	return -1
}

@(private="file")
replace_in_files_replace_next :: proc(editor: ^Editor) {
	state := &editor.replace_in_files
	replace_in_files_clear_error(editor)

	if len(state.results) == 0 { return }

	// Pick the currently selected entry if it's Pending, otherwise the first
	// Pending entry in document order. This keeps the operation predictable
	// regardless of whether the user is just clicking the button repeatedly
	// or navigating to a specific row first.
	target_index := -1
	if state.selected_index >= 0 && state.selected_index < len(state.results) &&
		state.results[state.selected_index].status == .Pending {
		target_index = state.selected_index
	}
	if target_index < 0 {
		for result_value, result_index in state.results {
			if result_value.status == .Pending { target_index = result_index; break }
		}
	}
	if target_index < 0 { return } // nothing left to do

	if !replace_in_files_apply_single(editor, target_index) { return }

	// Advance selection to the next Pending entry so the user can keep
	// hammering Replace Next without moving the mouse.
	next_pending_index := -1
	for candidate_index := target_index + 1; candidate_index < len(state.results); candidate_index += 1 {
		if state.results[candidate_index].status == .Pending { next_pending_index = candidate_index; break }
	}
	if next_pending_index < 0 {
		// Wrap to the first Pending earlier in the list; if there are none,
		// stay on the just-replaced row so the green tint is still visible.
		for candidate_index in 0..<target_index {
			if state.results[candidate_index].status == .Pending { next_pending_index = candidate_index; break }
		}
	}
	if next_pending_index >= 0 {
		state.selected_index = next_pending_index
	} else {
		state.selected_index = target_index
	}

	if state.visible_row_count > 0 {
		if state.selected_index < state.scroll_offset {
			state.scroll_offset = state.selected_index
		} else if state.selected_index >= state.scroll_offset + state.visible_row_count {
			state.scroll_offset = state.selected_index - state.visible_row_count + 1
		}
		if state.scroll_offset < 0 { state.scroll_offset = 0 }
	}
}

// Apply a single result's replacement: read the file, splice in the new bytes
// at the match offset, write it back, then shift the columns of any other
// Pending matches on the same line so subsequent replacements aim correctly.
@(private="file")
replace_in_files_apply_single :: proc(editor: ^Editor, result_index: int) -> bool {
	state := &editor.replace_in_files
	result := &state.results[result_index]
	if result.status != .Pending { return false }

	replace_text := string(state.replace_buffer[:])

	file_data, read_error := os.read_entire_file_from_path(result.file_path, context.allocator)
	if read_error != nil {
		replace_in_files_set_error(editor, fmt.tprintf("Cannot read %s: %v", result.relative_path, read_error))
		return false
	}
	defer delete(file_data)

	line_start_offset := find_line_start_offset_in_bytes(file_data, result.line)
	if line_start_offset < 0 {
		replace_in_files_set_error(editor, fmt.tprintf("Stale match: %s no longer has line %d", result.relative_path, result.line + 1))
		return false
	}

	match_offset := line_start_offset + int(result.column)
	match_end    := match_offset + int(result.match_length)
	if match_end > len(file_data) {
		replace_in_files_set_error(editor, fmt.tprintf("Stale match in %s", result.relative_path))
		return false
	}

	new_size := len(file_data) - int(result.match_length) + len(replace_text)
	new_content := make([]byte, new_size, context.temp_allocator)
	copy(new_content[:match_offset],                                file_data[:match_offset])
	copy(new_content[match_offset:match_offset + len(replace_text)], transmute([]u8)replace_text)
	copy(new_content[match_offset + len(replace_text):],            file_data[match_end:])

	write_error := os.write_entire_file(result.file_path, new_content)
	if write_error != nil {
		replace_in_files_set_error(editor, fmt.tprintf("Cannot write %s: %v", result.relative_path, write_error))
		return false
	}

	result.status = .Replaced

	// Shift columns of other Pending matches on the same line so the next
	// replacement still lands on the right bytes. Replace text can't contain
	// newlines (input filter strips them), so other lines are unaffected.
	delta := i32(len(replace_text)) - i32(result.match_length)
	if delta != 0 {
		for &other_result in state.results {
			if other_result.status   != .Pending          { continue }
			if other_result.file_path != result.file_path { continue }
			if other_result.line      != result.line      { continue }
			if other_result.column > result.column {
				other_result.column = u32(i32(other_result.column) + delta)
			}
		}
	}

	return true
}

// Replace All: process the result list one file at a time, splicing all of
// the file's Pending matches in one read/write cycle. Results are appended in
// scan order so all entries for a single file sit in a contiguous block — we
// just walk those blocks. Surfaces a confirmation popup with the total.
@(private="file")
replace_in_files_replace_all :: proc(editor: ^Editor) {
	state := &editor.replace_in_files
	replace_in_files_clear_error(editor)
	if len(state.results) == 0 { return }

	replace_text := string(state.replace_buffer[:])
	total_replacements := 0

	group_start := 0
	for group_start < len(state.results) {
		current_file_path := state.results[group_start].file_path
		group_end := group_start + 1
		for group_end < len(state.results) && state.results[group_end].file_path == current_file_path {
			group_end += 1
		}

		applied_count := replace_in_files_apply_file_group(editor, group_start, group_end, replace_text)
		total_replacements += applied_count

		group_start = group_end
	}

	// Columns inside Replaced rows still reflect their original positions in
	// the file (we don't track post-replace offsets — they're meaningless for
	// rows the user can't act on anymore). The alignment width only depends
	// on relative_path + line + column digits, so it's stable here, but call
	// the recompute anyway in case a future change makes the prefix dynamic.
	state.max_prefix_chars = compute_max_prefix_chars(state.results[:])

	state.show_completion  = true
	state.completion_count = total_replacements
}

@(private="file")
replace_in_files_apply_file_group :: proc(editor: ^Editor, group_start, group_end: int, replace_text: string) -> int {
	state := &editor.replace_in_files
	if group_start >= group_end { return 0 }

	current_file_path := state.results[group_start].file_path

	file_data, read_error := os.read_entire_file_from_path(current_file_path, context.allocator)
	if read_error != nil { return 0 }
	defer delete(file_data)

	// Collect splice ranges for every Pending match in this file, indexed by
	// the corresponding result so we can mark them Replaced on success.
	Splice :: struct { offset: int, end: int }
	splices_to_apply: [dynamic]Splice
	splices_to_apply.allocator = context.temp_allocator
	pending_indices_for_group: [dynamic]int
	pending_indices_for_group.allocator = context.temp_allocator

	for result_index in group_start..<group_end {
		if state.results[result_index].status != .Pending { continue }
		current_result := state.results[result_index]
		line_start_offset := find_line_start_offset_in_bytes(file_data, current_result.line)
		if line_start_offset < 0 { continue }
		match_offset := line_start_offset + int(current_result.column)
		match_end    := match_offset + int(current_result.match_length)
		if match_end > len(file_data) { continue }
		append(&splices_to_apply, Splice{offset = match_offset, end = match_end})
		append(&pending_indices_for_group, result_index)
	}

	if len(splices_to_apply) == 0 { return 0 }

	// Splices come out in ascending order (results are appended in scan order
	// of line, column). Concatenate the surviving runs around them.
	new_size := len(file_data)
	for splice_value in splices_to_apply {
		new_size -= (splice_value.end - splice_value.offset)
		new_size += len(replace_text)
	}
	new_content := make([]byte, new_size, context.temp_allocator)
	last_end := 0
	write_position := 0
	for splice_value in splices_to_apply {
		preserved_chunk_length := splice_value.offset - last_end
		copy(new_content[write_position:write_position + preserved_chunk_length], file_data[last_end:splice_value.offset])
		write_position += preserved_chunk_length
		copy(new_content[write_position:write_position + len(replace_text)], transmute([]u8)replace_text)
		write_position += len(replace_text)
		last_end = splice_value.end
	}
	trailing_chunk_length := len(file_data) - last_end
	copy(new_content[write_position:write_position + trailing_chunk_length], file_data[last_end:])

	write_error := os.write_entire_file(current_file_path, new_content)
	if write_error != nil {
		replace_in_files_set_error(editor, fmt.tprintf("Cannot write %s: %v", state.results[group_start].relative_path, write_error))
		return 0
	}

	for result_index in pending_indices_for_group {
		state.results[result_index].status = .Replaced
	}
	return len(pending_indices_for_group)
}

// --- Navigation ----------------------------------------------------------

@(private="file")
replace_in_files_move_selection :: proc(editor: ^Editor, delta: int) {
	state := &editor.replace_in_files
	result_count := len(state.results)
	if result_count == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0             { new_index = 0 }
	if new_index >= result_count { new_index = result_count - 1 }
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

// --- Text editing --------------------------------------------------------

@(private="file")
replace_in_files_focused_buffer :: proc(editor: ^Editor) -> ^[dynamic]u8 {
	switch editor.replace_in_files.focus {
	case .PathInput:    return &editor.replace_in_files.path_buffer
	case .SearchInput:  return &editor.replace_in_files.search_buffer
	case .ReplaceInput: return &editor.replace_in_files.replace_buffer
	case .FindAllButton, .ReplaceNextButton, .ReplaceAllButton, .ClearButton, .CancelButton, .Results:
		return nil
	}
	return nil
}

@(private="file")
replace_in_files_buffer_backspace :: proc(buffer: ^[dynamic]u8) {
	length := len(buffer^)
	if length == 0 { return }
	new_end := length - 1
	for new_end > 0 && ((buffer^)[new_end] & 0xC0) == 0x80 { new_end -= 1 }
	resize(buffer, new_end)
}

// --- Event handling ------------------------------------------------------

@(private)
replace_in_files_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	state := &editor.replace_in_files

	// The completion popup is its own modal layer — it intercepts every event
	// while shown so the user can't accidentally re-run Replace All from a
	// stray key press.
	if state.show_completion {
		#partial switch event.type {
		case .KEY_DOWN:
			pressed_key := event.key.key
			if pressed_key == sdl3.K_RETURN || pressed_key == sdl3.K_ESCAPE || pressed_key == sdl3.K_SPACE {
				state.show_completion = false
			}
		case .MOUSE_BUTTON_DOWN:
			if event.button.button == sdl3.BUTTON_LEFT {
				if ui.point_in_rect(state.completion_ok_button_rectangle, event.button.x, event.button.y) {
					state.show_completion = false
				}
			}
		}
		return
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		if buffer := replace_in_files_focused_buffer(editor); buffer != nil {
			input_text := string(event.text.text)
			for byte_value in transmute([]u8)input_text {
				// Newlines are illegal in any of the three input fields. In
				// the Replace field they would invalidate every other Pending
				// match's line/column offsets after a single replace.
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(buffer, byte_value)
			}
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		if ctrl_held && shift_held && pressed_key == sdl3.K_R {
			replace_in_files_close(editor)
			return
		}

		switch pressed_key {
		case sdl3.K_ESCAPE:
			replace_in_files_close(editor)

		case sdl3.K_TAB:
			if shift_held { replace_in_files_focus_prev(state) } else { replace_in_files_focus_next(state) }

		case sdl3.K_RETURN:
			// The intended flow is Find All → (Replace Next | Replace All).
			// Enter from any input or the Find All button runs Find All; the
			// replace buttons trigger their own actions. From the results
			// list, Enter is a quality-of-life shortcut for "replace this
			// specific entry now".
			switch state.focus {
			case .PathInput, .SearchInput, .ReplaceInput, .FindAllButton:
				replace_in_files_find_all(editor)
			case .ReplaceNextButton:
				replace_in_files_replace_next(editor)
			case .ReplaceAllButton:
				replace_in_files_replace_all(editor)
			case .ClearButton:
				replace_in_files_clear_action(editor)
			case .CancelButton:
				replace_in_files_close(editor)
			case .Results:
				replace_in_files_replace_next(editor)
			}

		case sdl3.K_BACKSPACE:
			if buffer := replace_in_files_focused_buffer(editor); buffer != nil {
				replace_in_files_buffer_backspace(buffer)
			}

		case sdl3.K_UP:       if state.focus == .Results { replace_in_files_move_selection(editor, -1) }
		case sdl3.K_DOWN:     if state.focus == .Results { replace_in_files_move_selection(editor, +1) }
		case sdl3.K_PAGEUP:
			if state.focus == .Results {
				step := state.visible_row_count;  if step < 1 { step = 1 }
				replace_in_files_move_selection(editor, -step)
			}
		case sdl3.K_PAGEDOWN:
			if state.focus == .Results {
				step := state.visible_row_count;  if step < 1 { step = 1 }
				replace_in_files_move_selection(editor, +step)
			}
		case sdl3.K_HOME: if state.focus == .Results { replace_in_files_move_selection(editor, -len(state.results)) }
		case sdl3.K_END:  if state.focus == .Results { replace_in_files_move_selection(editor, +len(state.results)) }
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.path_field_rectangle,           mouse_x, mouse_y):
			state.focus = .PathInput
		case ui.point_in_rect(state.search_field_rectangle,         mouse_x, mouse_y):
			state.focus = .SearchInput
		case ui.point_in_rect(state.replace_field_rectangle,        mouse_x, mouse_y):
			state.focus = .ReplaceInput
		case ui.point_in_rect(state.find_all_button_rectangle,      mouse_x, mouse_y):
			state.focus = .FindAllButton
			replace_in_files_find_all(editor)
		case ui.point_in_rect(state.replace_next_button_rectangle,  mouse_x, mouse_y):
			state.focus = .ReplaceNextButton
			replace_in_files_replace_next(editor)
		case ui.point_in_rect(state.replace_all_button_rectangle,   mouse_x, mouse_y):
			state.focus = .ReplaceAllButton
			replace_in_files_replace_all(editor)
		case ui.point_in_rect(state.clear_button_rectangle,         mouse_x, mouse_y):
			state.focus = .ClearButton
			replace_in_files_clear_action(editor)
		case ui.point_in_rect(state.cancel_button_rectangle,        mouse_x, mouse_y):
			state.focus = .CancelButton
			replace_in_files_close(editor)
		case ui.point_in_rect(state.results_list_rectangle,         mouse_x, mouse_y):
			state.focus = .Results
			// Clicking a row only selects it; the user still has to press
			// Replace Next / Replace All to mutate anything. The list is
			// described in the spec as "a way to assess the impact" before
			// committing — don't surprise the user with a destructive action
			// behind a single click.
			if editor.line_height > 0 {
				row_height := f32(editor.line_height)
				relative_y := mouse_y - state.results_list_rectangle.y
				if relative_y >= 0 {
					row_index_in_view := int(relative_y / row_height)
					target_index := state.scroll_offset + row_index_in_view
					if target_index >= 0 && target_index < len(state.results) {
						state.selected_index = target_index
					}
				}
			}
		}

	case .MOUSE_WHEEL:
		if state.visible_row_count > 0 && len(state.results) > 0 {
			scroll_delta := -int(event.wheel.y * 3)
			max_offset   := max(0, len(state.results) - state.visible_row_count)
			new_offset   := state.scroll_offset + scroll_delta
			if new_offset < 0          { new_offset = 0 }
			if new_offset > max_offset { new_offset = max_offset }
			state.scroll_offset = new_offset
		}
	}
}

// --- Rendering -----------------------------------------------------------

@(private)
replace_in_files_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	state := &editor.replace_in_files

	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	// Slightly larger than the find-in-files dialog — we have three input
	// fields and four buttons to fit above the result list.
	desired_columns: i32 = 110
	desired_rows:    i32 = 40
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows    * editor.line_height     + 40, viewport_height - 40)
	if dialog_width  < 280 { dialog_width  = min(viewport_width  - 16, 280) }
	if dialog_height < 280 { dialog_height = min(viewport_height - 16, 280) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Replace in Files", theme)

	line_step     := editor.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	// Three input fields stacked.
	state.path_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Path:    ", string(state.path_buffer[:]),    theme, state.focus == .PathInput)
	content_y += line_step + 14

	state.search_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Search:  ", string(state.search_buffer[:]),  theme, state.focus == .SearchInput)
	content_y += line_step + 14

	state.replace_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Replace: ", string(state.replace_buffer[:]), theme, state.focus == .ReplaceInput)
	content_y += line_step + 14

	// Five-button row. The replace buttons are wider so their longer labels fit.
	standard_button_width: i32 = 14 * editor.character_width
	replace_button_width:  i32 = 18 * editor.character_width
	button_height:         i32 = line_step + 12
	button_gap:            i32 = 8
	buttons_total_width := standard_button_width + replace_button_width + replace_button_width + standard_button_width + standard_button_width + button_gap * 4
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2

	current_x := buttons_start_x
	state.find_all_button_rectangle     = sdl3.FRect{f32(current_x), f32(content_y), f32(standard_button_width), f32(button_height)}
	current_x += standard_button_width + button_gap
	state.replace_next_button_rectangle = sdl3.FRect{f32(current_x), f32(content_y), f32(replace_button_width),  f32(button_height)}
	current_x += replace_button_width + button_gap
	state.replace_all_button_rectangle  = sdl3.FRect{f32(current_x), f32(content_y), f32(replace_button_width),  f32(button_height)}
	current_x += replace_button_width + button_gap
	state.clear_button_rectangle        = sdl3.FRect{f32(current_x), f32(content_y), f32(standard_button_width), f32(button_height)}
	current_x += standard_button_width + button_gap
	state.cancel_button_rectangle       = sdl3.FRect{f32(current_x), f32(content_y), f32(standard_button_width), f32(button_height)}

	ui.draw_button(&ui_context, state.find_all_button_rectangle,     "Find All",     state.focus == .FindAllButton,     theme)
	ui.draw_button(&ui_context, state.replace_next_button_rectangle, "Replace Next", state.focus == .ReplaceNextButton, theme)
	ui.draw_button(&ui_context, state.replace_all_button_rectangle,  "Replace All",  state.focus == .ReplaceAllButton,  theme)
	ui.draw_button(&ui_context, state.clear_button_rectangle,        "Clear",        state.focus == .ClearButton,       theme)
	ui.draw_button(&ui_context, state.cancel_button_rectangle,       "Cancel",       state.focus == .CancelButton,      theme)

	content_y += button_height + 12

	if len(state.error_message) > 0 {
		ui.draw_text(&ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_step + 4
	}

	// Results viewport
	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	if list_area_height < line_step { list_area_height = line_step }
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	state.results_list_rectangle = sdl3.FRect{f32(content_x), f32(list_top_y), f32(content_width), f32(list_area_height)}

	max_scroll_offset := max(0, len(state.results) - computed_visible_rows)
	if state.scroll_offset > max_scroll_offset { state.scroll_offset = max_scroll_offset }
	if state.scroll_offset < 0                 { state.scroll_offset = 0 }

	if len(state.results) == 0 {
		empty_message: string
		if len(state.search_buffer) == 0 {
			empty_message = "(enter search & replace text, then press Find All)"
		} else if len(state.error_message) == 0 {
			empty_message = "(no results — press Find All)"
		}
		if len(empty_message) > 0 {
			ui.draw_text(&ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
		}
	} else {
		replace_in_files_render_result_rows(editor, &ui_context, content_x, list_top_y, content_width, line_step, computed_visible_rows, theme)
	}

	// Footer hints (left) + counters (right).
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	hint_text := "Tab focus  Enter find-all / replace-next  ↑/↓ navigate  Esc close"
	ui.draw_text(&ui_context, hint_text, i32(dialog_rectangle.x) + 12, footer_y, theme.dim_foreground)

	if len(state.results) > 0 {
		pending_count, replaced_count := 0, 0
		for result_value in state.results {
			switch result_value.status {
			case .Pending:  pending_count  += 1
			case .Replaced: replaced_count += 1
			}
		}
		counter_text: string
		if len(state.results) >= RIF_MAX_RESULTS {
			counter_text = fmt.tprintf("%d+ matches  (pending %d, replaced %d)", len(state.results), pending_count, replaced_count)
		} else {
			counter_text = fmt.tprintf("%d matches  (pending %d, replaced %d)", len(state.results), pending_count, replaced_count)
		}
		counter_width, _ := ui.text_size(&ui_context, counter_text)
		counter_x := i32(dialog_rectangle.x + dialog_rectangle.w) - 12 - counter_width
		ui.draw_text(&ui_context, counter_text, counter_x, footer_y, theme.dim_foreground)
	}

	// Completion popup overlays everything else when shown.
	if state.show_completion {
		replace_in_files_render_completion_popup(editor, &ui_context, viewport_width, viewport_height, theme)
	}
}

// Per-row painter. Mirrors the find-in-files alignment + truncation scheme,
// plus a green tint on rows whose status is `.Replaced`. We bypass
// `ui.draw_list_row` so we can compose multiple background layers — selection
// fill, replaced-row tint, accent stripe — in the right order.
@(private="file")
replace_in_files_render_result_rows :: proc(
	editor: ^Editor, ui_context: ^ui.Context,
	content_x, list_top_y, content_width, line_step: i32,
	computed_visible_rows: int, theme: ui.Theme,
) {
	state := &editor.replace_in_files

	label_indent_pixels: i32 = 8
	right_margin_pixels: i32 = 8
	usable_pixels := content_width - label_indent_pixels - right_margin_pixels
	if usable_pixels < editor.character_width { usable_pixels = editor.character_width }
	max_chars_per_row := int(usable_pixels / editor.character_width)

	padded_prefix_chars := state.max_prefix_chars + 2
	if padded_prefix_chars > max_chars_per_row - 8 { padded_prefix_chars = max_chars_per_row - 8 }
	if padded_prefix_chars < 1                     { padded_prefix_chars = 1 }

	// Soft green for replaced rows. Alpha-blended so it tints both unselected
	// and selected backgrounds without obliterating the selection cue.
	replaced_row_tint     := sdl3.FColor{0.20, 0.55, 0.30, 0.35}
	replaced_label_color  := sdl3.FColor{0.60, 0.95, 0.65, 1.00}

	end_row_index := min(state.scroll_offset + computed_visible_rows, len(state.results))
	for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
		result := state.results[row_index]
		row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
		is_selected := row_index == state.selected_index && state.focus == .Results

		// 1. Selection background (solid)
		if is_selected {
			selection_background_rectangle := sdl3.FRect{f32(content_x), f32(row_y_position), f32(content_width), f32(line_step)}
			sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.title_background.r, theme.title_background.g, theme.title_background.b, theme.title_background.a)
			sdl3.RenderFillRect(ui_context.renderer, &selection_background_rectangle)
		}

		// 2. Green tint overlay for replaced rows (blended over whatever is there)
		if result.status == .Replaced {
			tint_rectangle := sdl3.FRect{f32(content_x), f32(row_y_position), f32(content_width), f32(line_step)}
			sdl3.SetRenderDrawBlendMode(ui_context.renderer, sdl3.BLENDMODE_BLEND)
			sdl3.SetRenderDrawColorFloat(ui_context.renderer, replaced_row_tint.r, replaced_row_tint.g, replaced_row_tint.b, replaced_row_tint.a)
			sdl3.RenderFillRect(ui_context.renderer, &tint_rectangle)
			sdl3.SetRenderDrawBlendMode(ui_context.renderer, sdl3.BLENDMODE_NONE)
		}

		// 3. Selection accent stripe along the left edge
		if is_selected {
			stripe_rectangle := sdl3.FRect{f32(content_x), f32(row_y_position), 2, f32(line_step)}
			sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
			sdl3.RenderFillRect(ui_context.renderer, &stripe_rectangle)
		}

		// 4. Row label — aligned + truncated like find-in-files
		prefix_string := fmt.tprintf("%s:%d:%d", result.relative_path, result.line + 1, result.column + 1)
		prefix_chars := utf8.rune_count_in_string(prefix_string)
		padding_chars := padded_prefix_chars - prefix_chars
		if padding_chars < 1 { padding_chars = 1 }
		padding_string := strings.repeat(" ", padding_chars, context.temp_allocator)

		combined_row := strings.concatenate({prefix_string, padding_string, result.snippet}, context.temp_allocator)
		row_label := truncate_to_runes_with_ellipsis(combined_row, max_chars_per_row)

		text_color := is_selected ? theme.title_foreground : theme.text_foreground
		if result.status == .Replaced { text_color = replaced_label_color }
		ui.draw_text(ui_context, row_label, content_x + label_indent_pixels, row_y_position, text_color)
	}
}

@(private="file")
replace_in_files_render_completion_popup :: proc(
	editor: ^Editor, parent_ui_context: ^ui.Context,
	viewport_width, viewport_height: i32, theme: ui.Theme,
) {
	state := &editor.replace_in_files

	// Extra dim layer on top of the main dialog so the popup visually dominates.
	ui.draw_dim_overlay(parent_ui_context, viewport_width, viewport_height, theme.overlay)

	popup_width  := min(50 * editor.character_width + 32, viewport_width  - 80)
	popup_height := min( 8 * editor.line_height     + 40, viewport_height - 80)
	if popup_width  < 280 { popup_width  = min(viewport_width  - 16, 280) }
	if popup_height < 160 { popup_height = min(viewport_height - 16, 160) }
	popup_x := (viewport_width  - popup_width)  / 2
	popup_y := (viewport_height - popup_height) / 2
	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}

	content_rectangle := ui.draw_window(parent_ui_context, popup_rectangle, "Replace All", theme)

	line_step    := editor.line_height
	content_x    := i32(content_rectangle.x)
	content_y    := i32(content_rectangle.y) + line_step
	content_width := i32(content_rectangle.w)

	message := fmt.tprintf("A total of %d instance%s ha%s been replaced.",
		state.completion_count,
		state.completion_count == 1 ? ""  : "s",
		state.completion_count == 1 ? "s" : "ve")
	message_width, _ := ui.text_size(parent_ui_context, message)
	message_x := content_x + (content_width - message_width) / 2
	ui.draw_text(parent_ui_context, message, message_x, content_y, theme.text_foreground)

	button_width:  i32 = 14 * editor.character_width
	button_height: i32 = line_step + 12
	button_x := i32(popup_rectangle.x + (popup_rectangle.w - f32(button_width)) / 2)
	button_y := i32(popup_rectangle.y + popup_rectangle.h) - button_height - 14

	state.completion_ok_button_rectangle = sdl3.FRect{f32(button_x), f32(button_y), f32(button_width), f32(button_height)}
	ui.draw_button(parent_ui_context, state.completion_ok_button_rectangle, "OK", true, theme)
}
