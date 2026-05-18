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
FindInFilesFocus :: enum {
	PathInput,
	QueryInput,
	FindButton,
	ClearButton,
	CancelButton,
	Results,
}

// One match within one file. `file_path` is an absolute path used to open the
// file; `relative_path` is what we display (relative to the search root).
// `line`/`column` are zero-based byte coordinates so the cursor lands on the
// exact match offset when the file is opened.
@(private)
FindInFilesResult :: struct {
	file_path:     string, // absolute, owned
	relative_path: string, // owned; relative to the search root for display
	line:          u32,    // 0-based
	column:        u32,    // 0-based byte column within the line
	snippet:       string, // owned; line content (clamped to FIF_SNIPPET_MAX_BYTES)
}

// State for the Ctrl+Shift+F dialog. Lives on `Editor` and is the active modal
// when `Editor.show_find_in_files` is true. Field rectangles are rewritten
// every frame by the renderer so the mouse handler can hit-test them.
@(private)
FindInFilesState :: struct {
	focus:             FindInFilesFocus,
	path_buffer:       [dynamic]u8,
	query_buffer:      [dynamic]u8,
	results:           [dynamic]FindInFilesResult,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	error_message:     string, // owned; "" when no error

	// Longest `relative_path:line:col` prefix across the current result set,
	// in display cells. The renderer uses this to align every row's snippet
	// to the same starting column.
	max_prefix_chars:  int,

	path_field_rectangle:    sdl3.FRect,
	query_field_rectangle:   sdl3.FRect,
	find_button_rectangle:   sdl3.FRect,
	clear_button_rectangle:  sdl3.FRect,
	cancel_button_rectangle: sdl3.FRect,
	results_list_rectangle:  sdl3.FRect,
}

// Caps to keep the search bounded. The recursive walk uses the same skip-list
// the F2 flat browser does — these directories are huge and almost never
// useful to grep through from an editor.
@(private="file")
FIF_MAX_DEPTH         :: 12
@(private="file")
FIF_MAX_RESULTS       :: 5000
@(private="file")
FIF_MAX_FILE_BYTES    :: 4 * 1024 * 1024 // 4 MiB
@(private="file")
FIF_SNIPPET_MAX_BYTES :: 200
@(private="file")
FIF_SKIP_DIRS := [?]string{
	".git", "node_modules", "target", "build", "dist", ".cache", ".idea", ".vscode", "out",
}

// --- Lifecycle -------------------------------------------------------------

@(private)
find_in_files_destroy :: proc(state: ^FindInFilesState) {
	delete(state.path_buffer)
	delete(state.query_buffer)
	find_in_files_clear_results_internal(state)
	delete(state.results)
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = FindInFilesState{}
}

@(private="file")
find_in_files_clear_results_internal :: proc(state: ^FindInFilesState) {
	for result in state.results {
		if len(result.file_path)     > 0 { delete(result.file_path)     }
		if len(result.relative_path) > 0 { delete(result.relative_path) }
		if len(result.snippet)       > 0 { delete(result.snippet)       }
	}
	clear(&state.results)
}

@(private="file")
find_in_files_clear_error :: proc(editor: ^Editor) {
	if len(editor.find_in_files.error_message) > 0 {
		delete(editor.find_in_files.error_message)
		editor.find_in_files.error_message = ""
	}
}

@(private="file")
find_in_files_set_error :: proc(editor: ^Editor, message: string) {
	find_in_files_clear_error(editor)
	editor.find_in_files.error_message = strings.clone(message)
}

