// Event handling + render for the F2 file browser modal.
package browse

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../../git"
import "../../keybindings"
import "../../ui"
import browse_prompt "../browse_prompt"

// Dispatch one SDL event. Returns:
//   intent       — Browse-level intent (non-nil when the host needs
//                  to act).
//   needs_redraw — Anything visible changed.
//
// When the sub-popup is active, all input is routed to it via the
// supplied `prompt_host`.
handle_event :: proc(state: ^State, event: ^sdl3.Event, bindings: ^keybindings.Bindings, prompt_host: ^browse_prompt.Host) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	if browse_prompt.active(&state.prompt) {
		redraw := browse_prompt.dispatch_event(&state.prompt, prompt_host, event)
		return nil, redraw
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			filter_append(state, input_text)
			needs_redraw = true
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod

		// Browse-scoped shortcuts: rename, new file, undo, set project
		// root. Looked up against `.Browse` so they can share chords
		// (Ctrl+R, Ctrl+Z, Ctrl+P) with global actions without fighting
		// them — the editor short-circuits to us while we're visible,
		// so the global table never gets a chance to fire.
		#partial switch keybindings.lookup(bindings, pressed_key, key_modifiers, .Browse) {
		case .BrowseRename:
			open_rename_at_selection(state)
			return nil, true
		case .BrowseNewFile:
			browse_prompt.open_new_file(&state.prompt)
			return nil, true
		case .BrowseNewFolder:
			browse_prompt.open_new_folder(&state.prompt)
			return nil, true
		case .BrowseUndo:
			return Undo{}, true
		case .BrowseSetProjectRoot:
			if len(state.current_working_directory) == 0 { return nil, false }
			cleaned, _ := filepath.clean(state.current_working_directory, context.temp_allocator)
			return SetProjectRoot{ path = strings.clone(cleaned, context.temp_allocator) }, true
		}

		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F2:
			close(state)
			return nil, true
		case sdl3.K_UP:
			move_selection(state, -1)
			return nil, true
		case sdl3.K_DOWN:
			move_selection(state, 1)
			return nil, true
		case sdl3.K_PAGEUP:
			page_step := state.visible_row_count
			if page_step < 1 { page_step = 1 }
			move_selection(state, -page_step)
			return nil, true
		case sdl3.K_PAGEDOWN:
			page_step := state.visible_row_count
			if page_step < 1 { page_step = 1 }
			move_selection(state, page_step)
			return nil, true
		case sdl3.K_HOME:
			move_selection(state, -len(state.filtered_indices))
			return nil, true
		case sdl3.K_END:
			move_selection(state, len(state.filtered_indices))
			return nil, true
		case sdl3.K_RETURN:
			shift_held := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers
			activate_intent, ok := try_activate(state, shift_held)
			if ok { return activate_intent, true }
			return nil, false
		case sdl3.K_BACKSPACE:
			if filter_backspace(state) { return nil, true }
		case sdl3.K_F3:
			return ToggleFlat{}, true
		}
	}
	return intent, needs_redraw
}

render :: proc(state: ^State, ui_context: ^ui.Context, chrome: Chrome, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 100
	desired_rows: i32 = 40
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 40, viewport_height - 40)
	if dialog_width  < 240 { dialog_width  = min(viewport_width  - 16, 240) }
	if dialog_height < 240 { dialog_height = min(viewport_height - 16, 240) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	mode_tag := state.flat_mode ? "  (flat)" : ""
	title := fmt.tprintf("Browse — %s%s", state.current_working_directory, mode_tag)
	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, title, theme)

	line_step     := ui_context.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	filter_string := string(state.filter_buffer[:])
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	footer_height: i32 = line_step + 12
	list_top_y    := content_y
	list_bottom_y := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12

	if len(state.error_message) > 0 {
		list_bottom_y -= line_step
	}

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

	end_row_index := min(state.scroll_offset + computed_visible_rows, len(state.filtered_indices))
	for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
		entry := state.entries[state.filtered_indices[row_index]]
		row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
		row_icon: ui.ListRowIcon = entry.is_dir ? .Folder : .File

		// Git status tints the label color; selection still wins for
		// visual emphasis (the brighter title_foreground stays on the
		// selected row so the selection is unambiguous even on
		// already-tinted entries).
		label_color_override: Maybe(sdl3.FColor)
		if row_index != state.selected_index {
			switch entry.git_status {
			case .None:                                          // no tint
			case .Modified:  label_color_override = chrome.git_modified
			case .Added:     label_color_override = chrome.git_added
			case .Untracked: label_color_override = chrome.git_untracked
			case .Renamed:   label_color_override = chrome.git_renamed
			case .Deleted:   label_color_override = chrome.git_deleted
			}
		}

		// Reserve a 3-character slot between the icon and the name for
		// the git status tag. The slot is filled with [N]/[M]/[D]/[R]
		// when the entry has a status and left blank otherwise, so
		// names line up in the same column regardless.
		git_status_tag_string := git.status_tag(entry.git_status)
		if len(git_status_tag_string) == 0 { git_status_tag_string = "   " }
		row_label := fmt.tprintf("%s %s", git_status_tag_string, entry.name)

		ui.draw_list_row(ui_context, content_x, row_y_position, content_width, row_label, row_index == state.selected_index, theme, row_icon, label_color_override)
	}

	if len(state.filtered_indices) == 0 {
		empty_message := len(state.filter_buffer) > 0 ? "(no matches)" : "(empty)"
		ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	}

	if len(state.error_message) > 0 {
		error_y := list_bottom_y
		ui.draw_text(ui_context, state.error_message, content_x, error_y, chrome.error_text)
	}

	hint_text := "Enter open  Ctrl+P set project root  Ctrl+R rename  Ctrl+N new file  Ctrl+Shift+N new folder  Ctrl+Z undo  F3 flat  Esc"
	hint_width, _ := ui.text_size(ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)

	// Rename / new-file popup, if any, painted on top of the browse modal.
	if browse_prompt.active(&state.prompt) {
		browse_prompt.render(&state.prompt, ui_context, viewport_width, viewport_height)
	}
}
