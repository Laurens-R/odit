// Per-frame mutators: open / seed_query / set_results / error helpers.
package find_in_files

import "core:strings"

// Open the modal. Path is seeded from `default_path` only when the
// existing path buffer is empty. Query + results persist across
// close→reopen.
open :: proc(state: ^State, default_path: string) {
	clear_error(state)

	if len(state.path_buffer) == 0 {
		for byte_value in transmute([]u8)default_path { append(&state.path_buffer, byte_value) }
	}

	state.focus = len(state.results) > 0 ? .Results : .QueryInput
	state.visible = true
}

// Replace the query buffer with `query`. Editor calls this at open
// time when the active pane has a short single-line selection.
seed_query :: proc(state: ^State, query: string) {
	clear(&state.query_buffer)
	for byte_value in transmute([]u8)query {
		if byte_value == '\n' || byte_value == '\r' { continue }
		append(&state.query_buffer, byte_value)
	}
}

// Replace the result list. `max_prefix_chars` is the widest
// `relpath:line:col` prefix in display cells.
set_results :: proc(state: ^State, sources: []ResultSource, max_prefix_chars: int) {
	clear_results_internal(state)
	for source in sources {
		append(&state.results, Result{
			file_path     = strings.clone(source.file_path),
			relative_path = strings.clone(source.relative_path),
			line          = source.line,
			column        = source.column,
			snippet       = strings.clone(source.snippet),
		})
	}
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = max_prefix_chars

	if len(state.results) > 0 { state.focus = .Results }
}

set_error :: proc(state: ^State, message: string) {
	clear_error(state)
	state.error_message = strings.clone(message)
}

clear_error :: proc(state: ^State) {
	if len(state.error_message) > 0 {
		delete(state.error_message)
		state.error_message = ""
	}
}
