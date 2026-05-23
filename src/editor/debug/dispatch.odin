// Per-frame mutators + input dispatch + breakpoint storage.
// Editor coupling routes through `binding.EditorAPI` (DAP actions,
// flushing breakpoints to the adapter).
package debug

import "core:strings"
import "vendor:sdl3"

import "../../dap"
import "../../ui"
import "../binding"

// --- Panel toggle / width ---------------------------------------------

// Toggle the panel visibility flag. The caller is responsible for
// coordinating with the Debug Output pane (showing/hiding both
// together).
panel_set_visible :: proc(state: ^State, visible: bool) {
	state.panel_visible = visible
}

// Width the debug panel currently claims on the right side of the
// window. Returns 0 when the panel is hidden — call sites can
// subtract this directly from `window_width`.
width :: proc(state: ^State) -> i32 {
	if !state.panel_visible { return 0 }
	requested := state.panel_width
	if requested < MIN_WIDTH { requested = MIN_WIDTH }
	return requested
}

// True when the user is mid-drag on any of the panel's resize
// handles OR any of the section scrollbars.
is_dragging :: proc(state: ^State) -> bool {
	return state.panel_resize_dragging       ||
	       state.stack_divider_dragging      ||
	       state.variables_divider_dragging  ||
	       state.stack_scrollbar.is_dragging      ||
	       state.variables_scrollbar.is_dragging  ||
	       state.breakpoints_scrollbar.is_dragging
}

// True when the user is hovering over any of the resize handles or
// is actively dragging one. The mouse cursor-swap path reads this
// to pick the right system cursor (EW for the panel edge, NS for
// section dividers).
handle_cursor_kind :: proc(state: ^State, mouse_x, mouse_y: f32) -> (wants_ew: bool, wants_ns: bool) {
	if !state.panel_visible { return false, false }
	if state.panel_resize_dragging || left_edge_hit(state, mouse_x, mouse_y) {
		return true, false
	}
	if state.stack_divider_dragging || state.variables_divider_dragging {
		return false, true
	}
	if ui.point_in_rect(state.stack_divider_rectangle,     mouse_x, mouse_y) ||
	   ui.point_in_rect(state.variables_divider_rectangle, mouse_x, mouse_y) {
		return false, true
	}
	return false, false
}

// --- Scope / variable expansion ---------------------------------------

@(private)
is_scope_expanded :: proc(state: ^State, scope_name: string, default_expanded: bool) -> bool {
	if value, has := state.expanded_scopes[scope_name]; has { return value }
	return default_expanded
}

@(private)
set_scope_expanded :: proc(state: ^State, scope_name: string, expanded: bool) {
	for existing_key in state.expanded_scopes {
		if existing_key == scope_name {
			state.expanded_scopes[existing_key] = expanded
			return
		}
	}
	state.expanded_scopes[strings.clone(scope_name)] = expanded
}

@(private)
is_variable_expanded :: proc(state: ^State, variables_reference: i64) -> bool {
	if value, has := state.expanded_variables[variables_reference]; has { return value }
	return false
}

// --- Breakpoint storage -----------------------------------------------

@(private="file")
file_index :: proc(state: ^State, file_path: string) -> int {
	for entry, idx in state.breakpoint_files {
		if path_equals_ignore_case(entry.file_path, file_path) { return idx }
	}
	return -1
}

// Returns the breakpoint list for a file, or nil when there are
// none. Caller does NOT own the slice — it aliases the storage in
// `state`.
breakpoints_for_file :: proc(state: ^State, file_path: string) -> []Breakpoint {
	if len(file_path) == 0 { return nil }
	idx := file_index(state, file_path)
	if idx < 0 { return nil }
	return state.breakpoint_files[idx].breakpoints[:]
}

// True when the given file has a breakpoint at `line` (0-based),
// with the breakpoint's enabled-flag returned in the second result.
at_line :: proc(state: ^State, file_path: string, line: u32) -> (found: bool, enabled: bool) {
	if len(file_path) == 0 { return false, false }
	idx := file_index(state, file_path)
	if idx < 0 { return false, false }
	for bp in state.breakpoint_files[idx].breakpoints {
		if bp.line == line { return true, bp.enabled }
	}
	return false, false
}

