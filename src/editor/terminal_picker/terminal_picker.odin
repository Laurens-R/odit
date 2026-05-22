// Package `terminal_picker` is the Ctrl+Shift+F9 modal — a small filterable
// list over every open terminal session that lets the user switch the
// active one. Extracted from src/editor/terminal_picker.odin as the second
// modal-subpackage cut; this one introduces the *Intent* return pattern
// that `help` didn't need.
//
// The picker doesn't know about the editor's `terminals` slice directly —
// the host passes a `[]Entry` view (display number + active flag) into
// every call. The picker holds only the ephemeral list-state it owns
// itself: filter buffer, selection cursor, scroll offset, derived filtered
// indices. When the user activates a row, `handle_event` returns an
// `Intent.Activate{terminal_index}` and the host runs whatever switch /
// pane-swap logic it had inline before. Closing is internal: the picker
// flips its `visible` flag and the host watches that on the next frame.
package terminal_picker

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../../ui"

State :: struct {
	visible:           bool,
	filtered_indices:  [dynamic]int, // indices into the `entries` slice last passed in
	filter_buffer:     [dynamic]u8,
	selected_index:    int,          // into `filtered_indices`
	scroll_offset:     int,
	visible_row_count: int,
}

// Snapshot of one entry the picker draws + matches against. The host fills
// these in fresh on every call (no stable storage required) — the picker
// only stores ints back into the slice for the duration of one call.
Entry :: struct {
	display_number: int,  // shown as `Terminal #<n>` in the list
	is_active:      bool, // true for the entry currently in the editor's TERMINAL_PANE_INDEX slot
}

// Intent returned to the host when the picker needs the editor to *do*
// something the picker can't (and shouldn't) do itself. Currently a single
// variant; phrased as a union so additional intents (e.g. close-terminal
// from inside the picker) can land without changing the call site shape.
Intent :: union {
	Activate,
}
Activate :: struct {
	// Index into the `entries` slice that was last passed to the picker.
	// Host translates that into its own terminal-list index.
	entry_index: int,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	if cap(state.filtered_indices) > 0 { delete(state.filtered_indices) }
	if cap(state.filter_buffer)    > 0 { delete(state.filter_buffer) }
	state^ = State{}
}

// Open the picker over the supplied entries. Caller decides which row the
// selection lands on (usually the index of the host's currently-active
// terminal). No-op when `entries` is empty so callers don't have to
// gate the open() call themselves.
open :: proc(state: ^State, entries: []Entry, initial_selection: int) {
	if len(entries) == 0 { return }

	clear(&state.filter_buffer)
	state.selected_index = initial_selection
	if state.selected_index < 0 { state.selected_index = 0 }
	state.scroll_offset  = 0
	state.visible        = true
	apply_filter(state, entries)
}

close :: proc(state: ^State) {
	state.visible = false
	clear(&state.filtered_indices)
}

// --- Input ----------------------------------------------------------------

// Dispatch one SDL event. Returns:
//   intent       — non-nil when the user activated a row (host should
//                  switch to that terminal). The picker has already
//                  closed itself when activation happens.
//   needs_redraw — true when anything visible changed; host can funnel
//                  this into its dirty-tracking the same way `help` does.
//
// Re-filters from `entries` on every keystroke so a host that
// added/removed terminals between events still gets indices that point
// into the current slice.
handle_event :: proc(state: ^State, event: ^sdl3.Event, entries: []Entry) -> (intent: Intent, needs_redraw: bool) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			filter_append(state, entries, input_text)
			needs_redraw = true
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		// Ctrl+Shift+F9 and plain F9 from inside the picker close — mirrors
		// how F4 closes the open-docs dialog. The keybindings package
		// considers these "PickTerminal" / "ToggleTerminal" actions in the
		// outer scope, but the modal short-circuits its own input so we
		// resolve them inline.
		if pressed_key == sdl3.K_F9 && ctrl_held && shift_held { close(state); return nil, true }
		if pressed_key == sdl3.K_F9                            { close(state); return nil, true }

		switch pressed_key {
		case sdl3.K_ESCAPE:
			close(state)
			needs_redraw = true
		case sdl3.K_UP:
			move_selection(state, -1)
			needs_redraw = true
		case sdl3.K_DOWN:
			move_selection(state,  1)
			needs_redraw = true
		case sdl3.K_PAGEUP:
			page_step := state.visible_row_count
			if page_step < 1 { page_step = 1 }
			move_selection(state, -page_step)
			needs_redraw = true
		case sdl3.K_PAGEDOWN:
			page_step := state.visible_row_count
			if page_step < 1 { page_step = 1 }
			move_selection(state,  page_step)
			needs_redraw = true
		case sdl3.K_HOME:
			move_selection(state, -len(state.filtered_indices))
			needs_redraw = true
		case sdl3.K_END:
			move_selection(state,  len(state.filtered_indices))
			needs_redraw = true
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			intent = try_activate(state)
			if intent != nil {
				close(state)
				needs_redraw = true
			}
		case sdl3.K_BACKSPACE:
			if filter_backspace(state, entries) { needs_redraw = true }
		}
	}
	return intent, needs_redraw
}

