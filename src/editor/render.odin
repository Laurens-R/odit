package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"
import "../syntax"
import "../terminal"
import "../ui"

TAB_WIDTH :: 4

@(private="file")
build_line_display :: proc(line_text: string, allocator := context.temp_allocator) -> (display_text: string, byte_to_visual_column: []int) {
	display_builder: strings.Builder
	strings.builder_init(&display_builder, 0, len(line_text) + 4, allocator)

	column_indices := make([]int, len(line_text) + 1, allocator)
	current_visual_column := 0
	character_index := 0
	for character_index < len(line_text) {
		current_character := line_text[character_index]

		rune_byte_length := 1
		if current_character >= 0xC0 {
			switch {
			case current_character < 0xE0: rune_byte_length = 2
			case current_character < 0xF0: rune_byte_length = 3
			case:                          rune_byte_length = 4
			}
			if character_index + rune_byte_length > len(line_text) { rune_byte_length = len(line_text) - character_index }
		}

		for byte_offset in 0..<rune_byte_length {
			column_indices[character_index + byte_offset] = current_visual_column
		}

		if rune_byte_length == 1 {
			switch {
			case current_character == '\t':
				space_count := TAB_WIDTH - (current_visual_column % TAB_WIDTH)
				for _ in 0..<space_count { strings.write_byte(&display_builder, ' ') }
				current_visual_column += space_count
			case current_character == '\r':
			case current_character < 0x20 || current_character == 0x7F:
				strings.write_byte(&display_builder, '?')
				current_visual_column += 1
			case:
				strings.write_byte(&display_builder, current_character)
				current_visual_column += 1
			}
		} else {
			for byte_offset in 0..<rune_byte_length {
				strings.write_byte(&display_builder, line_text[character_index + byte_offset])
			}
			current_visual_column += 1
		}

		character_index += rune_byte_length
	}
	column_indices[len(line_text)] = current_visual_column
	return strings.to_string(display_builder), column_indices
}

editor_update :: proc(editor: ^Editor, delta_time: f64) {
	editor.clock += delta_time

	if editor.diff_state.active {
		// Animate the shared diff scroll.
		if editor.diff_state.scroll_y != editor.diff_state.scroll_y_target {
			interpolation_factor := f32(delta_time * SCROLL_SMOOTHNESS)
			if interpolation_factor > 1.0 { interpolation_factor = 1.0 }
			editor.diff_state.scroll_y += (editor.diff_state.scroll_y_target - editor.diff_state.scroll_y) * interpolation_factor
			if abs(editor.diff_state.scroll_y_target - editor.diff_state.scroll_y) < 0.5 {
				editor.diff_state.scroll_y = editor.diff_state.scroll_y_target
			}
			editor_mark_dirty(editor)
		}
	} else {
		// Per-pane content updates (smooth-scroll for editor panes, byte
		// drain + cursor blink for terminal panes).
		for pane_index in 0..<len(editor.panes) {
			#partial switch &content_value in editor.panes[pane_index].content {
			case EditorPane:
				editor_pane_update(editor, &content_value, delta_time)
			case TerminalPane:
				if content_value.terminal != nil {
					title_bar_height := editor_title_bar_height(editor)
					terminal_body_rectangle := sdl3.Rect{
						editor.panes[pane_index].rectangle.x,
						editor.panes[pane_index].rectangle.y + title_bar_height,
						editor.panes[pane_index].rectangle.w,
						editor.panes[pane_index].rectangle.h - title_bar_height,
					}
					terminal.terminal_set_geometry(content_value.terminal, terminal_body_rectangle, editor.character_width, editor.line_height)
					if terminal.terminal_update(content_value.terminal, delta_time) {
						editor_mark_dirty(editor)
					}
				}
			}
		}
	}

	editor.cursor_timer += delta_time
	if editor.cursor_timer >= CURSOR_BLINK_RATE {
		editor.cursor_timer -= CURSOR_BLINK_RATE
		editor.cursor_visible = !editor.cursor_visible
		editor_mark_dirty(editor)
	}

	// Auto-reanalyze symbols once the user has paused. All three gates must
	// hold: the pane's doc has been mutated, at least 2 s have passed since
	// its last rebuild, and at least 1 s has passed since the most recent
	// keystroke anywhere in the editor. F6 is skipped — opening it already
	// forces a fresh rebuild, and rebuilding while its filtered_indices
	// slice is live would invalidate the dialog's indices.
	if !editor.show_symbols {
		for pane_index in 0..<len(editor.panes) {
			#partial switch &content_value in editor.panes[pane_index].content {
			case EditorPane:
				if !content_value.symbols_dirty                                { continue }
				if editor.clock - content_value.last_analysis_time   < 2.0     { continue }
				if editor.clock - editor.last_keystroke_time         < 1.0     { continue }
				pane_rebuild_symbols(&content_value)
				content_value.symbols_dirty      = false
				content_value.last_analysis_time = editor.clock
			}
		}
	}
}

