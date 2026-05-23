// Editor binding for the Save-As dialog.
package save_as

import "base:runtime"
import "vendor:sdl3"

import "../../ui"
import "../binding"

Hooks :: struct {
	user_data:    rawptr,
	default_path: proc(user_data: rawptr, pane_index: int, allocator: runtime.Allocator) -> string,
	commit:       proc(user_data: rawptr, pane_index: int, path: string, close_after_save: bool) -> (error_message: string),
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
		name         = "save_as",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Convenience: open the dialog with the host-provided default path.
open_with_hooks :: proc(state: ^State, hooks: Hooks, pane_index: int, close_after_save: bool) {
	default_path: string
	if hooks.default_path != nil {
		default_path = hooks.default_path(hooks.user_data, pane_index, context.temp_allocator)
	}
	open(state, pane_index, default_path, close_after_save)
}

@(private="file")
binding_visible :: proc(state_ptr: rawptr) -> bool {
	binding_context := cast(^BindingContext)state_ptr
	return binding_context.state.visible
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
	if !binding_context.state.visible { return false, false }

	intent, redraw := handle_event(binding_context.state, event)
	if intent != nil && binding_context.hooks.commit != nil {
		#partial switch intent_value in intent {
		case Commit:
			error_message := binding_context.hooks.commit(binding_context.hooks.user_data, intent_value.pane_index, intent_value.path, intent_value.close_after_save)
			if len(error_message) > 0 {
				set_error(binding_context.state, error_message)
			} else {
				close(binding_context.state)
			}
		}
		redraw = true
	}
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }
	render(binding_context.state, ui_context, viewport_width, viewport_height)
}
