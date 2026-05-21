package editor

import "core:fmt"
import "core:math"
import "core:strings"
import "vendor:sdl3"

import "../dap"
import "../document"
import "../ui"

// --- Types ----------------------------------------------------------------

@(private)
Breakpoint :: struct {
	line:      u32,    // 0-based document line
	enabled:   bool,
	condition: string, // owned; "" for an unconditional breakpoint
}

@(private)
BreakpointFile :: struct {
	file_path:   string, // owned absolute path
	breakpoints: [dynamic]Breakpoint,
}

// Marks a row in the Variables panel: either a scope header (Locals,
// Arguments, …) or one variable. Clicking a scope row toggles its expanded
// state by name; clicking a variable row toggles by `variables_reference`
// (only meaningful when the variable is compound, i.e. ref != 0).
@(private)
VariableRowKind :: enum {
	None,
	Scope,
	Variable,
}

@(private)
DebugState :: struct {
	panel_visible: bool,

	// Breakpoints persist across panel-hide and across debug sessions. Tied to
	// file paths (not pane indices), so they survive document swaps. A linear
	// search over `breakpoint_files` is fine — the user is rarely going to
	// have hundreds of distinct files with breakpoints.
	breakpoint_files: [dynamic]BreakpointFile,

	// Cached session flags — derived from `editor.active_dap_client` once per
	// frame in `debug_session_sync_from_client` so the panel doesn't have to
	// thread a client pointer through every render proc.
	session_active:       bool,
	is_stopped:           bool,
	selected_stack_frame: int,

	// Variable-tree UI state. Scopes use names as keys (stable across stops);
	// compound variables use their `variablesReference` (invalidated by the
	// adapter on continue/step, so `expanded_variables` is cleared on every
	// new stop transition).
	//   - presence-with-true  → user explicitly expanded
	//   - presence-with-false → user explicitly collapsed
	//   - absence             → use the default (non-expensive scopes expand
	//                            by default; variables collapse by default)
	expanded_scopes:      map[string]bool,
	expanded_variables:   map[i64]bool,

	// Per-section scroll offsets, in pixels.
	stack_scroll:       i32,
	variables_scroll:   i32,
	breakpoints_scroll: i32,

	// Per-section scrollbar widget state (hover, drag, track/thumb rects).
	// Each section behaves like the editor pane's scrollbar — widens on
	// hover, accepts thumb-drag and track-click-then-drag.
	stack_scrollbar:       ui.Scrollbar,
	variables_scrollbar:   ui.Scrollbar,
	breakpoints_scrollbar: ui.Scrollbar,

	// User-resizable panel width. Initialized to DEBUG_PANEL_DEFAULT_WIDTH in
	// `debug_state_init`; the left-edge drag handle mutates it directly.
	// Clamped at render time so a window resize that makes the requested
	// width unreasonable doesn't paint nonsense.
	panel_width: i32,

	// Section heights, expressed as fractions of the available body area so
	// the relative proportions survive window resizes. Stack + Variables
	// fractions are stored; Breakpoints takes whatever's left.
	stack_section_fraction:     f32,
	variables_section_fraction: f32,

	// Drag handle interaction. `panel_resize_*` is the left-edge width
	// handle; `*_section_resize_*` is the horizontal divider between two
	// vertically-stacked sections. Only one of these is true at a time.
	panel_resize_hovered:           bool,
	panel_resize_dragging:          bool,
	stack_divider_rectangle:        sdl3.FRect, // between Call Stack and Variables
	variables_divider_rectangle:    sdl3.FRect, // between Variables and Breakpoints
	stack_divider_hovered:          bool,
	variables_divider_hovered:      bool,
	stack_divider_dragging:         bool,
	variables_divider_dragging:     bool,

	// Rectangles rewritten by the renderer each frame so the mouse dispatcher
	// can hit-test against the exact pixels that were painted.
	panel_rectangle:        sdl3.FRect,
	run_button_rect:        sdl3.FRect,
	stop_button_rect:       sdl3.FRect,
	continue_button_rect:   sdl3.FRect,
	step_over_button_rect:  sdl3.FRect,
	step_into_button_rect:  sdl3.FRect,
	step_out_button_rect:   sdl3.FRect,
	stack_viewport:         sdl3.FRect,
	variables_viewport:     sdl3.FRect,
	breakpoints_viewport:   sdl3.FRect,

	// Per-row click targets for the variables list. Parallel arrays so the
	// dispatcher can keep its hit-test in O(rows). Scope rows carry a name +
	// scope index; variable rows carry a variables_reference (0 when leaf).
	variable_row_rects:        [dynamic]sdl3.FRect,
	variable_row_kinds:        [dynamic]VariableRowKind,
	variable_row_scope_index:  [dynamic]int,
	variable_row_scope_name:   [dynamic]string, // borrowed pointer into dap.Client (no clone)
	variable_row_var_ref:      [dynamic]i64,

	// Per-row click targets for the call-stack list — one entry per painted
	// frame. Lets the user click a frame to refresh scopes against that one.
	stack_row_rects: [dynamic]sdl3.FRect,

	// Per-row click targets for the breakpoint list (parallel arrays — one
	// entry per painted row). Rebuilt every frame.
	breakpoint_row_rects:      [dynamic]sdl3.FRect,
	breakpoint_toggle_rects:   [dynamic]sdl3.FRect,
	breakpoint_remove_rects:   [dynamic]sdl3.FRect,
	breakpoint_row_file_index: [dynamic]int,
	breakpoint_row_bp_index:   [dynamic]int,
}

@(private)
DEBUG_PANEL_DEFAULT_WIDTH: i32 : 320

// Width clamp so the panel can't shrink past the button row or steal the
// whole window. Min picked so all six debug buttons + a few characters of
// labels fit; max evaluated against the actual window width each frame.
@(private)
DEBUG_PANEL_MIN_WIDTH: i32 : 220

@(private)
DEBUG_PANEL_RESIZE_HOT_ZONE: i32 : 5 // pixels either side of the left edge that latch the drag

@(private)
DEBUG_SECTION_MIN_HEIGHT: i32 : 40

@(private)
DEBUG_SECTION_DIVIDER_HEIGHT: i32 : 6 // visual gap that doubles as the drag handle

@(private)
DEBUG_PANEL_TITLE_HEIGHT_EXTRA: i32 : 6

// --- Lifecycle ------------------------------------------------------------

@(private)
debug_state_init :: proc(state: ^DebugState) {
	state^ = DebugState{}
	state.expanded_scopes    = make(map[string]bool)
	state.expanded_variables = make(map[i64]bool)
	state.panel_width                = DEBUG_PANEL_DEFAULT_WIDTH
	state.stack_section_fraction     = 1.0 / 3.0
	state.variables_section_fraction = 1.0 / 3.0
}

