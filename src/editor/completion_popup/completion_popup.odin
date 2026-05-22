// Package `completion_popup` is the Ctrl+Space LSP completion popup —
// a filterable list of candidates pinned next to the editor cursor.
// Extracted from src/editor/completion.odin as the fourth modal
// subpackage. Same pattern as `hover` and `signature_popup`: state owns
// list / filter / scroll, the editor owns LSP wiring + anchor position,
// acceptance comes back as an `Intent`.
//
// The popup pre-measures every item's label + detail width at set-items
// time so the per-frame render loop is field reads instead of per-item
// TTF measurement — long completion lists scroll snappily as a result.
package completion_popup

import "core:strings"
import "vendor:sdl3"

import "../../ui"

State :: struct {
	visible:           bool,
	pane_index:        int,
	anchor_line:       u32,
	anchor_column:     u32,
	filter_buffer:     [dynamic]u8,
	selected_index:    int, // index into filtered indices, not items_snapshot
	scroll_offset:     int,
	request_pending:   bool,
	items_snapshot:    [dynamic]Item,
}

// One completion candidate stored on the popup. Strings are owned by the
// popup (cloned out of whatever the editor handed to `set_items`).
//
// `label_pixel_width` / `detail_pixel_width` are measured once at
// snapshot time so the render path is O(N · field_read) instead of
// O(N · TTF_round_trip). The original CompletionPopup used to re-measure
// every frame and a 500-item list scrolled visibly stuttery — this
// pre-measure is what made it instant.
Item :: struct {
	label:              string, // owned
	detail:             string, // owned
	insert_text:        string, // owned
	label_pixel_width:  i32,
	detail_pixel_width: i32,
}

// What the editor hands to `set_items` after parsing an LSP completion
// response. Strings are NOT owned by the editor after the call — the
// popup clones each one into its own storage.
ItemSource :: struct {
	label:       string,
	detail:      string,
	insert_text: string,
}

// Where the popup paints, in viewport coords. The editor knows panes,
// gutters, scroll offsets, font metrics — the popup doesn't.
//
// `cursor_screen_x` is the on-screen x of the *anchor column* (i.e.
// `pane.x + anchor_column * character_width + gutter_width + padding_x`)
// — the editor pre-computes that and hands it over.
AnchorScreenPosition :: struct {
	cursor_screen_top_y: i32,
	cursor_line_height:  i32,
	character_width:     i32,
	cursor_screen_x:     i32,
}

// Cursor snapshot the editor passes into `auto_close_if_cursor_moved`.
CursorState :: struct {
	pane_index:    int,
	cursor_line:   u32,
	cursor_column: u32,
	pane_is_editor: bool,
}

// Colors for the popup chrome. Body / detail / stub text colors live
// here too since the popup isn't drawing markdown — no point reusing
// `markdown.Theme` just for one row layout.
Chrome :: struct {
	background:    sdl3.FColor, // popup fill
	border:        sdl3.FColor,
	selection:     sdl3.FColor, // highlight row background
	label:         sdl3.FColor, // body label foreground
	label_selected: sdl3.FColor, // label color on the selected row
	detail:        sdl3.FColor, // dim foreground for the right-side detail
	stub:          sdl3.FColor, // "loading…" / "no completions" text
}

// Acceptance intent. Returned from `handle_key` on Enter/Tab so the
// editor can apply the insertion against the active document. The
// included `insert_text` is cloned into `context.temp_allocator` so the
// editor's `document_insert` call is safe even after the popup closes
// itself on the same dispatch.
Intent :: union {
	Accept,
}
Accept :: struct {
	insert_text: string, // lives in temp_allocator
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	clear_items(state)
	if cap(state.items_snapshot) > 0 { delete(state.items_snapshot) }
	if cap(state.filter_buffer)  > 0 { delete(state.filter_buffer)  }
	state^ = State{}
}

