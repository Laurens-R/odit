// Editor binding for the debug side-panel. Renders alongside the
// editor panes (not on top of them), so we render at the regular
// binding pass — but consume only mouse events that land on the
// panel area.
//
// The panel needs a `menu_bar_height` to position itself; the
// editor supplies that via Hooks.
package debug

import "vendor:sdl3"

import "../../ui"
import "../binding"

Hooks :: struct {
	user_data:       rawptr,
	menu_bar_height: proc(user_data: rawptr) -> i32,
}

@(private="file")
BindingContext :: struct {
	state: ^State,
	hooks: Hooks,
}

make_binding :: proc(state: ^State, hooks: Hooks, allocator := context.allocator) -> binding.Binding {
	binding_context := new(BindingContext, allocator)
	binding_context.state = state
	binding_context.hooks = hooks
	return binding.Binding{
		name         = "debug_panel",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

@(private="file")
binding_visible :: proc(state_ptr: rawptr) -> bool {
	binding_context := cast(^BindingContext)state_ptr
	return binding_context.state.panel_visible
}

@(private="file")
binding_destroy :: proc(state_ptr: rawptr) {
	binding_context := cast(^BindingContext)state_ptr
	destroy(binding_context.state)
	free(binding_context)
}

@(private="file")
binding_handle_event :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, event: ^sdl3.Event) -> (consumed: bool, needs_redraw: bool) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.panel_visible { return false, false }

	line_height := f32(16)
	if api != nil && api.line_height != nil { line_height = f32(api.line_height(api.editor)) }

	#partial switch event.type {
	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return false, false }
		if handle_click(state, api, event.button.x, event.button.y) {
			return true, true
		}

	case .MOUSE_MOTION:
		// Drag latched takes priority — keep handling motion even
		// when the cursor strays slightly off the original handle.
		if is_dragging(state) {
			if handle_drag(state, event.motion.x, event.motion.y) { return true, true }
		}
		if update_hover(state, event.motion.x, event.motion.y) {
			// Don't consume — hover doesn't own input — but mark
			// dirty so the next render shows the new highlight.
			return false, true
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT {
			if handle_mouse_up(state) { return true, true }
		}

	case .MOUSE_WHEEL:
		if handle_wheel(state, event.wheel.mouse_x, event.wheel.mouse_y, event.wheel.y, line_height) {
			return true, true
		}
	}
	return false, false
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.panel_visible { return }
	menu_bar_height: i32 = 0
	if binding_context.hooks.menu_bar_height != nil {
		menu_bar_height = binding_context.hooks.menu_bar_height(binding_context.hooks.user_data)
	}
	render(state, api, renderer, ui_context, viewport_width, viewport_height, menu_bar_height)
}