@(private)
debug_state_destroy :: proc(state: ^DebugState) {
	for file_entry in state.breakpoint_files {
		if len(file_entry.file_path) > 0 { delete(file_entry.file_path) }
		for bp in file_entry.breakpoints {
			if len(bp.condition) > 0 { delete(bp.condition) }
		}
		delete(file_entry.breakpoints)
	}
	if cap(state.breakpoint_files) > 0 { delete(state.breakpoint_files) }

	for scope_name in state.expanded_scopes { delete(scope_name) }
	delete(state.expanded_scopes)
	delete(state.expanded_variables)

	if cap(state.variable_row_rects)       > 0 { delete(state.variable_row_rects)       }
	if cap(state.variable_row_kinds)       > 0 { delete(state.variable_row_kinds)       }
	if cap(state.variable_row_scope_index) > 0 { delete(state.variable_row_scope_index) }
	if cap(state.variable_row_scope_name)  > 0 { delete(state.variable_row_scope_name)  }
	if cap(state.variable_row_var_ref)     > 0 { delete(state.variable_row_var_ref)     }
	if cap(state.stack_row_rects)          > 0 { delete(state.stack_row_rects)          }

	if cap(state.breakpoint_row_rects)      > 0 { delete(state.breakpoint_row_rects)      }
	if cap(state.breakpoint_toggle_rects)   > 0 { delete(state.breakpoint_toggle_rects)   }
	if cap(state.breakpoint_remove_rects)   > 0 { delete(state.breakpoint_remove_rects)   }
	if cap(state.breakpoint_row_file_index) > 0 { delete(state.breakpoint_row_file_index) }
	if cap(state.breakpoint_row_bp_index)   > 0 { delete(state.breakpoint_row_bp_index)   }
}

// Drop the per-session UI state (expansion sets, derived flags) but keep
// breakpoints. Called when the adapter has exited so the panel reverts to
// its idle-state placeholders and old refs don't leak into the next session.
@(private)
debug_session_clear :: proc(state: ^DebugState) {
	for scope_name in state.expanded_scopes { delete(scope_name) }
	clear(&state.expanded_scopes)
	clear(&state.expanded_variables)

	state.session_active       = false
	state.is_stopped           = false
	state.selected_stack_frame = 0
}

// Look up the effective expanded flag for a scope, applying the default
// (non-expensive scopes expand by default) when the user hasn't overridden.
@(private)
debug_is_scope_expanded :: proc(state: ^DebugState, scope_name: string, default_expanded: bool) -> bool {
	if value, has := state.expanded_scopes[scope_name]; has { return value }
	return default_expanded
}

@(private)
debug_set_scope_expanded :: proc(state: ^DebugState, scope_name: string, expanded: bool) {
	for existing_key in state.expanded_scopes {
		if existing_key == scope_name {
			state.expanded_scopes[existing_key] = expanded
			return
		}
	}
	state.expanded_scopes[strings.clone(scope_name)] = expanded
}

// Toggle the *debug UI as a whole*: the right-side debug panel AND the
// Debug Output pane in pane[1] are conceptually one feature, so Shift+F7
// raises/lowers them together. If either piece is currently visible, we
// hide both; otherwise we show both. Treating them as a unit keeps the
// keybinding predictable — there's no "half open" state to reason about.
@(private)
debug_panel_toggle :: proc(editor: ^Editor) {
	any_visible := editor.debug_state.panel_visible || editor_is_output_pane_visible(editor)
	if any_visible {
		editor.debug_state.panel_visible = false
		editor_output_pane_hide(editor)
	} else {
		editor.debug_state.panel_visible = true
		editor_output_pane_show(editor)
	}
	editor_mark_dirty(editor)
}

// Width the debug panel currently claims on the right side of the window.
// Returns 0 when the panel is hidden — call sites can subtract this directly
// from `window_width` to derive the editor-pane area. The width is clamped
// against the current window each frame so a wide-window-then-narrow-window
// resize doesn't leave the panel covering the whole pane area.
@(private)
debug_panel_width :: proc(editor: ^Editor) -> i32 {
	if !editor.debug_state.panel_visible { return 0 }
	return debug_panel_clamped_width(editor)
}

@(private)
debug_panel_clamped_width :: proc(editor: ^Editor) -> i32 {
	requested := editor.debug_state.panel_width
	if requested < DEBUG_PANEL_MIN_WIDTH { requested = DEBUG_PANEL_MIN_WIDTH }
	// We don't have window_width here; the renderer enforces the upper bound
	// against the live window each frame. This helper just enforces the floor.
	return requested
}

// --- Breakpoint storage ---------------------------------------------------

@(private="file")
breakpoint_file_index :: proc(state: ^DebugState, file_path: string) -> int {
	for entry, file_index in state.breakpoint_files {
		if path_equals_ignore_case(entry.file_path, file_path) { return file_index }
	}
	return -1
}

// Returns the breakpoint list for a file, or nil when there are none.
// Caller does NOT own the slice — it aliases the storage in `editor.debug_state`.
@(private)
breakpoints_for_file :: proc(editor: ^Editor, file_path: string) -> []Breakpoint {
	if len(file_path) == 0 { return nil }
	file_index := breakpoint_file_index(&editor.debug_state, file_path)
	if file_index < 0 { return nil }
	return editor.debug_state.breakpoint_files[file_index].breakpoints[:]
}

// True when the given file has a breakpoint at `line` (0-based), with the
// breakpoint's enabled-flag returned in the second result. (false, false) when
// no breakpoint exists on that line — the second value is meaningless then.
@(private)
breakpoint_at_line :: proc(editor: ^Editor, file_path: string, line: u32) -> (found: bool, enabled: bool) {
	if len(file_path) == 0 { return false, false }
	state := &editor.debug_state
	file_index := breakpoint_file_index(state, file_path)
	if file_index < 0 { return false, false }
	for bp in state.breakpoint_files[file_index].breakpoints {
		if bp.line == line { return true, bp.enabled }
	}
	return false, false
}

// Add a breakpoint at `line` if there isn't one yet, or remove it if there is.
// Empties the file's entry when its last breakpoint is removed so the panel's
// list doesn't show files with zero breakpoints.
@(private)
breakpoint_toggle_at :: proc(editor: ^Editor, file_path: string, line: u32) {
	if len(file_path) == 0 { return }
	state := &editor.debug_state
	file_index := breakpoint_file_index(state, file_path)
	if file_index < 0 {
		new_entry := BreakpointFile{ file_path = strings.clone(file_path) }
		append(&new_entry.breakpoints, Breakpoint{ line = line, enabled = true })
		append(&state.breakpoint_files, new_entry)
		editor_dap_flush_file_breakpoints(editor, file_path)
		editor_mark_dirty(editor)
		return
	}
	file_entry := &state.breakpoint_files[file_index]
	for bp, bp_index in file_entry.breakpoints {
		if bp.line == line {
			if len(bp.condition) > 0 { delete(bp.condition) }
			ordered_remove(&file_entry.breakpoints, bp_index)
			path_for_flush := file_path
			if len(file_entry.breakpoints) == 0 {
				delete(file_entry.file_path)
				delete(file_entry.breakpoints)
				ordered_remove(&state.breakpoint_files, file_index)
			}
			editor_dap_flush_file_breakpoints(editor, path_for_flush)
			editor_mark_dirty(editor)
			return
		}
	}
	append(&file_entry.breakpoints, Breakpoint{ line = line, enabled = true })
	editor_dap_flush_file_breakpoints(editor, file_path)
	editor_mark_dirty(editor)
}

@(private)
breakpoint_remove :: proc(editor: ^Editor, file_index, bp_index: int) {
	state := &editor.debug_state
	if file_index < 0 || file_index >= len(state.breakpoint_files) { return }
	file_entry := &state.breakpoint_files[file_index]
	if bp_index < 0 || bp_index >= len(file_entry.breakpoints) { return }
	// Clone the path before we maybe-drop the entry — we still need it to
	// tell the adapter the file's breakpoint list shrank.
	path_for_flush := strings.clone(file_entry.file_path, context.temp_allocator)
	{
		victim := file_entry.breakpoints[bp_index]
		if len(victim.condition) > 0 { delete(victim.condition) }
	}
	ordered_remove(&file_entry.breakpoints, bp_index)
	if len(file_entry.breakpoints) == 0 {
		delete(file_entry.file_path)
		delete(file_entry.breakpoints)
		ordered_remove(&state.breakpoint_files, file_index)
	}
	editor_dap_flush_file_breakpoints(editor, path_for_flush)
	editor_mark_dirty(editor)
}

