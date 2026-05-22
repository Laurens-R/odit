package editor

import "vendor:sdl3"

import "../document"
import "../terminal"
import "../ui"

// Set the OS cursor to `target_cursor` if it's not already the active one.
// Centralised so hover, drag, and release paths don't fight each other over
// the cursor.
@(private="file")
set_cursor :: proc(editor: ^Editor, target_cursor: ^sdl3.Cursor) {
	if target_cursor == nil || editor.current_cursor == target_cursor { return }
	_ = sdl3.SetCursor(target_cursor)
	editor.current_cursor = target_cursor
}

// Pick a cursor shape based on what (mouse_x, mouse_y) is over right now
// plus the active drag state. EW-resize on the pane-split divider or the
// debug-panel left edge; NS-resize on a debug-section divider; default
// arrow otherwise.
@(private)
editor_update_cursor :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	debug_wants_ew, debug_wants_ns := debug_panel_handle_cursor_kind(editor, mouse_x, mouse_y)
	if editor.divider_dragging || divider_hit_test(editor, mouse_x, mouse_y) || debug_wants_ew {
		set_cursor(editor, editor.cursor_resize_ew)
	} else if debug_wants_ns {
		set_cursor(editor, editor.cursor_resize_ns)
	} else {
		set_cursor(editor, editor.cursor_default)
	}
}

// Pan the active pane horizontally by `column_delta` columns. No-op when the
// pane is in wrap mode (the model says wrap and horizontal scroll are
// mutually exclusive — Ctrl+W toggles between them) or when there's no
// editor pane focused.
@(private)
editor_scroll_horizontal :: proc(editor: ^Editor, column_delta: i32) {
	if column_delta == 0 || editor.character_width == 0 { return }
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if editor_pane.wrap_mode { return }
	scroll_step_pixels := f32(column_delta * editor.character_width)
	new_scroll_target  := editor_pane.scroll_x_target + scroll_step_pixels
	if new_scroll_target < 0 { new_scroll_target = 0 }
	editor_pane.scroll_x_target = new_scroll_target
}

// Flip wrap-mode for the active pane. Horizontal scroll resets to zero on
// entering wrap (since the pane is now obligated to fit lines within the
// width). Cursor visibility is re-evaluated so the cursor stays on screen
// either way.
@(private)
editor_toggle_wrap :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	editor_pane.wrap_mode = !editor_pane.wrap_mode
	if editor_pane.wrap_mode {
		editor_pane.scroll_x        = 0
		editor_pane.scroll_x_target = 0
	}
	ensure_cursor_visible(editor)
	editor.cursor_visible = true
	editor.cursor_timer   = 0
}

// Scroll the active pane (if it's an editor pane) by `line_delta`. In diff
// mode the shared diff-state scroll is moved instead so both panes stay in
// lockstep.
@(private)
editor_scroll :: proc(editor: ^Editor, line_delta: i32) {
	if line_delta == 0 || editor.line_height == 0 { return }

	if editor.diff_state.active {
		active_pane_visible_lines := i32(editor.panes[editor.active_pane_index].rectangle.h / editor.line_height)
		if active_pane_visible_lines == 0 { active_pane_visible_lines = 1 }
		max_scroll_row_count := max(i32(0), i32(len(editor.diff_state.rows)) - active_pane_visible_lines)
		max_scroll_y := f32(max_scroll_row_count * editor.line_height)
		new_scroll_target := editor.diff_state.scroll_y_target + f32(line_delta * editor.line_height)
		editor.diff_state.scroll_y_target = clamp(new_scroll_target, 0, max_scroll_y)
		return
	}

	active_editor_pane := editor_active_editor_pane(editor); if active_editor_pane == nil { return }
	total_line_count := i32(document.document_line_count(&active_editor_pane.document))
	visible_line_count := i32(active_editor_pane.visible_lines)
	if visible_line_count == 0 { visible_line_count = 1 }
	max_scroll_line_count := max(i32(0), total_line_count - visible_line_count)
	max_scroll_y := f32(max_scroll_line_count * editor.line_height)
	new_scroll_target := active_editor_pane.scroll_y_target + f32(line_delta * editor.line_height)
	active_editor_pane.scroll_y_target = clamp(new_scroll_target, 0, max_scroll_y)
}

