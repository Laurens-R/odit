package editor

import "core:encoding/json"
import "core:os"
import "core:strings"

// Per-project configuration loaded from `<project_root>/.odit/project.json`.
// Holds build profiles (named recipes like "debug", "release") and debug
// profiles (launch / attach configurations, optionally with a pre-build
// reference). Replaces the legacy `debug.configurations` block that lived
// in the user-wide settings file — debug configurations are inherently
// project-specific (paths to binaries, args, etc.) so storing them on the
// app would mix configs from different projects.
//
// Schema (project.json):
//
//   {
//     "build_profiles": [
//       {
//         "name":        "debug",
//         "description": "Windows debug build",
//         "command":     ["pwsh", "-File", "scripts/build.ps1", "-Config", "debug"],
//         "command_windows": [...], // optional per-OS override
//         "command_linux":   [...],
//         "command_macos":   [...],
//         "working_dir":     "{project_root}"
//       }
//     ],
//     "debug_profiles": [
//       {
//         "name":          "Debug Odit",
//         "adapter":       "lldb",
//         "request":       "launch",
//         "program":       "{project_root}/out/{platform}/{build_name}/odit.exe",
//         "args":          [],
//         "cwd":           "{project_root}",
//         "stop_on_entry": false,
//         "build_profile": "debug",
//         "pid":           0,
//         "wait_for":      false
//       }
//     ]
//   }
//
// Placeholders accepted in path / arg strings:
//   {project_root} → editor.project_root
//   {build_name}   → name of the build profile referenced by build_profile;
//                    for build commands themselves it's the profile's own name
//   {platform}     → "windows" / "linux" / "macos"

@(private)
BuildProfile :: struct {
	name:            string, // owned
	description:     string, // owned
	command:         []string, // owned
	command_windows: []string, // owned; nil when no override
	command_linux:   []string, // owned
	command_macos:   []string, // owned
	working_dir:     string, // owned; "" inherits the project root
}

@(private)
DebugProfile :: struct {
	name:          string, // owned
	adapter:       string, // owned
	request_kind:  string, // owned
	program:       string, // owned
	working_dir:   string, // owned
	args:          []string, // owned
	stop_on_entry: bool,
	build_profile: string, // owned; name of a BuildProfile to run before launch
	pid:           int,
	wait_for:      bool,
}

@(private)
ProjectConfig :: struct {
	loaded_from_path: string, // owned; "" when no project.json was found
	build_profiles:   [dynamic]BuildProfile,
	debug_profiles:   [dynamic]DebugProfile,
}

// --- Lifecycle ------------------------------------------------------------

@(private)
project_config_init :: proc(config: ^ProjectConfig) {
	config^ = ProjectConfig{}
}

@(private)
project_config_destroy :: proc(config: ^ProjectConfig) {
	project_config_clear(config)
	if cap(config.build_profiles) > 0 { delete(config.build_profiles) }
	if cap(config.debug_profiles) > 0 { delete(config.debug_profiles) }
}

// Free every owned string in the existing config and shrink both arrays to
// zero length. Used by both destroy and reload (so a re-read of project.json
// doesn't leak the previous data).
@(private="file")
project_config_clear :: proc(config: ^ProjectConfig) {
	if len(config.loaded_from_path) > 0 {
		delete(config.loaded_from_path)
		config.loaded_from_path = ""
	}
	for profile in config.build_profiles {
		if len(profile.name)        > 0 { delete(profile.name)        }
		if len(profile.description) > 0 { delete(profile.description) }
		if len(profile.working_dir) > 0 { delete(profile.working_dir) }
		free_token_slice(profile.command)
		free_token_slice(profile.command_windows)
		free_token_slice(profile.command_linux)
		free_token_slice(profile.command_macos)
	}
	clear(&config.build_profiles)
	for profile in config.debug_profiles {
		if len(profile.name)          > 0 { delete(profile.name)          }
		if len(profile.adapter)       > 0 { delete(profile.adapter)       }
		if len(profile.request_kind)  > 0 { delete(profile.request_kind)  }
		if len(profile.program)       > 0 { delete(profile.program)       }
		if len(profile.working_dir)   > 0 { delete(profile.working_dir)   }
		if len(profile.build_profile) > 0 { delete(profile.build_profile) }
		free_token_slice(profile.args)
	}
	clear(&config.debug_profiles)
}