@(private)
breakpoint_set_enabled :: proc(editor: ^Editor, file_index, bp_index: int, enabled: bool) {
	state := &editor.debug_state
	if file_index < 0 || file_index >= len(state.breakpoint_files) { return }
	file_entry := &state.breakpoint_files[file_index]
	if bp_index < 0 || bp_index >= len(file_entry.breakpoints) { return }
	file_entry.breakpoints[bp_index].enabled = enabled
	editor_dap_flush_file_breakpoints(editor, file_entry.file_path)
	editor_mark_dirty(editor)
}

// Set (or clear, with an empty string) the breakpoint's condition. Creates
// the breakpoint at `line` if one doesn't already exist there, so the same
// proc serves "Add conditional breakpoint" and "Edit existing breakpoint".
@(private)
breakpoint_set_condition_at :: proc(editor: ^Editor, file_path: string, line: u32, condition: string) {
	if len(file_path) == 0 { return }
	state := &editor.debug_state
	file_index := breakpoint_file_index(state, file_path)
	if file_index < 0 {
		new_entry := BreakpointFile{ file_path = strings.clone(file_path) }
		condition_clone := len(condition) > 0 ? strings.clone(condition) : ""
		append(&new_entry.breakpoints, Breakpoint{ line = line, enabled = true, condition = condition_clone })
		append(&state.breakpoint_files, new_entry)
		editor_dap_flush_file_breakpoints(editor, file_path)
		editor_mark_dirty(editor)
		return
	}
	file_entry := &state.breakpoint_files[file_index]
	for bp, bp_index in file_entry.breakpoints {
		if bp.line == line {
			if len(file_entry.breakpoints[bp_index].condition) > 0 {
				delete(file_entry.breakpoints[bp_index].condition)
			}
			file_entry.breakpoints[bp_index].condition = len(condition) > 0 ? strings.clone(condition) : ""
			editor_dap_flush_file_breakpoints(editor, file_entry.file_path)
			editor_mark_dirty(editor)
			return
		}
	}
	condition_clone := len(condition) > 0 ? strings.clone(condition) : ""
	append(&file_entry.breakpoints, Breakpoint{ line = line, enabled = true, condition = condition_clone })
	editor_dap_flush_file_breakpoints(editor, file_path)
	editor_mark_dirty(editor)
}

// Look up the current condition string for the breakpoint at `(file, line)`.
// Returns `("", false)` when no breakpoint exists, or when there is one but
// its condition is empty. Caller MUST NOT delete the returned slice.
@(private)
breakpoint_condition_at :: proc(editor: ^Editor, file_path: string, line: u32) -> (condition: string, has_breakpoint: bool) {
	if len(file_path) == 0 { return "", false }
	state := &editor.debug_state
	file_index := breakpoint_file_index(state, file_path)
	if file_index < 0 { return "", false }
	for bp in state.breakpoint_files[file_index].breakpoints {
		if bp.line == line { return bp.condition, true }
	}
	return "", false
}

// --- Disc primitives ------------------------------------------------------

// Filled disc approximated by horizontal scanlines. Cheap, no GPU geometry
// allocation, looks identical to a TTF dot at the radii we paint at.
@(private)
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

// Outline-only disc — used for disabled breakpoints so the user can tell at a
// glance which dots are armed vs paused.
@(private)
draw_hollow_disc :: proc(renderer: ^sdl3.Renderer, center_x, center_y, radius: f32, color: sdl3.FColor) {
	if radius <= 0 { return }
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	segment_count :: 24
	previous_x := center_x + radius
	previous_y := center_y
	for segment in 1..=segment_count {
		angle := 2.0 * math.PI * f32(segment) / f32(segment_count)
		next_x := center_x + radius * math.cos_f32(angle)
		next_y := center_y + radius * math.sin_f32(angle)
		sdl3.RenderLine(renderer, previous_x, previous_y, next_x, next_y)
		previous_x = next_x
		previous_y = next_y
	}
}

// --- Panel rendering ------------------------------------------------------

