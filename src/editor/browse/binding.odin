// Editor binding for the F2 file browser. This file is the only
// place that knows the subpackage exists from the editor's
// perspective — it produces a `binding.Binding` the editor
// registers in its dispatch table, and translates Host-required
// editor primitives (open a file into a pane, set project root,
// etc.) through the `EditorAPI` vtable.
//
// The subpackage never imports the editor package; everything it
// needs from the editor comes in through `^binding.EditorAPI`.
package browse

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../../keybindings"
import "../../ui"
import "../binding"

// Maximum file size the file browser is willing to slurp. Anything
// larger is rejected up-front rather than handed to the piece tree.
@(private="file")
MAX_FILE_BYTES :: 256 * 1024 * 1024 // 256 MiB

// Per-binding context. We need both the State and a `^Keybindings`
// for keyboard dispatch — the editor passes ^Keybindings into make
// once and we capture it here.
@(private="file")
BindingContext :: struct {
	state:     ^State,
	bindings:  ^keybindings.Bindings,
}

// Heap-allocated so the editor can keep a `rawptr` to it without
// caring about the underlying type.
make_binding :: proc(state: ^State, key_bindings: ^keybindings.Bindings, allocator := context.allocator) -> binding.Binding {
	binding_context := new(BindingContext, allocator)
	binding_context.state    = state
	binding_context.bindings = key_bindings

	return binding.Binding{
		name         = "browse",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// --- Public open hook (called from editor in response to F2) ----------

// Open the file browser. Exposed so the editor can bind F2 / FileOpen
// without going through the binding vtable (which only carries
// per-event ops).
open :: proc(state: ^State, api: ^binding.EditorAPI) {
	if state.visible { return }
	state.visible = true

	start_directory_path: string
	cached_cwd := state.current_working_directory

	use_cached_cwd := false
	if len(cached_cwd) > 0 && api != nil {
		project_root_string := ""
		if api.project_root != nil { project_root_string = api.project_root(api.editor) }
		if len(project_root_string) == 0 {
			use_cached_cwd = true
		} else if api.path_inside_project_root != nil && api.path_inside_project_root(api.editor, cached_cwd) {
			use_cached_cwd = true
		}
	}

	switch {
	case use_cached_cwd:
		start_directory_path = strings.clone(cached_cwd, context.temp_allocator)
	case api != nil && api.project_root != nil:
		root := api.project_root(api.editor)
		if len(root) > 0 {
			start_directory_path = strings.clone(root, context.temp_allocator)
		} else {
			start_directory_path = fallback_working_directory()
		}
	case:
		start_directory_path = fallback_working_directory()
	}

	load_directory(state, start_directory_path)
}

@(private="file")
fallback_working_directory :: proc() -> string {
	working_directory, get_directory_error := os.get_working_directory(context.temp_allocator)
	return get_directory_error != nil ? "." : working_directory
}

// --- Binding vtable implementations -----------------------------------

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
	redraw := dispatch_event(binding_context.state, api, binding_context.bindings, event)
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }
	// Chrome is owned by the editor's theme; expose it via the API
	// later if other plugins need it. For now we keep the default
	// palette inline so this file is fully self-contained.
	chrome := Chrome{
		git_modified  = sdl3.FColor{0.95, 0.78, 0.35, 1.0},
		git_added     = sdl3.FColor{0.40, 0.88, 0.45, 1.0},
		git_untracked = sdl3.FColor{0.55, 0.78, 1.00, 1.0},
		git_renamed   = sdl3.FColor{0.75, 0.55, 0.95, 1.0},
		git_deleted   = sdl3.FColor{0.95, 0.42, 0.42, 1.0},
		error_text    = sdl3.FColor{0.95, 0.42, 0.42, 1.0},
	}
	render(binding_context.state, ui_context, chrome, viewport_width, viewport_height)
}

// --- File-open trampoline driven by an OpenFile intent ----------------

// Reads the file, dedupes against background docs, and asks the
// editor (via api) to install it in a pane. Lives here so this
// subpackage owns the entire "Enter on a file" code path.
@(private)
apply_open_file :: proc(state: ^State, api: ^binding.EditorAPI, full_path: string, split_secondary: bool) {
	if api == nil { return }

	if api.find_open_document != nil {
		existing_pane_index, existing_background_index := api.find_open_document(api.editor, full_path)
		if existing_pane_index >= 0 {
			if api.set_active_pane_index != nil { api.set_active_pane_index(api.editor, existing_pane_index) }
			close(state)
			return
		}
		if existing_background_index >= 0 {
			target_pane_index := 0
			if api.active_pane_index != nil { target_pane_index = api.active_pane_index(api.editor) }
			if split_secondary {
				if api.set_split_active      != nil { api.set_split_active(api.editor, true) }
				if api.set_active_pane_index != nil { api.set_active_pane_index(api.editor, 1) }
				target_pane_index = 1
			}
			if api.swap_background_into_pane != nil {
				api.swap_background_into_pane(api.editor, target_pane_index, existing_background_index)
			}
			close(state)
			return
		}
	}

	file_data, read_file_error := os.read_entire_file_from_path(full_path, context.allocator)
	if read_file_error != nil {
		set_error(state, fmt.tprintf("Cannot open %s: %v", filepath.base(full_path), read_file_error))
		return
	}
	defer delete(file_data)

	if len(file_data) > MAX_FILE_BYTES {
		set_error(state, fmt.tprintf("File %s is too large (%d bytes)", filepath.base(full_path), len(file_data)))
		return
	}

	file_content := strings.clone(string(file_data))

	target_pane_index := 0
	if api.active_pane_index != nil { target_pane_index = api.active_pane_index(api.editor) }
	if split_secondary {
		if api.set_split_active      != nil { api.set_split_active(api.editor, true) }
		if api.set_active_pane_index != nil { api.set_active_pane_index(api.editor, 1) }
		target_pane_index = 1
	}

	if api.open_string_in_pane != nil {
		api.open_string_in_pane(api.editor, target_pane_index, file_content, full_path)
	}
	close(state)
}
