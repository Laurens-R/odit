// Recursive directory walk + per-file scan + on-disk replacement
// engine. No editor coupling — uses `core:os` / `core:path/filepath`
// + the shared `textutil` helpers.
package replace_in_files

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

import "../textutil"

@(private)
RIF_MAX_DEPTH         :: 12
@(private)
RIF_MAX_RESULTS       :: 5000
@(private="file")
RIF_MAX_FILE_BYTES    :: 4 * 1024 * 1024 // 4 MiB
@(private="file")
RIF_SNIPPET_MAX_BYTES :: 200
@(private="file")
RIF_SKIP_DIRS := [?]string{
	".git", "node_modules", "target", "build", "dist", ".cache", ".idea", ".vscode", "out",
}

// Recompute the snippet-column alignment width over the full result
// set. Called after Find All and after Replace All (in case columns
// shift).
@(private)
compute_max_prefix_chars :: proc(results: []Result) -> int {
	max_prefix_chars := 0
	for result in results {
		prefix_chars := utf8.rune_count_in_string(result.relative_path) + 2 +
			textutil.digit_count_u32(result.line   + 1) +
			textutil.digit_count_u32(result.column + 1)
		if prefix_chars > max_prefix_chars { max_prefix_chars = prefix_chars }
	}
	return max_prefix_chars
}

@(private)
find_all :: proc(state: ^State) {
	clear_results_internal(state)
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = 0
	clear_error(state)

	query_string := string(state.search_buffer[:])
	if len(query_string) == 0 {
		set_error(state, "Enter a search query")
		return
	}

	path_string := string(state.path_buffer[:])
	if len(path_string) == 0 {
		set_error(state, "Enter a search path")
		return
	}

	cleaned_path, _ := filepath.clean(path_string, context.temp_allocator)
	file_info, stat_error := os.stat(cleaned_path, context.temp_allocator)
	if stat_error != nil {
		set_error(state, fmt.tprintf("Cannot access path: %v", stat_error))
		return
	}

	query_bytes := transmute([]u8)query_string
	if file_info.type == .Directory {
		walk(state, cleaned_path, "", 0, query_bytes)
	} else {
		scan_file(state, cleaned_path, file_info.name, query_bytes)
	}

	state.max_prefix_chars = compute_max_prefix_chars(state.results[:])

	if len(state.results) > 0 { state.focus = .Results }
}

@(private="file")
walk :: proc(state: ^State, root_directory, sub_relative_path: string, current_depth: int, query_bytes: []u8) {
	if current_depth > RIF_MAX_DEPTH         { return }
	if len(state.results) >= RIF_MAX_RESULTS { return }

	full_directory: string
	if len(sub_relative_path) == 0 {
		full_directory = root_directory
	} else {
		joined, _ := filepath.join({root_directory, sub_relative_path}, context.temp_allocator)
		full_directory = joined
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
			joined, _ := filepath.join({sub_relative_path, entry_info.name}, context.temp_allocator)
			entry_relative_path = joined
		}

		if entry_info.type == .Directory {
			if skip_dir(entry_info.name) { continue }
			walk(state, root_directory, entry_relative_path, current_depth + 1, query_bytes)
		} else if entry_info.type == .Regular || entry_info.type == .Symlink {
			joined, _ := filepath.join({root_directory, entry_relative_path}, context.temp_allocator)
			scan_file(state, joined, entry_relative_path, query_bytes)
		}
	}
}

@(private="file")
skip_dir :: proc(directory_name: string) -> bool {
	if strings.has_prefix(directory_name, ".") { return true }
	for skipped in RIF_SKIP_DIRS {
		if directory_name == skipped { return true }
	}
	return false
}