// Add a breakpoint at `line` if there isn't one yet, or remove it
// if there is. Calls `api.dap_flush_file_breakpoints` after every
// mutation so the adapter sees the change.
toggle_at :: proc(state: ^State, api: ^binding.EditorAPI, file_path: string, line: u32) {
	if len(file_path) == 0 { return }
	idx := file_index(state, file_path)
	if idx < 0 {
		new_entry := BreakpointFile{ file_path = strings.clone(file_path) }
		append(&new_entry.breakpoints, Breakpoint{ line = line, enabled = true })
		append(&state.breakpoint_files, new_entry)
		flush_via_api(api, file_path)
		return
	}
	file_entry := &state.breakpoint_files[idx]
	for bp, bp_index in file_entry.breakpoints {
		if bp.line == line {
			if len(bp.condition) > 0 { delete(bp.condition) }
			ordered_remove(&file_entry.breakpoints, bp_index)
			path_for_flush := file_path
			if len(file_entry.breakpoints) == 0 {
				delete(file_entry.file_path)
				delete(file_entry.breakpoints)
				ordered_remove(&state.breakpoint_files, idx)
			}
			flush_via_api(api, path_for_flush)
			return
		}
	}
	append(&file_entry.breakpoints, Breakpoint{ line = line, enabled = true })
	flush_via_api(api, file_path)
}

remove :: proc(state: ^State, api: ^binding.EditorAPI, file_idx, bp_index: int) {
	if file_idx < 0 || file_idx >= len(state.breakpoint_files) { return }
	file_entry := &state.breakpoint_files[file_idx]
	if bp_index < 0 || bp_index >= len(file_entry.breakpoints) { return }
	path_for_flush := strings.clone(file_entry.file_path, context.temp_allocator)
	{
		victim := file_entry.breakpoints[bp_index]
		if len(victim.condition) > 0 { delete(victim.condition) }
	}
	ordered_remove(&file_entry.breakpoints, bp_index)
	if len(file_entry.breakpoints) == 0 {
		delete(file_entry.file_path)
		delete(file_entry.breakpoints)
		ordered_remove(&state.breakpoint_files, file_idx)
	}
	flush_via_api(api, path_for_flush)
}

set_enabled :: proc(state: ^State, api: ^binding.EditorAPI, file_idx, bp_index: int, enabled: bool) {
	if file_idx < 0 || file_idx >= len(state.breakpoint_files) { return }
	file_entry := &state.breakpoint_files[file_idx]
	if bp_index < 0 || bp_index >= len(file_entry.breakpoints) { return }
	file_entry.breakpoints[bp_index].enabled = enabled
	flush_via_api(api, file_entry.file_path)
}

// Set (or clear, with an empty string) the breakpoint's condition.
// Creates the breakpoint at `line` if one doesn't already exist
// there, so the same proc serves "Add conditional breakpoint" and
// "Edit existing breakpoint".
set_condition_at :: proc(state: ^State, api: ^binding.EditorAPI, file_path: string, line: u32, condition: string) {
	if len(file_path) == 0 { return }
	idx := file_index(state, file_path)
	if idx < 0 {
		new_entry := BreakpointFile{ file_path = strings.clone(file_path) }
		condition_clone := len(condition) > 0 ? strings.clone(condition) : ""
		append(&new_entry.breakpoints, Breakpoint{ line = line, enabled = true, condition = condition_clone })
		append(&state.breakpoint_files, new_entry)
		flush_via_api(api, file_path)
		return
	}
	file_entry := &state.breakpoint_files[idx]
	for bp, bp_index in file_entry.breakpoints {
		if bp.line == line {
			if len(file_entry.breakpoints[bp_index].condition) > 0 {
				delete(file_entry.breakpoints[bp_index].condition)
			}
			file_entry.breakpoints[bp_index].condition = len(condition) > 0 ? strings.clone(condition) : ""
			flush_via_api(api, file_entry.file_path)
			return
		}
	}
	condition_clone := len(condition) > 0 ? strings.clone(condition) : ""
	append(&file_entry.breakpoints, Breakpoint{ line = line, enabled = true, condition = condition_clone })
	flush_via_api(api, file_path)
}

