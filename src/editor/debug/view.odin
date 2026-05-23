// Debug panel rendering. Uses `ui` primitives + raw SDL3 calls.
// Pulls DAP state via `api.active_dap_client`. Theme colors come
// from `api.theme()`.
package debug

import "core:fmt"
import "core:math"
import "core:strings"
import "vendor:sdl3"

import "../../dap"
import "../../ui"
import "../binding"

render :: proc(state: ^State, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, window_width, window_height, menu_bar_height: i32) {
	if !state.panel_visible { return }

	theme := api.theme(api.editor)
	line_height     := ui_context.line_height
	character_width := ui_context.character_width

	state.cached_window_width = window_width

	status_bar_height := line_height + 4
	max_width := window_width - MIN_WIDTH
	if max_width < MIN_WIDTH { max_width = window_width / 2 }
	if max_width < MIN_WIDTH { max_width = MIN_WIDTH }
	if state.panel_width > max_width        { state.panel_width = max_width }
	if state.panel_width < MIN_WIDTH        { state.panel_width = MIN_WIDTH }
	panel_width := state.panel_width
	panel_x := window_width - panel_width
	panel_y := menu_bar_height
	panel_h := window_height - menu_bar_height - status_bar_height
	if panel_h < 0 { panel_h = 0 }
	state.panel_rectangle = sdl3.FRect{ f32(panel_x), f32(panel_y), f32(panel_width), f32(panel_h) }

	// Background fill + left divider.
	sdl3.SetRenderDrawColorFloat(renderer, theme.background_color.r, theme.background_color.g, theme.background_color.b, theme.background_color.a)
	sdl3.RenderFillRect(renderer, &state.panel_rectangle)
	divider_color := theme.divider_color
	if state.panel_resize_hovered || state.panel_resize_dragging { divider_color = theme.cursor_color }
	sdl3.SetRenderDrawColorFloat(renderer, divider_color.r, divider_color.g, divider_color.b, divider_color.a)
	divider_rect := sdl3.FRect{ f32(panel_x), f32(panel_y), 2, f32(panel_h) }
	sdl3.RenderFillRect(renderer, &divider_rect)

	// Title strip — replicates render_pane_title_strip without
	// needing the editor's text cache.
	title_bar_height := line_height + TITLE_HEIGHT_EXTRA
	title_label := "Debug"
	if state.session_active {
		title_label = state.is_stopped ? "Debug — stopped" : "Debug — running"
	}
	title_rect := sdl3.FRect{ f32(panel_x), f32(panel_y), f32(panel_width), f32(title_bar_height) }
	sdl3.SetRenderDrawColorFloat(renderer, theme.status_bar_background.r, theme.status_bar_background.g, theme.status_bar_background.b, theme.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &title_rect)
	stripe_rect := sdl3.FRect{ f32(panel_x), f32(panel_y + title_bar_height - 1), f32(panel_width), 1 }
	sdl3.SetRenderDrawColorFloat(renderer, theme.cursor_color.r, theme.cursor_color.g, theme.cursor_color.b, 1.0)
	sdl3.RenderFillRect(renderer, &stripe_rect)
	ui.draw_text(ui_context, title_label, panel_x + 8, panel_y + 3, theme.status_bar_foreground)

	inner_x := panel_x + 8
	inner_w := panel_width - 16
	cursor_y := panel_y + title_bar_height + 8

	// Buttons.
	button_labels := [?]string{ "Run", "Stop", "Cont", "Over", "Into", "Out" }
	button_rect_pointers := [?]^sdl3.FRect{
		&state.run_button_rect,
		&state.stop_button_rect,
		&state.continue_button_rect,
		&state.step_over_button_rect,
		&state.step_into_button_rect,
		&state.step_out_button_rect,
	}
	button_count := i32(len(button_labels))
	button_gap: i32 = 4
	button_width := (inner_w - button_gap * (button_count - 1)) / button_count
	button_height := line_height + 8
	ui_theme := ui.default_theme()
	for button_index in 0..<button_count {
		button_x := inner_x + button_index * (button_width + button_gap)
		button_rect := sdl3.FRect{ f32(button_x), f32(cursor_y), f32(button_width), f32(button_height) }
		button_rect_pointers[button_index]^ = button_rect
		ui.draw_button(ui_context, button_rect, button_labels[button_index], false, ui_theme)
	}
	cursor_y += button_height + 12

	// Three stacked sections.
	remaining_height := panel_y + panel_h - cursor_y - 8
	if remaining_height < 90 { remaining_height = 90 }
	section_header_height := line_height + 6
	body_area_total := remaining_height - 3 * section_header_height - 2 * SECTION_DIVIDER_HEIGHT
	if body_area_total < 3 * SECTION_MIN_HEIGHT { body_area_total = 3 * SECTION_MIN_HEIGHT }

	normalize_section_fractions(state)
	stack_body_height := i32(f32(body_area_total) * state.stack_section_fraction)
	variables_body_height := i32(f32(body_area_total) * state.variables_section_fraction)
	if stack_body_height     < SECTION_MIN_HEIGHT { stack_body_height     = SECTION_MIN_HEIGHT }
	if variables_body_height < SECTION_MIN_HEIGHT { variables_body_height = SECTION_MIN_HEIGHT }
	breakpoints_body_height := body_area_total - stack_body_height - variables_body_height
	if breakpoints_body_height < SECTION_MIN_HEIGHT {
		deficit := SECTION_MIN_HEIGHT - breakpoints_body_height
		if variables_body_height - deficit >= SECTION_MIN_HEIGHT {
			variables_body_height -= deficit
		} else if stack_body_height - deficit >= SECTION_MIN_HEIGHT {
			stack_body_height -= deficit
		}
		breakpoints_body_height = SECTION_MIN_HEIGHT
	}

	// Call Stack.
	section_header(ui_context, ui_theme, theme, "Call Stack", inner_x, inner_w, &cursor_y, section_header_height, line_height)
	state.stack_viewport = sdl3.FRect{ f32(inner_x), f32(cursor_y), f32(inner_w - 8), f32(stack_body_height) }
	render_stack(state, api, ui_context, ui_theme, theme, state.stack_viewport, character_width, line_height)
	cursor_y += stack_body_height
	state.stack_divider_rectangle = section_divider(renderer, theme, inner_x, cursor_y, inner_w, state.stack_divider_hovered || state.stack_divider_dragging)
	cursor_y += SECTION_DIVIDER_HEIGHT

	// Variables.
	section_header(ui_context, ui_theme, theme, "Variables", inner_x, inner_w, &cursor_y, section_header_height, line_height)
	state.variables_viewport = sdl3.FRect{ f32(inner_x), f32(cursor_y), f32(inner_w - 8), f32(variables_body_height) }
	render_variables(state, api, ui_context, ui_theme, theme, state.variables_viewport, character_width, line_height)
	cursor_y += variables_body_height
	state.variables_divider_rectangle = section_divider(renderer, theme, inner_x, cursor_y, inner_w, state.variables_divider_hovered || state.variables_divider_dragging)
	cursor_y += SECTION_DIVIDER_HEIGHT

	// Breakpoints.
	section_header(ui_context, ui_theme, theme, "Breakpoints", inner_x, inner_w, &cursor_y, section_header_height, line_height)
	if breakpoints_body_height < SECTION_MIN_HEIGHT { breakpoints_body_height = SECTION_MIN_HEIGHT }
	state.breakpoints_viewport = sdl3.FRect{ f32(inner_x), f32(cursor_y), f32(inner_w - 8), f32(breakpoints_body_height) }
	render_breakpoints(state, renderer, ui_context, ui_theme, theme, state.breakpoints_viewport, character_width, line_height)
}

