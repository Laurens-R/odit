package editor

import "core:strings"
import "vendor:sdl3"

import "../ui"

// Scrolling read-only text view used for the debug-session output log.
// Lines come from `editor.debug_output_lines` (a single shared buffer); the
// pane just owns scroll state, so swapping between the output pane and the
// debug panel doesn't lose history.
//
// Lives in pane[1] (same slot as terminal / markdown preview). Auto-shown by
// `editor_dap_start_session` so adapter spawn errors and inferior output are
// immediately visible. Closed with Ctrl+F4 (matches the other pane types).
OutputPane :: struct {
	scrollbar:        ui.Scrollbar,
	scroll_y:         i32,  // pixel offset from top of content
	// When true the renderer pins scroll_y to the bottom on each frame so
	// fresh output keeps streaming into view. Any explicit upward scroll
	// turns it off; End / scroll-to-bottom turns it back on.
	sticky_to_bottom: bool,
	// Text selection (drag-to-highlight, Ctrl+C to copy). Anchor / current
	// are line + byte-column pairs into `editor.debug_output_lines`. Indices
	// are clamped at render time so old indices that have fallen off the
	// front of the log don't paint at invalid offsets.
	selection:        OutputSelection,
}

@(private)
OutputSelection :: struct {
	is_active:      bool,
	is_dragging:    bool,
	anchor_line:    int,
	anchor_column:  int,
	current_line:   int,
	current_column: int,
}

@(private)
DEBUG_OUTPUT_MAX_LINES :: 4096

// --- Log buffer -----------------------------------------------------------

// Append `message` to the debug output log. Multi-line input is split on
// '\n' so a single chunky DAP output event becomes the right number of rows;
// trailing whitespace is stripped per line (lldb-dap sends `\r\n` on
// Windows). Oldest lines fall off once the buffer would exceed
// DEBUG_OUTPUT_MAX_LINES.
//
// Owned strings live on context.allocator; freed by `debug_output_destroy`
// at editor teardown or by the cap-trim path below.
@(private)
debug_output_append :: proc(editor: ^Editor, message: string) {
	if len(message) == 0 { return }
	cursor := message
	for {
		newline_index := strings.index_byte(cursor, '\n')
		if newline_index < 0 {
			debug_output_push_line(editor, strings.trim_right_space(cursor))
			break
		}
		debug_output_push_line(editor, strings.trim_right_space(cursor[:newline_index]))
		cursor = cursor[newline_index + 1:]
		if len(cursor) == 0 { break }
	}
	editor_mark_dirty(editor)
}

@(private="file")
debug_output_push_line :: proc(editor: ^Editor, line: string) {
	// Drop the oldest entries when we hit the cap. Removing from index 0 is
	// O(n) but n is bounded at DEBUG_OUTPUT_MAX_LINES and this only fires on
	// overflow — a few thousand pointer shuffles per overflow is fine.
	for len(editor.debug_output_lines) >= DEBUG_OUTPUT_MAX_LINES {
		oldest := editor.debug_output_lines[0]
		if len(oldest) > 0 { delete(oldest) }
		ordered_remove(&editor.debug_output_lines, 0)
	}
	append(&editor.debug_output_lines, strings.clone(line))
}

@(private)
debug_output_clear :: proc(editor: ^Editor) {
	for line in editor.debug_output_lines {
		if len(line) > 0 { delete(line) }
	}
	clear(&editor.debug_output_lines)
	editor_mark_dirty(editor)
}

@(private)
debug_output_destroy :: proc(editor: ^Editor) {
	for line in editor.debug_output_lines {
		if len(line) > 0 { delete(line) }
	}
	if cap(editor.debug_output_lines) > 0 { delete(editor.debug_output_lines) }
	editor.debug_output_lines = nil
}

// --- Pane lifecycle -------------------------------------------------------

