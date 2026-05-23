// Editor binding for the open-documents picker.
package open_docs

import "base:runtime"
import "vendor:sdl3"

import "../../ui"
import "../binding"

Hooks :: struct {
	user_data:    rawptr,
	list_entries: proc(user_data: rawptr, source_pane_index: int, allocator: runtime.Allocator) -> []EntrySource,
	activate:     proc(user_data: rawptr, source_pane_index: int, location: EntryLocation, pane_index: int, background_index: int),
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
		name         = "open_docs",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

open_with_hooks :: proc(state: ^State, hooks: Hooks, source_pane_index: int) {
	if hooks.list_entries == nil { return }
	sources := hooks.list_entries(hooks.user_data, source_pane_index, context.temp_allocator)
	open(state, source_pane_index, sources)
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
		case Activate:
			if binding_context.hooks.activate != nil {
				binding_context.hooks.activate(binding_context.hooks.user_data, binding_context.state.source_pane_index, intent_value.location, intent_value.pane_index, intent_value.background_index)
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
