// Editor binding for the breakpoint-condition dialog.
package breakpoint_condition

import "vendor:sdl3"

import "../../ui"
import "../binding"

Hooks :: struct {
	user_data:             rawptr,
	existing_condition_at: proc(user_data: rawptr, file_path: string, line: u32) -> (existing: string, had_bp: bool),
	set_condition_at:      proc(user_data: rawptr, file_path: string, line: u32, condition_text: string),
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
		name         = "breakpoint_condition",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

open_with_hooks :: proc(state: ^State, hooks: Hooks, file_path: string, line: u32) {
	existing_condition: string
	had_bp: bool
	if hooks.existing_condition_at != nil {
		existing_condition, had_bp = hooks.existing_condition_at(hooks.user_data, file_path, line)
	}
	open(state, file_path, line, existing_condition, had_bp)
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
		case Commit:
			if binding_context.hooks.set_condition_at != nil {
				binding_context.hooks.set_condition_at(binding_context.hooks.user_data, intent_value.file_path, intent_value.line, intent_value.condition_text)
			}
		}
	}
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }
	render(binding_context.state, ui_context, viewport_width, viewport_height)
}