// Look up the current condition string for the breakpoint at
// `(file, line)`. Returns `("", false)` when no breakpoint exists,
// or when there is one but its condition is empty. Caller MUST NOT
// delete the returned slice.
condition_at :: proc(state: ^State, file_path: string, line: u32) -> (condition: string, has_breakpoint: bool) {
	if len(file_path) == 0 { return "", false }
	idx := file_index(state, file_path)
	if idx < 0 { return "", false }
	for bp in state.breakpoint_files[idx].breakpoints {
		if bp.line == line { return bp.condition, true }
	}
	return "", false
}

@(private="file")
flush_via_api :: proc(api: ^binding.EditorAPI, file_path: string) {
	if api == nil { return }
	if api.dap_flush_file_breakpoints != nil {
		api.dap_flush_file_breakpoints(api.editor, file_path)
	}
}

// Case-insensitive path equality + separator-fold. Local to this
// subpackage to avoid importing the editor package.
@(private="file")
path_equals_ignore_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for byte_index in 0..<len(a) {
		if ascii_fold(a[byte_index]) != ascii_fold(b[byte_index]) { return false }
	}
	return true
}

@(private="file")
ascii_fold :: proc(byte_value: u8) -> u8 {
	if byte_value >= 'A' && byte_value <= 'Z' { return byte_value + ('a' - 'A') }
	if byte_value == '\\' { return '/' }
	return byte_value
}

// --- Mouse / wheel input dispatch -------------------------------------

@(private)
left_edge_hit :: proc(state: ^State, mouse_x, mouse_y: f32) -> bool {
	if !state.panel_visible { return false }
	left_edge_x := state.panel_rectangle.x
	if mouse_x < left_edge_x - f32(RESIZE_HOT_ZONE) { return false }
	if mouse_x > left_edge_x + f32(RESIZE_HOT_ZONE) { return false }
	if mouse_y < state.panel_rectangle.y                         { return false }
	if mouse_y > state.panel_rectangle.y + state.panel_rectangle.h { return false }
	return true
}

// Per-frame hover sync — called from MOUSE_MOTION events. Returns
// true when any visible state changed (caller should mark dirty).
update_hover :: proc(state: ^State, mouse_x, mouse_y: f32) -> bool {
	if !state.panel_visible {
		changed := state.panel_resize_hovered || state.stack_divider_hovered || state.variables_divider_hovered
		state.panel_resize_hovered      = false
		state.stack_divider_hovered     = false
		state.variables_divider_hovered = false
		return changed
	}
	new_panel_hover         := left_edge_hit(state, mouse_x, mouse_y)
	new_stack_div_hover     := ui.point_in_rect(state.stack_divider_rectangle,     mouse_x, mouse_y)
	new_variables_div_hover := ui.point_in_rect(state.variables_divider_rectangle, mouse_x, mouse_y)

	control_rects := [?]sdl3.FRect{
		state.run_button_rect,
		state.stop_button_rect,
		state.continue_button_rect,
		state.step_over_button_rect,
		state.step_into_button_rect,
		state.step_out_button_rect,
	}
	any_button_hovered := false
	for rectangle in control_rects {
		if ui.point_in_rect(rectangle, mouse_x, mouse_y) { any_button_hovered = true; break }
	}

	any_section_scrollbar_changed :=
		ui.scrollbar_update_hover(&state.stack_scrollbar,       mouse_x, mouse_y) ||
		ui.scrollbar_update_hover(&state.variables_scrollbar,   mouse_x, mouse_y) ||
		ui.scrollbar_update_hover(&state.breakpoints_scrollbar, mouse_x, mouse_y)

	changed := new_panel_hover != state.panel_resize_hovered ||
	           new_stack_div_hover     != state.stack_divider_hovered ||
	           new_variables_div_hover != state.variables_divider_hovered ||
	           any_button_hovered ||
	           any_section_scrollbar_changed

	state.panel_resize_hovered      = new_panel_hover
	state.stack_divider_hovered     = new_stack_div_hover
	state.variables_divider_hovered = new_variables_div_hover
	return changed
}