@(private)
debug_panel_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, window_width, window_height: i32) {
	state := &editor.debug_state
	if !state.panel_visible { return }

	menu_bar_height   := editor_menu_bar_height(editor)
	status_bar_height := editor.line_height + 4
	// Clamp the requested width against the live window so the panel never
	// steals more than half of the available width (leaving room for the
	// editor / terminal panes). This is the only place that knows
	// window_width so the clamp lives here rather than in the helper above.
	max_width := window_width - DEBUG_PANEL_MIN_WIDTH
	if max_width < DEBUG_PANEL_MIN_WIDTH { max_width = window_width / 2 }
	if max_width < DEBUG_PANEL_MIN_WIDTH { max_width = DEBUG_PANEL_MIN_WIDTH }
	if state.panel_width > max_width        { state.panel_width = max_width }
	if state.panel_width < DEBUG_PANEL_MIN_WIDTH { state.panel_width = DEBUG_PANEL_MIN_WIDTH }
	panel_width := state.panel_width
	panel_x := window_width - panel_width
	panel_y := menu_bar_height
	panel_h := window_height - menu_bar_height - status_bar_height
	if panel_h < 0 { panel_h = 0 }
	state.panel_rectangle = sdl3.FRect{ f32(panel_x), f32(panel_y), f32(panel_width), f32(panel_h) }

	// Background fill + left divider so the panel reads as a distinct sidebar
	// rather than a chunk of editor. The divider doubles as the resize-handle
	// hit region — the cursor-update / mouse-down paths hit-test against a
	// slightly wider zone around the same x for grabability.
	sdl3.SetRenderDrawColorFloat(renderer, editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a)
	sdl3.RenderFillRect(renderer, &state.panel_rectangle)
	divider_color := editor.divider_color
	if state.panel_resize_hovered || state.panel_resize_dragging { divider_color = editor.cursor_color }
	sdl3.SetRenderDrawColorFloat(renderer, divider_color.r, divider_color.g, divider_color.b, divider_color.a)
	divider_rect := sdl3.FRect{ f32(panel_x), f32(panel_y), 2, f32(panel_h) }
	sdl3.RenderFillRect(renderer, &divider_rect)

	// Reuse the pane title strip so the panel matches editor / terminal panes.
	title_bar_height := editor.line_height + DEBUG_PANEL_TITLE_HEIGHT_EXTRA
	title_label := "Debug"
	if state.session_active {
		title_label = state.is_stopped ? "Debug — stopped" : "Debug — running"
	}
	render_pane_title_strip(editor, renderer, panel_x, panel_y, panel_width, title_bar_height, title_label, true)

	inner_x := panel_x + 8
	inner_w := panel_width - 16
	cursor_y := panel_y + title_bar_height + 8

	// Status / output messages live in the Debug Output pane (pane[1]) where
	// they can wrap and scroll — the panel header strip above already
	// distinguishes running / stopped, and the full log carries everything
	// else. Reserving a status row here would overflow the 320px panel.

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	// --- Buttons -----------------------------------------------------------
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
	button_height := editor.line_height + 8
	for button_index in 0..<button_count {
		button_x := inner_x + button_index * (button_width + button_gap)
		button_rect := sdl3.FRect{ f32(button_x), f32(cursor_y), f32(button_width), f32(button_height) }
		button_rect_pointers[button_index]^ = button_rect
		// Hover is auto-detected by `ui.draw_button` via the Context's
		// mouse fields, so we don't have to track it ourselves anymore.
		ui.draw_button(&ui_context, button_rect, button_labels[button_index], false, theme)
	}
	cursor_y += button_height + 12

	// --- Three stacked sections -------------------------------------------
	// Layout: each section is a header strip + body. Two horizontal drag
	// handles sit between adjacent bodies. Body heights come from
	// state.stack_section_fraction / variables_section_fraction (breakpoints
	// gets the leftover), with a per-section minimum so dragging can't
	// collapse a section to nothing.
	remaining_height := panel_y + panel_h - cursor_y - 8
	if remaining_height < 90 { remaining_height = 90 }
	section_header_height := editor.line_height + 6
	body_area_total := remaining_height - 3 * section_header_height - 2 * DEBUG_SECTION_DIVIDER_HEIGHT
	if body_area_total < 3 * DEBUG_SECTION_MIN_HEIGHT { body_area_total = 3 * DEBUG_SECTION_MIN_HEIGHT }

	debug_normalize_section_fractions(state)
	stack_body_height := i32(f32(body_area_total) * state.stack_section_fraction)
	variables_body_height := i32(f32(body_area_total) * state.variables_section_fraction)
	if stack_body_height     < DEBUG_SECTION_MIN_HEIGHT { stack_body_height     = DEBUG_SECTION_MIN_HEIGHT }
	if variables_body_height < DEBUG_SECTION_MIN_HEIGHT { variables_body_height = DEBUG_SECTION_MIN_HEIGHT }
	breakpoints_body_height := body_area_total - stack_body_height - variables_body_height
	if breakpoints_body_height < DEBUG_SECTION_MIN_HEIGHT {
		// Borrow the deficit from the larger of the upper two so the bottom
		// section can still meet its minimum.
		deficit := DEBUG_SECTION_MIN_HEIGHT - breakpoints_body_height
		if variables_body_height - deficit >= DEBUG_SECTION_MIN_HEIGHT {
			variables_body_height -= deficit
		} else if stack_body_height - deficit >= DEBUG_SECTION_MIN_HEIGHT {
			stack_body_height -= deficit
		}
		breakpoints_body_height = DEBUG_SECTION_MIN_HEIGHT
	}

	// Call Stack.
	debug_panel_render_section_header(editor, renderer, &ui_context, theme, "Call Stack", inner_x, inner_w, &cursor_y, section_header_height)
	state.stack_viewport = sdl3.FRect{ f32(inner_x), f32(cursor_y), f32(inner_w - 8), f32(stack_body_height) }
	debug_panel_render_stack(editor, renderer, &ui_context, theme, state.stack_viewport)
	cursor_y += stack_body_height
	state.stack_divider_rectangle = debug_panel_render_section_divider(editor, renderer, inner_x, cursor_y, inner_w, state.stack_divider_hovered || state.stack_divider_dragging)
	cursor_y += DEBUG_SECTION_DIVIDER_HEIGHT

	// Variables.
	debug_panel_render_section_header(editor, renderer, &ui_context, theme, "Variables", inner_x, inner_w, &cursor_y, section_header_height)
	state.variables_viewport = sdl3.FRect{ f32(inner_x), f32(cursor_y), f32(inner_w - 8), f32(variables_body_height) }
	debug_panel_render_variables(editor, renderer, &ui_context, theme, state.variables_viewport)
	cursor_y += variables_body_height
	state.variables_divider_rectangle = debug_panel_render_section_divider(editor, renderer, inner_x, cursor_y, inner_w, state.variables_divider_hovered || state.variables_divider_dragging)
	cursor_y += DEBUG_SECTION_DIVIDER_HEIGHT

	// Breakpoints. The final section gets whatever vertical space is left so
	// it grows when the window is tall instead of leaving wasted padding.
	debug_panel_render_section_header(editor, renderer, &ui_context, theme, "Breakpoints", inner_x, inner_w, &cursor_y, section_header_height)
	if breakpoints_body_height < DEBUG_SECTION_MIN_HEIGHT { breakpoints_body_height = DEBUG_SECTION_MIN_HEIGHT }
	state.breakpoints_viewport = sdl3.FRect{ f32(inner_x), f32(cursor_y), f32(inner_w - 8), f32(breakpoints_body_height) }
	debug_panel_render_breakpoints(editor, renderer, &ui_context, theme, state.breakpoints_viewport)
}

// Keep stack + variables fractions within [eps, 1-eps] and ensure breakpoints
// gets a non-zero slice too. Called every render before deriving heights.
@(private="file")
debug_normalize_section_fractions :: proc(state: ^DebugState) {
	epsilon: f32 = 0.05
	if state.stack_section_fraction     < epsilon { state.stack_section_fraction     = epsilon }
	if state.variables_section_fraction < epsilon { state.variables_section_fraction = epsilon }
	leftover := 1.0 - state.stack_section_fraction - state.variables_section_fraction
	if leftover < epsilon {
		// Rescale so breakpoints has at least `epsilon`. Preserve the ratio
		// of stack:variables.
		available := 1.0 - epsilon
		total := state.stack_section_fraction + state.variables_section_fraction
		if total > 0 {
			state.stack_section_fraction     = (state.stack_section_fraction     / total) * available
			state.variables_section_fraction = (state.variables_section_fraction / total) * available
		}
	}
}

// Paint a horizontal drag handle between two stacked sections. Returns the
// rectangle used so the input dispatcher can hit-test against the exact
// pixels rendered. Highlighted when hovered or actively dragged.
@(private="file")
debug_panel_render_section_divider :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, inner_x, top_y, inner_w: i32, highlighted: bool) -> sdl3.FRect {
	rect := sdl3.FRect{ f32(inner_x), f32(top_y), f32(inner_w), f32(DEBUG_SECTION_DIVIDER_HEIGHT) }
	bar_height: f32 = 2
	bar := sdl3.FRect{ rect.x, rect.y + (rect.h - bar_height) * 0.5, rect.w, bar_height }
	color := editor.divider_color
	if highlighted { color = editor.cursor_color }
	sdl3.SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a)
	sdl3.RenderFillRect(renderer, &bar)
	return rect
}

@(private="file")
debug_panel_render_section_header :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, theme: ui.Theme, label: string, inner_x, inner_w: i32, cursor_y: ^i32, header_height: i32) {
	render_string(editor, renderer, label, inner_x, cursor_y^, editor.syntax_keyword_foreground)
	rule_y := cursor_y^ + editor.line_height + 1
	ui.draw_hrule(ui_context, inner_x, rule_y, inner_w - 8, theme.border)
	cursor_y^ += header_height
}