@(private="file")
editor_pane_update :: proc(editor: ^Editor, editor_pane: ^EditorPane, delta_time: f64) {
	is_animating := false
	interpolation_factor := f32(delta_time * SCROLL_SMOOTHNESS)
	if interpolation_factor > 1.0 { interpolation_factor = 1.0 }

	if editor_pane.scroll_y != editor_pane.scroll_y_target {
		editor_pane.scroll_y += (editor_pane.scroll_y_target - editor_pane.scroll_y) * interpolation_factor
		if abs(editor_pane.scroll_y_target - editor_pane.scroll_y) < 0.5 {
			editor_pane.scroll_y = editor_pane.scroll_y_target
		}
		if editor.line_height > 0 {
			editor_pane.scroll_line = u32(editor_pane.scroll_y / f32(editor.line_height))
		}
		is_animating = true
	}

	if editor_pane.scroll_x != editor_pane.scroll_x_target {
		editor_pane.scroll_x += (editor_pane.scroll_x_target - editor_pane.scroll_x) * interpolation_factor
		if abs(editor_pane.scroll_x_target - editor_pane.scroll_x) < 0.5 {
			editor_pane.scroll_x = editor_pane.scroll_x_target
		}
		is_animating = true
	}

	if is_animating { editor_mark_dirty(editor) }
}