@(private="file")
scan_file :: proc(state: ^State, full_file_path, relative_path: string, query_bytes: []u8) {
	file_data, read_error := os.read_entire_file_from_path(full_file_path, context.temp_allocator)
	if read_error != nil                    { return }
	if len(file_data) > RIF_MAX_FILE_BYTES  { return }

	// Binary heuristic: any NUL in the first 1 KiB → skip.
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
			consumed_byte_count, matched := textutil.glob_match_at(line_bytes[search_position:], query_bytes)
			if !matched {
				search_position += 1
				continue
			}

			snippet_bytes := line_bytes
			if len(snippet_bytes) > RIF_SNIPPET_MAX_BYTES { snippet_bytes = snippet_bytes[:RIF_SNIPPET_MAX_BYTES] }

			append(&state.results, Result{
				file_path     = strings.clone(full_file_path),
				relative_path = strings.clone(relative_path),
				line          = line_index,
				column        = u32(search_position),
				match_length  = u32(consumed_byte_count),
				snippet       = textutil.sanitize_snippet(snippet_bytes),
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

// --- Replace operations -------------------------------------------------

// Find a line's byte offset within `file_data`. Returns -1 if the
// file has fewer than `line_index + 1` lines.
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

@(private)
replace_next :: proc(state: ^State) {
	clear_error(state)

	if len(state.results) == 0 { return }

	// Pick the currently selected entry if it's Pending, otherwise
	// the first Pending entry in document order.
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
	if target_index < 0 { return }

	if !apply_single(state, target_index) { return }

	// Advance selection to the next Pending entry.
	next_pending_index := -1
	for candidate_index := target_index + 1; candidate_index < len(state.results); candidate_index += 1 {
		if state.results[candidate_index].status == .Pending { next_pending_index = candidate_index; break }
	}
	if next_pending_index < 0 {
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

// Apply a single result's replacement: read the file, splice in the
// new bytes at the match offset, write it back, then shift the
// columns of any other Pending matches on the same line.
@(private="file")
apply_single :: proc(state: ^State, result_index: int) -> bool {
	result := &state.results[result_index]
	if result.status != .Pending { return false }

	replace_text := string(state.replace_buffer[:])

	file_data, read_error := os.read_entire_file_from_path(result.file_path, context.allocator)
	if read_error != nil {
		set_error(state, fmt.tprintf("Cannot read %s: %v", result.relative_path, read_error))
		return false
	}
	defer delete(file_data)

	line_start_offset := find_line_start_offset_in_bytes(file_data, result.line)
	if line_start_offset < 0 {
		set_error(state, fmt.tprintf("Stale match: %s no longer has line %d", result.relative_path, result.line + 1))
		return false
	}

	match_offset := line_start_offset + int(result.column)
	match_end    := match_offset + int(result.match_length)
	if match_end > len(file_data) {
		set_error(state, fmt.tprintf("Stale match in %s", result.relative_path))
		return false
	}

	new_size := len(file_data) - int(result.match_length) + len(replace_text)
	new_content := make([]byte, new_size, context.temp_allocator)
	copy(new_content[:match_offset],                                file_data[:match_offset])
	copy(new_content[match_offset:match_offset + len(replace_text)], transmute([]u8)replace_text)
	copy(new_content[match_offset + len(replace_text):],            file_data[match_end:])

	write_error := os.write_entire_file(result.file_path, new_content)
	if write_error != nil {
		set_error(state, fmt.tprintf("Cannot write %s: %v", result.relative_path, write_error))
		return false
	}

	result.status = .Replaced

	// Shift columns of other Pending matches on the same line so the
	// next replacement still lands on the right bytes.
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

// Replace All: process the result list one file at a time, splicing
// all of the file's Pending matches in one read/write cycle.
@(private)
replace_all :: proc(state: ^State) {
	clear_error(state)
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

		applied_count := apply_file_group(state, group_start, group_end, replace_text)
		total_replacements += applied_count

		group_start = group_end
	}

	state.max_prefix_chars = compute_max_prefix_chars(state.results[:])

	state.show_completion  = true
	state.completion_count = total_replacements
}

@(private="file")
apply_file_group :: proc(state: ^State, group_start, group_end: int, replace_text: string) -> int {
	if group_start >= group_end { return 0 }

	current_file_path := state.results[group_start].file_path

	file_data, read_error := os.read_entire_file_from_path(current_file_path, context.allocator)
	if read_error != nil { return 0 }
	defer delete(file_data)

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
		set_error(state, fmt.tprintf("Cannot write %s: %v", state.results[group_start].relative_path, write_error))
		return 0
	}

	for result_index in pending_indices_for_group {
		state.results[result_index].status = .Replaced
	}
	return len(pending_indices_for_group)
}
