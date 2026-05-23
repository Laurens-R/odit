package editor

// Project root state + case-insensitive path matching used by the
// file browser, find-in-files, persistence, and the open-document
// dedupe path in `panes.odin`.

// Replace the current project root. Pass "" to clear it. `path` is
// copied — the caller retains ownership of the buffer they pass in.
// Idempotent / safe to call repeatedly.
@(private)
editor_set_project_root :: proc(editor: ^Editor, path: string) {
	if len(editor.project_root) > 0 {
		delete(editor.project_root)
		editor.project_root = ""
	}
	if len(path) > 0 {
		// Normalize incoming path to platform-native separators so the
		// status bar, title strips, and debug output log all show one
		// consistent form regardless of whether the caller sourced the
		// path from F2 (OS-native) or from JSON config (forward slashes).
		editor.project_root = path_normalize(path)
	}
	// Reload per-project profiles whenever the root moves — the new root
	// might have its own `.odit/project.json`, and the old one's profiles
	// shouldn't follow the user across projects.
	project_config_reload(editor)
	// Forget any prior debug selection — indices into `debug_profiles` are
	// no longer meaningful against the new project's list.
	editor.active_debug_configuration_index = -1
	// Persist the new root so the next session can resume here.
	editor_persistence_save(editor)
}

// True when `path` is the project root or sits inside it. Caller
// passes already-normalized absolute paths; we just do a
// case-insensitive prefix check with a separator boundary so
// `C:/foo` is not treated as inside `C:/foobar`. Returns false if
// no project root is set.
@(private)
editor_path_inside_project_root :: proc(editor: ^Editor, path: string) -> bool {
	if len(editor.project_root) == 0 { return false }
	if len(path) == 0                { return false }
	if path_equals_ignore_case(path, editor.project_root) { return true }

	root_length := len(editor.project_root)
	if len(path) <= root_length { return false }
	if !path_has_prefix_ignore_case(path, editor.project_root) { return false }
	// Boundary check — refuse a hit where `editor.project_root` is
	// just a prefix of a longer sibling name.
	boundary_byte := path[root_length]
	return boundary_byte == '/' || boundary_byte == '\\'
}

// Case-insensitive path equality. ASCII-only fold + separator-fold
// (`\` == `/`); full Unicode case folding would need a real table
// and we don't need it for path matching on the platforms we
// target.
@(private)
path_equals_ignore_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for byte_index in 0..<len(a) {
		if ascii_fold_lower(a[byte_index]) != ascii_fold_lower(b[byte_index]) { return false }
	}
	return true
}

@(private="file")
path_has_prefix_ignore_case :: proc(path, prefix: string) -> bool {
	if len(prefix) > len(path) { return false }
	for byte_index in 0..<len(prefix) {
		if ascii_fold_lower(path[byte_index]) != ascii_fold_lower(prefix[byte_index]) { return false }
	}
	return true
}

// ASCII case-fold AND separator-fold. We want both `\` and `/` to
// compare as equal so paths from different sources (filepath.clean
// output, raw cwd, etc.) compare correctly.
@(private="file")
ascii_fold_lower :: proc(byte_value: u8) -> u8 {
	if byte_value >= 'A' && byte_value <= 'Z' { return byte_value + ('a' - 'A') }
	if byte_value == '\\' { return '/' }
	return byte_value
}