editor_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, window_width: i32, window_height: i32) {
	status_bar_height: i32 = editor.line_height + 4
	text_area_height := window_height - status_bar_height

	// Full-window background
	sdl3.SetRenderDrawColorFloat(renderer, editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, 0, f32(window_width), f32(window_height)})

	// Compute per-pane rectangles. The divider sits at `split_ratio` of the
	// total width and is clamped so neither pane can drop below a usable
	// minimum (~10 character cells, falling back to 80 px if the font hasn't
	// been measured yet).
	visible_pane_count := editor_visible_pane_count(editor)
	if visible_pane_count == 1 {
		editor.panes[0].rectangle = sdl3.Rect{0, 0, window_width, text_area_height}
	} else {
		divider_width: i32 = 2
		usable_width := window_width - divider_width

		minimum_pane_width: i32 = 80
		if editor.character_width > 0 { minimum_pane_width = editor.character_width * 10 }
		if minimum_pane_width > usable_width/2 { minimum_pane_width = usable_width / 2 }

		split_ratio := editor.split_ratio
		if split_ratio < 0.05 { split_ratio = 0.05 }
		if split_ratio > 0.95 { split_ratio = 0.95 }
		left_pane_width := i32(f32(usable_width) * split_ratio)
		if left_pane_width < minimum_pane_width              { left_pane_width = minimum_pane_width }
		if left_pane_width > usable_width - minimum_pane_width { left_pane_width = usable_width - minimum_pane_width }

		editor.panes[0].rectangle = sdl3.Rect{0,                            0, left_pane_width,                 text_area_height}
		editor.panes[1].rectangle = sdl3.Rect{left_pane_width + divider_width, 0, usable_width - left_pane_width,  text_area_height}
	}

	// Render each visible pane by dispatching on its content type.
	for pane_index in 0..<visible_pane_count {
		pane := &editor.panes[pane_index]
		pane_is_active := pane_index == editor.active_pane_index
		#partial switch &content_value in pane.content {
		case EditorPane:
			render_editor_pane(editor, renderer, pane, &content_value, pane_is_active, pane_index)
		case TerminalPane:
			if content_value.terminal != nil {
				title_bar_height := editor_title_bar_height(editor)
				render_pane_title_strip(editor, renderer, pane.rectangle.x, pane.rectangle.y, pane.rectangle.w, title_bar_height, "Terminal", pane_is_active)
				terminal_body_rectangle := sdl3.Rect{
					pane.rectangle.x,
					pane.rectangle.y + title_bar_height,
					pane.rectangle.w,
					pane.rectangle.h - title_bar_height,
				}
				terminal.terminal_set_geometry(content_value.terminal, terminal_body_rectangle, editor.character_width, editor.line_height)
				terminal.terminal_render(content_value.terminal, renderer, editor.font, editor.text_engine, &editor.text_cache)
			}
		}
	}

	// Divider between panes.
	if visible_pane_count == 2 {
		divider_x := editor.panes[1].rectangle.x - 2
		divider_rectangle := sdl3.FRect{f32(divider_x), 0, 2, f32(text_area_height)}
		sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
		sdl3.RenderFillRect(renderer, &divider_rectangle)
	}

	// Status bar — content depends on the active pane's type.
	status_bar_y := window_height - status_bar_height
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, f32(status_bar_y), f32(window_width), f32(status_bar_height)})

	status_text: string
	#partial switch &content_value in editor_active_pane(editor).content {
	case EditorPane:
		dirty_indicator := document.document_is_dirty(&content_value.document) ? "[+] " : ""
		pane_tag := editor.split_active ? fmt.tprintf("[Pane %d] ", editor.active_pane_index + 1) : ""
		diff_tag := editor.diff_state.active ? "[DIFF] " : ""
		hint_text := editor.diff_state.active ? "(F8 exit diff, F1 help)" : "(F1 help, F2 browse, Ctrl+Tab swap panes, F8 diff)"
		status_text = fmt.tprintf("%s%s%sLn %d, Col %d | %d lines | %d bytes  %s",
			diff_tag,
			pane_tag,
			dirty_indicator,
			content_value.cursor_line + 1,
			content_value.cursor_column + 1,
			document.document_line_count(&content_value.document),
			document.document_length(&content_value.document),
			hint_text,
		)
	}
	if len(status_text) > 0 {
		render_string(editor, renderer, status_text, editor.padding_x, status_bar_y + 2, editor.status_bar_foreground)
	}

	// Modal overlays render on top of everything else.
	if editor.show_browse {
		browse_render(editor, renderer, window_width, window_height)
	}
	if editor.show_symbols {
		symbols_dialog_render(editor, renderer, window_width, window_height)
	}
	if editor.show_help {
		help_render(editor, renderer, window_width, window_height)
	}
	if editor.show_terminal_close_confirm {
		terminal_close_confirm_render(editor, renderer, window_width, window_height)
	}
}

// --- Per-content renderers ------------------------------------------------