@(private)
editor_mouse_down :: proc(editor: ^Editor, mouse_x: f32, mouse_y: f32, shift_held: bool, click_count: i32 = 1) {
	// Any click in the editor dismisses the LSP hover popup — it's
	// anchored to a specific symbol, so clicking elsewhere counts as
	// "the user moved on".
	if editor.hover_popup.visible { hover_popup_close(editor) }

	// Grab the divider first when both panes are showing — the hit zone is
	// generous (a few pixels either side of the 2-px line) because the line
	// itself is hard to hit precisely.
	if divider_hit_test(editor, mouse_x, mouse_y) {
		editor.divider_dragging = true
		return
	}

	// Debug panel sits on the right edge and isn't a pane. Its hit-test
	// returns true for any click landing inside, so we have to dispatch
	// before the regular pane routing.
	if debug_panel_handle_click(editor, mouse_x, mouse_y) { return }

	// Find bar swallows clicks that land on it (so the user can poke at it
	// without dismissing find). A click anywhere else closes find and falls
	// through to normal click handling so the cursor still lands where they
	// clicked.
	if find_active(editor) {
		if ui.point_in_rect(editor.find.bar_rectangle, mouse_x, mouse_y) { return }
		find_close(editor)
	}
	// Replace bar: a click inside the bar focuses whichever input field was
	// hit. A click outside cancels the in-progress preview and falls through
	// to normal cursor placement.
	if replace_active(editor) {
		if ui.point_in_rect(editor.replace.bar_rectangle, mouse_x, mouse_y) {
			replace_handle_bar_click(editor, mouse_x, mouse_y)
			return
		}
		replace_close(editor, false)
	}

	pane_hit_index := editor_pane_at(editor, mouse_x, mouse_y)
	if pane_hit_index < 0 { return }
	editor.active_pane_index = pane_hit_index

	pane := &editor.panes[pane_hit_index]
	#partial switch &content_value in pane.content {
	case EditorPane:
		// Scrollbar takes priority over text selection — clicking the thumb
		// (or anywhere on the track) latches a drag instead of moving the
		// cursor. Track click jumps to that position and then drags.
		if ui.scrollbar_thumb_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_thumb_drag(&content_value.scrollbar, mouse_y)
			return
		}
		if ui.scrollbar_track_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_track_drag(&content_value.scrollbar)
			scrollbar_apply_to_editor_pane(editor, &content_value, mouse_y)
			return
		}
		editor_pane_mouse_down(editor, pane, &content_value, mouse_x, mouse_y, shift_held, click_count)

	case TerminalPane:
		if content_value.terminal == nil { return }
		if ui.scrollbar_thumb_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_thumb_drag(&content_value.scrollbar, mouse_y)
			return
		}
		if ui.scrollbar_track_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_track_drag(&content_value.scrollbar)
			scrollbar_apply_to_terminal_pane(&content_value, mouse_y)
			return
		}
		title_bar_height := editor_title_bar_height(editor)
		if mouse_y < f32(pane.rectangle.y + title_bar_height) { return }
		terminal.terminal_mouse_down(content_value.terminal, mouse_x, mouse_y)

	case MarkdownPreviewPane:
		if ui.scrollbar_thumb_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_thumb_drag(&content_value.scrollbar, mouse_y)
			return
		}
		if ui.scrollbar_track_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_track_drag(&content_value.scrollbar)
			scrollbar_apply_to_markdown_pane(&content_value, mouse_y)
			return
		}

	case OutputPane:
		if ui.scrollbar_thumb_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_thumb_drag(&content_value.scrollbar, mouse_y)
			return
		}
		if ui.scrollbar_track_hit(&content_value.scrollbar, mouse_x, mouse_y) {
			ui.scrollbar_begin_track_drag(&content_value.scrollbar)
			scrollbar_apply_to_output_pane(editor, &content_value, mouse_y)
			return
		}
		title_bar_height := editor_title_bar_height(editor)
		if mouse_y < f32(pane.rectangle.y + title_bar_height) { return }
		output_pane_mouse_down(editor, &content_value, pane, mouse_x, mouse_y)
	}
}

