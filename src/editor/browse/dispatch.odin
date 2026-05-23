// Dispatcher + filesystem ops for the F2 file browser. Lives in the
// subpackage so the editor side stays a one-time Host registration.
package browse

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../../git"
import "../../keybindings"
import "../binding"
import browse_prompt "../browse_prompt"

// Caps for the recursive walk so flat mode stays usable in large trees.
@(private="file")
FLAT_MAX_DEPTH   :: 10
@(private="file")
FLAT_MAX_ENTRIES :: 5000

// Directory names we always skip when recursing.
@(private="file")
FLAT_SKIP_DIRS := [?]string{
	".git", "node_modules", "target", "build", "dist", ".cache", ".idea", ".vscode",
}

// --- Dispatch -----------------------------------------------------------

dispatch_event :: proc(state: ^State, api: ^binding.EditorAPI, bindings: ^keybindings.Bindings, event: ^sdl3.Event) -> (needs_redraw: bool) {
	// Embedded prompt host bridges into our internal do_rename /
	// do_create_file. user_data carries the State pointer so the
	// trampolines can find the surrounding browse state.
	prompt_host := browse_prompt.Host{
		user_data        = state,
		apply_rename     = prompt_host_apply_rename,
		apply_new_file   = prompt_host_apply_new_file,
		apply_new_folder = prompt_host_apply_new_folder,
	}

	intent, redraw := handle_event(state, event, bindings, &prompt_host)
	if intent != nil {
		#partial switch intent_value in intent {
		case OpenDirectory:
			load_directory(state, intent_value.path)
		case OpenFile:
			apply_open_file(state, api, intent_value.path, intent_value.split_secondary)
		case ToggleFlat:
			state.flat_mode = !state.flat_mode
			directory_path := strings.clone(state.current_working_directory, context.temp_allocator)
			load_directory(state, directory_path)
		case SetProjectRoot:
			if api != nil && api.set_project_root != nil { api.set_project_root(api.editor, intent_value.path) }
		case Undo:
			do_undo(state)
		}
	}
	return redraw
}

// --- Directory loading -------------------------------------------------

@(private)
load_directory :: proc(state: ^State, directory_path: string) {
	sources := make([dynamic]EntrySource, 0, 64, context.temp_allocator)

	// Always offer ".." (works in both tree and flat views).
	append(&sources, EntrySource{ name = "..", is_dir = true })

	error_to_report: string

	if state.flat_mode {
		flat_walk(directory_path, "", 0, &sources)
		if len(sources) > 1 {
			sort_entry_sources(sources[1:])
		}
	} else {
		directory_entries, read_directory_error := os.read_all_directory_by_path(directory_path, context.temp_allocator)
		if read_directory_error != nil {
			error_to_report = fmt.tprintf("Cannot read directory: %v", read_directory_error)
		} else {
			tree_entries := make([dynamic]EntrySource, 0, len(directory_entries), context.temp_allocator)
			for entry_info in directory_entries {
				if entry_info.name == "." || entry_info.name == ".." { continue }
				entry_is_directory := entry_info.type == .Directory
				if !entry_is_directory && entry_info.type != .Regular && entry_info.type != .Symlink {
					continue
				}
				append(&tree_entries, EntrySource{
					name   = entry_info.name,
					is_dir = entry_is_directory,
				})
			}
			sort_entry_sources(tree_entries[:])
			for tree_entry in tree_entries { append(&sources, tree_entry) }
		}
	}

	// Annotate with git status.
	git_status_map := git.query_status(directory_path)
	for &source in sources {
		source.git_status = git.status_for_entry(git_status_map, source.name, source.is_dir)
	}

	set_entries_internal(state, sources[:], directory_path)
	if len(error_to_report) > 0 {
		set_error(state, error_to_report)
	}
}

@(private="file")
flat_skip_dir :: proc(directory_name: string) -> bool {
	if strings.has_prefix(directory_name, ".") { return true }
	for skipped_directory in FLAT_SKIP_DIRS {
		if directory_name == skipped_directory { return true }
	}
	return false
}

// Recursively walk `root_directory + sub_relative_path`, appending every
// regular file we find to `output_sources` with its path *relative to
// `root_directory`*. Bounded by FLAT_MAX_DEPTH and FLAT_MAX_ENTRIES.
@(private="file")
flat_walk :: proc(root_directory: string, sub_relative_path: string, current_depth: int, output_sources: ^[dynamic]EntrySource) {
	if current_depth > FLAT_MAX_DEPTH { return }
	if len(output_sources^) >= FLAT_MAX_ENTRIES { return }

	full_directory_path: string
	if len(sub_relative_path) == 0 {
		full_directory_path = root_directory
	} else {
		joined, _ := filepath.join({root_directory, sub_relative_path}, context.temp_allocator)
		full_directory_path = joined
	}

	directory_entries, read_directory_error := os.read_all_directory_by_path(full_directory_path, context.temp_allocator)
	if read_directory_error != nil { return }

	for entry_info in directory_entries {
		if len(output_sources^) >= FLAT_MAX_ENTRIES { return }
		if entry_info.name == "." || entry_info.name == ".." { continue }

		entry_is_directory := entry_info.type == .Directory
		if !entry_is_directory && entry_info.type != .Regular && entry_info.type != .Symlink { continue }

		entry_relative_path: string
		if len(sub_relative_path) == 0 {
			entry_relative_path = entry_info.name
		} else {
			joined, _ := filepath.join({sub_relative_path, entry_info.name}, context.temp_allocator)
			entry_relative_path = joined
		}

		if entry_is_directory {
			if flat_skip_dir(entry_info.name) { continue }
			flat_walk(root_directory, entry_relative_path, current_depth + 1, output_sources)
		} else {
			append(output_sources, EntrySource{
				name   = strings.clone(entry_relative_path, context.temp_allocator),
				is_dir = false,
			})
		}
	}
}