@(private="file")
render_editor_pane :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane, editor_pane: ^EditorPane, is_active: bool, pane_index: int) {
	view_width  := pane.rectangle.w
	view_height := pane.rectangle.h
	view_x      := pane.rectangle.x
	view_y      := pane.rectangle.y

	// Title bar (tinted strip with filename + dirty marker) at the top of the
	// pane. Text-area math below is in terms of `text_y` / `text_height` so
	// the title bar stays anchored above the visible content.
	title_bar_height := editor_title_bar_height(editor)
	render_pane_title_bar(editor, renderer, editor_pane, view_x, view_y, view_width, title_bar_height, is_active)

	text_y      := view_y + title_bar_height
	text_height := view_height - title_bar_height

	editor_pane.visible_lines = u32(text_height / editor.line_height)
	if editor_pane.visible_lines == 0 { editor_pane.visible_lines = 1 }

	total_line_count := document.document_line_count(&editor_pane.document)
	gutter_character_count := max(digit_count(total_line_count), 3)
	gutter_width_pixels := i32(gutter_character_count + 1) * editor.character_width
	editor_pane.gutter_width = gutter_width_pixels

	view_clip_rectangle := sdl3.Rect{view_x, text_y, view_width, text_height}
	sdl3.SetRenderClipRect(renderer, &view_clip_rectangle)

	if editor.diff_state.active {
		render_editor_pane_diff(editor, renderer, editor_pane, view_x, text_y, view_width, is_active, pane_index, gutter_character_count, gutter_width_pixels)
	} else {
		render_editor_pane_normal(editor, renderer, editor_pane, view_x, text_y, is_active, gutter_character_count, gutter_width_pixels)
	}

	sdl3.SetRenderClipRect(renderer, nil)

	// Scrollbar — content range and scroll value differ between modes.
	// Width widens on hover / drag so it's actually grabbable; track + thumb
	// rects come back from the painter so input handlers can hit-test them.
	{
		ui_context := ui.Context{
			renderer        = renderer,
			font            = editor.font,
			engine          = editor.text_engine,
			character_width = editor.character_width,
			line_height     = editor.line_height,
		}
		theme := ui.default_theme()

		content_height_pixels, current_scroll_value: f32
		if editor.diff_state.active {
			content_height_pixels = f32(len(editor.diff_state.rows)) * f32(editor.line_height)
			current_scroll_value  = editor.diff_state.scroll_y
		} else {
			content_height_pixels = f32(total_line_count) * f32(editor.line_height)
			current_scroll_value  = editor_pane.scroll_y
		}

		scrollbar_width: i32 = 6
		if editor_pane.scrollbar.is_hovered || editor_pane.scrollbar.is_dragging { scrollbar_width = 14 }
		scrollbar_x := view_x + view_width - scrollbar_width - 2

		track_rectangle, thumb_rectangle := ui.draw_scrollbar(&ui_context, scrollbar_x, text_y, text_height, content_height_pixels, f32(text_height), current_scroll_value, scrollbar_width, theme)
		editor_pane.scrollbar.track_rectangle = track_rectangle
		editor_pane.scrollbar.thumb_rectangle = thumb_rectangle
	}
}

// Tinted strip at the top of an editor pane showing the document's file name
// (basename), or "untitled" for an unsaved buffer, with a trailing `*` when
// dirty. The active pane gets a brighter text color; the inactive pane is
// muted so focus is unambiguous at a glance.
@(private="file")
render_pane_title_bar :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane, x_position, y_position, width, height: i32, is_active: bool) {
	display_name := editor_pane.file_path != "" ? filepath_base(editor_pane.file_path) : "untitled"
	dirty_marker := document.document_is_dirty(&editor_pane.document) ? " *" : ""
	full_label := fmt.tprintf("%s%s", display_name, dirty_marker)
	render_pane_title_strip(editor, renderer, x_position, y_position, width, height, full_label, is_active)
}

// Generic pane title strip: tinted bar, active-pane accent stripe along the
// bottom, label on the left. Shared by editor panes (filename + dirty flag)
// and terminal panes (static "Terminal" label) so the visual treatment stays
// consistent.
@(private)
render_pane_title_strip :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, x_position, y_position, width, height: i32, label: string, is_active: bool) {
	bar_rectangle := sdl3.FRect{f32(x_position), f32(y_position), f32(width), f32(height)}
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &bar_rectangle)

	if is_active {
		stripe_rectangle := sdl3.FRect{f32(x_position), f32(y_position + height - 1), f32(width), 1}
		sdl3.SetRenderDrawColorFloat(renderer, editor.cursor_color.r, editor.cursor_color.g, editor.cursor_color.b, 1.0)
		sdl3.RenderFillRect(renderer, &stripe_rectangle)
	}

	text_color := is_active ? editor.status_bar_foreground : editor.line_number_color
	render_string(editor, renderer, label, x_position + editor.padding_x, y_position + 3, text_color)
}

// Local wrapper so the renderer doesn't need to import core:path/filepath.
@(private="file")
filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	// Walk back to the last separator (works for both / and \ to keep things
	// platform-agnostic without dragging filepath in).
	character_index := len(file_path) - 1
	for character_index >= 0 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' {
			return file_path[character_index+1:]
		}
		character_index -= 1
	}
	return file_path
}