@(private)
editor_is_output_pane_visible :: proc(editor: ^Editor) -> bool {
	_, is_output := editor.panes[TERMINAL_PANE_INDEX].content.(OutputPane)
	return is_output
}

// Show the output pane in pane[1]. If pane[1] is currently the user's
// editor content, that content is stashed into `saved_content` the same way
// `editor_terminal_show` does it. If pane[1] is already a swap-in (a build
// terminal that itself stashed an editor pane), the stash is preserved and
// we just swap the displayed content — that way closing the output pane
// still puts the original editor back, not a now-finished build terminal.
@(private)
editor_output_pane_show :: proc(editor: ^Editor) {
	if editor_is_output_pane_visible(editor) {
		editor.active_pane_index = TERMINAL_PANE_INDEX
		return
	}
	pane := &editor.panes[TERMINAL_PANE_INDEX]

	// Null any borrowed terminal pointer before we swap content so a
	// concurrent render path can't latch onto a handle whose pane variant is
	// about to change.
	if terminal_pane, is_terminal := &pane.content.(TerminalPane); is_terminal {
		terminal_pane.terminal = nil
	}

	if !pane.has_saved_content {
		pane.saved_content      = pane.content
		pane.saved_split_active = editor.split_active
		pane.has_saved_content  = true
	} else {
		// Already had a stash from an earlier swap-in. Drop the displaced
		// content — TerminalPane / OutputPane cases are pointer-only with
		// nothing to free; EditorPane releases its document.
		pane_content_destroy(&pane.content)
	}

	pane.content             = OutputPane{ sticky_to_bottom = true }
	editor.split_active      = true
	editor.active_pane_index = TERMINAL_PANE_INDEX
}

// Symmetric counterpart for `editor_output_pane_show`. Restores
// `saved_content` if any (so the user's original editor reappears).
@(private)
editor_output_pane_hide :: proc(editor: ^Editor) {
	if !editor_is_output_pane_visible(editor) { return }
	pane := &editor.panes[TERMINAL_PANE_INDEX]
	if pane.has_saved_content {
		pane.content            = pane.saved_content
		editor.split_active     = pane.saved_split_active
		pane.saved_content      = PaneContent{}
		pane.saved_split_active = false
		pane.has_saved_content  = false
	} else {
		pane.content        = PaneContent{}
		editor.split_active = false
	}
	if !editor.split_active { editor.active_pane_index = 0 }
}

// --- Rendering ------------------------------------------------------------

@(private)
output_pane_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane, content: ^OutputPane, is_active: bool) {
	title_bar_height := editor_title_bar_height(editor)
	render_pane_title_strip(editor, renderer, pane.rectangle.x, pane.rectangle.y, pane.rectangle.w, title_bar_height, "Debug Output", is_active)

	body_x := pane.rectangle.x
	body_y := pane.rectangle.y + title_bar_height
	body_w := pane.rectangle.w
	body_h := pane.rectangle.h - title_bar_height
	if body_h < editor.line_height { return }

	line_count := i32(len(editor.debug_output_lines))
	content_height_pixels := line_count * editor.line_height
	max_scroll := max(i32(0), content_height_pixels - body_h)

	if content.sticky_to_bottom { content.scroll_y = max_scroll }
	if content.scroll_y < 0          { content.scroll_y = 0 }
	if content.scroll_y > max_scroll { content.scroll_y = max_scroll }

	clip := sdl3.Rect{ body_x, body_y, body_w, body_h }
	sdl3.SetRenderClipRect(renderer, &clip)

	if line_count == 0 {
		render_string(editor, renderer, "(no debug output yet)", body_x + editor.padding_x, body_y + 2, editor.line_number_color)
	} else {
		// Paint selection background first so glyphs render on top of the
		// highlight rather than getting masked by it.
		output_pane_render_selection(editor, renderer, content, body_x, body_y)

		first_visible_line := content.scroll_y / editor.line_height
		visible_row_count  := body_h / editor.line_height + 2
		last_visible_line  := min(line_count, first_visible_line + visible_row_count)
		for line_index in first_visible_line..<last_visible_line {
			line_y := body_y + line_index * editor.line_height - content.scroll_y
			render_string(editor, renderer, editor.debug_output_lines[line_index], body_x + editor.padding_x, line_y, editor.foreground_color)
		}
	}

	sdl3.SetRenderClipRect(renderer, nil)

	output_pane_render_scrollbar(editor, renderer, pane, content, content_height_pixels, body_h)
	_ = max_scroll
}

