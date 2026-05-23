// Editor binding for the F3 git history dialog. All editor
// coupling flows through `binding.EditorAPI`.
package git_history

import "core:fmt"
import "core:strings"
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
		name         = "git_history",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Open the dialog for the active pane's file. Uses `api` to fetch
// the active pane file path; everything else is package-local.
open_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	file_path := ""
	if api != nil && api.active_pane_file_path != nil {
		file_path = api.active_pane_file_path(api.editor)
	}
	source_pane_index := 0
	if api != nil && api.active_pane_index != nil {
		source_pane_index = api.active_pane_index(api.editor)
	}
	open_for_file(state, source_pane_index, file_path)
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
	state := binding_context.state
	if !state.visible { return false, false }
	intent, redraw := handle_event(state, event)
	if intent != nil {
		#partial switch intent_value in intent {
		case Activate:
			apply_activate(state, api, intent_value.hash, intent_value.short_hash)
		}
	}
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.visible { return }

	title_subject := ""
	if len(state.file_path) > 0 {
		title_subject = filepath_base(state.file_path)
	}
	render(state, ui_context, title_subject, viewport_width, viewport_height)
}

// Fetch the picked revision and open it in the opposite pane.
@(private="file")
apply_activate :: proc(state: ^State, api: ^binding.EditorAPI, full_hash, short_hash: string) {
	if api == nil                  { return }
	if len(state.file_path) == 0   { return }

	revision_text, error_message := fetch_revision(state, full_hash, short_hash)
	if len(error_message) > 0 {
		set_error(state, error_message)
		state.visible = true
		return
	}

	source_file_path := strings.clone(state.file_path, context.temp_allocator)
	revision_clone   := strings.clone(revision_text)

	display_basename := filepath_base(source_file_path)
	display_title    := strings.clone(fmt.tprintf("%s @ %s", display_basename, short_hash))

	if api.open_string_in_opposite_pane != nil {
		api.open_string_in_opposite_pane(api.editor, state.source_pane_index, revision_clone, source_file_path, display_title)
	}

	// Free the context strings now that the activate is done.
	if len(state.context_file_directory) > 0 { delete(state.context_file_directory); state.context_file_directory = "" }
	if len(state.context_relative_path)  > 0 { delete(state.context_relative_path);  state.context_relative_path  = "" }
}

@(private="file")
filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for index := len(file_path) - 1; index >= 0; index -= 1 {
		if file_path[index] == '/' || file_path[index] == '\\' { return file_path[index+1:] }
	}
	return file_path
}
