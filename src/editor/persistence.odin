package editor

import "core:encoding/json"
import "core:os"
import "core:strings"

// Per-user persistent UI state: things that aren't project- or settings-
// scoped but should survive an app restart. Lives in a separate file from
// `settings.json` so the user can hand-edit settings without touching
// state, and so a corrupt state file doesn't take settings down with it.
//
// Layout:
//   { "last_project_root": "D:/odit" }
//
// File location (first existing parent directory wins):
//   Windows: %APPDATA%/odit/state.json
//   POSIX:   $HOME/.config/odit/state.json
//   Fallback: ./.odit_state.json (next to the binary)

@(private="file")
PersistedState :: struct {
	last_project_root: string,
}

// Read the state file (if any) and apply its fields to the editor. Called
// once from `editor_init` so a fresh session lands in the project the user
// was working in last. Silently does nothing on missing / malformed files —
// state persistence is best-effort, never blocking.
@(private)
editor_persistence_load :: proc(editor: ^Editor) {
	state, ok := persistence_read_state()
	if !ok { return }

	if len(state.last_project_root) > 0 && os.is_dir(state.last_project_root) {
		// Use the same setter the F2 browser does so the project_config
		// reload and active-debug-index reset run consistently. The setter
		// will also re-save state — that's a no-op write of the same path.
		editor_set_project_root(editor, state.last_project_root)
	}

	persistence_state_destroy(&state)
}

// Write current persistent state out to disk. Called after every mutation
// that changes a persisted field (currently just `editor.project_root` via
// `editor_set_project_root`). Failures are swallowed — the user shouldn't
// see an error popup just because their AppData folder is read-only.
@(private)
editor_persistence_save :: proc(editor: ^Editor) {
	state := PersistedState{
		last_project_root = editor.project_root,
	}
	persistence_write_state(&state)
}

// --- File IO --------------------------------------------------------------

@(private="file")
persistence_read_state :: proc() -> (state: PersistedState, ok: bool) {
	for path_candidate in persistence_candidate_paths() {
		if len(path_candidate) == 0 { continue }
		file_data, read_error := os.read_entire_file_from_path(path_candidate, context.temp_allocator)
		if read_error != nil { continue }

		parsed_value, parse_error := json.parse(file_data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if parse_error != .None { continue }
		root_object, root_is_object := parsed_value.(json.Object); if !root_is_object { continue }

		if v, has := root_object["last_project_root"]; has {
			if s, is_string := v.(string); is_string && len(s) > 0 {
				state.last_project_root = strings.clone(s)
			}
		}
		return state, true
	}
	return PersistedState{}, false
}

@(private="file")
persistence_write_state :: proc(state: ^PersistedState) {
	target_path := persistence_writable_path()
	if len(target_path) == 0 { return }

	// Make sure the parent directory exists. On a fresh install nobody has
	// created `%APPDATA%/odit/` yet; the JSON write would fail otherwise.
	parent_dir := persistence_parent_directory(target_path)
	if len(parent_dir) > 0 { _ = os.make_directory(parent_dir) }

	builder: strings.Builder
	strings.builder_init(&builder, 0, 128, context.temp_allocator)
	strings.write_string(&builder, "{\n  \"last_project_root\": ")
	persistence_write_json_string(&builder, state.last_project_root)
	strings.write_string(&builder, "\n}\n")

	payload := transmute([]u8) strings.to_string(builder)
	_ = os.write_entire_file(target_path, payload)
}

@(private="file")
persistence_state_destroy :: proc(state: ^PersistedState) {
	if len(state.last_project_root) > 0 {
		delete(state.last_project_root)
		state.last_project_root = ""
	}
}

// Candidate read paths — first existing file wins. Mirrors the precedence
// the settings loader uses (project local → user appdata → user home).
@(private="file")
persistence_candidate_paths :: proc() -> [3]string {
	out: [3]string
	out[0] = ".odit_state.json"
	if appdata := os.get_env("APPDATA", context.temp_allocator); len(appdata) > 0 {
		out[1] = strings.concatenate({appdata, "/odit/state.json"}, context.temp_allocator)
	}
	if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
		out[2] = strings.concatenate({home, "/.config/odit/state.json"}, context.temp_allocator)
	}
	return out
}

// The single path we write to. Prefers the per-user app-data folder so
// state survives moving the binary around; falls back to a dotfile next to
// the binary when no env vars are usable (e.g. CI shells).
@(private="file")
persistence_writable_path :: proc() -> string {
	if appdata := os.get_env("APPDATA", context.temp_allocator); len(appdata) > 0 {
		return strings.concatenate({appdata, "/odit/state.json"}, context.temp_allocator)
	}
	if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
		return strings.concatenate({home, "/.config/odit/state.json"}, context.temp_allocator)
	}
	return ".odit_state.json"
}

@(private="file")
persistence_parent_directory :: proc(path: string) -> string {
	last_slash_index := -1
	for byte_index in 0..<len(path) {
		current_byte := path[byte_index]
		if current_byte == '/' || current_byte == '\\' { last_slash_index = byte_index }
	}
	if last_slash_index <= 0 { return "" }
	return strings.clone(path[:last_slash_index], context.temp_allocator)
}

@(private="file")
persistence_write_json_string :: proc(builder: ^strings.Builder, value: string) {
	strings.write_byte(builder, '"')
	for byte_index in 0..<len(value) {
		current_byte := value[byte_index]
		switch current_byte {
		case '"':  strings.write_string(builder, `\"`)
		case '\\': strings.write_string(builder, `\\`)
		case '\n': strings.write_string(builder, `\n`)
		case '\r': strings.write_string(builder, `\r`)
		case '\t': strings.write_string(builder, `\t`)
		case:
			if current_byte < 0x20 {
				// Control characters get the \u00XX treatment; the editor
				// would never write one but a corrupted prior file might.
				hex := "0123456789ABCDEF"
				strings.write_string(builder, "\\u00")
				strings.write_byte(builder, hex[(current_byte >> 4) & 0xF])
				strings.write_byte(builder, hex[current_byte & 0xF])
			} else {
				strings.write_byte(builder, current_byte)
			}
		}
	}
	strings.write_byte(builder, '"')
}