// Walk the selected line range and paint one rect per row. Lines strictly
// between start and end are painted full-width (selection visually wraps);
// the first / last rows are partial.
@(private="file")
output_pane_render_selection :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, content: ^OutputPane, body_x, body_y: i32) {
	if !content.selection.is_active { return }
	if editor.line_height <= 0 || editor.character_width <= 0 { return }
	line_count := len(editor.debug_output_lines)
	if line_count == 0 { return }

	start_line, start_column, end_line, end_column := output_selection_normalized(&content.selection)
	if start_line >= line_count { return }
	if end_line   >= line_count { end_line = line_count - 1 }
	if start_line < 0           { start_line = 0 }

	text_origin_x := body_x + editor.padding_x

	for line_index in start_line..=end_line {
		line_text := editor.debug_output_lines[line_index]
		line_length := len(line_text)

		column_low  := 0
		column_high := line_length
		if line_index == start_line { column_low  = clamp(start_column, 0, line_length) }
		if line_index == end_line   { column_high = clamp(end_column,   0, line_length) }

		// Multi-line selections still highlight the trailing newline as one
		// extra cell so the rows visually connect, matching how every other
		// editor shows wrapped selections.
		highlight_extra: i32 = 0
		if line_index < end_line {
			column_high = line_length
			highlight_extra = editor.character_width
		}
		if column_high < column_low { column_high = column_low }

		row_y := body_y + i32(line_index) * editor.line_height - content.scroll_y
		x0 := text_origin_x + i32(column_low)  * editor.character_width
		x1 := text_origin_x + i32(column_high) * editor.character_width + highlight_extra
		if x1 <= x0 && highlight_extra == 0 { continue }

		highlight_rect := sdl3.FRect{ f32(x0), f32(row_y), f32(x1 - x0), f32(editor.line_height) }
		sdl3.SetRenderDrawColorFloat(renderer, editor.selection_color.r, editor.selection_color.g, editor.selection_color.b, editor.selection_color.a)
		sdl3.RenderFillRect(renderer, &highlight_rect)
	}
}

@(private="file")
output_pane_render_scrollbar :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane, content: ^OutputPane, content_height_pixels, body_h: i32) {
	if editor.line_height <= 0 { return }
	track_y := pane.rectangle.y + editor_title_bar_height(editor)
	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()
	ui.scrollbar_render(&ui_context, &content.scrollbar, pane.rectangle.x + pane.rectangle.w - 2, track_y, body_h,
		f32(body_h), f32(content_height_pixels), f32(content.scroll_y), theme)
}

// --- Input ----------------------------------------------------------------

// Scroll by `line_delta` rows (negative = up). Updates `sticky_to_bottom`:
// any upward scroll detaches; scrolling back to the bottom (or hitting End)
// re-attaches so subsequent output keeps streaming into view.
@(private)
output_pane_scroll :: proc(editor: ^Editor, content: ^OutputPane, line_delta: i32) {
	if line_delta == 0 || editor.line_height == 0 { return }
	content.scroll_y += line_delta * editor.line_height
	if content.scroll_y < 0 { content.scroll_y = 0 }

	body_h := editor.panes[TERMINAL_PANE_INDEX].rectangle.h - editor_title_bar_height(editor)
	if body_h <= 0 { return }
	line_count := i32(len(editor.debug_output_lines))
	max_scroll := max(i32(0), line_count * editor.line_height - body_h)
	if content.scroll_y >= max_scroll {
		content.scroll_y         = max_scroll
		content.sticky_to_bottom = true
	} else {
		content.sticky_to_bottom = false
	}
	editor_mark_dirty(editor)
}