@(private="file")
debug_panel_render_stack :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, theme: ui.Theme, viewport: sdl3.FRect) {
	state := &editor.debug_state
	clear(&state.stack_row_rects)

	frames := dap.client_stack_frames(editor.active_dap_client)
	if len(frames) == 0 {
		idle_label := state.session_active ? "(running...)" : "(no active session)"
		render_string(editor, renderer, idle_label, i32(viewport.x), i32(viewport.y), editor.line_number_color)
		return
	}
	content_height := i32(len(frames)) * editor.line_height
	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.stack_scrollbar, viewport, &state.stack_scroll, content_height)
	for frame, frame_index in frames {
		row_y := origin_y + i32(frame_index) * editor.line_height
		is_selected := frame_index == state.selected_stack_frame
		label_text := frame.name
		if len(frame.file_path) > 0 {
			label_text = fmt.tprintf("%s — %s:%d", frame.name, debug_filepath_base(frame.file_path), int(frame.line))
		}
		ui.draw_list_row(ui_context, origin_x, row_y, i32(viewport.w), label_text, is_selected, theme)
		append(&state.stack_row_rects, sdl3.FRect{ f32(origin_x), f32(row_y), viewport.w, f32(editor.line_height) })
	}
	ui.scroll_view_end(scroll_view, theme)
}

@(private="file")
debug_panel_render_variables :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, theme: ui.Theme, viewport: sdl3.FRect) {
	state := &editor.debug_state
	client := editor.active_dap_client

	clear(&state.variable_row_rects)
	clear(&state.variable_row_kinds)
	clear(&state.variable_row_scope_index)
	clear(&state.variable_row_scope_name)
	clear(&state.variable_row_var_ref)

	scopes := dap.client_scopes(client)
	if len(scopes) == 0 {
		idle_label := state.session_active ? "(no variables in this frame)" : "(no active session)"
		render_string(editor, renderer, idle_label, i32(viewport.x), i32(viewport.y), editor.line_number_color)
		return
	}

	// First pass: total row count so the scroll view can size its thumb. We
	// have to walk the tree twice (once for layout, once for painting) since
	// scroll_view_begin needs content_height up front.
	total_rows: i32 = 0
	for scope in scopes {
		total_rows += 1
		if debug_is_scope_expanded(state, scope.name, !scope.expensive) {
			total_rows += debug_variable_subtree_row_count(state, scope.variables[:], client)
		}
	}
	content_height := total_rows * editor.line_height

	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.variables_scrollbar, viewport, &state.variables_scroll, content_height)
	row_index: i32 = 0
	for scope, scope_index in scopes {
		row_y := origin_y + row_index * editor.line_height
		scope_expanded := debug_is_scope_expanded(state, scope.name, !scope.expensive)

		expand_glyph := scope_expanded ? "v " : "> "
		header := strings.concatenate({expand_glyph, scope.name}, context.temp_allocator)
		render_string(editor, renderer, header, origin_x + 4, row_y, editor.syntax_type_foreground)

		row_rect := sdl3.FRect{ f32(origin_x), f32(row_y), viewport.w, f32(editor.line_height) }
		append(&state.variable_row_rects,       row_rect)
		append(&state.variable_row_kinds,       VariableRowKind.Scope)
		append(&state.variable_row_scope_index, scope_index)
		append(&state.variable_row_scope_name,  scope.name)
		append(&state.variable_row_var_ref,     i64(0))
		row_index += 1

		if !scope_expanded { continue }
		debug_panel_render_variable_subtree(
			editor, renderer, ui_context, theme, scope.variables[:],
			origin_x, origin_y, viewport.w, &row_index, 1,
		)
	}
	ui.scroll_view_end(scroll_view, theme)
}

// Layout-only walk. Counts rows that *would* be painted given the current
// expansion state — we don't recurse past an unfetched compound (its
// children just aren't there yet).
@(private="file")
debug_variable_subtree_row_count :: proc(state: ^DebugState, variables: []dap.Variable, client: ^dap.Client) -> i32 {
	count: i32 = 0
	for variable in variables {
		count += 1
		if variable.variables_reference == 0 { continue }
		if !debug_is_variable_expanded(state, variable.variables_reference) { continue }
		children, fetched := dap.client_children(client, variable.variables_reference)
		if !fetched { continue }
		count += debug_variable_subtree_row_count(state, children, client)
	}
	return count
}

@(private="file")
debug_is_variable_expanded :: proc(state: ^DebugState, variables_reference: i64) -> bool {
	if value, has := state.expanded_variables[variables_reference]; has { return value }
	return false
}

@(private="file")
debug_panel_render_variable_subtree :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, theme: ui.Theme, variables: []dap.Variable, origin_x, origin_y: i32, viewport_width: f32, row_index: ^i32, depth: int) {
	state := &editor.debug_state
	client := editor.active_dap_client
	indent_per_level := editor.character_width * 2
	for variable in variables {
		row_y := origin_y + row_index^ * editor.line_height
		is_compound := variable.variables_reference != 0
		var_expanded := is_compound && debug_is_variable_expanded(state, variable.variables_reference)

		indent_x := origin_x + i32(depth) * indent_per_level

		// Compound variables get a v / > glyph so the user can tell at a
		// glance which rows can be expanded; leaves just sit there.
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
		render_string(editor, renderer, label, indent_x + 4, row_y, editor.foreground_color)

		row_rect := sdl3.FRect{ f32(origin_x), f32(row_y), viewport_width, f32(editor.line_height) }
		append(&state.variable_row_rects,       row_rect)
		append(&state.variable_row_kinds,       VariableRowKind.Variable)
		append(&state.variable_row_scope_index, -1)
		append(&state.variable_row_scope_name,  "")
		append(&state.variable_row_var_ref,     variable.variables_reference)
		row_index^ += 1

		if !var_expanded { continue }
		children, fetched := dap.client_children(client, variable.variables_reference)
		if !fetched { continue }
		debug_panel_render_variable_subtree(editor, renderer, ui_context, theme, children, origin_x, origin_y, viewport_width, row_index, depth + 1)
	}
}

@(private="file")
debug_panel_render_breakpoints :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, theme: ui.Theme, viewport: sdl3.FRect) {
	state := &editor.debug_state

	// Rebuild the parallel row-rect arrays from scratch every frame so click
	// dispatch hit-tests against exactly the pixels the user can see.
	clear(&state.breakpoint_row_rects)
	clear(&state.breakpoint_toggle_rects)
	clear(&state.breakpoint_remove_rects)
	clear(&state.breakpoint_row_file_index)
	clear(&state.breakpoint_row_bp_index)

	total_bp_count := 0
	for file_entry in state.breakpoint_files { total_bp_count += len(file_entry.breakpoints) }
	if total_bp_count == 0 {
		render_string(editor, renderer, "(no breakpoints)", i32(viewport.x), i32(viewport.y), editor.line_number_color)
		return
	}

	content_height := i32(total_bp_count) * editor.line_height
	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.breakpoints_scrollbar, viewport, &state.breakpoints_scroll, content_height)

	row_index: i32 = 0
	for file_entry, file_index in state.breakpoint_files {
		for bp, bp_index in file_entry.breakpoints {
			row_y := origin_y + row_index * editor.line_height

			row_rect := sdl3.FRect{ f32(origin_x), f32(row_y), viewport.w, f32(editor.line_height) }

			// Toggle dot (filled when enabled, hollow when disabled).
			dot_radius := f32(editor.line_height) * 0.28
			dot_center_x := f32(origin_x) + 8 + dot_radius
			dot_center_y := f32(row_y) + f32(editor.line_height) * 0.5
			if bp.enabled {
				draw_filled_disc(renderer, dot_center_x, dot_center_y, dot_radius, editor.breakpoint_color)
			} else {
				draw_hollow_disc(renderer, dot_center_x, dot_center_y, dot_radius, editor.breakpoint_disabled_color)
			}
			toggle_hit_padding: f32 = 4
			toggle_rect := sdl3.FRect{
				dot_center_x - dot_radius - toggle_hit_padding,
				f32(row_y),
				(dot_radius + toggle_hit_padding) * 2,
				f32(editor.line_height),
			}

			label_x := i32(dot_center_x + dot_radius + 6)
			file_basename := debug_filepath_base(file_entry.file_path)
			label: string
			if len(bp.condition) > 0 {
				label = fmt.tprintf("%s:%d  if %s", file_basename, int(bp.line + 1), bp.condition)
			} else {
				label = fmt.tprintf("%s:%d", file_basename, int(bp.line + 1))
			}
			label_color := bp.enabled ? editor.foreground_color : editor.line_number_color
			render_string(editor, renderer, label, label_x, row_y, label_color)

			// Remove button — a small × glyph on the right side of the row.
			remove_width := editor.character_width * 2
			remove_rect := sdl3.FRect{
				f32(origin_x) + viewport.w - f32(remove_width) - 2,
				f32(row_y),
				f32(remove_width),
				f32(editor.line_height),
			}
			remove_label_x := i32(remove_rect.x) + (remove_width - editor.character_width) / 2
			render_string(editor, renderer, "x", remove_label_x, row_y, editor.git_deleted_foreground)

			append(&state.breakpoint_row_rects,      row_rect)
			append(&state.breakpoint_toggle_rects,   toggle_rect)
			append(&state.breakpoint_remove_rects,   remove_rect)
			append(&state.breakpoint_row_file_index, file_index)
			append(&state.breakpoint_row_bp_index,   bp_index)

			row_index += 1
		}
	}
	ui.scroll_view_end(scroll_view, theme)
}

