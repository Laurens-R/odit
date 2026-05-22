package editor

import "core:strings"

// --- Platform path conventions --------------------------------------------
//
// Every path that flows through the editor is normalized to the
// platform-native separator on assignment so display surfaces (title bars,
// status strip, debug-output log, save/find dialogs) don't end up with
// the `D:\odit/out/windows/debug` mixed-separator soup that's common on
// Windows when paths come from a mix of OS APIs and JSON config files.
//
// `PATH_SEPARATOR` / `PATH_SEPARATOR_CHAR` are the constants; `path_separator`
// / `path_separator_char` are matching procs for call sites that want a
// function-style API (mirrors the user's request for a "get_path_separator
// procedure" with a different implementation per target platform). Both
// forms are kept because the constant flavor is friendlier inside a loop
// body and the proc flavor reads better at call sites that already do other
// per-platform dispatch.

when ODIN_OS == .Windows {
	PATH_SEPARATOR      :: "\\"
	PATH_SEPARATOR_CHAR :: '\\'
} else {
	PATH_SEPARATOR      :: "/"
	PATH_SEPARATOR_CHAR :: '/'
}

@(private)
path_separator :: proc() -> string { return PATH_SEPARATOR }

@(private)
path_separator_char :: proc() -> u8 { return PATH_SEPARATOR_CHAR }

// Rewrite `/` and `\` in `input` to the platform-native separator. Cheap
// enough to call at every boundary that touches a path string; we lean on
// it heavily because Win32 APIs accept both separators interchangeably,
// which means paths can sneak through with the wrong slash and only become
// visible when displayed to the user.
//
// Returns a freshly-allocated string in `allocator`. Caller owns it.
@(private)
path_normalize :: proc(input: string, allocator := context.allocator) -> string {
	if len(input) == 0 { return strings.clone(input, allocator) }
	builder: strings.Builder
	strings.builder_init(&builder, 0, len(input), allocator)
	for byte_index in 0..<len(input) {
		current_byte := input[byte_index]
		if current_byte == '/' || current_byte == '\\' {
			strings.write_byte(&builder, PATH_SEPARATOR_CHAR)
		} else {
			strings.write_byte(&builder, current_byte)
		}
	}
	return strings.to_string(builder)
}

// Join the parts with the platform separator. Treats every part as a path
// segment — leading / trailing separators on individual parts are folded
// into single separators in the output so `path_join({"D:\\odit\\", "out"})`
// produces `D:\odit\out` (not `D:\odit\\out`). All internal separators in
// parts are also normalized, so a part like `out/windows/debug` ends up
// using the native separator on Windows.
//
// Returns a freshly-allocated string in `allocator`. Caller owns it.
@(private)
path_join :: proc(parts: []string, allocator := context.allocator) -> string {
	if len(parts) == 0 { return strings.clone("", allocator) }

	builder: strings.Builder
	strings.builder_init(&builder, 0, 128, allocator)

	for part, part_index in parts {
		// Trim the leading separators on every part except the first so an
		// absolute path in the middle doesn't reset the join. (Absolute
		// segments in the middle are almost always a bug in the caller; if
		// the user really wants that, they can pass that part alone.)
		segment := part
		if part_index > 0 {
			for len(segment) > 0 && (segment[0] == '/' || segment[0] == '\\') { segment = segment[1:] }
		}
		// Strip trailing separators on every part except the last so we can
		// glue them back in with a single SEPARATOR below.
		if part_index < len(parts) - 1 {
			for len(segment) > 0 && (segment[len(segment)-1] == '/' || segment[len(segment)-1] == '\\') {
				segment = segment[:len(segment)-1]
			}
		}

		// Insert the platform separator between non-empty segments.
		if part_index > 0 && strings.builder_len(builder) > 0 && len(segment) > 0 {
			strings.write_string(&builder, PATH_SEPARATOR)
		}

		// Rewrite any internal mixed separators as we go.
		for byte_index in 0..<len(segment) {
			current_byte := segment[byte_index]
			if current_byte == '/' || current_byte == '\\' {
				strings.write_byte(&builder, PATH_SEPARATOR_CHAR)
			} else {
				strings.write_byte(&builder, current_byte)
			}
		}
	}
	return strings.to_string(builder)
}