// --- Pane-specific scroll setters -----------------------------------------
//
// The shared `ui.Scrollbar` widget knows nothing about each pane's storage
// units — these helpers translate its drag output (a pixel scroll value in
// `[0, max_scroll]`) into whatever the pane actually stores: editor pane
// pixel scroll + animated target, terminal pane rows-from-bottom offset,
// markdown preview pixel scroll, output pane integer pixel scroll +
// sticky-to-bottom flag.

@(private="file")
scrollbar_apply_to_editor_pane :: proc(editor: ^Editor, editor_pane: ^EditorPane, mouse_y: f32) {
	if editor.line_height <= 0 { return }
	if editor.diff_state.active {
		diff_row_count := f32(len(editor.diff_state.rows))
		content_height  := diff_row_count * f32(editor.line_height)
		viewport_height := f32(editor_pane.visible_lines) * f32(editor.line_height)
		max_scroll := max(f32(0), content_height - viewport_height)
		new_scroll := ui.scrollbar_drag_to(&editor_pane.scrollbar, mouse_y, max_scroll)
		editor.diff_state.scroll_y        = new_scroll
		editor.diff_state.scroll_y_target = new_scroll
		return
	}
	total_line_count := f32(document.document_line_count(&editor_pane.document))
	content_height  := total_line_count * f32(editor.line_height)
	viewport_height := f32(editor_pane.visible_lines) * f32(editor.line_height)
	max_scroll := max(f32(0), content_height - viewport_height)
	new_scroll := ui.scrollbar_drag_to(&editor_pane.scrollbar, mouse_y, max_scroll)
	editor_pane.scroll_y        = new_scroll
	editor_pane.scroll_y_target = new_scroll
	editor_pane.scroll_line     = u32(new_scroll / f32(editor.line_height))
}

@(private="file")
scrollbar_apply_to_terminal_pane :: proc(terminal_pane: ^TerminalPane, mouse_y: f32) {
	if terminal_pane.terminal == nil { return }
	line_height := terminal_pane.terminal.line_height
	if line_height <= 0 { return }
	screen := &terminal_pane.terminal.screen
	scrollback_count := i32(len(screen.scrollback_rows))
	content_height  := f32(scrollback_count + screen.rows) * f32(line_height)
	viewport_height := f32(screen.rows) * f32(line_height)
	max_scroll := max(f32(0), content_height - viewport_height)
	new_scroll := ui.scrollbar_drag_to(&terminal_pane.scrollbar, mouse_y, max_scroll)
	// Convert top-relative pixel scroll into rows-up-from-the-live-bottom.
	new_offset := scrollback_count - i32(new_scroll / f32(line_height) + 0.5)
	if new_offset < 0                { new_offset = 0 }
	if new_offset > scrollback_count { new_offset = scrollback_count }
	terminal_pane.terminal.scroll_offset = new_offset
}

@(private="file")
scrollbar_apply_to_markdown_pane :: proc(preview_pane: ^MarkdownPreviewPane, mouse_y: f32) {
	max_scroll := preview_pane.last_max_scroll_pixels
	if max_scroll <= 0 { return }
	new_scroll := ui.scrollbar_drag_to(&preview_pane.scrollbar, mouse_y, max_scroll)
	preview_pane.scroll_y_target = new_scroll
	preview_pane.scroll_y        = new_scroll
}

@(private="file")
scrollbar_apply_to_output_pane :: proc(editor: ^Editor, output_pane: ^OutputPane, mouse_y: f32) {
	if editor.line_height <= 0 { return }
	line_count := i32(len(editor.debug_output_lines))
	body_h := editor.panes[TERMINAL_PANE_INDEX].rectangle.h - editor_title_bar_height(editor)
	if body_h <= 0 { return }
	content_height := f32(line_count * editor.line_height)
	max_scroll := max(f32(0), content_height - f32(body_h))
	new_scroll := ui.scrollbar_drag_to(&output_pane.scrollbar, mouse_y, max_scroll)
	output_pane.scroll_y         = i32(new_scroll)
	output_pane.sticky_to_bottom = output_pane.scroll_y >= i32(max_scroll)
}