close :: proc(state: ^State) {
	clear_items(state)
	clear(&state.filter_buffer)
	state.visible         = false
	state.request_pending = false
	state.selected_index  = 0
	state.scroll_offset   = 0
}

// Open the popup at the cursor and mark "waiting for LSP". Anchor info
// snapshots where the request was issued so the auto-close check can
// detect cursor drift.
open :: proc(state: ^State, pane_index: int, anchor_line, anchor_column: u32) {
	close(state)
	state.visible         = true
	state.pane_index      = pane_index
	state.anchor_line     = anchor_line
	state.anchor_column   = anchor_column
	state.request_pending = true
}

// --- Item ingestion -------------------------------------------------------

// Replace the snapshot with a fresh list of items from an LSP response.
// Clones every string and pre-measures each item's label / detail width
// using `ui_context`. Caller is whatever drained the LSP completion
// result.
set_items :: proc(state: ^State, ui_context: ^ui.Context, sources: []ItemSource) {
	clear_items(state)
	state.request_pending = false
	state.selected_index  = 0
	state.scroll_offset   = 0

	for source in sources {
		label_copy  := strings.clone(source.label)
		detail_copy := strings.clone(source.detail)
		insert_copy := strings.clone(source.insert_text)
		label_width:  i32 = 0
		detail_width: i32 = 0
		if len(label_copy)  > 0 { label_width,  _ = ui.text_size(ui_context, label_copy)  }
		if len(detail_copy) > 0 { detail_width, _ = ui.text_size(ui_context, detail_copy) }
		append(&state.items_snapshot, Item{
			label              = label_copy,
			detail             = detail_copy,
			insert_text        = insert_copy,
			label_pixel_width  = label_width,
			detail_pixel_width = detail_width,
		})
	}
}

// --- Stickiness ----------------------------------------------------------

// Auto-close when the cursor wanders off the trigger. Returns true if
// the popup was actually closed. The cursor-column check accepts being
// one byte to the LEFT of anchor because the trigger character itself
// (`.` / `"` / `:`) sits between the anchor and the first typed filter
// char — without that slack the popup would close the instant ols sent
// back its first result.
auto_close_if_cursor_moved :: proc(state: ^State, cursor: CursorState) -> (closed: bool) {
	if !state.visible { return false }

	close_reason := false
	switch {
	case state.pane_index < 0:
		close_reason = true
	case state.pane_index != cursor.pane_index:
		close_reason = true
	case !cursor.pane_is_editor:
		close_reason = true
	case cursor.cursor_line != state.anchor_line:
		close_reason = true
	case u32(cursor.cursor_column + 1) < state.anchor_column:
		close_reason = true
	}

	if !close_reason { return false }
	close(state)
	return true
}

// --- Input handling -------------------------------------------------------

// Per-keypress dispatch. Returns:
//   intent       — Accept on Enter/Tab; nil otherwise.
//   consumed     — true when the key should NOT propagate to the document
//                  (i.e. arrow keys / Enter / Esc). Filter typing falls
//                  through via `consume_text` below so the user keeps
//                  typing while the popup narrows.
//   needs_redraw — anything visible changed.
//
// On Accept, the returned `insert_text` lives in `context.temp_allocator`
// and the popup closes itself before returning — the editor can apply
// the insertion without worrying about the original String being freed
// out from under it.
handle_key :: proc(state: ^State, event: ^sdl3.Event) -> (intent: Intent, consumed: bool, needs_redraw: bool) {
	if !state.visible { return nil, false, false }
	if event.type != .KEY_DOWN { return nil, false, false }

	switch event.key.key {
	case sdl3.K_ESCAPE:
		close(state)
		return nil, true, true
	case sdl3.K_UP:
		move_selection(state, -1)
		return nil, true, true
	case sdl3.K_DOWN:
		move_selection(state, +1)
		return nil, true, true
	case sdl3.K_PAGEUP:
		move_selection(state, -8)
		return nil, true, true
	case sdl3.K_PAGEDOWN:
		move_selection(state, +8)
		return nil, true, true
	case sdl3.K_RETURN, sdl3.K_KP_ENTER, sdl3.K_TAB:
		accept_intent, ok := try_accept(state)
		if !ok {
			// Nothing to insert (empty filtered list / out-of-range cursor) —
			// just close and let the keystroke fall through to the doc.
			close(state)
			return nil, false, true
		}
		close(state)
		return accept_intent, true, true
	}
	return nil, false, false
}