@(private)
find_in_files_open :: proc(editor: ^Editor) {
	state := &editor.find_in_files
	find_in_files_clear_error(editor)

	// Persist path/query/results across close→reopen so the user can jump out
	// to inspect a hit and come back to keep scanning the list. Only seed the
	// path field when it's empty (first open, or after Clear).
	if len(state.path_buffer) == 0 {
		default_path := find_in_files_default_path(editor)
		for byte_value in transmute([]u8)default_path { append(&state.path_buffer, byte_value) }
	}

	// Seed query from a short single-line selection — only when the query is
	// empty, so a reopened dialog doesn't have its query overwritten by the
	// selection the user happened to leave behind in the file they jumped to.
	if len(state.query_buffer) == 0 {
		if editor_pane := editor_active_editor_pane(editor); editor_pane != nil && editor_pane.selection_active {
			low_offset, high_offset, has_selection := editor_pane_selection_range(editor_pane)
			if has_selection && high_offset - low_offset <= 256 {
				selection_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
				contains_newline := false
				for byte_value in transmute([]u8)selection_text {
					if byte_value == '\n' { contains_newline = true; break }
				}
				if !contains_newline {
					for byte_value in transmute([]u8)selection_text { append(&state.query_buffer, byte_value) }
				}
			}
		}
	}

	// Land focus on existing results if we have any; otherwise on the query
	// input so the user can start typing immediately.
	state.focus = len(state.results) > 0 ? .Results : .QueryInput

	editor.show_find_in_files = true
}

@(private)
find_in_files_close :: proc(editor: ^Editor) {
	editor.show_find_in_files = false
}

// Reset the query and any prior results — invoked by the Clear button. Path
// is kept so the user doesn't have to retype it on the next search.
@(private="file")
find_in_files_clear_action :: proc(editor: ^Editor) {
	state := &editor.find_in_files
	clear(&state.query_buffer)
	find_in_files_clear_results_internal(state)
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = 0
	find_in_files_clear_error(editor)
	state.focus = .QueryInput
}