@(private)
output_pane_handle_key :: proc(editor: ^Editor, content: ^OutputPane, event: ^sdl3.Event) {
	pressed_key := event.key.key
	key_modifiers := event.key.mod
	ctrl_held := .LCTRL in key_modifiers || .RCTRL in key_modifiers

	if ctrl_held {
		switch pressed_key {
		case sdl3.K_C:
			output_pane_copy_selection_to_clipboard(editor, content)
			return
		case sdl3.K_A:
			output_pane_select_all(editor, content)
			return
		}
	}

	switch pressed_key {
	case sdl3.K_UP:
		output_pane_scroll(editor, content, -1)
	case sdl3.K_DOWN:
		output_pane_scroll(editor, content, 1)
	case sdl3.K_PAGEUP:
		rows_per_page := max(i32(1), (editor.panes[TERMINAL_PANE_INDEX].rectangle.h - editor_title_bar_height(editor)) / editor.line_height - 1)
		output_pane_scroll(editor, content, -rows_per_page)
	case sdl3.K_PAGEDOWN:
		rows_per_page := max(i32(1), (editor.panes[TERMINAL_PANE_INDEX].rectangle.h - editor_title_bar_height(editor)) / editor.line_height - 1)
		output_pane_scroll(editor, content, rows_per_page)
	case sdl3.K_HOME:
		content.scroll_y         = 0
		content.sticky_to_bottom = false
		editor_mark_dirty(editor)
	case sdl3.K_END:
		content.sticky_to_bottom = true
		editor_mark_dirty(editor)
	case sdl3.K_ESCAPE:
		// Clear any active selection — mirrors the way most read-only
		// viewers drop the highlight on Esc.
		if content.selection.is_active {
			content.selection = OutputSelection{}
			editor_mark_dirty(editor)
		}
	}
}

// --- Selection ------------------------------------------------------------

// Hit-test a pane-local pixel position to a (line, column) pair into
// `editor.debug_output_lines`. Clamps to legal indices so a click past the
// last line or past end-of-line still produces a sensible position.
@(private="file")
output_pane_pixel_to_position :: proc(editor: ^Editor, content: ^OutputPane, pane: ^Pane, mouse_x, mouse_y: f32) -> (line_index, column: int) {
	if editor.line_height <= 0 || editor.character_width <= 0 { return 0, 0 }
	line_count := len(editor.debug_output_lines)
	if line_count == 0 { return 0, 0 }

	title_bar_height := editor_title_bar_height(editor)
	body_x := f32(pane.rectangle.x)
	body_y := f32(pane.rectangle.y + title_bar_height)

	document_y := mouse_y - body_y + f32(content.scroll_y)
	if document_y < 0 { document_y = 0 }
	line_index = int(document_y / f32(editor.line_height))
	if line_index < 0           { line_index = 0 }
	if line_index >= line_count { line_index = line_count - 1 }

	relative_x := mouse_x - body_x - f32(editor.padding_x)
	if relative_x < 0 { relative_x = 0 }
	column = int((relative_x + f32(editor.character_width) / 2) / f32(editor.character_width))
	line_length := len(editor.debug_output_lines[line_index])
	if column < 0           { column = 0 }
	if column > line_length { column = line_length }
	return
}

// Normalized [(start_line, start_col), (end_line, end_col)] range so the
// renderer / copy paths don't have to care which end of the drag came first.
@(private="file")
output_selection_normalized :: proc(selection: ^OutputSelection) -> (start_line, start_column, end_line, end_column: int) {
	if selection.anchor_line < selection.current_line ||
	   (selection.anchor_line == selection.current_line && selection.anchor_column <= selection.current_column) {
		return selection.anchor_line, selection.anchor_column, selection.current_line, selection.current_column
	}
	return selection.current_line, selection.current_column, selection.anchor_line, selection.anchor_column
}