@(private="file")
render_editor_pane_normal :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane, view_x, view_y: i32, is_active: bool, gutter_character_count: u32, gutter_width: i32) {
	total_line_count := document.document_line_count(&editor_pane.document)

	selection_low_offset, selection_high_offset, has_selection := editor_pane_selection_range(editor_pane)
	scroll_y_pixels := i32(editor_pane.scroll_y)

	if !editor_pane.wrap_mode {
		end_line_index := min(editor_pane.scroll_line + editor_pane.visible_lines + 2, total_line_count)
		for line_index := editor_pane.scroll_line; line_index < end_line_index; line_index += 1 {
			screen_y_position := view_y + editor.padding_y + i32(line_index) * editor.line_height - scroll_y_pixels
			render_doc_line_into(editor, renderer, editor_pane, view_x, screen_y_position, gutter_character_count, gutter_width,
				i32(line_index), has_selection, selection_low_offset, selection_high_offset, is_active, i32(line_index) == i32(editor_pane.cursor_line))
		}
		return
	}

	// --- wrap mode ---------------------------------------------------
	// Walk source lines in document order; each one occupies one or more
	// visual rows. We stop once we've passed the bottom of the pane.
	pane := &editor.panes[get_pane_index(editor, editor_pane)]
	view_height := pane.rectangle.h
	bottom_y    := view_y + view_height
	text_area_width := pane.rectangle.w - editor.padding_x - gutter_width - editor.padding_x
	columns_per_row := text_area_width / editor.character_width
	if columns_per_row < 1 { columns_per_row = 1 }

	current_y_position := view_y + editor.padding_y - scroll_y_pixels % editor.line_height
	for line_index := editor_pane.scroll_line; line_index < total_line_count && current_y_position < bottom_y; line_index += 1 {
		visual_rows_consumed := render_wrapped_doc_line(editor, renderer, editor_pane, view_x, current_y_position,
			gutter_character_count, gutter_width, columns_per_row,
			i32(line_index), has_selection, selection_low_offset, selection_high_offset, is_active,
			i32(line_index) == i32(editor_pane.cursor_line))
		current_y_position += visual_rows_consumed * editor.line_height
	}
}

@(private="file")
render_editor_pane_diff :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane, view_x, view_y, view_width: i32, is_active: bool, pane_index: int, gutter_character_count: u32, gutter_width: i32) {
	scroll_y_pixels := i32(editor.diff_state.scroll_y)
	visible_row_count := editor_pane.visible_lines + 2

	start_row_index: u32 = 0
	if editor.line_height > 0 {
		start_row_index = u32(editor.diff_state.scroll_y / f32(editor.line_height))
	}
	total_row_count := u32(len(editor.diff_state.rows))
	end_row_index := min(start_row_index + visible_row_count, total_row_count)

	for row_index := start_row_index; row_index < end_row_index; row_index += 1 {
		diff_row := editor.diff_state.rows[row_index]
		screen_y_position := view_y + editor.padding_y + i32(row_index) * editor.line_height - scroll_y_pixels

		// Determine which doc line this row shows on this side, and the
		// background color for the row.
		doc_line_index: i32 = -1
		row_background: ^sdl3.FColor

		if pane_index == 0 {
			doc_line_index = diff_row.left_line
			switch diff_row.kind {
			case .Equal:
				// no bg tint
			case .Delete:
				row_background = &editor.diff_delete_background
			case .Insert:
				row_background = &editor.diff_gap_background
			}
		} else {
			doc_line_index = diff_row.right_line
			switch diff_row.kind {
			case .Equal:
			case .Insert:
				row_background = &editor.diff_insert_background
			case .Delete:
				row_background = &editor.diff_gap_background
			}
		}

		// Fill row background tint for non-equal rows.
		if row_background != nil {
			row_rectangle := sdl3.FRect{f32(view_x), f32(screen_y_position), f32(view_width), f32(editor.line_height)}
			sdl3.SetRenderDrawColorFloat(renderer, row_background.r, row_background.g, row_background.b, row_background.a)
			sdl3.RenderFillRect(renderer, &row_rectangle)
		}

		if doc_line_index < 0 { continue } // gap — nothing to draw beyond background

		is_cursor_row := is_active && doc_line_index == i32(editor_pane.cursor_line)
		render_doc_line_into(editor, renderer, editor_pane, view_x, screen_y_position, gutter_character_count, gutter_width,
			doc_line_index, false, 0, 0, is_active, is_cursor_row)
	}
}

