// Editor binding for the Ctrl+Shift+F find-in-files dialog. All
// editor coupling flows through `binding.EditorAPI`; no per-host
// callbacks needed.
package find_in_files

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
		name         = "find_in_files",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Open the dialog. Computes the default path via `api` (project
// root → active pane's file dir → cwd) and optionally seeds the
// query from a short selection on the active pane.
open_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	default_path: string
	if api != nil {
		if root := api.project_root(api.editor) if api.project_root != nil else ""; len(root) > 0 {
			default_path = root
		} else {
			file_path := api.active_pane_file_path(api.editor) if api.active_pane_file_path != nil else ""
			if len(file_path) > 0 {
				default_path = file_directory(file_path)
			}
		}
	}
	if len(default_path) == 0 {
		working_directory, get_directory_error := os.get_working_directory(context.temp_allocator)
		default_path = get_directory_error != nil ? "." : working_directory
	}

	open(state, default_path)

	if api != nil && api.active_pane_short_selection != nil {
		selection_text, ok := api.active_pane_short_selection(api.editor, 256, context.temp_allocator)
		if ok && len(selection_text) > 0 {
			seed_query(state, selection_text)
		}
	}
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
	state := binding_context.state
	if !state.visible { return false, false }
	intent, redraw := handle_event(state, event)
	if intent != nil {
		#partial switch intent_value in intent {
		case ExecuteSearch:
			run_search(state, intent_value.path, intent_value.query)
		case ActivateResult:
			apply_activate_result(state, api, intent_value)
		}
	}
	return true, redraw
}

// Open the picked result in the active pane and place the cursor
// at the matching line / column. All editor coupling goes through
// `api`.
@(private="file")
apply_activate_result :: proc(state: ^State, api: ^binding.EditorAPI, activate: ActivateResult) {
	if api == nil { return }

	if api.open_file_at_path != nil {
		error_message := api.open_file_at_path(api.editor, activate.file_path, /*split_secondary=*/ false, context.temp_allocator)
		if len(error_message) > 0 {
			set_error(state, error_message)
			state.visible = true
			return
		}
	}

	if api.jump_active_pane_to != nil {
		api.jump_active_pane_to(api.editor, activate.line, activate.column)
	}

	close(state)
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }
	render(binding_context.state, ui_context, viewport_width, viewport_height)
}
