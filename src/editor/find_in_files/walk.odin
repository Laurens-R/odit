// Recursive directory walk + per-file grep that powers the
// ExecuteSearch intent. No editor coupling — uses `core:os` /
// `core:path/filepath` directly, plus the shared `textutil`
// helpers.
package find_in_files

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

import "../textutil"

@(private="file")
FIF_MAX_DEPTH         :: 12
@(private="file")
FIF_MAX_RESULTS       :: 5000
@(private="file")
FIF_MAX_FILE_BYTES    :: 4 * 1024 * 1024
@(private="file")
FIF_SNIPPET_MAX_BYTES :: 200
@(private="file")
FIF_SKIP_DIRS := [?]string{
	".git", "node_modules", "target", "build", "dist", ".cache", ".idea", ".vscode", "out",
}

// Run the search and stuff the result list into `state` via
// `set_results`. Called from the binding's ExecuteSearch handler.
run_search :: proc(state: ^State, path_string, query_string: string) {
	cleaned_path, _ := filepath.clean(path_string, context.temp_allocator)
	file_info, stat_error := os.stat(cleaned_path, context.temp_allocator)
	if stat_error != nil {
		set_error(state, fmt.tprintf("Cannot access path: %v", stat_error))
		return
	}

	sources := make([dynamic]ResultSource, 0, 256, context.temp_allocator)
	query_bytes := transmute([]u8)query_string
	if file_info.type == .Directory {
		walk(cleaned_path, "", 0, query_bytes, &sources)
	} else {
		scan_file(cleaned_path, file_info.name, query_bytes, &sources)
	}

	max_prefix_chars := 0
	for source in sources {
		prefix_chars := utf8.rune_count_in_string(source.relative_path) + 2 +
			textutil.digit_count_u32(source.line   + 1) +
			textutil.digit_count_u32(source.column + 1)
		if prefix_chars > max_prefix_chars { max_prefix_chars = prefix_chars }
	}

	set_results(state, sources[:], max_prefix_chars)
}

@(private="file")
walk :: proc(root_directory, sub_relative_path: string, current_depth: int, query_bytes: []u8, output_sources: ^[dynamic]ResultSource) {
	if current_depth > FIF_MAX_DEPTH                { return }
	if len(output_sources^) >= FIF_MAX_RESULTS      { return }

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
		if len(output_sources^) >= FIF_MAX_RESULTS            { return }
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
			walk(root_directory, entry_relative_path, current_depth + 1, query_bytes, output_sources)
		} else if entry_info.type == .Regular || entry_info.type == .Symlink {
			joined, _ := filepath.join({root_directory, entry_relative_path}, context.temp_allocator)
			scan_file(joined, entry_relative_path, query_bytes, output_sources)
		}
	}
}

@(private="file")
skip_dir :: proc(directory_name: string) -> bool {
	if strings.has_prefix(directory_name, ".") { return true }
	for skipped in FIF_SKIP_DIRS {
		if directory_name == skipped { return true }
	}
	return false
}

@(private="file")
scan_file :: proc(full_file_path, relative_path: string, query_bytes: []u8, output_sources: ^[dynamic]ResultSource) {
	file_data, read_error := os.read_entire_file_from_path(full_file_path, context.temp_allocator)
	if read_error != nil                       { return }
	if len(file_data) > FIF_MAX_FILE_BYTES     { return }

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
			if len(output_sources^) >= FIF_MAX_RESULTS { return }
			consumed_byte_count, matched := textutil.glob_match_at(line_bytes[search_position:], query_bytes)
			if !matched {
				search_position += 1
				continue
			}

			snippet_bytes := line_bytes
			if len(snippet_bytes) > FIF_SNIPPET_MAX_BYTES { snippet_bytes = snippet_bytes[:FIF_SNIPPET_MAX_BYTES] }

			append(output_sources, ResultSource{
				file_path     = strings.clone(full_file_path, context.temp_allocator),
				relative_path = strings.clone(relative_path,  context.temp_allocator),
				line          = line_index,
				column        = u32(search_position),
				snippet       = textutil.sanitize_snippet(snippet_bytes, context.temp_allocator),
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
