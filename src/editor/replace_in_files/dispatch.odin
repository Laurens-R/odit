// Per-frame mutator entry points called by the binding's
// handle_event. Each takes `^State` (no editor access) and does its
// work in-package.
package replace_in_files

// Open the dialog. Path is seeded from `default_path` only when the
// buffer is empty (preserves the user's last setting across
// close→reopen). `selection_query` overrides the search field when
// non-empty (the "select X, hit Ctrl+Shift+R" gesture).
open :: proc(state: ^State, default_path: string, selection_query: string) {
	clear_error(state)

	if len(state.path_buffer) == 0 {
		for byte_value in transmute([]u8)default_path { append(&state.path_buffer, byte_value) }
	}

	if len(selection_query) > 0 {
		clear(&state.search_buffer)
		for byte_value in transmute([]u8)selection_query { append(&state.search_buffer, byte_value) }
	}

	state.focus = len(state.results) > 0 ? .Results : .SearchInput
	state.visible = true
}