// --- Input dispatch -------------------------------------------------------

// Returns true when the click was inside the panel — caller stops further
// processing. Button rects are stored each frame; the click hits whichever
// widget the renderer just painted.
@(private)
debug_panel_handle_click :: proc(editor: ^Editor, mouse_x, mouse_y: f32) -> bool {
	state := &editor.debug_state
	if !state.panel_visible { return false }

	// Left-edge resize handle — a thin strip ±DEBUG_PANEL_RESIZE_HOT_ZONE
	// around the panel's left border. Latches a drag and returns; the
	// motion handler in `debug_panel_handle_drag` does the actual resize.
	if debug_panel_left_edge_hit(state, mouse_x, mouse_y) {
		state.panel_resize_dragging = true
		return true
	}

	// Section dividers between bodies. Same idea — latch, let the drag
	// handler update fractions per motion event.
	if ui.point_in_rect(state.stack_divider_rectangle, mouse_x, mouse_y) {
		state.stack_divider_dragging = true
		return true
	}
	if ui.point_in_rect(state.variables_divider_rectangle, mouse_x, mouse_y) {
		state.variables_divider_dragging = true
		return true
	}

	// Per-section scrollbars. Same pattern as the editor pane: thumb hit
	// latches a drag, track hit jumps to the click position and then drags.
	if debug_section_scrollbar_mouse_down(editor, &state.stack_scrollbar,       &state.stack_scroll,       state.stack_viewport,       mouse_x, mouse_y) { return true }
	if debug_section_scrollbar_mouse_down(editor, &state.variables_scrollbar,   &state.variables_scroll,   state.variables_viewport,   mouse_x, mouse_y) { return true }
	if debug_section_scrollbar_mouse_down(editor, &state.breakpoints_scrollbar, &state.breakpoints_scroll, state.breakpoints_viewport, mouse_x, mouse_y) { return true }

	if !ui.point_in_rect(state.panel_rectangle, mouse_x, mouse_y) { return false }

	// Debug control buttons — dispatch to the DAP layer. Run on a fresh
	// session spawns the adapter; on a stopped session it continues.
	if ui.point_in_rect(state.run_button_rect,       mouse_x, mouse_y) {
		editor_dap_start_session(editor)
		return true
	}
	if ui.point_in_rect(state.stop_button_rect,      mouse_x, mouse_y) {
		editor_dap_stop_session(editor)
		return true
	}
	if ui.point_in_rect(state.continue_button_rect,  mouse_x, mouse_y) {
		dap.client_continue(editor.active_dap_client)
		return true
	}
	if ui.point_in_rect(state.step_over_button_rect, mouse_x, mouse_y) {
		dap.client_step_over(editor.active_dap_client)
		return true
	}
	if ui.point_in_rect(state.step_into_button_rect, mouse_x, mouse_y) {
		dap.client_step_in(editor.active_dap_client)
		return true
	}
	if ui.point_in_rect(state.step_out_button_rect,  mouse_x, mouse_y) {
		dap.client_step_out(editor.active_dap_client)
		return true
	}

	// Call-stack row hit — clicking a frame selects it as the source of the
	// current-line marker and (eventually) the scopes/variables view. The
	// adapter still reports scopes against the top frame by default; we keep
	// the selection client-side until the user expands "view that frame".
	if ui.point_in_rect(state.stack_viewport, mouse_x, mouse_y) {
		for row_rect, row_index in state.stack_row_rects {
			if ui.point_in_rect(row_rect, mouse_x, mouse_y) {
				state.selected_stack_frame = row_index
				editor_mark_dirty(editor)
				return true
			}
		}
		return true // click in viewport area but on empty space — consume
	}

	// Variables panel — scope/variable expand & lazy-fetch.
	if ui.point_in_rect(state.variables_viewport, mouse_x, mouse_y) {
		for row_rect, row_index in state.variable_row_rects {
			if !ui.point_in_rect(row_rect, mouse_x, mouse_y) { continue }
			switch state.variable_row_kinds[row_index] {
			case .Scope:
				scope_index := state.variable_row_scope_index[row_index]
				scope_name  := state.variable_row_scope_name[row_index]
				scopes := dap.client_scopes(editor.active_dap_client)
				if scope_index < 0 || scope_index >= len(scopes) { return true }
				scope := scopes[scope_index]
				currently_expanded := debug_is_scope_expanded(state, scope_name, !scope.expensive)
				new_expanded := !currently_expanded
				debug_set_scope_expanded(state, scope_name, new_expanded)
				if new_expanded && scope.expensive {
					dap.client_request_scope_variables(editor.active_dap_client, scope_index)
				}
				editor_mark_dirty(editor)
				return true
			case .Variable:
				var_ref := state.variable_row_var_ref[row_index]
				if var_ref == 0 { return true } // leaf — nothing to expand
				currently_expanded := debug_is_variable_expanded(state, var_ref)
				new_expanded := !currently_expanded
				state.expanded_variables[var_ref] = new_expanded
				if new_expanded {
					dap.client_request_children(editor.active_dap_client, var_ref)
				}
				editor_mark_dirty(editor)
				return true
			case .None:
				return true
			}
		}
		return true // click in viewport area but on empty space — consume
	}

	// Breakpoint list interactions. Test remove first, then toggle, then the
	// row body — the remove × sits inside the row rect, so a row-level hit
	// would otherwise swallow the click before remove gets a chance.
	for row_index in 0..<len(state.breakpoint_row_rects) {
		if ui.point_in_rect(state.breakpoint_remove_rects[row_index], mouse_x, mouse_y) {
			breakpoint_remove(editor, state.breakpoint_row_file_index[row_index], state.breakpoint_row_bp_index[row_index])
			return true
		}
		if ui.point_in_rect(state.breakpoint_toggle_rects[row_index], mouse_x, mouse_y) {
			file_index := state.breakpoint_row_file_index[row_index]
			bp_index   := state.breakpoint_row_bp_index[row_index]
			if file_index < len(state.breakpoint_files) && bp_index < len(state.breakpoint_files[file_index].breakpoints) {
				current := state.breakpoint_files[file_index].breakpoints[bp_index].enabled
				breakpoint_set_enabled(editor, file_index, bp_index, !current)
			}
			return true
		}
		if ui.point_in_rect(state.breakpoint_row_rects[row_index], mouse_x, mouse_y) {
			// Future: jump to file:line. Consume the click either way.
			return true
		}
	}

	// Click inside the panel but not on any widget — still consumed so the
	// pane underneath doesn't reposition the text cursor.
	return true
}