@(private="file")
free_token_slice :: proc(tokens: []string) {
	if tokens == nil { return }
	for token in tokens { if len(token) > 0 { delete(token) } }
	delete(tokens)
}

// Re-read the project's `.odit/project.json` from disk and replace the
// in-memory state. Idempotent — safe to call repeatedly. Empty project_root
// clears the config (drops every profile).
@(private)
project_config_reload :: proc(editor: ^Editor) {
	project_config_clear(&editor.project_config)
	if len(editor.project_root) == 0 { return }

	config_path := strings.concatenate({editor.project_root, "/.odit/project.json"}, context.temp_allocator)
	file_data, read_error := os.read_entire_file_from_path(config_path, context.temp_allocator)
	if read_error != nil { return }

	parsed_value, parse_error := json.parse(file_data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_error != .None { return }
	root_object, root_is_object := parsed_value.(json.Object); if !root_is_object { return }

	editor.project_config.loaded_from_path = strings.clone(config_path)

	if value, has := root_object["build_profiles"]; has {
		if profiles_array, is_array := value.(json.Array); is_array {
			for entry in profiles_array {
				entry_object, ok := entry.(json.Object); if !ok { continue }
				profile := parse_build_profile(entry_object)
				append(&editor.project_config.build_profiles, profile)
			}
		}
	}
	if value, has := root_object["debug_profiles"]; has {
		if profiles_array, is_array := value.(json.Array); is_array {
			for entry in profiles_array {
				entry_object, ok := entry.(json.Object); if !ok { continue }
				profile := parse_debug_profile(entry_object)
				append(&editor.project_config.debug_profiles, profile)
			}
		}
	}
}

@(private="file")
parse_build_profile :: proc(entry_object: json.Object) -> BuildProfile {
	profile: BuildProfile
	if v, has := entry_object["name"];        has { if s, ok := v.(string); ok { profile.name        = strings.clone(s) } }
	if v, has := entry_object["description"]; has { if s, ok := v.(string); ok { profile.description = strings.clone(s) } }
	if v, has := entry_object["working_dir"]; has { if s, ok := v.(string); ok { profile.working_dir = strings.clone(s) } }
	if v, has := entry_object["command"];         has { profile.command         = clone_string_array(v) }
	if v, has := entry_object["command_windows"]; has { profile.command_windows = clone_string_array(v) }
	if v, has := entry_object["command_linux"];   has { profile.command_linux   = clone_string_array(v) }
	if v, has := entry_object["command_macos"];   has { profile.command_macos   = clone_string_array(v) }
	if len(profile.name) == 0 { profile.name = strings.clone("(unnamed)") }
	return profile
}

@(private="file")
parse_debug_profile :: proc(entry_object: json.Object) -> DebugProfile {
	profile: DebugProfile
	if v, has := entry_object["name"];          has { if s, ok := v.(string); ok { profile.name          = strings.clone(s) } }
	if v, has := entry_object["adapter"];       has { if s, ok := v.(string); ok { profile.adapter       = strings.clone(s) } }
	if v, has := entry_object["request"];       has { if s, ok := v.(string); ok { profile.request_kind  = strings.clone(s) } }
	if v, has := entry_object["program"];       has { if s, ok := v.(string); ok { profile.program       = strings.clone(s) } }
	if v, has := entry_object["cwd"];           has { if s, ok := v.(string); ok { profile.working_dir   = strings.clone(s) } }
	if v, has := entry_object["build_profile"]; has { if s, ok := v.(string); ok { profile.build_profile = strings.clone(s) } }
	if v, has := entry_object["stop_on_entry"]; has { if b, ok := v.(bool);   ok { profile.stop_on_entry = b } }
	if v, has := entry_object["wait_for"];      has { if b, ok := v.(bool);   ok { profile.wait_for      = b } }
	if v, has := entry_object["pid"]; has {
		#partial switch n in v {
		case i64: profile.pid = int(n)
		case f64: profile.pid = int(n)
		}
	}
	if v, has := entry_object["args"]; has { profile.args = clone_string_array(v) }

	// Sensible defaults so a half-filled config still works.
	if len(profile.adapter)      == 0 { profile.adapter      = strings.clone("lldb")   }
	if len(profile.request_kind) == 0 { profile.request_kind = strings.clone("launch") }
	if len(profile.name)         == 0 { profile.name         = strings.clone("Debug")  }
	return profile
}