@(private)
output_pane_mouse_down :: proc(editor: ^Editor, content: ^OutputPane, pane: ^Pane, mouse_x, mouse_y: f32) {
	line_index, column := output_pane_pixel_to_position(editor, content, pane, mouse_x, mouse_y)
	content.selection = OutputSelection{
		is_active      = true,
		is_dragging    = true,
		anchor_line    = line_index,
		anchor_column  = column,
		current_line   = line_index,
		current_column = column,
	}
	editor_mark_dirty(editor)
}

@(private)
output_pane_mouse_drag :: proc(editor: ^Editor, content: ^OutputPane, pane: ^Pane, mouse_x, mouse_y: f32) {
	if !content.selection.is_dragging { return }
	line_index, column := output_pane_pixel_to_position(editor, content, pane, mouse_x, mouse_y)
	if line_index == content.selection.current_line && column == content.selection.current_column { return }
	content.selection.current_line   = line_index
	content.selection.current_column = column
	editor_mark_dirty(editor)
}

@(private)
output_pane_mouse_up :: proc(editor: ^Editor, content: ^OutputPane) {
	content.selection.is_dragging = false
	// Click without drag → empty selection; drop it so we don't paint a
	// zero-width rect (and so subsequent Ctrl+C is a no-op rather than
	// copying an empty string).
	if content.selection.anchor_line == content.selection.current_line && content.selection.anchor_column == content.selection.current_column {
		content.selection.is_active = false
		editor_mark_dirty(editor)
	}
}

// Select every line in the log.
@(private)
output_pane_select_all :: proc(editor: ^Editor, content: ^OutputPane) {
	line_count := len(editor.debug_output_lines)
	if line_count == 0 { return }
	last_line := line_count - 1
	content.selection = OutputSelection{
		is_active      = true,
		is_dragging    = false,
		anchor_line    = 0,
		anchor_column  = 0,
		current_line   = last_line,
		current_column = len(editor.debug_output_lines[last_line]),
	}
	editor_mark_dirty(editor)
}

// Set the OS clipboard to the currently-selected text. No-op when there's
// nothing selected. Lines are joined with '\n'; the OS clipboard layer
// normalizes line endings as needed for paste targets.
@(private)
output_pane_copy_selection_to_clipboard :: proc(editor: ^Editor, content: ^OutputPane) {
	if !content.selection.is_active { return }
	line_count := len(editor.debug_output_lines)
	if line_count == 0 { return }

	start_line, start_column, end_line, end_column := output_selection_normalized(&content.selection)
	if start_line >= line_count { return }
	if end_line   >= line_count { end_line = line_count - 1 }
	if start_line < 0           { start_line = 0 }

	output_builder: strings.Builder
	strings.builder_init(&output_builder, 0, 256, context.temp_allocator)
	for line_index in start_line..=end_line {
		line_text := editor.debug_output_lines[line_index]
		line_length := len(line_text)

		column_low  := 0
		column_high := line_length
		if line_index == start_line { column_low  = clamp(start_column, 0, line_length) }
		if line_index == end_line   { column_high = clamp(end_column,   0, line_length) }
		if column_high < column_low { column_high = column_low }

		if column_high > column_low {
			strings.write_string(&output_builder, line_text[column_low:column_high])
		}
		if line_index != end_line { strings.write_byte(&output_builder, '\n') }
	}

	selected_text := strings.to_string(output_builder)
	if len(selected_text) == 0 { return }
	c_string_text := strings.clone_to_cstring(selected_text, context.temp_allocator)
	_ = sdl3.SetClipboardText(c_string_text)
}