// Called from the editor's text-input path so the popup tracks what the
// user is typing while it's open. Returns whether the keystroke should
// be suppressed from the document edit path — currently always false
// (popup mirrors typing rather than capturing it). The boolean is here
// so a future "snippet mode" can capture e.g. Tab without disrupting
// the open-popup invariants.
consume_text :: proc(state: ^State, input_text: string) -> (consumed: bool, needs_redraw: bool) {
	if !state.visible || state.request_pending { return false, false }
	if len(input_text) == 0                    { return false, false }
	for byte_value in transmute([]u8)input_text { append(&state.filter_buffer, byte_value) }
	state.selected_index = 0
	state.scroll_offset  = 0
	return false, true
}

consume_backspace :: proc(state: ^State) -> (consumed: bool, needs_redraw: bool) {
	if !state.visible || state.request_pending { return false, false }
	if len(state.filter_buffer) == 0           { return false, false }
	new_end := len(state.filter_buffer) - 1
	for new_end > 0 && (state.filter_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
	resize(&state.filter_buffer, new_end)
	return false, true
}

// --- Render --------------------------------------------------------------

render :: proc(state: ^State, ui_context: ^ui.Context, chrome: Chrome, anchor: AnchorScreenPosition, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	renderer := ui_context.renderer
	if renderer == nil { return }

	filtered := filtered_indices(state); defer delete(filtered)

	visible_lines := len(filtered)
	if visible_lines > 12 { visible_lines = 12 }
	stub_message := ""
	if state.request_pending     { stub_message = "loading…" }
	else if visible_lines == 0   { stub_message = "no completions" }

	line_step          := anchor.cursor_line_height
	character_width    := anchor.character_width
	horizontal_padding: i32 = 8
	popup_min_width:    i32 = 28 * character_width
	popup_max_width:    i32 = 60 * character_width

	max_label_width:  i32 = 0
	max_detail_width: i32 = 0
	if len(stub_message) > 0 {
		stub_width, _ := ui.text_size(ui_context, stub_message)
		max_label_width = stub_width
	} else {
		for index in filtered {
			item := &state.items_snapshot[index]
			if item.label_pixel_width  > max_label_width  { max_label_width  = item.label_pixel_width }
			if item.detail_pixel_width > max_detail_width { max_detail_width = item.detail_pixel_width }
		}
	}

	gap_between_columns: i32 = max_detail_width > 0 ? 16 : 0
	popup_width := horizontal_padding * 2 + max_label_width + gap_between_columns + max_detail_width
	if popup_width < popup_min_width { popup_width = popup_min_width }
	if popup_width > popup_max_width { popup_width = popup_max_width }

	row_count := visible_lines
	if len(stub_message) > 0 { row_count = 1 }
	popup_height := i32(row_count) * line_step + 8

	// Anchor below the cursor row; flip above if the bubble would clip.
	popup_y := anchor.cursor_screen_top_y + line_step + 2
	if popup_y + popup_height > viewport_height - 4 {
		popup_y = anchor.cursor_screen_top_y - popup_height - 2
		if popup_y < 4 { popup_y = 4 }
	}
	popup_x := anchor.cursor_screen_x
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	panel_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}
	sdl3.SetRenderDrawColorFloat(renderer, chrome.background.r, chrome.background.g, chrome.background.b, chrome.background.a)
	sdl3.RenderFillRect(renderer, &panel_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, chrome.border.r, chrome.border.g, chrome.border.b, chrome.border.a)
	sdl3.RenderRect(renderer, &panel_rectangle)

	if len(stub_message) > 0 {
		ui.draw_text(ui_context, stub_message, popup_x + horizontal_padding, popup_y + 4, chrome.stub)
		return
	}

	// Scroll so the selection is visible. Single-step scroll for now.
	if state.selected_index < state.scroll_offset                  { state.scroll_offset = state.selected_index }
	if state.selected_index >= state.scroll_offset + visible_lines { state.scroll_offset = state.selected_index - visible_lines + 1 }
	if state.scroll_offset < 0 { state.scroll_offset = 0 }

	end_row := state.scroll_offset + visible_lines
	if end_row > len(filtered) { end_row = len(filtered) }

	for visible_row_index in state.scroll_offset..<end_row {
		item := state.items_snapshot[filtered[visible_row_index]]
		row_y := popup_y + 4 + i32(visible_row_index - state.scroll_offset) * line_step
		is_selected := visible_row_index == state.selected_index
		if is_selected {
			highlight_rectangle := sdl3.FRect{f32(popup_x + 2), f32(row_y), f32(popup_width - 4), f32(line_step)}
			sdl3.SetRenderDrawColorFloat(renderer, chrome.selection.r, chrome.selection.g, chrome.selection.b, chrome.selection.a)
			sdl3.RenderFillRect(renderer, &highlight_rectangle)
		}
		label_color  := is_selected ? chrome.label_selected : chrome.label
		ui.draw_text(ui_context, item.label, popup_x + horizontal_padding, row_y, label_color)
		if len(item.detail) > 0 {
			detail_x := popup_x + popup_width - horizontal_padding
			detail_x -= item.detail_pixel_width
			if detail_x < popup_x + horizontal_padding + max_label_width + gap_between_columns {
				detail_x = popup_x + horizontal_padding + max_label_width + gap_between_columns
			}
			ui.draw_text(ui_context, item.detail, detail_x, row_y, chrome.detail)
		}
	}
}