// Returns true when the click was inside the panel — caller should
// stop further processing.
@(private)
handle_click :: proc(state: ^State, api: ^binding.EditorAPI, mouse_x, mouse_y: f32) -> bool {
	if !state.panel_visible { return false }

	if left_edge_hit(state, mouse_x, mouse_y) {
		state.panel_resize_dragging = true
		return true
	}

	if ui.point_in_rect(state.stack_divider_rectangle, mouse_x, mouse_y) {
		state.stack_divider_dragging = true
		return true
	}
	if ui.point_in_rect(state.variables_divider_rectangle, mouse_x, mouse_y) {
		state.variables_divider_dragging = true
		return true
	}

	if section_scrollbar_mouse_down(&state.stack_scrollbar,       &state.stack_scroll,       state.stack_viewport,       mouse_x, mouse_y) { return true }
	if section_scrollbar_mouse_down(&state.variables_scrollbar,   &state.variables_scroll,   state.variables_viewport,   mouse_x, mouse_y) { return true }
	if section_scrollbar_mouse_down(&state.breakpoints_scrollbar, &state.breakpoints_scroll, state.breakpoints_viewport, mouse_x, mouse_y) { return true }

	if !ui.point_in_rect(state.panel_rectangle, mouse_x, mouse_y) { return false }

	client: ^dap.Client
	if api != nil && api.active_dap_client != nil { client = api.active_dap_client(api.editor) }

	if ui.point_in_rect(state.run_button_rect,       mouse_x, mouse_y) { dap_dispatch(api, .StartSession); return true }
	if ui.point_in_rect(state.stop_button_rect,      mouse_x, mouse_y) { dap_dispatch(api, .StopSession);  return true }
	if ui.point_in_rect(state.continue_button_rect,  mouse_x, mouse_y) { dap_dispatch(api, .Continue);     return true }
	if ui.point_in_rect(state.step_over_button_rect, mouse_x, mouse_y) { dap_dispatch(api, .StepOver);     return true }
	if ui.point_in_rect(state.step_into_button_rect, mouse_x, mouse_y) { dap_dispatch(api, .StepInto);     return true }
	if ui.point_in_rect(state.step_out_button_rect,  mouse_x, mouse_y) { dap_dispatch(api, .StepOut);      return true }

	if ui.point_in_rect(state.stack_viewport, mouse_x, mouse_y) {
		for row_rect, row_index in state.stack_row_rects {
			if ui.point_in_rect(row_rect, mouse_x, mouse_y) {
				state.selected_stack_frame = row_index
				return true
			}
		}
		return true
	}

	if ui.point_in_rect(state.variables_viewport, mouse_x, mouse_y) {
		for row_rect, row_index in state.variable_row_rects {
			if !ui.point_in_rect(row_rect, mouse_x, mouse_y) { continue }
			switch state.variable_row_kinds[row_index] {
			case .Scope:
				scope_index := state.variable_row_scope_index[row_index]
				scope_name  := state.variable_row_scope_name[row_index]
				scopes := dap.client_scopes(client)
				if scope_index < 0 || scope_index >= len(scopes) { return true }
				scope := scopes[scope_index]
				currently_expanded := is_scope_expanded(state, scope_name, !scope.expensive)
				new_expanded := !currently_expanded
				set_scope_expanded(state, scope_name, new_expanded)
				if new_expanded && scope.expensive {
					dap.client_request_scope_variables(client, scope_index)
				}
				return true
			case .Variable:
				var_ref := state.variable_row_var_ref[row_index]
				if var_ref == 0 { return true }
				currently_expanded := is_variable_expanded(state, var_ref)
				new_expanded := !currently_expanded
				state.expanded_variables[var_ref] = new_expanded
				if new_expanded {
					dap.client_request_children(client, var_ref)
				}
				return true
			case .None:
				return true
			}
		}
		return true
	}

	for row_index in 0..<len(state.breakpoint_row_rects) {
		if ui.point_in_rect(state.breakpoint_remove_rects[row_index], mouse_x, mouse_y) {
			remove(state, api, state.breakpoint_row_file_index[row_index], state.breakpoint_row_bp_index[row_index])
			return true
		}
		if ui.point_in_rect(state.breakpoint_toggle_rects[row_index], mouse_x, mouse_y) {
			file_idx := state.breakpoint_row_file_index[row_index]
			bp_index := state.breakpoint_row_bp_index[row_index]
			if file_idx < len(state.breakpoint_files) && bp_index < len(state.breakpoint_files[file_idx].breakpoints) {
				current := state.breakpoint_files[file_idx].breakpoints[bp_index].enabled
				set_enabled(state, api, file_idx, bp_index, !current)
			}
			return true
		}
		if ui.point_in_rect(state.breakpoint_row_rects[row_index], mouse_x, mouse_y) {
			// Future: jump to file:line. Consume the click either way.
			return true
		}
	}

	return true
}

