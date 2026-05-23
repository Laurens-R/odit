// Editor binding for the F7 Tasks modal. All editor coupling flows
// through `binding.EditorAPI`.
package tasks_dialog

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
		name         = "tasks_dialog",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Open the dialog with the project's build + debug profiles. Uses
// `api` to fetch the profile lists.
open_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	sources := build_entry_sources(api, context.temp_allocator)
	open(state, sources)
}

@(private="file")
build_entry_sources :: proc(api: ^binding.EditorAPI, allocator := context.temp_allocator) -> []EntrySource {
	sources := make([dynamic]EntrySource, 0, 8, allocator)
	if api == nil { return sources[:] }

	if api.list_build_profiles != nil {
		for profile, build_index in api.list_build_profiles(api.editor, allocator) {
			label: string
			if len(profile.description) > 0 {
				label = strings.clone(fmt.tprintf("[build]  %s — %s", profile.name, profile.description), allocator)
			} else {
				label = strings.clone(fmt.tprintf("[build]  %s", profile.name), allocator)
			}
			append(&sources, EntrySource{
				kind          = .BuildProfile,
				profile_index = build_index,
				label         = label,
			})
		}
	}
	if api.list_debug_profiles != nil {
		for profile, debug_index in api.list_debug_profiles(api.editor, allocator) {
			label: string
			if len(profile.build_profile) > 0 {
				label = strings.clone(fmt.tprintf("[debug]  %s  (builds: %s)", profile.name, profile.build_profile), allocator)
			} else {
				label = strings.clone(fmt.tprintf("[debug]  %s", profile.name), allocator)
			}
			append(&sources, EntrySource{
				kind          = .DebugProfile,
				profile_index = debug_index,
				label         = label,
			})
		}
	}
	return sources[:]
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
			if api == nil { break }
			switch intent_value.kind {
			case .BuildProfile:
				if api.run_build_profile != nil { api.run_build_profile(api.editor, intent_value.profile_index) }
			case .DebugProfile:
				if api.start_debug_profile != nil { api.start_debug_profile(api.editor, intent_value.profile_index) }
			}
		}
	}
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }

	loaded_path := ""
	project_root := ""
	if api != nil {
		if api.project_loaded_path != nil { loaded_path = api.project_loaded_path(api.editor) }
		if api.project_root        != nil { project_root = api.project_root(api.editor) }
	}

	title := "Tasks"
	if len(loaded_path) == 0 { title = "Tasks — no project loaded" }

	empty_message := "(no build_profiles / debug_profiles in .odit/project.json)"
	if len(project_root) == 0 {
		empty_message = "(no project — set one via Ctrl+P in the file browser)"
	}

	render(binding_context.state, ui_context, title, empty_message, viewport_width, viewport_height)
}