@(private="file")
section_divider :: proc(renderer: ^sdl3.Renderer, theme: binding.Theme, inner_x, top_y, inner_w: i32, highlighted: bool) -> sdl3.FRect {
	rect := sdl3.FRect{ f32(inner_x), f32(top_y), f32(inner_w), f32(SECTION_DIVIDER_HEIGHT) }
	bar_height: f32 = 2
	bar := sdl3.FRect{ rect.x, rect.y + (rect.h - bar_height) * 0.5, rect.w, bar_height }
	color := theme.divider_color
	if highlighted { color = theme.cursor_color }
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderFillRect(renderer, &bar)
	return rect
}

@(private="file")
section_header :: proc(ui_context: ^ui.Context, ui_theme: ui.Theme, theme: binding.Theme, label: string, inner_x, inner_w: i32, cursor_y: ^i32, header_height: i32, line_height: i32) {
	ui.draw_text(ui_context, label, inner_x, cursor_y^, theme.syntax_keyword_foreground)
	rule_y := cursor_y^ + line_height + 1
	ui.draw_hrule(ui_context, inner_x, rule_y, inner_w - 8, ui_theme.border)
	cursor_y^ += header_height
}

@(private="file")
render_stack :: proc(state: ^State, api: ^binding.EditorAPI, ui_context: ^ui.Context, ui_theme: ui.Theme, theme: binding.Theme, viewport: sdl3.FRect, character_width, line_height: i32) {
	clear(&state.stack_row_rects)

	client: ^dap.Client
	if api != nil && api.active_dap_client != nil { client = api.active_dap_client(api.editor) }

	frames := dap.client_stack_frames(client)
	if len(frames) == 0 {
		idle_label := state.session_active ? "(running...)" : "(no active session)"
		ui.draw_text(ui_context, idle_label, i32(viewport.x), i32(viewport.y), theme.line_number_color)
		return
	}
	content_height := i32(len(frames)) * line_height
	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.stack_scrollbar, viewport, &state.stack_scroll, content_height)
	for frame, frame_index in frames {
		row_y := origin_y + i32(frame_index) * line_height
		is_selected := frame_index == state.selected_stack_frame
		label_text := frame.name
		if len(frame.file_path) > 0 {
			label_text = fmt.tprintf("%s — %s:%d", frame.name, filepath_base(frame.file_path), int(frame.line))
		}
		ui.draw_list_row(ui_context, origin_x, row_y, i32(viewport.w), label_text, is_selected, ui_theme)
		append(&state.stack_row_rects, sdl3.FRect{ f32(origin_x), f32(row_y), viewport.w, f32(line_height) })
	}
	ui.scroll_view_end(scroll_view, ui_theme)
	_ = character_width
}