// --- Render ---------------------------------------------------------------

render :: proc(state: ^State, ui_context: ^ui.Context, entries: []Entry, viewport_width, viewport_height: i32) {
	theme := ui.default_theme()
	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 64
	desired_rows:    i32 = 20
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 40,        viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Open terminals", theme)

	line_step     := ui_context.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	filter_string := string(state.filter_buffer[:])
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	if state.selected_index < state.scroll_offset {
		state.scroll_offset = state.selected_index
	} else if state.selected_index >= state.scroll_offset + computed_visible_rows {
		state.scroll_offset = state.selected_index - computed_visible_rows + 1
	}
	if state.scroll_offset < 0 { state.scroll_offset = 0 }

	if len(state.filtered_indices) == 0 {
		empty_message := len(state.filter_buffer) > 0 ? "(no matches)" : "(no terminals open)"
		ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		filtered_view := state.filtered_indices[:]
		end_row_index := min(state.scroll_offset + computed_visible_rows, len(filtered_view))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry_index := filtered_view[row_index]
			if entry_index < 0 || entry_index >= len(entries) { continue }
			entry := entries[entry_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step

			active_marker := entry.is_active ? "* " : "  "
			row_label := fmt.tprintf("%sTerminal #%d", active_marker, entry.display_number)

			is_selected := row_index == state.selected_index
			ui.draw_list_row(ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	hint_text := "↑/↓ navigate    Enter switch    Type to filter    F9/Esc close"
	hint_width, _ := ui.text_size(ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}

// --- Internals ------------------------------------------------------------

@(private="file")
apply_filter :: proc(state: ^State, entries: []Entry) {
	clear(&state.filtered_indices)

	filter_lowercase := strings.to_lower(string(state.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in entries {
		if len(filter_lowercase) == 0 {
			append(&state.filtered_indices, entry_index)
			continue
		}
		label_lowercase := strings.to_lower(fmt.tprintf("terminal #%d", entry.display_number), context.temp_allocator)
		if strings.contains(label_lowercase, filter_lowercase) {
			append(&state.filtered_indices, entry_index)
		}
	}

	filtered_count := len(state.filtered_indices)
	if filtered_count == 0 {
		state.selected_index = 0
	} else if state.selected_index >= filtered_count {
		state.selected_index = filtered_count - 1
	}
	if state.selected_index < 0 { state.selected_index = 0 }
}

@(private="file")
move_selection :: proc(state: ^State, selection_delta: int) {
	filtered_count := len(state.filtered_indices)
	if filtered_count == 0 { return }
	new_selection := state.selected_index + selection_delta
	if new_selection < 0                  { new_selection = 0 }
	if new_selection >= filtered_count    { new_selection = filtered_count - 1 }
	state.selected_index = new_selection
}

@(private="file")
filter_append :: proc(state: ^State, entries: []Entry, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append { append(&state.filter_buffer, byte_value) }
	apply_filter(state, entries)
}

@(private="file")
filter_backspace :: proc(state: ^State, entries: []Entry) -> (changed: bool) {
	filter_length := len(state.filter_buffer)
	if filter_length == 0 { return false }
	// Step back one UTF-8 codepoint, not one byte, so backspacing through
	// multi-byte characters doesn't leave dangling continuation bytes.
	new_end_index := filter_length - 1
	for new_end_index > 0 && (state.filter_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&state.filter_buffer, new_end_index)
	apply_filter(state, entries)
	return true
}

@(private="file")
try_activate :: proc(state: ^State) -> Intent {
	filtered_count := len(state.filtered_indices)
	if filtered_count == 0                                                       { return nil }
	if state.selected_index < 0 || state.selected_index >= filtered_count        { return nil }
	return Activate{ entry_index = state.filtered_indices[state.selected_index] }
}
