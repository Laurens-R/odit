// Menu-bar input handling + rendering (strip + dropdown).
package menu

import "vendor:sdl3"

import "../../ui"
import "../binding"

// Returns true when the event was consumed.
handle_event :: proc(state: ^State, event: ^sdl3.Event, api: ^binding.EditorAPI) -> bool {
	when ODIN_OS == .Darwin { return false }

	#partial switch event.type {
	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return state.open_menu_index >= 0 }
		mouse_x, mouse_y := event.button.x, event.button.y

		// Click on a top-level title — toggle that menu.
		for title_index in 0..<state.title_count {
			if ui.point_in_rect(state.title_rectangles[title_index], mouse_x, mouse_y) {
				if state.open_menu_index == title_index {
					close(state)
				} else {
					open(state, title_index)
				}
				return true
			}
		}

		// Click inside the open dropdown — pick the hit item.
		if state.open_menu_index >= 0 {
			items := MENUS[state.open_menu_index].items
			for item_index in 0..<min(state.item_count, len(items)) {
				if !ui.point_in_rect(state.item_rectangles[item_index], mouse_x, mouse_y) { continue }
				item := items[item_index]
				if item.action == .None { return true } // separator
				close(state)
				dispatch_action(api, state, item.action)
				return true
			}

			// Click outside both the title row and the dropdown —
			// close the menu and let the event propagate.
			close(state)
			return false
		}
		return false

	case .MOUSE_MOTION:
		mouse_x, mouse_y := event.motion.x, event.motion.y

		if state.open_menu_index >= 0 {
			for title_index in 0..<state.title_count {
				if ui.point_in_rect(state.title_rectangles[title_index], mouse_x, mouse_y) {
					if state.open_menu_index != title_index { open(state, title_index) }
					return true
				}
			}

			state.hovered_item_index = -1
			items := MENUS[state.open_menu_index].items
			for item_index in 0..<min(state.item_count, len(items)) {
				if ui.point_in_rect(state.item_rectangles[item_index], mouse_x, mouse_y) {
					if items[item_index].action != .None {
						state.hovered_item_index = item_index
					}
					break
				}
			}
			return true
		}
		return false

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		alt_held      := .LALT in key_modifiers || .RALT in key_modifiers
		ctrl_held     := .LCTRL in key_modifiers || .RCTRL in key_modifiers

		// Alt+<mnemonic> opens (or switches to) the matching menu.
		if alt_held && !ctrl_held {
			for menu_def, menu_index in MENUS {
				if menu_def.mnemonic_letter == 0 { continue }
				if u32(pressed_key) == u32(menu_def.mnemonic_letter) {
					if state.open_menu_index == menu_index {
						close(state)
					} else {
						open(state, menu_index)
					}
					return true
				}
			}
		}

		if state.open_menu_index < 0 { return false }
		switch pressed_key {
		case sdl3.K_ESCAPE:
			close(state)
			return true
		case sdl3.K_LEFT:
			new_index := state.open_menu_index - 1
			if new_index < 0 { new_index = len(MENUS) - 1 }
			open(state, new_index)
			return true
		case sdl3.K_RIGHT:
			new_index := state.open_menu_index + 1
			if new_index >= len(MENUS) { new_index = 0 }
			open(state, new_index)
			return true
		case sdl3.K_DOWN:
			navigate_item(state, +1)
			return true
		case sdl3.K_UP:
			navigate_item(state, -1)
			return true
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			items := MENUS[state.open_menu_index].items
			if state.hovered_item_index < 0 || state.hovered_item_index >= len(items) { return true }
			selected := items[state.hovered_item_index]
			if selected.action == .None { return true }
			close(state)
			dispatch_action(api, state, selected.action)
			return true
		}
		return true
	}

	return state.open_menu_index >= 0
}

@(private="file")
dispatch_action :: proc(api: ^binding.EditorAPI, state: ^State, action: ActionKind) {
	// Hide the bar on the next visibility check, even if Alt is
	// still held — matches platform-standard "menu disappears
	// after selection".
	state.alt_press_consumed = true
	// Forward via api — wired in editor_init. The action is sent
	// as a u32 (its enum representation) so the leaf `binding`
	// package doesn't have to know about ActionKind.
	if api == nil { return }
	if api.dispatch_menu_action != nil {
		api.dispatch_menu_action(api.editor, u32(action))
	}
}