@(private="file")
render_variables :: proc(state: ^State, api: ^binding.EditorAPI, ui_context: ^ui.Context, ui_theme: ui.Theme, theme: binding.Theme, viewport: sdl3.FRect, character_width, line_height: i32) {
	client: ^dap.Client
	if api != nil && api.active_dap_client != nil { client = api.active_dap_client(api.editor) }

	clear(&state.variable_row_rects)
	clear(&state.variable_row_kinds)
	clear(&state.variable_row_scope_index)
	clear(&state.variable_row_scope_name)
	clear(&state.variable_row_var_ref)

	scopes := dap.client_scopes(client)
	if len(scopes) == 0 {
		idle_label := state.session_active ? "(no variables in this frame)" : "(no active session)"
		ui.draw_text(ui_context, idle_label, i32(viewport.x), i32(viewport.y), theme.line_number_color)
		return
	}

	total_rows: i32 = 0
	for scope in scopes {
		total_rows += 1
		if is_scope_expanded(state, scope.name, !scope.expensive) {
			total_rows += variable_subtree_row_count(state, scope.variables[:], client)
		}
	}
	content_height := total_rows * line_height

	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.variables_scrollbar, viewport, &state.variables_scroll, content_height)
	row_index: i32 = 0
	for scope, scope_index in scopes {
		row_y := origin_y + row_index * line_height
		scope_expanded := is_scope_expanded(state, scope.name, !scope.expensive)

		expand_glyph := scope_expanded ? "v " : "> "
		header := strings.concatenate({expand_glyph, scope.name}, context.temp_allocator)
		ui.draw_text(ui_context, header, origin_x + 4, row_y, theme.syntax_type_foreground)

		row_rect := sdl3.FRect{ f32(origin_x), f32(row_y), viewport.w, f32(line_height) }
		append(&state.variable_row_rects,       row_rect)
		append(&state.variable_row_kinds,       VariableRowKind.Scope)
		append(&state.variable_row_scope_index, scope_index)
		append(&state.variable_row_scope_name,  scope.name)
		append(&state.variable_row_var_ref,     i64(0))
		row_index += 1

		if !scope_expanded { continue }
		render_variable_subtree(state, client, ui_context, theme, scope.variables[:], origin_x, origin_y, viewport.w, &row_index, 1, character_width, line_height)
	}
	ui.scroll_view_end(scroll_view, ui_theme)
}

