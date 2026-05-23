// Per-frame mutator: open with a fresh list of entry sources.
package tasks_dialog

import "core:strings"

// Populate the dialog with the supplied entries (snapshotted —
// labels are cloned).
open :: proc(state: ^State, sources: []EntrySource) {
	clear_entries(state)
	for source in sources {
		append(&state.entries, Entry{
			kind          = source.kind,
			profile_index = source.profile_index,
			label         = strings.clone(source.label),
		})
	}
	state.selected_index = 0
	state.scroll_offset  = 0
	state.visible        = true
}
