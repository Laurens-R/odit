// Event handling + render for the Ctrl+Shift+R replace-in-files
// dialog.
package replace_in_files

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import "../textutil"
import "../../ui"

// Returns true when the event was consumed.
handle_event :: proc(state: ^State, event: ^sdl3.Event) -> bool {
	if !state.visible { return false }

	// The completion popup is its own modal layer — it intercepts
	// every event while shown so the user can't accidentally re-run
	// Replace All from a stray key press.
	if state.show_completion {
		#partial switch event.type {
		case .KEY_DOWN:
			pressed_key := event.key.key
			if pressed_key == sdl3.K_RETURN || pressed_key == sdl3.K_ESCAPE || pressed_key == sdl3.K_SPACE {
				state.show_completion = false
			}
		case .MOUSE_BUTTON_DOWN:
			if event.button.button == sdl3.BUTTON_LEFT {
				if ui.point_in_rect(state.completion_ok_button_rectangle, event.button.x, event.button.y) {
					state.show_completion = false
				}
			}
		}
		return true
	}

	#partial switch event.type {
	case .TEXT_INPUT:
		if buffer := focused_buffer(state); buffer != nil {
			input_text := string(event.text.text)
			for byte_value in transmute([]u8)input_text {
				// Newlines are illegal in any of the three input
				// fields. In the Replace field they would invalidate
				// every other Pending match's line/column offsets
				// after a single replace.
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(buffer, byte_value)
			}
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		if ctrl_held && shift_held && pressed_key == sdl3.K_R {
			close(state)
			return true
		}

		switch pressed_key {
		case sdl3.K_ESCAPE:
			close(state)

		case sdl3.K_TAB:
			if shift_held { focus_prev(state) } else { focus_next(state) }

		case sdl3.K_RETURN:
			switch state.focus {
			case .PathInput, .SearchInput, .ReplaceInput, .FindAllButton:
				find_all(state)
			case .ReplaceNextButton:
				replace_next(state)
			case .ReplaceAllButton:
				replace_all(state)
			case .ClearButton:
				clear_action(state)
			case .CancelButton:
				close(state)
			case .Results:
				replace_next(state)
			}

		case sdl3.K_BACKSPACE:
			if buffer := focused_buffer(state); buffer != nil {
				buffer_backspace(buffer)
			}

		case sdl3.K_UP:       if state.focus == .Results { move_selection(state, -1) }
		case sdl3.K_DOWN:     if state.focus == .Results { move_selection(state, +1) }
		case sdl3.K_PAGEUP:
			if state.focus == .Results {
				step := state.visible_row_count;  if step < 1 { step = 1 }
				move_selection(state, -step)
			}
		case sdl3.K_PAGEDOWN:
			if state.focus == .Results {
				step := state.visible_row_count;  if step < 1 { step = 1 }
				move_selection(state, +step)
			}
		case sdl3.K_HOME: if state.focus == .Results { move_selection(state, -len(state.results)) }
		case sdl3.K_END:  if state.focus == .Results { move_selection(state, +len(state.results)) }
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return true }
		mouse_x, mouse_y := event.button.x, event.button.y

		// Scrollbar hit-test first — a thumb grab on top of the
		// results list should latch a drag, not select the row
		// underneath.
		if ui.scrollbar_thumb_hit(&state.results_scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_thumb_drag(&state.results_scrollbar, mouse_y)
			return true
		}
		if ui.scrollbar_track_hit(&state.results_scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_track_drag(&state.results_scrollbar)
			// Caller forwards the line_height via render; for drag
			// we use the cached visible_row_count to estimate
			// pixels-per-row. apply_scrollbar_drag will read
			// `state.visible_row_count`.
		}

		switch {
		case ui.point_in_rect(state.path_field_rectangle,           mouse_x, mouse_y):
			state.focus = .PathInput
		case ui.point_in_rect(state.search_field_rectangle,         mouse_x, mouse_y):
			state.focus = .SearchInput
		case ui.point_in_rect(state.replace_field_rectangle,        mouse_x, mouse_y):
			state.focus = .ReplaceInput
		case ui.point_in_rect(state.find_all_button_rectangle,      mouse_x, mouse_y):
			state.focus = .FindAllButton
			find_all(state)
		case ui.point_in_rect(state.replace_next_button_rectangle,  mouse_x, mouse_y):
			state.focus = .ReplaceNextButton
			replace_next(state)
		case ui.point_in_rect(state.replace_all_button_rectangle,   mouse_x, mouse_y):
			state.focus = .ReplaceAllButton
			replace_all(state)
		case ui.point_in_rect(state.clear_button_rectangle,         mouse_x, mouse_y):
			state.focus = .ClearButton
			clear_action(state)
		case ui.point_in_rect(state.cancel_button_rectangle,        mouse_x, mouse_y):
			state.focus = .CancelButton
			close(state)
		case ui.point_in_rect(state.results_list_rectangle,         mouse_x, mouse_y):
			state.focus = .Results
			// Clicking a row only selects it; the user still has to
			// press Replace Next / Replace All to mutate anything.
			// Row height is derived from the visible-area / row-
			// count split set during render.
			row_count := state.visible_row_count
			if row_count > 0 && state.results_list_rectangle.h > 0 {
				row_height := state.results_list_rectangle.h / f32(row_count)
				if row_height > 0 {
					relative_y := mouse_y - state.results_list_rectangle.y
					if relative_y >= 0 {
						row_index_in_view := int(relative_y / row_height)
						target_index := state.scroll_offset + row_index_in_view
						if target_index >= 0 && target_index < len(state.results) {
							state.selected_index = target_index
						}
					}
				}
			}
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT && state.results_scrollbar.is_dragging {
			ui.scrollbar_end_drag(&state.results_scrollbar)
		}

	case .MOUSE_MOTION:
		if state.results_scrollbar.is_dragging {
			// Approximate line_height from the cached list rect.
			row_count := state.visible_row_count
			if row_count > 0 && state.results_list_rectangle.h > 0 {
				row_height := i32(state.results_list_rectangle.h / f32(row_count))
				apply_scrollbar_drag(state, event.motion.y, row_height)
			}
		} else {
			_ = ui.scrollbar_update_hover(&state.results_scrollbar, event.motion.x, event.motion.y)
		}

	case .MOUSE_WHEEL:
		if state.visible_row_count > 0 && len(state.results) > 0 {
			scroll_delta := -int(event.wheel.y * 3)
			max_offset   := max(0, len(state.results) - state.visible_row_count)
			new_offset   := state.scroll_offset + scroll_delta
			if new_offset < 0          { new_offset = 0 }
			if new_offset > max_offset { new_offset = max_offset }
			state.scroll_offset = new_offset
		}
	}
	return true
}

