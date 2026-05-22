package editor

import "core:encoding/json"
import "core:os"
import "core:strings"

// User-tunable knobs loaded from `%APPDATA%/odit/settings.json` (or
// `./odit.json` in the cwd, checked first). The schema:
//
//   {
//     "lsp": {
//       "odin": { "command": ["ols"] },
//       "c++":  { "command": ["clangd"] }
//     },
//     "dap": {
//       "lldb": { "command": ["lldb-dap"] }
//     }
//   }
//
// Debug / build configurations are per-project (see `project_config.odin`)
// — those live in `<project_root>/.odit/project.json` so each project owns
// its own paths, args, and pre-build links instead of fighting for a global
// slot. This file holds only application-level wiring: which executable
// runs which adapter / language server.
//
// Missing file / parse failure / missing keys silently fall back to baked-in
// defaults so the editor still launches against a fresh machine without any
// config.

@(private)
EditorSettings :: struct {
	// Map language id ("odin", "rust", …) → command + args. The first
	// token is the executable, the rest are CLI args. All strings owned.
	lsp_commands: map[string][]string,

	// Map adapter id ("lldb", "codelldb", …) → command + args. Same shape
	// as `lsp_commands`; lookup happens at debug-session start.
	dap_commands: map[string][]string,
}

@(private)
editor_settings_init :: proc(settings: ^EditorSettings) {
	settings.lsp_commands = make(map[string][]string)
	settings.dap_commands = make(map[string][]string)

	// Baked-in default: Odin uses ols on PATH. Other languages aren't
	// auto-wired — users opt in by adding entries to settings.json.
	// Clone the key — the rest of this module (settings load, destroy)
	// assumes every key in the map is heap-owned. Using a string literal
	// here would crash on the first `delete(existing_key)` since literals
	// live in read-only memory.
	default_odin_command := make([]string, 1)
	default_odin_command[0] = strings.clone("ols")
	settings.lsp_commands[strings.clone("odin")] = default_odin_command

	// Likewise: assume lldb-dap is on PATH (or staged under vendor/<plat>/lsp/).
	// The same resolver used for LSP rewrites a bare relative name to that
	// folder if it exists, so a vendored `lldb-dap.exe` lands without config.
	default_lldb_command := make([]string, 1)
	default_lldb_command[0] = strings.clone("lldb-dap")
	settings.dap_commands[strings.clone("lldb")] = default_lldb_command

	editor_settings_try_load(settings)
}

@(private)
editor_settings_destroy :: proc(settings: ^EditorSettings) {
	for language_id, command_tokens in settings.lsp_commands {
		_ = language_id
		for token in command_tokens { delete(token) }
		delete(command_tokens)
	}
	for language_id in settings.lsp_commands {
		delete(language_id)
	}
	delete(settings.lsp_commands)

	for adapter_id, command_tokens in settings.dap_commands {
		_ = adapter_id
		for token in command_tokens { delete(token) }
		delete(command_tokens)
	}
	for adapter_id in settings.dap_commands {
		delete(adapter_id)
	}
	delete(settings.dap_commands)
}

// Try a small list of candidate paths. First one that parses wins; everything
// else is ignored. Missing entries leave the bakedin defaults in place.
@(private="file")
editor_settings_try_load :: proc(settings: ^EditorSettings) {
	candidate_paths: [3]string

	candidate_paths[0] = "odit.json"
	if appdata := os.get_env("APPDATA", context.temp_allocator); len(appdata) > 0 {
		candidate_paths[1] = path_join({appdata, "odit", "settings.json"}, context.temp_allocator)
	}
	if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
		candidate_paths[2] = path_join({home, ".config", "odit", "settings.json"}, context.temp_allocator)
	}

	for path_candidate in candidate_paths {
		if len(path_candidate) == 0 { continue }
		if editor_settings_load_from_path(settings, path_candidate) { return }
	}
}

@(private="file")
editor_settings_load_from_path :: proc(settings: ^EditorSettings, file_path: string) -> bool {
	file_data, read_error := os.read_entire_file_from_path(file_path, context.temp_allocator)
	if read_error != nil { return false }

	parsed_value, parse_error := json.parse(file_data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_error != .None { return false }

	root_object, root_is_object := parsed_value.(json.Object); if !root_is_object { return false }

	if lsp_value, has := root_object["lsp"]; has {
		if lsp_object, is_object := lsp_value.(json.Object); is_object {
			parse_command_map(&settings.lsp_commands, lsp_object)
		}
	}

	if dap_value, has := root_object["dap"]; has {
		if dap_object, is_object := dap_value.(json.Object); is_object {
			parse_command_map(&settings.dap_commands, dap_object)
		}
	}

	return true
}

// Parse one of the `{ id: { "command": [...] } }` blocks (used by both `lsp`
// and `dap`). Replaces existing entries on each call so settings reload is
// idempotent. Silently skips malformed entries — invalid JSON should never
// brick editor startup.
@(private="file")
parse_command_map :: proc(target: ^map[string][]string, source: json.Object) {
	for entry_id, entry_value in source {
		entry_object, is_object := entry_value.(json.Object); if !is_object { continue }
		command_value, has_command := entry_object["command"]; if !has_command { continue }
		command_array, is_array := command_value.(json.Array); if !is_array { continue }
		if len(command_array) == 0 { continue }

		new_tokens := make([]string, len(command_array))
		all_strings := true
		for token_index in 0..<len(command_array) {
			token_value, token_is_string := command_array[token_index].(string)
			if !token_is_string { all_strings = false; break }
			new_tokens[token_index] = strings.clone(token_value)
		}
		if !all_strings {
			for token in new_tokens { if len(token) > 0 { delete(token) } }
			delete(new_tokens)
			continue
		}

		// Replace any prior entry.
		for existing_key, existing_command in target {
			if existing_key == entry_id {
				for token in existing_command { delete(token) }
				delete(existing_command)
				delete_key(target, existing_key)
				delete(existing_key)
				break
			}
		}
		target[strings.clone(entry_id)] = new_tokens
	}
}

// Public lookup helper: returns the configured command tokens for a given
// language id, or nil if none is registered. Caller does NOT own the slice
// or its strings — they're owned by `EditorSettings`.
@(private)
editor_settings_lsp_command :: proc(settings: ^EditorSettings, language_id: string) -> []string {
	tokens, has_entry := settings.lsp_commands[language_id]
	if !has_entry { return nil }
	return tokens
}

@(private)
editor_settings_dap_command :: proc(settings: ^EditorSettings, adapter_id: string) -> []string {
	tokens, has_entry := settings.dap_commands[adapter_id]
	if !has_entry { return nil }
	return tokens
}