// --- Filesystem actions + undo bookkeeping -----------------------------

@(private)
prompt_host_apply_rename :: proc(user_data: rawptr, old_name, new_name: string) {
	state := cast(^State)user_data
	do_rename(state, old_name, new_name)
}

@(private)
prompt_host_apply_new_file :: proc(user_data: rawptr, file_name: string) {
	state := cast(^State)user_data
	do_create_file(state, file_name)
}

@(private)
prompt_host_apply_new_folder :: proc(user_data: rawptr, folder_name: string) {
	state := cast(^State)user_data
	do_create_folder(state, folder_name)
}

@(private="file")
do_rename :: proc(state: ^State, old_name, new_name: string) {
	if old_name == new_name { return }

	current_directory := state.current_working_directory
	old_full_path, _ := filepath.join({current_directory, old_name}, context.temp_allocator)
	new_full_path, _ := filepath.join({current_directory, new_name}, context.temp_allocator)

	rename_error := os.rename(old_full_path, new_full_path)
	if rename_error != nil {
		set_error(state, fmt.tprintf("Cannot rename: %v", rename_error))
		return
	}

	append(&state.undo_stack, UndoEntry{
		operation = .Rename,
		path_a    = strings.clone(old_full_path),
		path_b    = strings.clone(new_full_path),
	})

	reload_directory_path := strings.clone(current_directory, context.temp_allocator)
	load_directory(state, reload_directory_path)
}

@(private="file")
do_create_file :: proc(state: ^State, file_name: string) {
	current_directory := state.current_working_directory
	new_full_path, _ := filepath.join({current_directory, file_name}, context.temp_allocator)

	// `write_entire_file` truncates if the file exists. For "new file",
	// refuse to clobber.
	if existing_file_handle, open_error := os.open(new_full_path); open_error == nil {
		os.close(existing_file_handle)
		set_error(state, fmt.tprintf("File already exists: %s", file_name))
		return
	}

	if write_error := os.write_entire_file(new_full_path, []byte{}); write_error != nil {
		set_error(state, fmt.tprintf("Cannot create file: %v", write_error))
		return
	}

	append(&state.undo_stack, UndoEntry{
		operation = .Create,
		path_a    = strings.clone(new_full_path),
		path_b    = "",
	})

	reload_directory_path := strings.clone(current_directory, context.temp_allocator)
	load_directory(state, reload_directory_path)
}

@(private="file")
do_create_folder :: proc(state: ^State, folder_name: string) {
	current_directory := state.current_working_directory
	new_full_path, _ := filepath.join({current_directory, folder_name}, context.temp_allocator)

	// Refuse to clobber an existing file or directory at the same path.
	if existing_handle, open_error := os.open(new_full_path); open_error == nil {
		os.close(existing_handle)
		set_error(state, fmt.tprintf("Path already exists: %s", folder_name))
		return
	}

	// `make_directory` creates a single level; intermediate components
	// that don't exist will fail. The user can chain mkdirs by drilling
	// down through the browser if they want a deeper path.
	if make_error := os.make_directory(new_full_path); make_error != nil {
		set_error(state, fmt.tprintf("Cannot create folder: %v", make_error))
		return
	}

	append(&state.undo_stack, UndoEntry{
		operation = .CreateFolder,
		path_a    = strings.clone(new_full_path),
		path_b    = "",
	})

	reload_directory_path := strings.clone(current_directory, context.temp_allocator)
	load_directory(state, reload_directory_path)
}

@(private="file")
do_undo :: proc(state: ^State) {
	undo_stack_length := len(state.undo_stack)
	if undo_stack_length == 0 { return }

	undo_entry := state.undo_stack[undo_stack_length - 1]
	resize(&state.undo_stack, undo_stack_length - 1)

	defer {
		if len(undo_entry.path_a) > 0 { delete(undo_entry.path_a) }
		if len(undo_entry.path_b) > 0 { delete(undo_entry.path_b) }
	}

	switch undo_entry.operation {
	case .Rename:
		if rename_error := os.rename(undo_entry.path_b, undo_entry.path_a); rename_error != nil {
			set_error(state, fmt.tprintf("Cannot undo rename: %v", rename_error))
			return
		}
	case .Create:
		if remove_error := os.remove(undo_entry.path_a); remove_error != nil {
			set_error(state, fmt.tprintf("Cannot undo create: %v", remove_error))
			return
		}
	case .CreateFolder:
		// `os.remove` on a directory only succeeds when the directory
		// is still empty — exactly what we want so the undo doesn't
		// silently nuke files the user dropped into it after creating.
		if remove_error := os.remove(undo_entry.path_a); remove_error != nil {
			set_error(state, fmt.tprintf("Cannot undo create folder: %v", remove_error))
			return
		}
	}

	current_directory := state.current_working_directory
	reload_directory_path := strings.clone(current_directory, context.temp_allocator)
	load_directory(state, reload_directory_path)
}
