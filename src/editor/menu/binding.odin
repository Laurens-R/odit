// Editor binding for the in-app menu bar. The bar's visibility
// follows the platform: hidden entirely on macOS (native NSMenu
// owns the menu surface); on Windows / Linux, shown when Alt is
// held or a dropdown is open.
package menu

import "vendor:sdl3"

import "../../ui"
import "../binding"

@(private="file")
BindingContext :: struct {
	state: ^State,
}

make_binding :: proc(state: ^State, allocator := context.allocator) -> binding.Binding {
	binding_context := new(BindingContext, allocator)
	binding_context.state = state
	return binding.Binding{
		name         = "menu_bar",
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
	return is_visible(binding_context.state)
}

@(private="file")
binding_destroy :: proc(state_ptr: rawptr) {
	binding_context := cast(^BindingContext)state_ptr
	free(binding_context)
}

@(private="file")
binding_handle_event :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, event: ^sdl3.Event) -> (consumed: bool, needs_redraw: bool) {
	binding_context := cast(^BindingContext)state_ptr
	if handle_event(binding_context.state, event, api) {
		return true, true
	}
	return false, false
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !is_visible(state) { return }
	theme := api.theme(api.editor)
	render_bar(state, ui_context, theme, viewport_width)
	render_dropdown(state, ui_context, theme, viewport_width, viewport_height)
}