// Latch a drag on one of the three section scrollbars. Returns true when
// either the thumb or the track was hit (so the panel-level handler stops
// further dispatch on the same click). Track clicks center the thumb under
// the cursor and immediately jump-scroll to that position.
@(private="file")
debug_section_scrollbar_mouse_down :: proc(editor: ^Editor, scrollbar: ^ui.Scrollbar, scroll_value: ^i32, viewport: sdl3.FRect, mouse_x, mouse_y: f32) -> bool {
	if ui.scrollbar_thumb_hit(scrollbar, mouse_x, mouse_y) {
		ui.scrollbar_begin_thumb_drag(scrollbar, mouse_y)
		return true
	}
	if ui.scrollbar_track_hit(scrollbar, mouse_x, mouse_y) {
		ui.scrollbar_begin_track_drag(scrollbar)
		debug_section_scrollbar_apply(editor, scrollbar, scroll_value, viewport, mouse_y)
		return true
	}
	return false
}

// Translate a drag y into a section scroll value and write it back.
// max_scroll is recomputed each call so a resize between the drag-start
// and the next motion event doesn't pin the thumb at a stale position.
@(private="file")
debug_section_scrollbar_apply :: proc(editor: ^Editor, scrollbar: ^ui.Scrollbar, scroll_value: ^i32, viewport: sdl3.FRect, mouse_y: f32) {
	// Content height is unknown here — the section renderer is what knows
	// it — but the widget's drag_to clamps internally to [0, max_scroll],
	// so we just need an upper bound large enough to cover the worst case.
	// `track.h / thumb.h` is the inverse of the visible ratio, which
	// recovers content_height = viewport_height * (track.h / thumb.h).
	track := scrollbar.track_rectangle
	thumb := scrollbar.thumb_rectangle
	if track.h <= 0 || thumb.h <= 0 { return }
	content_height := track.h * track.h / thumb.h
	max_scroll := content_height - track.h
	if max_scroll < 0 { max_scroll = 0 }
	new_scroll := ui.scrollbar_drag_to(scrollbar, mouse_y, max_scroll)
	scroll_value^ = i32(new_scroll)
	editor_mark_dirty(editor)
	_ = viewport
}

// True when mouse_x is within DEBUG_PANEL_RESIZE_HOT_ZONE of the panel's
// left edge AND mouse_y is within the panel's vertical span.
@(private="file")
debug_panel_left_edge_hit :: proc(state: ^DebugState, mouse_x, mouse_y: f32) -> bool {
	if !state.panel_visible { return false }
	left_edge_x := state.panel_rectangle.x
	if mouse_x < left_edge_x - f32(DEBUG_PANEL_RESIZE_HOT_ZONE) { return false }
	if mouse_x > left_edge_x + f32(DEBUG_PANEL_RESIZE_HOT_ZONE) { return false }
	if mouse_y < state.panel_rectangle.y                         { return false }
	if mouse_y > state.panel_rectangle.y + state.panel_rectangle.h { return false }
	return true
}

// True when the user is mid-drag on any of the panel's resize handles OR
// any of the section scrollbars. Used by the main mouse-drag loop to keep
// the drag latched even when the cursor strays slightly off the handle.
@(private)
debug_panel_is_dragging :: proc(state: ^DebugState) -> bool {
	return state.panel_resize_dragging       ||
	       state.stack_divider_dragging      ||
	       state.variables_divider_dragging  ||
	       state.stack_scrollbar.is_dragging      ||
	       state.variables_scrollbar.is_dragging  ||
	       state.breakpoints_scrollbar.is_dragging
}