@(private="file")
dap_dispatch :: proc(api: ^binding.EditorAPI, action: binding.DapAction) {
	if api == nil || api.dap_action == nil { return }
	api.dap_action(api.editor, action)
}

@(private="file")
section_scrollbar_mouse_down :: proc(scrollbar: ^ui.Scrollbar, scroll_value: ^i32, viewport: sdl3.FRect, mouse_x, mouse_y: f32) -> bool {
	if ui.scrollbar_thumb_hit(scrollbar, mouse_x, mouse_y) {
		ui.scrollbar_begin_thumb_drag(scrollbar, mouse_y)
		return true
	}
	if ui.scrollbar_track_hit(scrollbar, mouse_x, mouse_y) {
		ui.scrollbar_begin_track_drag(scrollbar)
		section_scrollbar_apply(scrollbar, scroll_value, viewport, mouse_y)
		return true
	}
	return false
}

@(private="file")
section_scrollbar_apply :: proc(scrollbar: ^ui.Scrollbar, scroll_value: ^i32, viewport: sdl3.FRect, mouse_y: f32) {
	track := scrollbar.track_rectangle
	thumb := scrollbar.thumb_rectangle
	if track.h <= 0 || thumb.h <= 0 { return }
	content_height := track.h * track.h / thumb.h
	max_scroll := content_height - track.h
	if max_scroll < 0 { max_scroll = 0 }
	new_scroll := ui.scrollbar_drag_to(scrollbar, mouse_y, max_scroll)
	scroll_value^ = i32(new_scroll)
	_ = viewport
}

// Mouse-motion handler while a panel drag is latched. Returns true
// when a drag actually consumed the motion.
@(private)
handle_drag :: proc(state: ^State, mouse_x, mouse_y: f32) -> bool {
	if state.panel_resize_dragging {
		window_width := state.cached_window_width
		if window_width <= 0 { window_width = MIN_WIDTH * 4 } // sane default
		new_width := window_width - i32(mouse_x)
		if new_width < MIN_WIDTH { new_width = MIN_WIDTH }
		max_width := window_width - MIN_WIDTH
		if max_width < MIN_WIDTH { max_width = MIN_WIDTH }
		if new_width > max_width { new_width = max_width }
		if new_width != state.panel_width { state.panel_width = new_width }
		return true
	}

	if state.stack_divider_dragging || state.variables_divider_dragging {
		resize_section(state, mouse_y)
		return true
	}

	if state.stack_scrollbar.is_dragging {
		section_scrollbar_apply(&state.stack_scrollbar, &state.stack_scroll, state.stack_viewport, mouse_y)
		return true
	}
	if state.variables_scrollbar.is_dragging {
		section_scrollbar_apply(&state.variables_scrollbar, &state.variables_scroll, state.variables_viewport, mouse_y)
		return true
	}
	if state.breakpoints_scrollbar.is_dragging {
		section_scrollbar_apply(&state.breakpoints_scrollbar, &state.breakpoints_scroll, state.breakpoints_viewport, mouse_y)
		return true
	}
	return false
}