// Common path for laying out a single document line into a pane at the given
// screen_y. Used by both the normal and diff renderers.
//
// In non-wrap mode we apply `editor_pane.scroll_x` to the text so long lines
// pan horizontally; the gutter background is then painted last (over the
// text) to mask any glyph that bled left into the gutter area.
@(private="file")
render_doc_line_into :: proc(
	editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane,
	view_x: i32, screen_y: i32,
	gutter_character_count: u32, gutter_width: i32,
	doc_line: i32,
	has_selection: bool, selection_low, selection_high: u32,
	is_active: bool, cursor_on_this_line: bool,
) {
	line_index := u32(doc_line)
	line_text := document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
	display_text, byte_to_visual_column := build_line_display(line_text)

	scroll_x_pixels := i32(editor_pane.scroll_x)
	if editor_pane.wrap_mode { scroll_x_pixels = 0 }

	text_x_position := view_x + editor.padding_x + gutter_width - scroll_x_pixels

	if has_selection {
		line_byte_start := document.document_line_start(&editor_pane.document, line_index)
		line_byte_end := line_byte_start + u32(len(line_text))
		if selection_high > line_byte_start && selection_low <= line_byte_end {
			low_byte_index := selection_low > line_byte_start ? int(selection_low - line_byte_start) : 0
			low_visual_column := i32(byte_to_visual_column[low_byte_index])

			high_visual_column: i32
			if selection_high > line_byte_end {
				high_visual_column = i32(byte_to_visual_column[len(line_text)]) + 1
			} else {
				high_byte_index := int(selection_high - line_byte_start)
				high_visual_column = i32(byte_to_visual_column[high_byte_index])
			}

			if high_visual_column > low_visual_column {
				selection_rectangle := sdl3.FRect{
					f32(text_x_position + low_visual_column * editor.character_width),
					f32(screen_y),
					f32((high_visual_column - low_visual_column) * editor.character_width),
					f32(editor.line_height),
				}
				sdl3.SetRenderDrawColorFloat(renderer, editor.selection_color.r, editor.selection_color.g, editor.selection_color.b, editor.selection_color.a)
				sdl3.RenderFillRect(renderer, &selection_rectangle)
			}
		}
	}

	if len(display_text) > 0 {
		render_line_with_syntax(editor, renderer, editor_pane, display_text, text_x_position, screen_y)
	}

	if is_active && cursor_on_this_line && editor.cursor_visible {
		cursor_byte_column := int(editor_pane.cursor_column)
		cursor_visual_column := byte_to_visual_column[clamp(cursor_byte_column, 0, len(line_text))]
		cursor_x_position := text_x_position + i32(cursor_visual_column) * editor.character_width

		cursor_rectangle := sdl3.FRect{
			f32(cursor_x_position), f32(screen_y),
			f32(editor.character_width), f32(editor.line_height),
		}
		sdl3.SetRenderDrawColorFloat(renderer, editor.cursor_color.r, editor.cursor_color.g, editor.cursor_color.b, 1.0)
		sdl3.RenderFillRect(renderer, &cursor_rectangle)

		if cursor_byte_column < len(line_text) {
			character_at_cursor := line_text[cursor_byte_column]
			if character_at_cursor >= 0x20 && character_at_cursor != 0x7F {
				character_end_index := cursor_byte_column + 1
				if character_at_cursor >= 0xC0 {
					switch {
					case character_at_cursor < 0xE0: character_end_index = cursor_byte_column + 2
					case character_at_cursor < 0xF0: character_end_index = cursor_byte_column + 3
					case:                            character_end_index = cursor_byte_column + 4
					}
				}
				character_end_index = min(character_end_index, len(line_text))
				render_string(editor, renderer, line_text[cursor_byte_column:character_end_index], cursor_x_position, screen_y, editor.background_color)
			}
		}
	}

	// Gutter painted last so glyphs panned by horizontal scroll don't bleed
	// into the line-number column. Only needed when actually scrolled — the
	// extra fill is otherwise a wasted draw.
	if scroll_x_pixels > 0 {
		gutter_rectangle := sdl3.FRect{ f32(view_x), f32(screen_y), f32(editor.padding_x + gutter_width), f32(editor.line_height) }
		sdl3.SetRenderDrawColorFloat(renderer, editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a)
		sdl3.RenderFillRect(renderer, &gutter_rectangle)
	}
	line_number_string := fmt.tprintf("%*d", gutter_character_count, line_index + 1)
	render_string(editor, renderer, line_number_string, view_x + editor.padding_x, screen_y, editor.line_number_color)
}

