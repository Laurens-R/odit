// Editor binding for the F1 help dialog. No editor-side coupling
// besides reading line_height via the API.
package help

import "vendor:sdl3"

import "../../ui"
import "../binding"

make_binding :: proc(state: ^State) -> binding.Binding {
	return binding.Binding{
		name         = "help",
		state        = rawptr(state),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Toggle the help modal. Exposed so the editor can bind F1 / HelpToggle
// without going through the vtable.
toggle_modal :: proc(state: ^State) -> (needs_redraw: bool) {
	return toggle(state)
}

@(private="file")
binding_visible :: proc(state_ptr: rawptr) -> bool {
	state := cast(^State)state_ptr
	return state.visible
}

@(private="file")
binding_destroy :: proc(state_ptr: rawptr) {
	// help.State holds no heap allocations of its own.
}

@(private="file")
binding_handle_event :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, event: ^sdl3.Event) -> (consumed: bool, needs_redraw: bool) {
	state := cast(^State)state_ptr
	if !state.visible { return false, false }
	line_height: i32 = 16
	if api != nil && api.line_height != nil { line_height = api.line_height(api.editor) }
	redraw := dispatch_event(state, event, line_height)
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	state := cast(^State)state_ptr
	if !state.visible { return }
	render(state, ui_context, viewport_width, viewport_height)
}
