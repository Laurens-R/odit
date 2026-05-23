// Editor binding for the Ctrl+Shift+R replace-in-files modal.
package replace_in_files

import "core:os"
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
		name         = "replace_in_files",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Open the dialog. Default path comes from project root → active
// pane file dir → cwd; query is seeded from a short single-line
// selection if any.
open_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	default_path: string
	if api != nil {
		if api.project_root != nil {
			root := api.project_root(api.editor)
			if len(root) > 0 { default_path = root }
		}
		if len(default_path) == 0 && api.active_pane_file_path != nil {
			file_path := api.active_pane_file_path(api.editor)
			if len(file_path) > 0 { default_path = file_directory(file_path) }
		}
	}
	if len(default_path) == 0 {
		working_directory, get_directory_error := os.get_working_directory(context.temp_allocator)
		default_path = get_directory_error != nil ? "." : working_directory
	}

	selection_query: string
	if api != nil && api.active_pane_short_selection != nil {
		text, ok := api.active_pane_short_selection(api.editor, 256, context.temp_allocator)
		if ok && len(text) > 0 { selection_query = text }
	}

	open(state, default_path, selection_query)
}

@(private="file")
file_directory :: proc(file_path: string) -> string {
	for index := len(file_path) - 1; index >= 0; index -= 1 {
		if file_path[index] == '/' || file_path[index] == '\\' {
			return file_path[:index]
		}
	}
	return "."
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
	handle_event(binding_context.state, event)
	return true, true
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }
	render(binding_context.state, ui_context, viewport_width, viewport_height)
}