// Index of the Pane that contains `editor_pane` (so we can read its rect
// during the wrap-mode layout pass). Returns 0 as a sensible default when
// the pane can't be found — should never happen in practice.
@(private="file")
get_pane_index :: proc(editor: ^Editor, editor_pane: ^EditorPane) -> int {
	for pane_index in 0..<len(editor.panes) {
		if pane_as_editor(&editor.panes[pane_index]) == editor_pane { return pane_index }
	}
	return 0
}

// Render a single source line in wrap mode at `screen_y`, breaking it into
// visual rows that each hold at most `columns_per_row` characters. Returns
// the number of visual rows the line consumed so the caller can advance y.
//
// MVP: wrap at column count, no per-row selection rectangle (selection only
// paints under the first visual row), cursor placed on the visual row that
// contains it.
@(private="file")
render_wrapped_doc_line :: proc(
	editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane,
	view_x, screen_y: i32,
	gutter_character_count: u32, gutter_width: i32,
	columns_per_row: i32,
	doc_line: i32,
	has_selection: bool, selection_low, selection_high: u32,
	is_active: bool, cursor_on_this_line: bool,
) -> i32 {
	line_index := u32(doc_line)
	line_text := document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
	display_text, byte_to_visual_column := build_line_display(line_text)
	total_display_columns := i32(len(display_text))
	if total_display_columns == 0 { total_display_columns = 1 } // empty line still occupies one visual row

	visual_row_count := (total_display_columns + columns_per_row - 1) / columns_per_row
	if visual_row_count < 1 { visual_row_count = 1 }

	text_x_position := view_x + editor.padding_x + gutter_width

	// Selection rectangle on the FIRST visual row only (MVP).
	if has_selection {
		line_byte_start := document.document_line_start(&editor_pane.document, line_index)
		line_byte_end := line_byte_start + u32(len(line_text))
		if selection_high > line_byte_start && selection_low <= line_byte_end {
			low_byte_index := selection_low > line_byte_start ? int(selection_low - line_byte_start) : 0
			low_visual_column := i32(byte_to_visual_column[low_byte_index])
			high_visual_column: i32
			if selection_high > line_byte_end {
				high_visual_column = i32(byte_to_visual_column[len(line_text)]) + 1
			} else {
				high_byte_index := int(selection_high - line_byte_start)
				high_visual_column = i32(byte_to_visual_column[high_byte_index])
			}
			low_visual_row  := low_visual_column / columns_per_row
			high_visual_row := high_visual_column / columns_per_row
			for visual_row in low_visual_row..=high_visual_row {
				row_start_column := visual_row * columns_per_row
				row_end_column   := row_start_column + columns_per_row
				segment_low  := max(low_visual_column,  row_start_column)
				segment_high := min(high_visual_column, row_end_column)
				if segment_high > segment_low {
					selection_rectangle := sdl3.FRect{
						f32(text_x_position + (segment_low - row_start_column) * editor.character_width),
						f32(screen_y + visual_row * editor.line_height),
						f32((segment_high - segment_low) * editor.character_width),
						f32(editor.line_height),
					}
					sdl3.SetRenderDrawColorFloat(renderer, editor.selection_color.r, editor.selection_color.g, editor.selection_color.b, editor.selection_color.a)
					sdl3.RenderFillRect(renderer, &selection_rectangle)
				}
			}
		}
	}

	// Render each visual row's slice of `display_text`.
	for visual_row in 0..<visual_row_count {
		row_y_position := screen_y + visual_row * editor.line_height
		slice_start_index := int(visual_row * columns_per_row)
		slice_end_index   := min(int((visual_row+1)*columns_per_row), len(display_text))
		if slice_end_index > slice_start_index {
			render_line_with_syntax(editor, renderer, editor_pane, display_text[slice_start_index:slice_end_index], text_x_position, row_y_position)
		}
	}

	// Cursor on the visual row it actually falls on.
	if is_active && cursor_on_this_line && editor.cursor_visible {
		cursor_byte_column := int(editor_pane.cursor_column)
		cursor_visual_column := i32(byte_to_visual_column[clamp(cursor_byte_column, 0, len(line_text))])
		current_visual_row := cursor_visual_column / columns_per_row
		column_within_row  := cursor_visual_column - current_visual_row * columns_per_row
		cursor_x_position := text_x_position + column_within_row * editor.character_width
		cursor_y_position := screen_y + current_visual_row * editor.line_height
		cursor_rectangle := sdl3.FRect{
			f32(cursor_x_position), f32(cursor_y_position),
			f32(editor.character_width), f32(editor.line_height),
		}
		sdl3.SetRenderDrawColorFloat(renderer, editor.cursor_color.r, editor.cursor_color.g, editor.cursor_color.b, 1.0)
		sdl3.RenderFillRect(renderer, &cursor_rectangle)
	}

	// Line number on the first visual row only.
	line_number_string := fmt.tprintf("%*d", gutter_character_count, line_index + 1)
	render_string(editor, renderer, line_number_string, view_x + editor.padding_x, screen_y, editor.line_number_color)

	return visual_row_count
}