// --- Internals ------------------------------------------------------------

@(private="file")
clear_items :: proc(state: ^State) {
	for item in state.items_snapshot {
		if len(item.label)       > 0 { delete(item.label) }
		if len(item.detail)      > 0 { delete(item.detail) }
		if len(item.insert_text) > 0 { delete(item.insert_text) }
	}
	clear(&state.items_snapshot)
}

@(private="file")
move_selection :: proc(state: ^State, delta: int) {
	filtered := filtered_indices(state); defer delete(filtered)
	if len(filtered) == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0                 { new_index = 0 }
	if new_index >= len(filtered)    { new_index = len(filtered) - 1 }
	state.selected_index = new_index
}

// Indices into `items_snapshot` matching the current filter. Caller owns
// the slice (it's a `[dynamic]int[:]` so `delete` works on it).
@(private="file")
filtered_indices :: proc(state: ^State) -> []int {
	indices: [dynamic]int
	filter_string := string(state.filter_buffer[:])
	filter_lower := strings.to_lower(filter_string, context.temp_allocator)
	for item, item_index in state.items_snapshot {
		if len(filter_lower) == 0 {
			append(&indices, item_index)
			continue
		}
		label_lower := strings.to_lower(item.label, context.temp_allocator)
		if strings.contains(label_lower, filter_lower) {
			append(&indices, item_index)
		}
	}
	return indices[:]
}

@(private="file")
try_accept :: proc(state: ^State) -> (intent: Accept, ok: bool) {
	filtered := filtered_indices(state); defer delete(filtered)
	if len(filtered) == 0                                                  { return {}, false }
	if state.selected_index < 0 || state.selected_index >= len(filtered)   { return {}, false }
	item_index := filtered[state.selected_index]
	if item_index < 0 || item_index >= len(state.items_snapshot)           { return {}, false }
	insert_text := state.items_snapshot[item_index].insert_text
	// Clone into temp_allocator so the editor can still read it after
	// the popup closes itself on the same dispatch.
	return Accept{ insert_text = strings.clone(insert_text, context.temp_allocator) }, true
}