render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	if !state.visible { return }
	theme := ui.default_theme()

	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	character_width := ui_context.character_width
	line_height     := ui_context.line_height

	desired_columns: i32 = 110
	desired_rows:    i32 = 40
	dialog_width  := min(desired_columns * character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows    * line_height     + 40, viewport_height - 40)
	if dialog_width  < 280 { dialog_width  = min(viewport_width  - 16, 280) }
	if dialog_height < 280 { dialog_height = min(viewport_height - 16, 280) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Replace in Files", theme)

	line_step     := line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	// Three input fields stacked.
	state.path_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Path:    ", string(state.path_buffer[:]),    theme, state.focus == .PathInput)
	content_y += line_step + 14

	state.search_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Search:  ", string(state.search_buffer[:]),  theme, state.focus == .SearchInput)
	content_y += line_step + 14

	state.replace_field_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Replace: ", string(state.replace_buffer[:]), theme, state.focus == .ReplaceInput)
	content_y += line_step + 14

	// Five-button row.
	standard_button_width: i32 = 14 * character_width
	replace_button_width:  i32 = 18 * character_width
	button_height:         i32 = line_step + 12
	button_gap:            i32 = 8
	buttons_total_width := standard_button_width + replace_button_width + replace_button_width + standard_button_width + standard_button_width + button_gap * 4
	buttons_start_x := content_x + (content_width - buttons_total_width) / 2

	current_x := buttons_start_x
	state.find_all_button_rectangle     = sdl3.FRect{f32(current_x), f32(content_y), f32(standard_button_width), f32(button_height)}
	current_x += standard_button_width + button_gap
	state.replace_next_button_rectangle = sdl3.FRect{f32(current_x), f32(content_y), f32(replace_button_width),  f32(button_height)}
	current_x += replace_button_width + button_gap
	state.replace_all_button_rectangle  = sdl3.FRect{f32(current_x), f32(content_y), f32(replace_button_width),  f32(button_height)}
	current_x += replace_button_width + button_gap
	state.clear_button_rectangle        = sdl3.FRect{f32(current_x), f32(content_y), f32(standard_button_width), f32(button_height)}
	current_x += standard_button_width + button_gap
	state.cancel_button_rectangle       = sdl3.FRect{f32(current_x), f32(content_y), f32(standard_button_width), f32(button_height)}

	ui.draw_button(ui_context, state.find_all_button_rectangle,     "Find All",     state.focus == .FindAllButton,     theme)
	ui.draw_button(ui_context, state.replace_next_button_rectangle, "Replace Next", state.focus == .ReplaceNextButton, theme)
	ui.draw_button(ui_context, state.replace_all_button_rectangle,  "Replace All",  state.focus == .ReplaceAllButton,  theme)
	ui.draw_button(ui_context, state.clear_button_rectangle,        "Clear",        state.focus == .ClearButton,       theme)
	ui.draw_button(ui_context, state.cancel_button_rectangle,       "Cancel",       state.focus == .CancelButton,      theme)

	content_y += button_height + 12

	if len(state.error_message) > 0 {
		ui.draw_text(ui_context, state.error_message, content_x, content_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
		content_y += line_step + 4
	}

	// Results viewport
	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	if list_area_height < line_step { list_area_height = line_step }
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	scrollbar_reservation: i32 = ui.SCROLLBAR_NARROW_WIDTH + 2
	row_width := content_width - scrollbar_reservation
	if row_width < character_width { row_width = character_width }

	state.results_list_rectangle = sdl3.FRect{f32(content_x), f32(list_top_y), f32(content_width), f32(list_area_height)}

	max_scroll_offset := max(0, len(state.results) - computed_visible_rows)
	if state.scroll_offset > max_scroll_offset { state.scroll_offset = max_scroll_offset }
	if state.scroll_offset < 0                 { state.scroll_offset = 0 }

	if len(state.results) == 0 {
		empty_message: string
		if len(state.search_buffer) == 0 {
			empty_message = "(enter search & replace text, then press Find All)"
		} else if len(state.error_message) == 0 {
			empty_message = "(no results — press Find All)"
		}
		if len(empty_message) > 0 {
			ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
		}
	} else {
		render_result_rows(state, ui_context, content_x, list_top_y, row_width, line_step, computed_visible_rows, theme)
	}

	// Scrollbar.
	total_rows := len(state.results)
	if total_rows > 0 {
		content_height_pixels  := f32(total_rows * int(line_step))
		viewport_height_pixels := f32(list_area_height)
		current_scroll_pixels  := f32(state.scroll_offset * int(line_step))
		ui.scrollbar_render(ui_context, &state.results_scrollbar,
			content_x + content_width, list_top_y, list_area_height,
			viewport_height_pixels, content_height_pixels, current_scroll_pixels, theme)
	} else {
		state.results_scrollbar.track_rectangle = sdl3.FRect{}
		state.results_scrollbar.thumb_rectangle = sdl3.FRect{}
	}

	// Footer hints (left) + counters (right).
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	hint_text := "Tab focus  Enter find-all / replace-next  ↑/↓ navigate  Esc close"
	ui.draw_text(ui_context, hint_text, i32(dialog_rectangle.x) + 12, footer_y, theme.dim_foreground)

	if len(state.results) > 0 {
		pending_count, replaced_count := 0, 0
		for result_value in state.results {
			switch result_value.status {
			case .Pending:  pending_count  += 1
			case .Replaced: replaced_count += 1
			}
		}
		counter_text: string
		if len(state.results) >= RIF_MAX_RESULTS {
			counter_text = fmt.tprintf("%d+ matches  (pending %d, replaced %d)", len(state.results), pending_count, replaced_count)
		} else {
			counter_text = fmt.tprintf("%d matches  (pending %d, replaced %d)", len(state.results), pending_count, replaced_count)
		}
		counter_width, _ := ui.text_size(ui_context, counter_text)
		counter_x := i32(dialog_rectangle.x + dialog_rectangle.w) - 12 - counter_width
		ui.draw_text(ui_context, counter_text, counter_x, footer_y, theme.dim_foreground)
	}

	// Completion popup overlays everything else when shown.
	if state.show_completion {
		render_completion_popup(state, ui_context, viewport_width, viewport_height, theme)
	}
}

@(private="file")
render_result_rows :: proc(
	state: ^State, ui_context: ^ui.Context,
	content_x, list_top_y, content_width, line_step: i32,
	computed_visible_rows: int, theme: ui.Theme,
) {
	character_width := ui_context.character_width
	label_indent_pixels: i32 = 8
	right_margin_pixels: i32 = 8
	usable_pixels := content_width - label_indent_pixels - right_margin_pixels
	if usable_pixels < character_width { usable_pixels = character_width }
	max_chars_per_row := int(usable_pixels / character_width)

	padded_prefix_chars := state.max_prefix_chars + 2
	if padded_prefix_chars > max_chars_per_row - 8 { padded_prefix_chars = max_chars_per_row - 8 }
	if padded_prefix_chars < 1                     { padded_prefix_chars = 1 }

	replaced_row_tint    := sdl3.FColor{0.20, 0.55, 0.30, 0.35}
	replaced_label_color := sdl3.FColor{0.60, 0.95, 0.65, 1.00}

	end_row_index := min(state.scroll_offset + computed_visible_rows, len(state.results))
	for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
		result := state.results[row_index]
		row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
		is_selected := row_index == state.selected_index && state.focus == .Results

		if is_selected {
			selection_background_rectangle := sdl3.FRect{f32(content_x), f32(row_y_position), f32(content_width), f32(line_step)}
			sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.title_background.r, theme.title_background.g, theme.title_background.b, theme.title_background.a)
			sdl3.RenderFillRect(ui_context.renderer, &selection_background_rectangle)
		}

		if result.status == .Replaced {
			tint_rectangle := sdl3.FRect{f32(content_x), f32(row_y_position), f32(content_width), f32(line_step)}
			sdl3.SetRenderDrawBlendMode(ui_context.renderer, sdl3.BLENDMODE_BLEND)
			sdl3.SetRenderDrawColorFloat(ui_context.renderer, replaced_row_tint.r, replaced_row_tint.g, replaced_row_tint.b, replaced_row_tint.a)
			sdl3.RenderFillRect(ui_context.renderer, &tint_rectangle)
			sdl3.SetRenderDrawBlendMode(ui_context.renderer, sdl3.BLENDMODE_NONE)
		}

		if is_selected {
			stripe_rectangle := sdl3.FRect{f32(content_x), f32(row_y_position), 2, f32(line_step)}
			sdl3.SetRenderDrawColorFloat(ui_context.renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
			sdl3.RenderFillRect(ui_context.renderer, &stripe_rectangle)
		}

		prefix_string := fmt.tprintf("%s:%d:%d", result.relative_path, result.line + 1, result.column + 1)
		prefix_chars := utf8.rune_count_in_string(prefix_string)
		padding_chars := padded_prefix_chars - prefix_chars
		if padding_chars < 1 { padding_chars = 1 }
		padding_string := strings.repeat(" ", padding_chars, context.temp_allocator)

		combined_row := strings.concatenate({prefix_string, padding_string, result.snippet}, context.temp_allocator)
		row_label := textutil.truncate_to_runes_with_ellipsis(combined_row, max_chars_per_row)

		text_color := is_selected ? theme.title_foreground : theme.text_foreground
		if result.status == .Replaced { text_color = replaced_label_color }
		ui.draw_text(ui_context, row_label, content_x + label_indent_pixels, row_y_position, text_color)
	}
}