@(private="file")
variable_subtree_row_count :: proc(state: ^State, variables: []dap.Variable, client: ^dap.Client) -> i32 {
	count: i32 = 0
	for variable in variables {
		count += 1
		if variable.variables_reference == 0 { continue }
		if !is_variable_expanded(state, variable.variables_reference) { continue }
		children, fetched := dap.client_children(client, variable.variables_reference)
		if !fetched { continue }
		count += variable_subtree_row_count(state, children, client)
	}
	return count
}

@(private="file")
render_variable_subtree :: proc(state: ^State, client: ^dap.Client, ui_context: ^ui.Context, theme: binding.Theme, variables: []dap.Variable, origin_x, origin_y: i32, viewport_width: f32, row_index: ^i32, depth: int, character_width, line_height: i32) {
	indent_per_level := character_width * 2
	for variable in variables {
		row_y := origin_y + row_index^ * line_height
		is_compound := variable.variables_reference != 0
		var_expanded := is_compound && is_variable_expanded(state, variable.variables_reference)

		indent_x := origin_x + i32(depth) * indent_per_level

		prefix: string
		if is_compound {
			prefix = var_expanded ? "v " : "> "
		} else {
			prefix = "  "
		}

		label: string
		if len(variable.value) > 0 {
			label = fmt.tprintf("%s%s = %s", prefix, variable.name, variable.value)
		} else {
			label = fmt.tprintf("%s%s", prefix, variable.name)
		}
		ui.draw_text(ui_context, label, indent_x + 4, row_y, theme.foreground_color)

		row_rect := sdl3.FRect{ f32(origin_x), f32(row_y), viewport_width, f32(line_height) }
		append(&state.variable_row_rects,       row_rect)
		append(&state.variable_row_kinds,       VariableRowKind.Variable)
		append(&state.variable_row_scope_index, -1)
		append(&state.variable_row_scope_name,  "")
		append(&state.variable_row_var_ref,     variable.variables_reference)
		row_index^ += 1

		if !var_expanded { continue }
		children, fetched := dap.client_children(client, variable.variables_reference)
		if !fetched { continue }
		render_variable_subtree(state, client, ui_context, theme, children, origin_x, origin_y, viewport_width, row_index, depth + 1, character_width, line_height)
	}
}