// Render one display-line, optionally colored by `language`'s tokenizer.
// `display_text` is the already-expanded line (tabs → spaces, CR hidden,
// control chars → '?'). When language is nil, we render in a single pass
// with the default foreground.
@(private="file")
render_line_with_syntax :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane, display_text: string, text_x, screen_y: i32) {
	if editor_pane.language == nil {
		render_string(editor, renderer, display_text, text_x, screen_y, editor.foreground_color)
		return
	}

	// Per-frame token buffer in the temp arena.
	tokens := make([dynamic]syntax.Token, 0, 16, context.temp_allocator)
	syntax.tokenize_line(editor_pane.language, display_text, &tokens, editor_pane.symbol_names)

	for token in tokens {
		if token.end <= token.start { continue }
		token_text := display_text[token.start:token.end]
		token_color := syntax_color_for(editor, token.kind)
		token_x_position := text_x + i32(token.start) * editor.character_width
		render_string(editor, renderer, token_text, token_x_position, screen_y, token_color)
	}
}

@(private="file")
syntax_color_for :: proc(editor: ^Editor, token_kind: syntax.TokenKind) -> sdl3.FColor {
	switch token_kind {
	case .Keyword:      return editor.syntax_keyword_foreground
	case .Type:         return editor.syntax_type_foreground
	case .String:       return editor.syntax_string_foreground
	case .Number:       return editor.syntax_number_foreground
	case .Comment:      return editor.syntax_comment_foreground
	case .Preprocessor: return editor.syntax_preprocessor_foreground
	case .Symbol:       return editor.syntax_symbol_foreground
	case .Punctuation:  return editor.foreground_color
	case .Default:      return editor.foreground_color
	}
	return editor.foreground_color
}

@(private="file")
render_string :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, text_to_render: string, x_position: i32, y_position: i32, color: sdl3.FColor) {
	if len(text_to_render) == 0 { return }
	text_object := ui.text_cache_get(&editor.text_cache, text_to_render)
	if text_object == nil { return }
	_ = ttf.SetTextColorFloat(text_object, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_object, f32(x_position), f32(y_position))
}

@(private="file")
digit_count :: proc(number: u32) -> u32 {
	if number == 0 { return 1 }
	digit_total: u32 = 0
	remaining_value := number
	for remaining_value > 0 {
		digit_total += 1
		remaining_value /= 10
	}
	return digit_total
}
