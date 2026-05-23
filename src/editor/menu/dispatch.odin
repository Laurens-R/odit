// Open/close, Alt-poll, keyboard navigation within a dropdown.
package menu

import "vendor:sdl3"

close :: proc(state: ^State) {
	state.open_menu_index    = -1
	state.hovered_item_index = -1
}

@(private)
open :: proc(state: ^State, menu_index: int) {
	if menu_index < 0 || menu_index >= len(MENUS) { return }
	state.open_menu_index    = menu_index
	state.hovered_item_index = -1
}

// Per-frame Alt poll. SDL3's KEY_UP events aren't routed through
// the editor's main event handler, so we query the live modifier
// mask. Returns true when the alt-held flag changed (caller marks
// dirty).
poll_alt_state :: proc(state: ^State) -> (changed: bool) {
	when ODIN_OS == .Darwin { return false }
	current_modifiers := sdl3.GetModState()
	alt_currently_held := .LALT in current_modifiers || .RALT in current_modifiers
	if alt_currently_held != state.alt_held {
		if alt_currently_held && !state.alt_held {
			state.alt_press_consumed = false
		}
		state.alt_held = alt_currently_held
		return true
	}
	return false
}

// Pick the next / previous selectable item in the open dropdown,
// skipping separators (action == .None).
@(private)
navigate_item :: proc(state: ^State, direction: int) {
	if state.open_menu_index < 0 { return }
	items := MENUS[state.open_menu_index].items
	if len(items) == 0 { return }

	start_index := state.hovered_item_index
	if start_index < 0 { start_index = direction > 0 ? -1 : len(items) }

	for step in 1..=len(items) {
		candidate := start_index + direction * step
		// Wrap.
		for candidate < 0           { candidate += len(items) }
		for candidate >= len(items) { candidate -= len(items) }
		if items[candidate].action != .None {
			state.hovered_item_index = candidate
			return
		}
	}
}