// --- Rendering -------------------------------------------------------

render_bar :: proc(state: ^State, ui_context: ^ui.Context, theme: binding.Theme, window_width: i32) {
	if !is_visible(state) {
		state.title_count = 0
		return
	}
	renderer := ui_context.renderer
	if renderer == nil { return }
	line_height := ui_context.line_height
	bar_height := bar_paint_height(line_height)

	// Background strip.
	bar_rectangle := sdl3.FRect{0, 0, f32(window_width), f32(bar_height)}
	sdl3.SetRenderDrawColorFloat(renderer, theme.status_bar_background.r, theme.status_bar_background.g, theme.status_bar_background.b, theme.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &bar_rectangle)

	// Hairline underneath the strip.
	hairline_rectangle := sdl3.FRect{0, f32(bar_height - 1), f32(window_width), 1}
	sdl3.SetRenderDrawColorFloat(renderer, theme.divider_color.r, theme.divider_color.g, theme.divider_color.b, theme.divider_color.a)
	sdl3.RenderFillRect(renderer, &hairline_rectangle)

	// Title row.
	current_x: i32 = 0
	state.title_count = 0
	for menu_def, menu_index in MENUS {
		if state.title_count >= len(state.title_rectangles) { break }

		title_width, _ := ui.text_size(ui_context, menu_def.title)
		cell_width  := title_width + TITLE_PADDING * 2
		title_rect := sdl3.FRect{f32(current_x), 0, f32(cell_width), f32(bar_height)}
		state.title_rectangles[state.title_count] = title_rect
		state.title_count += 1

		is_open := menu_index == state.open_menu_index
		if is_open {
			sdl3.SetRenderDrawColorFloat(renderer, theme.selection_color.r, theme.selection_color.g, theme.selection_color.b, theme.selection_color.a)
			sdl3.RenderFillRect(renderer, &title_rect)
		}

		text_color := is_open ? theme.cursor_color : theme.status_bar_foreground
		text_y    := (bar_height - line_height) / 2
		title_x   := current_x + TITLE_PADDING
		ui.draw_text(ui_context, menu_def.title, title_x, text_y, text_color)

		// Mnemonic underline (while Alt is held or menu is open).
		if state.alt_held || is_open {
			mnemonic_position := mnemonic_index_in_title(menu_def.title, menu_def.mnemonic_letter)
			if mnemonic_position >= 0 {
				prefix_width:    i32 = 0
				if mnemonic_position > 0 {
					prefix_width, _ = ui.text_size(ui_context, menu_def.title[:mnemonic_position])
				}
				mnemonic_char_text := menu_def.title[mnemonic_position:mnemonic_position+1]
				mnemonic_char_width, _ := ui.text_size(ui_context, mnemonic_char_text)

				underline_y := text_y + line_height - 2
				underline_x := title_x + prefix_width
				sdl3.SetRenderDrawColorFloat(renderer, text_color.r, text_color.g, text_color.b, text_color.a)
				sdl3.RenderLine(renderer, f32(underline_x), f32(underline_y), f32(underline_x + mnemonic_char_width - 1), f32(underline_y))
			}
		}

		current_x += cell_width
	}
}