@(private="file")
render_breakpoints :: proc(state: ^State, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, ui_theme: ui.Theme, theme: binding.Theme, viewport: sdl3.FRect, character_width, line_height: i32) {
	clear(&state.breakpoint_row_rects)
	clear(&state.breakpoint_toggle_rects)
	clear(&state.breakpoint_remove_rects)
	clear(&state.breakpoint_row_file_index)
	clear(&state.breakpoint_row_bp_index)

	total_bp_count := 0
	for file_entry in state.breakpoint_files { total_bp_count += len(file_entry.breakpoints) }
	if total_bp_count == 0 {
		ui.draw_text(ui_context, "(no breakpoints)", i32(viewport.x), i32(viewport.y), theme.line_number_color)
		return
	}

	content_height := i32(total_bp_count) * line_height
	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.breakpoints_scrollbar, viewport, &state.breakpoints_scroll, content_height)

	row_index: i32 = 0
	for file_entry, file_idx in state.breakpoint_files {
		for bp, bp_index in file_entry.breakpoints {
			row_y := origin_y + row_index * line_height

			row_rect := sdl3.FRect{ f32(origin_x), f32(row_y), viewport.w, f32(line_height) }

			dot_radius := f32(line_height) * 0.28
			dot_center_x := f32(origin_x) + 8 + dot_radius
			dot_center_y := f32(row_y) + f32(line_height) * 0.5
			if bp.enabled {
				draw_filled_disc(renderer, dot_center_x, dot_center_y, dot_radius, theme.breakpoint_color)
			} else {
				draw_hollow_disc(renderer, dot_center_x, dot_center_y, dot_radius, theme.breakpoint_disabled_color)
			}
			toggle_hit_padding: f32 = 4
			toggle_rect := sdl3.FRect{
				dot_center_x - dot_radius - toggle_hit_padding,
				f32(row_y),
				(dot_radius + toggle_hit_padding) * 2,
				f32(line_height),
			}

			label_x := i32(dot_center_x + dot_radius + 6)
			file_basename := filepath_base(file_entry.file_path)
			label: string
			if len(bp.condition) > 0 {
				label = fmt.tprintf("%s:%d  if %s", file_basename, int(bp.line + 1), bp.condition)
			} else {
				label = fmt.tprintf("%s:%d", file_basename, int(bp.line + 1))
			}
			label_color := bp.enabled ? theme.foreground_color : theme.line_number_color
			ui.draw_text(ui_context, label, label_x, row_y, label_color)

			remove_width := character_width * 2
			remove_rect := sdl3.FRect{
				f32(origin_x) + viewport.w - f32(remove_width) - 2,
				f32(row_y),
				f32(remove_width),
				f32(line_height),
			}
			remove_label_x := i32(remove_rect.x) + (remove_width - character_width) / 2
			ui.draw_text(ui_context, "x", remove_label_x, row_y, theme.git_deleted_foreground)

			append(&state.breakpoint_row_rects,      row_rect)
			append(&state.breakpoint_toggle_rects,   toggle_rect)
			append(&state.breakpoint_remove_rects,   remove_rect)
			append(&state.breakpoint_row_file_index, file_idx)
			append(&state.breakpoint_row_bp_index,   bp_index)

			row_index += 1
		}
	}
	ui.scroll_view_end(scroll_view, ui_theme)
}

// Filled disc approximated by horizontal scanlines.
@(private="file")
draw_filled_disc :: proc(renderer: ^sdl3.Renderer, center_x, center_y, radius: f32, color: sdl3.FColor) {
	if radius <= 0 { return }
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	radius_squared := radius * radius
	r_int := i32(radius + 0.5)
	for y_offset := -r_int; y_offset <= r_int; y_offset += 1 {
		y_squared := f32(y_offset) * f32(y_offset)
		if y_squared > radius_squared { continue }
		x_half_width := math.sqrt_f32(radius_squared - y_squared)
		sdl3.RenderLine(renderer,
			center_x - x_half_width, center_y + f32(y_offset),
			center_x + x_half_width, center_y + f32(y_offset))
	}
}

// Hollow disc — same approach as filled but only paints the
// outermost annulus.
@(private="file")
draw_hollow_disc :: proc(renderer: ^sdl3.Renderer, center_x, center_y, radius: f32, color: sdl3.FColor) {
	if radius <= 0 { return }
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	inner_radius := radius - 1.5
	if inner_radius < 0 { inner_radius = 0 }
	outer_squared := radius * radius
	inner_squared := inner_radius * inner_radius
	r_int := i32(radius + 0.5)
	for y_offset := -r_int; y_offset <= r_int; y_offset += 1 {
		y_squared := f32(y_offset) * f32(y_offset)
		if y_squared > outer_squared { continue }
		outer_x := math.sqrt_f32(outer_squared - y_squared)
		if y_squared >= inner_squared {
			sdl3.RenderLine(renderer,
				center_x - outer_x, center_y + f32(y_offset),
				center_x + outer_x, center_y + f32(y_offset))
		} else {
			inner_x := math.sqrt_f32(inner_squared - y_squared)
			sdl3.RenderLine(renderer,
				center_x - outer_x, center_y + f32(y_offset),
				center_x - inner_x, center_y + f32(y_offset))
			sdl3.RenderLine(renderer,
				center_x + inner_x, center_y + f32(y_offset),
				center_x + outer_x, center_y + f32(y_offset))
		}
	}
}

@(private="file")
filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
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