@(private="file")
clone_string_array :: proc(value: json.Value) -> []string {
	array, is_array := value.(json.Array); if !is_array { return nil }
	if len(array) == 0 { return nil }
	result := make([]string, len(array))
	all_strings := true
	for index in 0..<len(array) {
		token_value, is_string := array[index].(string)
		if !is_string { all_strings = false; break }
		result[index] = strings.clone(token_value)
	}
	if !all_strings {
		for token in result { if len(token) > 0 { delete(token) } }
		delete(result)
		return nil
	}
	return result
}

// --- Lookups --------------------------------------------------------------

// Look up the build profile with the given name. Returns `nil` when the name
// doesn't match any loaded profile.
@(private)
project_config_find_build_profile :: proc(config: ^ProjectConfig, name: string) -> ^BuildProfile {
	if len(name) == 0 { return nil }
	for &profile in config.build_profiles {
		if profile.name == name { return &profile }
	}
	return nil
}

// Pick the actual command tokens for a build profile, applying the per-OS
// override when one is present. Returns the slice held by the profile —
// caller MUST NOT delete it.
@(private)
build_profile_active_command :: proc(profile: ^BuildProfile) -> []string {
	when ODIN_OS == .Windows {
		if profile.command_windows != nil { return profile.command_windows }
	} else when ODIN_OS == .Linux {
		if profile.command_linux != nil { return profile.command_linux }
	} else when ODIN_OS == .Darwin {
		if profile.command_macos != nil { return profile.command_macos }
	}
	return profile.command
}

// Canonical name for the current build platform — appears in the {platform}
// placeholder. Matches the conventional layout `out/<platform>/<config>`.
@(private)
project_active_platform_name :: proc() -> string {
	when      ODIN_OS == .Windows { return "windows" }
	else when ODIN_OS == .Linux   { return "linux"   }
	else when ODIN_OS == .Darwin  { return "macos"   }
	else                          { return "unknown" }
}

// --- Placeholder expansion ------------------------------------------------

// Replace `{project_root}`, `{build_name}`, `{platform}` (and the legacy
// `${workspaceFolder}` token from the .vscode launch.json era) inside
// `value`. Pass an empty `build_name` if there's no associated build
// profile — that placeholder then expands to the empty string. The returned
// string lives in `context.temp_allocator`.
@(private)
project_expand_placeholders :: proc(value: string, editor: ^Editor, build_name: string) -> string {
	if len(value) == 0 { return "" }
	root := editor.project_root
	if len(root) == 0 { root = "." }
	platform_name := project_active_platform_name()

	// Two-pass through strings.replace_all so we don't have to write a custom
	// tokenizer; the four placeholders we accept are distinct enough to not
	// overlap one another's substitutions.
	intermediate := value
	intermediate, _ = strings.replace_all(intermediate, "{project_root}",     root,          context.temp_allocator)
	intermediate, _ = strings.replace_all(intermediate, "${workspaceFolder}", root,          context.temp_allocator)
	intermediate, _ = strings.replace_all(intermediate, "{platform}",        platform_name,  context.temp_allocator)
	intermediate, _ = strings.replace_all(intermediate, "{build_name}",      build_name,     context.temp_allocator)
	return intermediate
}