@(private="file")
resize_section :: proc(state: ^State, mouse_y: f32) {
	stack_viewport     := state.stack_viewport
	variables_viewport := state.variables_viewport
	breakpoints_viewport := state.breakpoints_viewport
	body_area_total := i32(stack_viewport.h + variables_viewport.h + breakpoints_viewport.h)
	if body_area_total <= 0 { return }

	if state.stack_divider_dragging {
		stack_top := stack_viewport.y
		min_y := stack_top + f32(SECTION_MIN_HEIGHT)
		max_y := variables_viewport.y + variables_viewport.h - f32(SECTION_MIN_HEIGHT)
		clamped_y := clamp_f32(mouse_y, min_y, max_y)
		new_stack_height := i32(clamped_y - stack_top)
		new_variables_height := i32(variables_viewport.y + variables_viewport.h) - i32(clamped_y) - SECTION_DIVIDER_HEIGHT
		if new_variables_height < SECTION_MIN_HEIGHT { new_variables_height = SECTION_MIN_HEIGHT }
		state.stack_section_fraction     = f32(new_stack_height)     / f32(body_area_total)
		state.variables_section_fraction = f32(new_variables_height) / f32(body_area_total)
		return
	}

	if state.variables_divider_dragging {
		variables_top := variables_viewport.y
		min_y := variables_top + f32(SECTION_MIN_HEIGHT)
		max_y := breakpoints_viewport.y + breakpoints_viewport.h - f32(SECTION_MIN_HEIGHT)
		clamped_y := clamp_f32(mouse_y, min_y, max_y)
		new_variables_height := i32(clamped_y - variables_top)
		state.variables_section_fraction = f32(new_variables_height) / f32(body_area_total)
		return
	}
}

@(private="file")
clamp_f32 :: #force_inline proc(value, low, high: f32) -> f32 {
	if value < low  { return low }
	if value > high { return high }
	return value
}

// Release every latched resize drag AND every section scrollbar
// drag.
@(private)
handle_mouse_up :: proc(state: ^State) -> bool {
	was_dragging := is_dragging(state)
	state.panel_resize_dragging       = false
	state.stack_divider_dragging      = false
	state.variables_divider_dragging  = false
	ui.scrollbar_end_drag(&state.stack_scrollbar)
	ui.scrollbar_end_drag(&state.variables_scrollbar)
	ui.scrollbar_end_drag(&state.breakpoints_scrollbar)
	return was_dragging
}

// Returns true when wheel scroll was inside the panel and consumed.
@(private)
handle_wheel :: proc(state: ^State, mouse_x, mouse_y: f32, wheel_y, line_height: f32) -> bool {
	if !state.panel_visible { return false }
	if !ui.point_in_rect(state.panel_rectangle, mouse_x, mouse_y) { return false }

	step := -i32(wheel_y * line_height * 3.0)
	switch {
	case ui.point_in_rect(state.stack_viewport, mouse_x, mouse_y):
		state.stack_scroll += step
		if state.stack_scroll < 0 { state.stack_scroll = 0 }
	case ui.point_in_rect(state.variables_viewport, mouse_x, mouse_y):
		state.variables_scroll += step
		if state.variables_scroll < 0 { state.variables_scroll = 0 }
	case ui.point_in_rect(state.breakpoints_viewport, mouse_x, mouse_y):
		state.breakpoints_scroll += step
		if state.breakpoints_scroll < 0 { state.breakpoints_scroll = 0 }
	}
	return true
}

@(private)
normalize_section_fractions :: proc(state: ^State) {
	epsilon: f32 = 0.05
	if state.stack_section_fraction     < epsilon { state.stack_section_fraction     = epsilon }
	if state.variables_section_fraction < epsilon { state.variables_section_fraction = epsilon }
	leftover := 1.0 - state.stack_section_fraction - state.variables_section_fraction
	if leftover < epsilon {
		available := 1.0 - epsilon
		total := state.stack_section_fraction + state.variables_section_fraction
		if total > 0 {
			state.stack_section_fraction     = (state.stack_section_fraction     / total) * available
			state.variables_section_fraction = (state.variables_section_fraction / total) * available
		}
	}
}