render_dropdown :: proc(state: ^State, ui_context: ^ui.Context, theme: binding.Theme, window_width, window_height: i32) {
	if state.open_menu_index < 0 || state.open_menu_index >= len(MENUS) { return }
	renderer := ui_context.renderer
	if renderer == nil { return }
	line_height := ui_context.line_height
	bar_height  := bar_paint_height(line_height)
	menu_def    := MENUS[state.open_menu_index]
	items       := menu_def.items

	// Measure widest label + widest shortcut.
	max_label_width:    i32 = 0
	max_shortcut_width: i32 = 0
	has_any_shortcut := false
	for item in items {
		if item.action == .None { continue }
		label_width, _ := ui.text_size(ui_context, item.label)
		if label_width > max_label_width { max_label_width = label_width }
		if len(item.shortcut) > 0 {
			shortcut_width, _ := ui.text_size(ui_context, item.shortcut)
			if shortcut_width > max_shortcut_width { max_shortcut_width = shortcut_width }
			has_any_shortcut = true
		}
	}

	dropdown_width := ITEM_HORIZONTAL_PADDING * 2 + max_label_width
	if has_any_shortcut {
		dropdown_width += SHORTCUT_GAP + max_shortcut_width
	}

	dropdown_x: i32 = i32(state.title_rectangles[state.open_menu_index].x)
	if dropdown_x + dropdown_width > window_width - 4 {
		dropdown_x = window_width - 4 - dropdown_width
		if dropdown_x < 0 { dropdown_x = 0 }
	}
	dropdown_y: i32 = bar_height

	row_height := line_height + ITEM_VERTICAL_PADDING * 2
	total_height: i32 = 4
	for item in items {
		if item.action == .None { total_height += SEPARATOR_HEIGHT }
		else                    { total_height += row_height }
	}
	total_height += 4

	if dropdown_y + total_height > window_height { total_height = window_height - dropdown_y - 4 }

	dropdown_rect := sdl3.FRect{f32(dropdown_x), f32(dropdown_y), f32(dropdown_width), f32(total_height)}

	sdl3.SetRenderDrawColorFloat(renderer, theme.background_color.r, theme.background_color.g, theme.background_color.b, theme.background_color.a)
	sdl3.RenderFillRect(renderer, &dropdown_rect)
	sdl3.SetRenderDrawColorFloat(renderer, theme.divider_color.r, theme.divider_color.g, theme.divider_color.b, theme.divider_color.a)
	sdl3.RenderRect(renderer, &dropdown_rect)

	state.dropdown_x     = dropdown_x
	state.dropdown_y     = dropdown_y
	state.dropdown_width = dropdown_width
	state.item_count     = 0

	current_y := dropdown_y + 4
	for item, item_index in items {
		if state.item_count >= len(state.item_rectangles) { break }

		if item.action == .None {
			state.item_rectangles[state.item_count] = sdl3.FRect{0, 0, 0, 0}
			state.item_count += 1
			rule_y := current_y + SEPARATOR_HEIGHT / 2
			sdl3.SetRenderDrawColorFloat(renderer, theme.divider_color.r, theme.divider_color.g, theme.divider_color.b, theme.divider_color.a)
			sdl3.RenderLine(renderer, f32(dropdown_x + 6), f32(rule_y), f32(dropdown_x + dropdown_width - 6), f32(rule_y))
			current_y += SEPARATOR_HEIGHT
			continue
		}

		row_rect := sdl3.FRect{f32(dropdown_x + 2), f32(current_y), f32(dropdown_width - 4), f32(row_height)}
		state.item_rectangles[state.item_count] = row_rect
		state.item_count += 1

		is_hovered := item_index == state.hovered_item_index
		if is_hovered {
			sdl3.SetRenderDrawColorFloat(renderer, theme.selection_color.r, theme.selection_color.g, theme.selection_color.b, theme.selection_color.a)
			sdl3.RenderFillRect(renderer, &row_rect)
		}

		label_text_color    := is_hovered ? theme.cursor_color          : theme.status_bar_foreground
		shortcut_text_color := is_hovered ? theme.status_bar_foreground : theme.line_number_color

		ui.draw_text(ui_context, item.label,
			dropdown_x + ITEM_HORIZONTAL_PADDING,
			current_y + ITEM_VERTICAL_PADDING,
			label_text_color)

		if len(item.shortcut) > 0 {
			shortcut_width, _ := ui.text_size(ui_context, item.shortcut)
			shortcut_x := dropdown_x + dropdown_width - ITEM_HORIZONTAL_PADDING - shortcut_width
			ui.draw_text(ui_context, item.shortcut, shortcut_x, current_y + ITEM_VERTICAL_PADDING, shortcut_text_color)
		}

		current_y += row_height
	}
}