// Update the per-pane scrollbar hover flag from the current mouse position.
// Called on every MOUSE_MOTION so the next frame paints a widened scrollbar
// while the cursor is over it. Walks all pane content kinds that own a
// `ui.Scrollbar`.
@(private)
editor_scrollbar_update_hover :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	debug_panel_update_hover(editor, mouse_x, mouse_y)
	for pane_index in 0..<editor_visible_pane_count(editor) {
		#partial switch &content_value in editor.panes[pane_index].content {
		case EditorPane:
			if ui.scrollbar_update_hover(&content_value.scrollbar, mouse_x, mouse_y) { editor_mark_dirty(editor) }
		case TerminalPane:
			if ui.scrollbar_update_hover(&content_value.scrollbar, mouse_x, mouse_y) { editor_mark_dirty(editor) }
		case MarkdownPreviewPane:
			if ui.scrollbar_update_hover(&content_value.scrollbar, mouse_x, mouse_y) { editor_mark_dirty(editor) }
		case OutputPane:
			if ui.scrollbar_update_hover(&content_value.scrollbar, mouse_x, mouse_y) { editor_mark_dirty(editor) }
		}
	}
}

// True when (mouse_x,mouse_y) is inside the resize-handle zone around the
// divider. The physical divider is 2 px wide; we accept ±4 px on either side
// so the user can actually grab it. Only applicable when a split is
// currently active.
@(private="file")
divider_hit_test :: proc(editor: ^Editor, mouse_x, mouse_y: f32) -> bool {
	if !editor.split_active                    { return false }
	if editor_visible_pane_count(editor) != 2  { return false }
	// Divider runs vertically between the two pane rects.
	left_pane_rectangle  := editor.panes[0].rectangle
	right_pane_rectangle := editor.panes[1].rectangle
	divider_x := f32(left_pane_rectangle.x + left_pane_rectangle.w)
	divider_width := f32(right_pane_rectangle.x) - divider_x
	if divider_width <= 0 { return false }
	horizontal_padding: f32 = 4
	return mouse_x >= divider_x - horizontal_padding && mouse_x < divider_x + divider_width + horizontal_padding &&
	       mouse_y >= f32(left_pane_rectangle.y)     && mouse_y < f32(left_pane_rectangle.y + left_pane_rectangle.h)
}

@(private="file")
editor_pane_mouse_down :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x: f32, mouse_y: f32, shift_held: bool, click_count: i32) {
	// Gutter click → toggle a breakpoint at that line. Has to run before the
	// regular cursor-placement path so the same gesture doesn't also reposition
	// the text cursor. Shift+click in the gutter opens the conditional-bp
	// editor for that line instead of toggling.
	if editor_pane_gutter_toggle_breakpoint(editor, pane, editor_pane, mouse_x, mouse_y, shift_held) { return }

	clicked_offset := screen_to_offset(editor, pane, editor_pane, mouse_x, mouse_y)

	if shift_held {
		if !editor_pane.selection_active {
			editor_pane.selection_anchor = editor_pane.cursor_offset
			editor_pane.selection_active = true
		}
	} else {
		editor_pane.selection_anchor = clicked_offset
		editor_pane.selection_active = true
	}
	editor_pane.cursor_offset  = clicked_offset
	editor_pane.mouse_dragging = true
	editor.cursor_visible = true
	editor.cursor_timer = 0
	sync_cursor_from_offset(editor)

	// Double-click expands the click point to a word (identifier run) so the
	// usual "select word, copy / replace / search" flow doesn't need a manual
	// drag. Skipped on shift-click because that's an explicit extend-selection
	// gesture from the user.
	if click_count >= 2 && !shift_held {
		line_text     := document.document_get_line(&editor_pane.document, editor_pane.cursor_line, context.temp_allocator)
		cursor_column := int(editor_pane.cursor_column)
		word_start := cursor_column
		word_end   := cursor_column
		for word_start > 0           && is_word_byte(line_text[word_start - 1]) { word_start -= 1 }
		for word_end   < len(line_text) && is_word_byte(line_text[word_end])    { word_end   += 1 }
		if word_end > word_start {
			start_offset := clicked_offset - u32(cursor_column - word_start)
			end_offset   := clicked_offset + u32(word_end - cursor_column)
			editor_pane.selection_anchor = start_offset
			editor_pane.cursor_offset    = end_offset
			editor_pane.selection_active = true
			sync_cursor_from_offset(editor)
		}
	}
}

