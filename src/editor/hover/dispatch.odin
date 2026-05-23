// Per-frame mutators the editor calls outside the binding's
// render/event path: anchor recording, content ingest from the LSP
// reply, and the cursor-stickiness probe.
package hover

import "core:strings"

import "../../markdown"

// Record where a freshly-fired hover request was anchored. Called by
// the editor *before* the LSP response lands so the popup's auto-close
// stickiness range survives the round-trip — without this, the next
// frame would see range columns of zero and immediately auto-close.
set_anchor :: proc(state: ^State, pane_index: int, anchor_line, anchor_column, range_start, range_end: u32) {
	state.anchor_line        = anchor_line
	state.anchor_column      = anchor_column
	state.anchor_pane_index  = pane_index
	state.range_start_column = range_start
	state.range_end_column   = range_end
}

// Populate the popup from an LSP hover response. `raw_text` is cloned —
// the caller can pass an LSP-owned string directly. Re-parses the
// markdown immediately so per-frame render work is just layout + draw.
set_content :: proc(state: ^State, raw_text: string) {
	// Capture anchor info before destroy() zeros the struct.
	anchor_line        := state.anchor_line
	anchor_column      := state.anchor_column
	anchor_pane_index  := state.anchor_pane_index
	range_start_column := state.range_start_column
	range_end_column   := state.range_end_column

	destroy(state)

	state.visible            = true
	state.text               = strings.clone(raw_text)
	state.anchor_line        = anchor_line
	state.anchor_column      = anchor_column
	state.anchor_pane_index  = anchor_pane_index
	state.range_start_column = range_start_column
	state.range_end_column   = range_end_column

	markdown.parse_into(state.text, &state.blocks)
}

// Stickiness check — close the popup when the cursor wanders off the
// anchored symbol. Returns true if the popup was actually closed.
auto_close_if_cursor_moved :: proc(state: ^State, cursor: CursorState) -> (closed: bool) {
	if !state.visible { return false }

	close_reason := false
	switch {
	case state.anchor_pane_index < 0:
		close_reason = true
	case state.anchor_pane_index != cursor.active_pane_index:
		close_reason = true
	case !cursor.pane_is_editor:
		close_reason = true
	case cursor.cursor_line != state.anchor_line:
		close_reason = true
	case cursor.cursor_column < state.range_start_column:
		close_reason = true
	case cursor.cursor_column > state.range_end_column:
		close_reason = true
	}

	if !close_reason { return false }
	close(state)
	return true
}
