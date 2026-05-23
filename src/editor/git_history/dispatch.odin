// Per-frame mutators: open / set_entries / error helpers.
package git_history

import "core:strings"

// Open the dialog over `file_path` (cloned). Caller follows up with
// `set_entries` once it has the git log; meantime the dialog shows
// "(no commits)". Errors surface via `set_error`.
open :: proc(state: ^State, source_pane_index: int, file_path: string) {
	clear_entries(state)
	if len(state.file_path)     > 0 { delete(state.file_path);     state.file_path     = "" }
	if len(state.error_message) > 0 { delete(state.error_message); state.error_message = "" }

	state.source_pane_index = source_pane_index
	state.file_path         = strings.clone(file_path)
	state.focus             = .List
	state.selected_index    = 0
	state.scroll_offset     = 0
	state.visible           = true
}

set_entries :: proc(state: ^State, sources: []EntrySource) {
	clear_entries(state)
	for source in sources {
		append(&state.entries, Entry{
			hash       = strings.clone(source.hash),
			short_hash = strings.clone(source.short_hash),
			date       = strings.clone(source.date),
			author     = strings.clone(source.author),
			subject    = strings.clone(source.subject),
		})
	}
}

set_error :: proc(state: ^State, message: string) {
	if len(state.error_message) > 0 { delete(state.error_message) }
	state.error_message = strings.clone(message)
}

clear_error :: proc(state: ^State) {
	if len(state.error_message) > 0 {
		delete(state.error_message)
		state.error_message = ""
	}
}