// Word-boundary predicate for double-click selection. Matches the identifier
// class used by completion / hover so a double-click selects exactly what the
// surrounding code already treats as one symbol.
@(private="file")
is_word_byte :: proc(byte_value: u8) -> bool {
	return (byte_value >= 'a' && byte_value <= 'z') ||
	       (byte_value >= 'A' && byte_value <= 'Z') ||
	       (byte_value >= '0' && byte_value <= '9') ||
	       byte_value == '_'
}

@(private)
editor_mouse_drag :: proc(editor: ^Editor, mouse_x: f32, mouse_y: f32) {
	// Debug-panel resize handles take top priority once latched — needs the
	// live window width, but mouse_drag doesn't carry it. Read it back from
	// the active panes (their cumulative width + the panel width).
	if debug_panel_is_dragging(&editor.debug_state) {
		window_width := editor.panes[0].rectangle.w + debug_panel_width(editor)
		if editor.split_active { window_width += editor.panes[1].rectangle.w + 2 }
		if debug_panel_handle_drag(editor, mouse_x, mouse_y, window_width) { return }
	}

	// Scrollbar drag takes top priority — once latched, every motion event
	// just maps to a new scroll position until the user releases the
	// button. Each pane content type stores its own scrollbar state.
	for pane_index in 0..<editor_visible_pane_count(editor) {
		#partial switch &content_value in editor.panes[pane_index].content {
		case EditorPane:
			if content_value.scrollbar.is_dragging {
				scrollbar_apply_to_editor_pane(editor, &content_value, mouse_y)
				editor_mark_dirty(editor)
				return
			}
		case TerminalPane:
			if content_value.scrollbar.is_dragging {
				scrollbar_apply_to_terminal_pane(&content_value, mouse_y)
				editor_mark_dirty(editor)
				return
			}
		case MarkdownPreviewPane:
			if content_value.scrollbar.is_dragging {
				scrollbar_apply_to_markdown_pane(&content_value, mouse_y)
				editor_mark_dirty(editor)
				return
			}
		case OutputPane:
			if content_value.scrollbar.is_dragging {
				scrollbar_apply_to_output_pane(editor, &content_value, mouse_y)
				editor_mark_dirty(editor)
				return
			}
		}
	}

	// Divider drag takes priority — once it's grabbed, the cursor owns the
	// split position until release. Update `split_ratio` from the current
	// mouse x; render's clamp keeps both panes above the usable minimum.
	if editor.divider_dragging {
		total_pane_width := editor.panes[0].rectangle.w + editor.panes[1].rectangle.w
		// The divider itself is 2 px; account for it so the math matches
		// what `editor_render` uses to lay out the panes.
		divider_width: i32 = 2
		usable_width := total_pane_width + divider_width
		if usable_width <= 0 { return }
		new_ratio := mouse_x / f32(usable_width)
		if new_ratio < 0.05 { new_ratio = 0.05 }
		if new_ratio > 0.95 { new_ratio = 0.95 }
		editor.split_ratio = new_ratio
		return
	}

	// Drag stays locked to the pane that started the drag.
	for pane_index in 0..<editor_visible_pane_count(editor) {
		pane := &editor.panes[pane_index]
		#partial switch &content_value in pane.content {
		case EditorPane:
			if content_value.mouse_dragging {
				editor.active_pane_index = pane_index
				editor_pane_mouse_drag(editor, pane, &content_value, mouse_x, mouse_y)
				return
			}
		case TerminalPane:
			if content_value.terminal != nil && content_value.terminal.selection.is_dragging {
				editor.active_pane_index = pane_index
				terminal.terminal_mouse_drag(content_value.terminal, mouse_x, mouse_y)
				editor_mark_dirty(editor)
				return
			}
		case OutputPane:
			if content_value.selection.is_dragging {
				editor.active_pane_index = pane_index
				output_pane_mouse_drag(editor, &content_value, pane, mouse_x, mouse_y)
				return
			}
		}
	}
}