@(private="file")
render_completion_popup :: proc(
	state: ^State, parent_ui_context: ^ui.Context,
	viewport_width, viewport_height: i32, theme: ui.Theme,
) {
	character_width := parent_ui_context.character_width
	line_step       := parent_ui_context.line_height

	ui.draw_dim_overlay(parent_ui_context, viewport_width, viewport_height, theme.overlay)

	popup_width  := min(50 * character_width + 32, viewport_width  - 80)
	popup_height := min( 8 * line_step       + 40, viewport_height - 80)
	if popup_width  < 280 { popup_width  = min(viewport_width  - 16, 280) }
	if popup_height < 160 { popup_height = min(viewport_height - 16, 160) }
	popup_x := (viewport_width  - popup_width)  / 2
	popup_y := (viewport_height - popup_height) / 2
	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}

	content_rectangle := ui.draw_window(parent_ui_context, popup_rectangle, "Replace All", theme)

	content_x    := i32(content_rectangle.x)
	content_y    := i32(content_rectangle.y) + line_step
	content_width := i32(content_rectangle.w)

	message := fmt.tprintf("A total of %d instance%s ha%s been replaced.",
		state.completion_count,
		state.completion_count == 1 ? ""  : "s",
		state.completion_count == 1 ? "s" : "ve")
	message_width, _ := ui.text_size(parent_ui_context, message)
	message_x := content_x + (content_width - message_width) / 2
	ui.draw_text(parent_ui_context, message, message_x, content_y, theme.text_foreground)

	button_width:  i32 = 14 * character_width
	button_height: i32 = line_step + 12
	button_x := i32(popup_rectangle.x + (popup_rectangle.w - f32(button_width)) / 2)
	button_y := i32(popup_rectangle.y + popup_rectangle.h) - button_height - 14

	state.completion_ok_button_rectangle = sdl3.FRect{f32(button_x), f32(button_y), f32(button_width), f32(button_height)}
	ui.draw_button(parent_ui_context, state.completion_ok_button_rectangle, "OK", true, theme)
}