// Resolve the default search path. Precedence: project root → directory of the
// active pane's open file → current working directory.
@(private="file")
find_in_files_default_path :: proc(editor: ^Editor) -> string {
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
find_in_files_focus_next :: proc(state: ^FindInFilesState) {
	switch state.focus {
	case .PathInput:    state.focus = .QueryInput
	case .QueryInput:   state.focus = .FindButton
	case .FindButton:   state.focus = .ClearButton
	case .ClearButton:  state.focus = .CancelButton
	case .CancelButton: state.focus = .Results
	case .Results:      state.focus = .PathInput
	}
}

@(private="file")
find_in_files_focus_prev :: proc(state: ^FindInFilesState) {
	switch state.focus {
	case .PathInput:    state.focus = .Results
	case .QueryInput:   state.focus = .PathInput
	case .FindButton:   state.focus = .QueryInput
	case .ClearButton:  state.focus = .FindButton
	case .CancelButton: state.focus = .ClearButton
	case .Results:      state.focus = .CancelButton
	}
}

// --- Search execution -----------------------------------------------------

@(private="file")
find_in_files_execute :: proc(editor: ^Editor) {
	state := &editor.find_in_files
	find_in_files_clear_results_internal(state)
	state.selected_index = 0
	state.scroll_offset  = 0
	find_in_files_clear_error(editor)

	query_string := string(state.query_buffer[:])
	if len(query_string) == 0 {
		find_in_files_set_error(editor, "Enter a search query")
		return
	}

	path_string := string(state.path_buffer[:])
	if len(path_string) == 0 {
		find_in_files_set_error(editor, "Enter a search path")
		return
	}

	cleaned_path, _ := filepath.clean(path_string, context.temp_allocator)
	file_info, stat_error := os.stat(cleaned_path, context.temp_allocator)
	if stat_error != nil {
		find_in_files_set_error(editor, fmt.tprintf("Cannot access path: %v", stat_error))
		return
	}

	query_bytes := transmute([]u8)query_string
	if file_info.type == .Directory {
		find_in_files_walk(editor, cleaned_path, "", 0, query_bytes)
	} else {
		find_in_files_scan_file(editor, cleaned_path, file_info.name, query_bytes)
	}

	// Stable snippet-column alignment: take the widest `relpath:line:col`
	// prefix over the full result set so scrolling doesn't shift columns.
	state.max_prefix_chars = 0
	for result in state.results {
		prefix_chars := utf8.rune_count_in_string(result.relative_path) + 2 +
			digit_count_u32(result.line   + 1) +
			digit_count_u32(result.column + 1)
		if prefix_chars > state.max_prefix_chars { state.max_prefix_chars = prefix_chars }
	}

	// Auto-focus the results list once we have something to navigate.
	if len(state.results) > 0 {
		state.focus = .Results
	}
}

// Decimal digit count for a u32, used to size the line/column section of the
// row prefix without a sprintf round-trip per result. Shared with the
// Replace-in-Files dialog (replace_in_files.odin).
@(private)
digit_count_u32 :: proc(value: u32) -> int {
	if value == 0 { return 1 }
	count := 0
	for remaining := value; remaining > 0; remaining /= 10 { count += 1 }
	return count
}

@(private="file")
find_in_files_walk :: proc(editor: ^Editor, root_directory, sub_relative_path: string, current_depth: int, query_bytes: []u8) {
	state := &editor.find_in_files
	if current_depth > FIF_MAX_DEPTH                  { return }
	if len(state.results) >= FIF_MAX_RESULTS          { return }

	full_directory: string
	if len(sub_relative_path) == 0 {
		full_directory = root_directory
	} else {
		full_directory = strings.concatenate({root_directory, "/", sub_relative_path}, context.temp_allocator)
	}

	directory_entries, read_directory_error := os.read_all_directory_by_path(full_directory, context.temp_allocator)
	if read_directory_error != nil { return }

	for entry_info in directory_entries {
		if len(state.results) >= FIF_MAX_RESULTS              { return }
		if entry_info.name == "." || entry_info.name == ".."  { continue }

		entry_relative_path: string
		if len(sub_relative_path) == 0 {
			entry_relative_path = entry_info.name
		} else {
			entry_relative_path = strings.concatenate({sub_relative_path, "/", entry_info.name}, context.temp_allocator)
		}

		if entry_info.type == .Directory {
			if fif_skip_dir(entry_info.name) { continue }
			find_in_files_walk(editor, root_directory, entry_relative_path, current_depth + 1, query_bytes)
		} else if entry_info.type == .Regular || entry_info.type == .Symlink {
			full_file_path := strings.concatenate({root_directory, "/", entry_relative_path}, context.temp_allocator)
			find_in_files_scan_file(editor, full_file_path, entry_relative_path, query_bytes)
		}
	}
}

@(private="file")
fif_skip_dir :: proc(directory_name: string) -> bool {
	if strings.has_prefix(directory_name, ".") { return true } // dotdirs
	for skipped in FIF_SKIP_DIRS {
		if directory_name == skipped { return true }
	}
	return false
}

@(private="file")
find_in_files_scan_file :: proc(editor: ^Editor, full_file_path, relative_path: string, query_bytes: []u8) {
	state := &editor.find_in_files
	file_data, read_error := os.read_entire_file_from_path(full_file_path, context.temp_allocator)
	if read_error != nil                       { return }
	if len(file_data) > FIF_MAX_FILE_BYTES     { return }

	// Cheap binary heuristic: any NUL byte in the first 1 KiB → treat as
	// binary and skip. Keeps the results human-readable when the user points
	// the dialog at a tree mixed with images, archives, compiled blobs, etc.
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
		// Strip a trailing CR so the snippet doesn't render a phantom glyph.
		if len(line_bytes) > 0 && line_bytes[len(line_bytes)-1] == '\r' {
			line_bytes = line_bytes[:len(line_bytes)-1]
		}

		search_position := 0
		for search_position <= len(line_bytes) {
			if len(state.results) >= FIF_MAX_RESULTS { return }
			consumed_byte_count, matched := glob_match_at(line_bytes[search_position:], query_bytes)
			if !matched {
				search_position += 1
				continue
			}

			snippet_bytes := line_bytes
			if len(snippet_bytes) > FIF_SNIPPET_MAX_BYTES { snippet_bytes = snippet_bytes[:FIF_SNIPPET_MAX_BYTES] }

			append(&state.results, FindInFilesResult{
				file_path     = strings.clone(full_file_path),
				relative_path = strings.clone(relative_path),
				line          = line_index,
				column        = u32(search_position),
				snippet       = sanitize_snippet(snippet_bytes),
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

// --- Result activation ----------------------------------------------------

// Open the currently selected result in the active pane and place the cursor
// at the matching line / column. Same pattern as `symbols_dialog_activate`.
@(private="file")
find_in_files_open_selected :: proc(editor: ^Editor) {
	state := &editor.find_in_files
	if state.selected_index < 0 || state.selected_index >= len(state.results) { return }
	result := state.results[state.selected_index]

	file_data, read_error := os.read_entire_file_from_path(result.file_path, context.allocator)
	if read_error != nil {
		find_in_files_set_error(editor, fmt.tprintf("Cannot open %s: %v", result.relative_path, read_error))
		return
	}
	defer delete(file_data)

	if len(file_data) > EDITOR_MAX_DOCUMENT_BYTES {
		find_in_files_set_error(editor, fmt.tprintf("File %s is too large to open", result.relative_path))
		return
	}

	file_content := strings.clone(string(file_data))
	editor_open_string_in_pane(editor, editor.active_pane_index, file_content, result.file_path)

	editor_pane := editor_active_editor_pane(editor)
	if editor_pane != nil {
		document_line_count := document.document_line_count(&editor_pane.document)
		target_line := result.line
		if target_line >= document_line_count { target_line = document_line_count - 1 }

		line_start_offset := document.document_line_start(&editor_pane.document, target_line)
		line_text         := document.document_get_line(&editor_pane.document, target_line, context.temp_allocator)
		target_column     := result.column
		if int(target_column) > len(line_text) { target_column = u32(len(line_text)) }

		editor_pane.cursor_line      = target_line
		editor_pane.cursor_column    = target_column
		editor_pane.cursor_offset    = line_start_offset + target_column
		editor_pane.selection_active = false

		editor.cursor_visible = true
		editor.cursor_timer   = 0

		// Anchor the target line near the top of the pane, matching the F6
		// symbol-jump behavior.
		if editor.line_height > 0 {
			target_scroll_y := f32(target_line) * f32(editor.line_height)
			if target_scroll_y < 0 { target_scroll_y = 0 }
			editor_pane.scroll_y        = target_scroll_y
			editor_pane.scroll_y_target = target_scroll_y
			editor_pane.scroll_line     = target_line
		} else {
			sync_cursor_from_offset(editor)
		}
	}

	find_in_files_close(editor)
}

// --- Navigation ----------------------------------------------------------

@(private="file")
find_in_files_move_selection :: proc(editor: ^Editor, delta: int) {
	state := &editor.find_in_files
	result_count := len(state.results)
	if result_count == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0               { new_index = 0 }
	if new_index >= result_count   { new_index = result_count - 1 }
	state.selected_index = new_index

	// Keyboard navigation is the only thing that auto-scrolls the list; mouse
	// wheel intentionally does not move the selection, so the render path no
	// longer drags scroll_offset to follow the selection. `visible_row_count`
	// is rewritten by the renderer each frame — first move after open uses
	// last frame's value, which is correct because the dialog had to be drawn
	// at least once for the user to see anything to navigate to.
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
find_in_files_focused_buffer :: proc(editor: ^Editor) -> ^[dynamic]u8 {
	switch editor.find_in_files.focus {
	case .PathInput:    return &editor.find_in_files.path_buffer
	case .QueryInput:   return &editor.find_in_files.query_buffer
	case .FindButton, .ClearButton, .CancelButton, .Results:
		return nil
	}
	return nil
}

// Strip / fold characters that would break a single-row preview render:
//   * leading whitespace (spaces & tabs)  → dropped, so every preview starts
//                                           flush with content instead of the
//                                           matched line's indent (deeply-
//                                           nested matches were rendering
//                                           shoved-right relative to top-level
//                                           ones, defeating the aligned column)
//   * tab (mid-line)  → single space  (the cell-grid renderer would otherwise
//                                      expand to TAB_WIDTH spaces and shove the
//                                      rest of the snippet past the dialog edge)
//   * CR/LF → dropped                 (any in-line CR; matches don't cross
//                                      '\n' so this mostly catches an
//                                      accidental \r mid-line)
//   * other ASCII control / DEL → '?'
//   * UTF-8 multi-byte → passed through so accented filenames and in-content
//                        non-ASCII text render normally
// Result owns its memory via the default allocator (caller is responsible for
// `delete`ing it — `find_in_files_clear_results_internal` handles that).
// Shared with the Replace-in-Files dialog.
@(private)
sanitize_snippet :: proc(line_bytes: []byte) -> string {
	// Skip leading indent before sanitizing the rest. The match's column is
	// preserved separately (in the prefix), so trimming here is purely a
	// display concern.
	leading_skip := 0
	for leading_skip < len(line_bytes) && (line_bytes[leading_skip] == ' ' || line_bytes[leading_skip] == '\t') {
		leading_skip += 1
	}
	trimmed := line_bytes[leading_skip:]

	builder: strings.Builder
	strings.builder_init(&builder, 0, len(trimmed))
	byte_index := 0
	for byte_index < len(trimmed) {
		current_byte := trimmed[byte_index]
		switch {
		case current_byte == '\t':
			strings.write_byte(&builder, ' ')
			byte_index += 1
		case current_byte == '\r' || current_byte == '\n':
			byte_index += 1
		case current_byte < 0x20 || current_byte == 0x7F:
			strings.write_byte(&builder, '?')
			byte_index += 1
		case current_byte >= 0x80:
			rune_length: int = 1
			switch {
			case current_byte < 0xC0: rune_length = 1 // stray continuation byte
			case current_byte < 0xE0: rune_length = 2
			case current_byte < 0xF0: rune_length = 3
			case:                     rune_length = 4
			}
			if byte_index + rune_length > len(trimmed) { rune_length = len(trimmed) - byte_index }
			for offset in 0..<rune_length {
				strings.write_byte(&builder, trimmed[byte_index + offset])
			}
			byte_index += rune_length
		case:
			strings.write_byte(&builder, current_byte)
			byte_index += 1
		}
	}
	return strings.to_string(builder)
}

// Cell-aware right-truncate. Returns `text` unchanged when it already fits
// in `max_runes`; otherwise keeps the leading runes and appends "..." so the
// caller can render a single-line row that never extends past the dialog.
// Shared with the Replace-in-Files dialog.
@(private)
truncate_to_runes_with_ellipsis :: proc(text: string, max_runes: int, allocator := context.temp_allocator) -> string {
	if max_runes <= 0 { return "" }
	rune_count := utf8.rune_count_in_string(text)
	if rune_count <= max_runes { return text }
	if max_runes <= 3 {
		// Not enough room for "<content>..." — degenerate to dots.
		return strings.repeat(".", max_runes, allocator)
	}
	keep_runes := max_runes - 3
	byte_index := 0
	runes_kept := 0
	for runes_kept < keep_runes && byte_index < len(text) {
		_, byte_count := utf8.decode_rune_in_string(text[byte_index:])
		byte_index += byte_count
		runes_kept += 1
	}
	return strings.concatenate({text[:byte_index], "..."}, allocator)
}

@(private="file")
find_in_files_buffer_append :: proc(buffer: ^[dynamic]u8, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		if byte_value == '\n' || byte_value == '\r' { continue }
		append(buffer, byte_value)
	}
}

@(private="file")
find_in_files_buffer_backspace :: proc(buffer: ^[dynamic]u8) {
	buffer_length := len(buffer^)
	if buffer_length == 0 { return }
	new_end_index := buffer_length - 1
	for new_end_index > 0 && ((buffer^)[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(buffer, new_end_index)
}

// --- Event handling ------------------------------------------------------

@(private)
find_in_files_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	state := &editor.find_in_files

	#partial switch event.type {
	case .TEXT_INPUT:
		if buffer := find_in_files_focused_buffer(editor); buffer != nil {
			input_text := string(event.text.text)
			if len(input_text) > 0 { find_in_files_buffer_append(buffer, input_text) }
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		// Ctrl+Shift+F closes the dialog (mirrors the toggle the global hotkey
		// performs from outside).
		if ctrl_held && shift_held && pressed_key == sdl3.K_F {
			find_in_files_close(editor)
			return
		}

		switch pressed_key {
		case sdl3.K_ESCAPE:
			find_in_files_close(editor)

		case sdl3.K_TAB:
			if shift_held { find_in_files_focus_prev(state) } else { find_in_files_focus_next(state) }

		case sdl3.K_RETURN:
			switch state.focus {
			case .PathInput, .QueryInput, .FindButton:
				find_in_files_execute(editor)
			case .ClearButton:
				find_in_files_clear_action(editor)
			case .CancelButton:
				find_in_files_close(editor)
			case .Results:
				find_in_files_open_selected(editor)
			}

		case sdl3.K_BACKSPACE:
			if buffer := find_in_files_focused_buffer(editor); buffer != nil {
				find_in_files_buffer_backspace(buffer)
			}

		case sdl3.K_UP:
			if state.focus == .Results { find_in_files_move_selection(editor, -1) }

		case sdl3.K_DOWN:
			if state.focus == .Results { find_in_files_move_selection(editor, +1) }

		case sdl3.K_PAGEUP:
			if state.focus == .Results {
				step := state.visible_row_count;  if step < 1 { step = 1 }
				find_in_files_move_selection(editor, -step)
			}

		case sdl3.K_PAGEDOWN:
			if state.focus == .Results {
				step := state.visible_row_count;  if step < 1 { step = 1 }
				find_in_files_move_selection(editor, +step)
			}

		case sdl3.K_HOME:
			if state.focus == .Results { find_in_files_move_selection(editor, -len(state.results)) }

		case sdl3.K_END:
			if state.focus == .Results { find_in_files_move_selection(editor, +len(state.results)) }
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x, mouse_y := event.button.x, event.button.y
		switch {
		case ui.point_in_rect(state.path_field_rectangle,    mouse_x, mouse_y):
			state.focus = .PathInput
		case ui.point_in_rect(state.query_field_rectangle,   mouse_x, mouse_y):
			state.focus = .QueryInput
		case ui.point_in_rect(state.find_button_rectangle,   mouse_x, mouse_y):
			state.focus = .FindButton
			find_in_files_execute(editor)
		case ui.point_in_rect(state.clear_button_rectangle,  mouse_x, mouse_y):
			state.focus = .ClearButton
			find_in_files_clear_action(editor)
		case ui.point_in_rect(state.cancel_button_rectangle, mouse_x, mouse_y):
			state.focus = .CancelButton
			find_in_files_close(editor)
		case ui.point_in_rect(state.results_list_rectangle,  mouse_x, mouse_y):
			state.focus = .Results
			if editor.line_height > 0 {
				row_height := f32(editor.line_height)
				relative_y := mouse_y - state.results_list_rectangle.y
				if relative_y >= 0 {
					row_index_in_view := int(relative_y / row_height)
					target_index := state.scroll_offset + row_index_in_view
					if target_index >= 0 && target_index < len(state.results) {
						state.selected_index = target_index
						find_in_files_open_selected(editor)
					}
				}
			}
		}

	case .MOUSE_WHEEL:
		// The result list is the only scrollable region in the dialog, so any
		// wheel event while the modal is open targets it — no hit-test needed.
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
find_in_files_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	state := &editor.find_in_files

	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 110
	desired_rows:    i32 = 36
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows    * editor.line_height     + 40, viewport_height - 40)
	if dialog_width  < 280 { dialog_width  = min(viewport_width  - 16, 280) }
	if dialog_height < 240 { dialog_height = min(viewport_height - 16, 240) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Find in Files", theme)

	line_step       := editor.line_height
	content_x       := i32(content_rectangle.x)
	content_y       := i32(content_rectangle.y)
	content_width   := i32(content_rectangle.w)

	// Path field
	state.path_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Path:   ", string(state.path_buffer[:]), theme, state.focus == .PathInput)
	content_y += line_step + 14

	// Search field
	state.query_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Search: ", string(state.query_buffer[:]), theme, state.focus == .QueryInput)
	content_y += line_step + 14

	// Buttons row — Find / Clear / Cancel laid out centered with equal gaps.
	button_width:  i32 = 14 * editor.character_width
	button_height: i32 = line_step + 12
	button_gap:    i32 = 8
	buttons_total_width := button_width * 3 + button_gap * 2
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2

	state.find_button_rectangle   = sdl3.FRect{f32(buttons_start_x),                                    f32(content_y), f32(button_width), f32(button_height)}
	state.clear_button_rectangle  = sdl3.FRect{f32(buttons_start_x + (button_width + button_gap) * 1), f32(content_y), f32(button_width), f32(button_height)}
	state.cancel_button_rectangle = sdl3.FRect{f32(buttons_start_x + (button_width + button_gap) * 2), f32(content_y), f32(button_width), f32(button_height)}

	ui.draw_button(&ui_context, state.find_button_rectangle,   "Find",   state.focus == .FindButton,   theme)
	ui.draw_button(&ui_context, state.clear_button_rectangle,  "Clear",  state.focus == .ClearButton,  theme)
	ui.draw_button(&ui_context, state.cancel_button_rectangle, "Cancel", state.focus == .CancelButton, theme)

	content_y += button_height + 12

	// Optional error line (tinted red, drawn above the results).
	if len(state.error_message) > 0 {
		ui.draw_text(&ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_step + 4
	}

	// Footer reservation + results viewport
	footer_height: i32 = line_step + 12
	list_top_y    := content_y
	list_bottom_y := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	if list_area_height < line_step { list_area_height = line_step }
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	state.results_list_rectangle = sdl3.FRect{f32(content_x), f32(list_top_y), f32(content_width), f32(list_area_height)}

	// Clamp scroll_offset to a valid range; mouse-wheel writes it directly
	// and a re-search may have shrunk the list under it. Selection-driven
	// scroll-into-view lives in `find_in_files_move_selection`.
	max_scroll_offset := max(0, len(state.results) - computed_visible_rows)
	if state.scroll_offset > max_scroll_offset { state.scroll_offset = max_scroll_offset }
	if state.scroll_offset < 0                 { state.scroll_offset = 0 }

	if len(state.results) == 0 {
		empty_message: string
		if len(state.query_buffer) == 0 {
			empty_message = "(enter a query and press Find)"
		} else if len(state.error_message) == 0 {
			empty_message = "(no results)"
		}
		if len(empty_message) > 0 {
			ui.draw_text(&ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
		}
	} else {
		// Layout math for column-aligned rows. `draw_list_row` indents the
		// label by 8 px from the row's left edge; we knock another 8 px off
		// the right for visual breathing room so a maxed-out row doesn't kiss
		// the dialog border.
		label_indent_pixels: i32 = 8
		right_margin_pixels: i32 = 8
		usable_pixels := content_width - label_indent_pixels - right_margin_pixels
		if usable_pixels < editor.character_width { usable_pixels = editor.character_width }
		max_chars_per_row := int(usable_pixels / editor.character_width)

		// 2-cell gap between the location prefix and the snippet. Cap the
		// padded-prefix width so a single ridiculously long path can't squeeze
		// out the snippet entirely.
		padded_prefix_chars := state.max_prefix_chars + 2
		if padded_prefix_chars > max_chars_per_row - 8 { padded_prefix_chars = max_chars_per_row - 8 }
		if padded_prefix_chars < 1                     { padded_prefix_chars = 1 }

		end_row_index := min(state.scroll_offset + computed_visible_rows, len(state.results))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			result := state.results[row_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
			is_selected := row_index == state.selected_index && state.focus == .Results

			prefix_string := fmt.tprintf("%s:%d:%d", result.relative_path, result.line + 1, result.column + 1)
			prefix_chars := utf8.rune_count_in_string(prefix_string)
			padding_chars := padded_prefix_chars - prefix_chars
			if padding_chars < 1 { padding_chars = 1 }
			padding_string := strings.repeat(" ", padding_chars, context.temp_allocator)

			combined_row := strings.concatenate({prefix_string, padding_string, result.snippet}, context.temp_allocator)
			row_label := truncate_to_runes_with_ellipsis(combined_row, max_chars_per_row)

			ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	// Footer: keybinding hint on the left, result count on the right.
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	hint_text := "Tab focus  Enter find/open  ↑/↓ navigate results  Esc close"
	ui.draw_text(&ui_context, hint_text, i32(dialog_rectangle.x) + 12, footer_y, theme.dim_foreground)

	count_text: string
	switch {
	case len(state.results) >= FIF_MAX_RESULTS:
		count_text = fmt.tprintf("%d+ results (cap reached)", len(state.results))
	case len(state.results) > 0:
		count_text = fmt.tprintf("%d results", len(state.results))
	}
	if len(count_text) > 0 {
		count_width, _ := ui.text_size(&ui_context, count_text)
		count_x := i32(dialog_rectangle.x + dialog_rectangle.w) - 12 - count_width
		ui.draw_text(&ui_context, count_text, count_x, footer_y, theme.dim_foreground)
	}
}
