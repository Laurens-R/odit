// Package `debug` is the right-side debug panel (Shift+F7) and its
// per-pane breakpoint storage.
//
// File layout:
//   * `state.odin`    — types + lifecycle + constants.
//   * `dispatch.odin` — breakpoint storage ops, panel toggle, hover,
//                       click / drag / wheel / mouse-up handlers,
//                       cursor-hint helpers.
//   * `view.odin`     — panel render + helpers (sections, stack,
//                       variables, breakpoints list).
//   * `binding.odin`  — vtable wrapper that plugs the panel into the
//                       editor's binding registry.
//
// The panel reads DAP state via `binding.EditorAPI.active_dap_client`
// and triggers run/step/stop via `dap_action`. Breakpoint storage
// lives entirely in this subpackage.
package debug

import "vendor:sdl3"

import "../../ui"

Breakpoint :: struct {
	line:      u32,    // 0-based document line
	enabled:   bool,
	condition: string, // owned; "" for an unconditional breakpoint
}

BreakpointFile :: struct {
	file_path:   string, // owned absolute path
	breakpoints: [dynamic]Breakpoint,
}

// Marks a row in the Variables panel: either a scope header
// (Locals, Arguments, …) or one variable. Clicking a scope row
// toggles its expanded state by name; clicking a variable row
// toggles by `variables_reference` (only meaningful when the
// variable is compound, i.e. ref != 0).
VariableRowKind :: enum {
	None,
	Scope,
	Variable,
}

State :: struct {
	panel_visible: bool,

	// Breakpoints persist across panel-hide and across debug sessions.
	// Tied to file paths (not pane indices), so they survive document
	// swaps.
	breakpoint_files: [dynamic]BreakpointFile,

	// Cached session flags — derived from the active DAP client once
	// per frame in `sync_from_client` so the panel doesn't have to
	// thread a client pointer through every render proc.
	session_active:       bool,
	is_stopped:           bool,
	selected_stack_frame: int,

	// Variable-tree UI state.
	expanded_scopes:      map[string]bool,
	expanded_variables:   map[i64]bool,

	// Per-section scroll offsets, in pixels.
	stack_scroll:       i32,
	variables_scroll:   i32,
	breakpoints_scroll: i32,

	// Per-section scrollbar widget state.
	stack_scrollbar:       ui.Scrollbar,
	variables_scrollbar:   ui.Scrollbar,
	breakpoints_scrollbar: ui.Scrollbar,

	// User-resizable panel width.
	panel_width: i32,

	// Section heights, expressed as fractions of the available body
	// area so the relative proportions survive window resizes. Stack
	// + Variables fractions are stored; Breakpoints takes whatever's
	// left.
	stack_section_fraction:     f32,
	variables_section_fraction: f32,

	// Drag handle interaction.
	panel_resize_hovered:           bool,
	panel_resize_dragging:          bool,
	stack_divider_rectangle:        sdl3.FRect,
	variables_divider_rectangle:    sdl3.FRect,
	stack_divider_hovered:          bool,
	variables_divider_hovered:      bool,
	stack_divider_dragging:         bool,
	variables_divider_dragging:     bool,

	// Rectangles rewritten by the renderer each frame.
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

	// Cached window width so input dispatch (which receives mouse
	// events between renders) can clamp the panel resize without
	// having to be passed it explicitly. Set in `render`.
	cached_window_width: i32,

	// Per-row click targets for the variables list.
	variable_row_rects:        [dynamic]sdl3.FRect,
	variable_row_kinds:        [dynamic]VariableRowKind,
	variable_row_scope_index:  [dynamic]int,
	variable_row_scope_name:   [dynamic]string, // borrowed pointer into dap.Client (no clone)
	variable_row_var_ref:      [dynamic]i64,

	// Per-row click targets for the call-stack list.
	stack_row_rects: [dynamic]sdl3.FRect,

	// Per-row click targets for the breakpoint list.
	breakpoint_row_rects:      [dynamic]sdl3.FRect,
	breakpoint_toggle_rects:   [dynamic]sdl3.FRect,
	breakpoint_remove_rects:   [dynamic]sdl3.FRect,
	breakpoint_row_file_index: [dynamic]int,
	breakpoint_row_bp_index:   [dynamic]int,
}

DEFAULT_WIDTH: i32 : 320

// Width clamp so the panel can't shrink past the button row or
// steal the whole window.
MIN_WIDTH: i32 : 220

@(private)
RESIZE_HOT_ZONE: i32 : 5 // pixels either side of the left edge that latch the drag

@(private)
SECTION_MIN_HEIGHT: i32 : 40

@(private)
SECTION_DIVIDER_HEIGHT: i32 : 6 // visual gap that doubles as the drag handle

@(private)
TITLE_HEIGHT_EXTRA: i32 : 6

// --- Lifecycle ---------------------------------------------------------

init :: proc(state: ^State) {
	state^ = State{}
	state.expanded_scopes    = make(map[string]bool)
	state.expanded_variables = make(map[i64]bool)
	state.panel_width                = DEFAULT_WIDTH
	state.stack_section_fraction     = 1.0 / 3.0
	state.variables_section_fraction = 1.0 / 3.0
}

destroy :: proc(state: ^State) {
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

// Drop the per-session UI state (expansion sets, derived flags)
// but keep breakpoints. Called when the adapter has exited so the
// panel reverts to its idle-state placeholders.
session_clear :: proc(state: ^State) {
	for scope_name in state.expanded_scopes { delete(scope_name) }
	clear(&state.expanded_scopes)
	clear(&state.expanded_variables)

	state.session_active       = false
	state.is_stopped           = false
	state.selected_stack_frame = 0
}
