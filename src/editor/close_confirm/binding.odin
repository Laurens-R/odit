// Editor binding for the Yes/No/Cancel close-confirmation dialog.
package close_confirm

import "vendor:sdl3"

import "../../ui"
import "../binding"

// Subpackage-specific callbacks: per-pane subject-name + the two
// commit actions. Don't belong on `binding.EditorAPI` because they
// require knowing which pane this dialog instance is closing.
Hooks :: struct {
	user_data:         rawptr,
	subject_name:      proc(user_data: rawptr, pane_index: int) -> string,
	save_and_close:    proc(user_data: rawptr, pane_index: int),
	discard_and_close: proc(user_data: rawptr, pane_index: int),
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
		name         = "close_confirm",
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
	if intent != nil {
		#partial switch intent_value in intent {
		case SaveAndClose:
			if binding_context.hooks.save_and_close != nil {
				binding_context.hooks.save_and_close(binding_context.hooks.user_data, intent_value.pane_index)
			}
		case DiscardAndClose:
			if binding_context.hooks.discard_and_close != nil {
				binding_context.hooks.discard_and_close(binding_context.hooks.user_data, intent_value.pane_index)
			}
		}
	}
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }

	subject := "this file"
	if binding_context.hooks.subject_name != nil {
		subject = binding_context.hooks.subject_name(binding_context.hooks.user_data, binding_context.state.pane_index)
	}
	render(binding_context.state, ui_context, subject, viewport_width, viewport_height)
}