// True when the user is hovering over any of the resize handles or is
// actively dragging one. The mouse cursor-swap path reads this to pick the
// right system cursor (EW for the panel edge, NS for section dividers).
@(private)
debug_panel_handle_cursor_kind :: proc(editor: ^Editor, mouse_x, mouse_y: f32) -> (wants_ew: bool, wants_ns: bool) {
	state := &editor.debug_state
	if !state.panel_visible { return false, false }
	if state.panel_resize_dragging || debug_panel_left_edge_hit(state, mouse_x, mouse_y) {
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

// Per-frame hover sync — called from the main mouse-motion path so the
// drag-handle highlight tracks the cursor. Button hover state is handled
// entirely by `ui.draw_button` via the Context's mouse fields; we just
// need to mark dirty when the cursor moves over a button-bearing area so
// the next render reflects the new hover.
@(private)
debug_panel_update_hover :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	state := &editor.debug_state
	if !state.panel_visible {
		state.panel_resize_hovered      = false
		state.stack_divider_hovered     = false
		state.variables_divider_hovered = false
		return
	}
	new_panel_hover         := debug_panel_left_edge_hit(state, mouse_x, mouse_y)
	new_stack_div_hover     := ui.point_in_rect(state.stack_divider_rectangle,     mouse_x, mouse_y)
	new_variables_div_hover := ui.point_in_rect(state.variables_divider_rectangle, mouse_x, mouse_y)

	// Mouse-in-button-row is enough to want a repaint — the actual hover
	// highlight is drawn by `ui.draw_button` from Context.mouse_*, but it
	// only repaints when we tell the editor that something visible changed.
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

	// Hover the three section scrollbars through the widget itself so they
	// widen on mouse-over (and shrink on mouse-out) the same way the
	// editor pane scrollbar does.
	any_section_scrollbar_changed :=
		ui.scrollbar_update_hover(&state.stack_scrollbar,       mouse_x, mouse_y) ||
		ui.scrollbar_update_hover(&state.variables_scrollbar,   mouse_x, mouse_y) ||
		ui.scrollbar_update_hover(&state.breakpoints_scrollbar, mouse_x, mouse_y)

	if new_panel_hover != state.panel_resize_hovered ||
	   new_stack_div_hover     != state.stack_divider_hovered ||
	   new_variables_div_hover != state.variables_divider_hovered ||
	   any_button_hovered ||
	   any_section_scrollbar_changed {
		state.panel_resize_hovered      = new_panel_hover
		state.stack_divider_hovered     = new_stack_div_hover
		state.variables_divider_hovered = new_variables_div_hover
		editor_mark_dirty(editor)
	}
}

// Mouse-motion handler while a panel drag is latched. Returns true when a
// drag actually consumed the motion (so the caller skips its other drag
// dispatchers). window_width is forwarded so the panel-edge drag can clamp
// the new width against the available space.
@(private)
debug_panel_handle_drag :: proc(editor: ^Editor, mouse_x, mouse_y: f32, window_width: i32) -> bool {
	state := &editor.debug_state

	if state.panel_resize_dragging {
		new_width := window_width - i32(mouse_x)
		if new_width < DEBUG_PANEL_MIN_WIDTH { new_width = DEBUG_PANEL_MIN_WIDTH }
		// Cap so the panel can't eat more than (window_width - MIN_WIDTH) —
		// the editor / terminal pane area always keeps at least
		// DEBUG_PANEL_MIN_WIDTH of room to render in.
		max_width := window_width - DEBUG_PANEL_MIN_WIDTH
		if max_width < DEBUG_PANEL_MIN_WIDTH { max_width = DEBUG_PANEL_MIN_WIDTH }
		if new_width > max_width { new_width = max_width }
		if new_width != state.panel_width {
			state.panel_width = new_width
			editor_mark_dirty(editor)
		}
		return true
	}

	if state.stack_divider_dragging || state.variables_divider_dragging {
		debug_panel_resize_section(editor, mouse_y)
		return true
	}

	// Section scrollbars take priority when latched so a small wobble off
	// the thumb doesn't break the drag.
	if state.stack_scrollbar.is_dragging {
		debug_section_scrollbar_apply(editor, &state.stack_scrollbar, &state.stack_scroll, state.stack_viewport, mouse_y)
		return true
	}
	if state.variables_scrollbar.is_dragging {
		debug_section_scrollbar_apply(editor, &state.variables_scrollbar, &state.variables_scroll, state.variables_viewport, mouse_y)
		return true
	}
	if state.breakpoints_scrollbar.is_dragging {
		debug_section_scrollbar_apply(editor, &state.breakpoints_scrollbar, &state.breakpoints_scroll, state.breakpoints_viewport, mouse_y)
		return true
	}
	return false
}

// Translate the current mouse_y into a new section fraction for whichever
// divider is currently being dragged. Clamps so adjacent sections respect
// their per-section minimum.
@(private="file")
debug_panel_resize_section :: proc(editor: ^Editor, mouse_y: f32) {
	state := &editor.debug_state
	stack_viewport     := state.stack_viewport
	variables_viewport := state.variables_viewport
	breakpoints_viewport := state.breakpoints_viewport
	body_area_total := i32(stack_viewport.h + variables_viewport.h + breakpoints_viewport.h)
	if body_area_total <= 0 { return }

	if state.stack_divider_dragging {
		// User is dragging the line between Call Stack and Variables. The
		// stack body grows or shrinks; the variables body absorbs the
		// inverse. Breakpoints fraction is untouched.
		stack_top      := stack_viewport.y
		// Available range for the divider y: from min-stack-height (top + MIN)
		// to (variables_top + variables.h - MIN) so variables keeps its min.
		min_y := stack_top + f32(DEBUG_SECTION_MIN_HEIGHT)
		max_y := variables_viewport.y + variables_viewport.h - f32(DEBUG_SECTION_MIN_HEIGHT)
		clamped_y := clamp_f32(mouse_y, min_y, max_y)
		new_stack_height := i32(clamped_y - stack_top)
		new_variables_height := i32(variables_viewport.y + variables_viewport.h) - i32(clamped_y) - DEBUG_SECTION_DIVIDER_HEIGHT
		if new_variables_height < DEBUG_SECTION_MIN_HEIGHT { new_variables_height = DEBUG_SECTION_MIN_HEIGHT }
		state.stack_section_fraction     = f32(new_stack_height)     / f32(body_area_total)
		state.variables_section_fraction = f32(new_variables_height) / f32(body_area_total)
		editor_mark_dirty(editor)
		return
	}

	if state.variables_divider_dragging {
		// Dragging the line between Variables and Breakpoints. Variables
		// grows/shrinks; breakpoints absorbs the inverse.
		variables_top := variables_viewport.y
		min_y := variables_top + f32(DEBUG_SECTION_MIN_HEIGHT)
		max_y := breakpoints_viewport.y + breakpoints_viewport.h - f32(DEBUG_SECTION_MIN_HEIGHT)
		clamped_y := clamp_f32(mouse_y, min_y, max_y)
		new_variables_height := i32(clamped_y - variables_top)
		state.variables_section_fraction = f32(new_variables_height) / f32(body_area_total)
		// stack fraction is unchanged; breakpoints derives from the
		// remainder.
		editor_mark_dirty(editor)
		return
	}
}

@(private="file")
clamp_f32 :: #force_inline proc(value, low, high: f32) -> f32 {
	if value < low  { return low }
	if value > high { return high }
	return value
}

// Release every latched resize drag AND every section scrollbar drag.
// Called from the main mouse-up path.
@(private)
debug_panel_handle_mouse_up :: proc(editor: ^Editor) {
	state := &editor.debug_state
	was_dragging := debug_panel_is_dragging(state)
	state.panel_resize_dragging       = false
	state.stack_divider_dragging      = false
	state.variables_divider_dragging  = false
	ui.scrollbar_end_drag(&state.stack_scrollbar)
	ui.scrollbar_end_drag(&state.variables_scrollbar)
	ui.scrollbar_end_drag(&state.breakpoints_scrollbar)
	if was_dragging { editor_mark_dirty(editor) }
}

// Returns true when wheel scroll was inside the panel and consumed.
@(private)
debug_panel_handle_wheel :: proc(editor: ^Editor, mouse_x, mouse_y, wheel_y: f32) -> bool {
	state := &editor.debug_state
	if !state.panel_visible { return false }
	if !ui.point_in_rect(state.panel_rectangle, mouse_x, mouse_y) { return false }

	step := -i32(wheel_y * f32(editor.line_height) * 3.0)
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
	editor_mark_dirty(editor)
	return true
}

// --- Gutter click → breakpoint toggle -------------------------------------

// Hit-test the editor pane's gutter and either toggle a breakpoint at the
// line under the click, or — when shift is held — open the condition editor
// for that line. Returns true when the click landed in the gutter and was
// handled (the caller skips text-cursor placement). Diff mode and untitled
// buffers don't get gutter breakpoints — they have nowhere to anchor to.
@(private)
editor_pane_gutter_toggle_breakpoint :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x, mouse_y: f32, shift_held: bool) -> bool {
	if editor.diff_state.active           { return false }
	if len(editor_pane.file_path) == 0    { return false }

	title_bar_height := f32(editor_title_bar_height(editor))
	gutter_x_start := f32(pane.rectangle.x + editor.padding_x)
	gutter_x_end   := f32(pane.rectangle.x + editor.padding_x + editor_pane.gutter_width)
	if mouse_x < gutter_x_start || mouse_x >= gutter_x_end { return false }
	if mouse_y < f32(pane.rectangle.y) + title_bar_height  { return false }

	document_y := mouse_y - f32(pane.rectangle.y) - title_bar_height - f32(editor.padding_y) + editor_pane.scroll_y
	if document_y < 0                 { return false }
	if editor.line_height <= 0        { return false }

	clicked_line := u32(document_y / f32(editor.line_height))
	total_line_count := document.document_line_count(&editor_pane.document)
	if clicked_line >= total_line_count { return false }

	if shift_held {
		breakpoint_condition_dialog_open(editor, editor_pane.file_path, clicked_line)
	} else {
		breakpoint_toggle_at(editor, editor_pane.file_path, clicked_line)
	}
	return true
}

// --- Local helpers --------------------------------------------------------

// File-private mirror of `filepath_base` in render.odin so this file doesn't
// need to import path/filepath.
@(private="file")
debug_filepath_base :: proc(file_path: string) -> string {
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