@(private="file")
editor_pane_mouse_drag :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x: f32, mouse_y: f32) {
	new_offset := screen_to_offset(editor, pane, editor_pane, mouse_x, mouse_y)
	if new_offset == editor_pane.cursor_offset { return }
	editor_pane.cursor_offset = new_offset
	editor_pane.selection_active = true
	editor.cursor_visible = true
	editor.cursor_timer = 0
	sync_cursor_from_offset(editor)
}

@(private)
editor_mouse_up :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	editor.divider_dragging = false
	debug_panel_handle_mouse_up(editor)
	for pane_index in 0..<len(editor.panes) {
		#partial switch &content_value in editor.panes[pane_index].content {
		case EditorPane:
			content_value.mouse_dragging = false
			ui.scrollbar_end_drag(&content_value.scrollbar)
		case TerminalPane:
			ui.scrollbar_end_drag(&content_value.scrollbar)
			if content_value.terminal != nil {
				terminal.terminal_mouse_up(content_value.terminal, mouse_x, mouse_y)
			}
		case MarkdownPreviewPane:
			ui.scrollbar_end_drag(&content_value.scrollbar)
		case OutputPane:
			ui.scrollbar_end_drag(&content_value.scrollbar)
			output_pane_mouse_up(editor, &content_value)
		}
	}
	// Update cursor based on the release position so it snaps back to the
	// default arrow if the user has moved off the divider while dragging.
	editor_update_cursor(editor, mouse_x, mouse_y)
}

@(private="file")
screen_to_offset :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x: f32, mouse_y: f32) -> u32 {
	total_line_count := document.document_line_count(&editor_pane.document)
	if total_line_count == 0 { return 0 }

	// Y → line, using fractional scroll offset for accurate mid-animation
	// clicks. The text area begins below the title bar at the top of the pane.
	title_bar_height := f32(editor_title_bar_height(editor))
	document_y := mouse_y - f32(pane.rectangle.y) - title_bar_height - f32(editor.padding_y) + editor_pane.scroll_y
	if document_y < 0 { document_y = 0 }
	target_line: u32 = 0
	if editor.line_height > 0 {
		target_line = u32(document_y / f32(editor.line_height))
	}
	if target_line >= total_line_count { target_line = total_line_count - 1 }

	// X → visual column, then visual column → byte column via the same
	// tab-expansion / multi-byte-rune mapping the renderer uses. Without
	// this inverse, clicking past a tab lands several bytes too far right
	// because the click math would treat each visual cell as one byte.
	scroll_x_pixels := i32(editor_pane.scroll_x)
	if editor_pane.wrap_mode { scroll_x_pixels = 0 }
	relative_x := i32(mouse_x) - pane.rectangle.x - editor.padding_x - editor_pane.gutter_width + scroll_x_pixels
	visual_column: i32 = 0
	if relative_x > 0 && editor.character_width > 0 {
		visual_column = (relative_x + editor.character_width / 2) / editor.character_width
	}

	line_start_offset := document.document_line_start(&editor_pane.document, target_line)
	target_line_text  := document.document_get_line(&editor_pane.document, target_line, context.temp_allocator)
	byte_column       := visual_to_byte_column(target_line_text, visual_column)

	return line_start_offset + u32(byte_column)
}

// Walk the byte-to-visual table produced by `build_line_display` and return
// the byte index whose visual column is closest to `target_visual_column`.
// Ties prefer the LATER byte so clicking on the right half of a tab lands
// the cursor after it, matching how most editors handle the gesture.
@(private="file")
visual_to_byte_column :: proc(line_text: string, target_visual_column: i32) -> i32 {
	_, byte_to_visual_column := build_line_display(line_text)
	if target_visual_column <= 0 { return 0 }

	best_byte_index: i32 = 0
	best_distance:   i32 = max(i32)
	for byte_index in 0..=len(line_text) {
		visual_at := i32(byte_to_visual_column[byte_index])
		distance  := visual_at - target_visual_column
		if distance < 0 { distance = -distance }
		if distance <= best_distance {
			best_distance   = distance
			best_byte_index = i32(byte_index)
		}
		// Once we've passed the target with no chance of getting closer,
		// we can stop early. visual_at only ever grows along the line.
		if visual_at - target_visual_column > best_distance { break }
	}
	return best_byte_index
}
