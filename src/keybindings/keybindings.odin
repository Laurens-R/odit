package keybindings

import "core:encoding/json"
import "core:strings"
import "vendor:sdl3"

// Every configurable shortcut in the editor. Names are stable identifiers
// that the per-platform JSON in `defaults/<os>.json` references — renaming
// one is a breaking change for user-edited copies of those files.
//
// Conventional text-editing keys (arrows, Home/End, Tab, Backspace, …) are
// intentionally NOT in here — they're typing primitives, not shortcuts.
Action :: enum {
	None,

	// Application
	Quit,

	// File / pane lifecycle
	SaveFile, SaveFileAs, CloseFile,

	// Editing
	Undo, Redo, Copy, Cut, Paste, SelectAll,

	// Multi-cursor
	AddCursorAbove, AddCursorBelow, AddCursorAtNextMatch,

	// Pane navigation
	FocusLeftPane, FocusRightPane,
	MoveToLeftPane, MoveToRightPane,
	SwapPanes,
	ToggleWrap,

	// Search / replace
	FindToggle, FindInFiles,
	ReplaceToggle, ReplaceInFiles,

	// Modal dialogs / modes
	Help,
	FileBrowser,
	GitHistory,
	OpenDocs,
	MarkdownPreview,
	Symbols,
	Tasks,
	ToggleDebugPanel,
	ToggleDiff,

	// Terminal
	ToggleTerminal, NewTerminal, PickTerminal,
	TerminalCopy, TerminalPaste,

	// Debugger
	StepOver, StepIn,

	// LSP
	Hover, TriggerCompletion,

	// File browser (active only while the F2 browse modal is open)
	BrowseRename, BrowseNewFile, BrowseNewFolder, BrowseUndo, BrowseSetProjectRoot,
}

Modifier :: enum u8 {
	Ctrl,  // Control on Windows/Linux, Control on macOS too. Distinct from `Gui`.
	Shift,
	Alt,
	Gui,   // Cmd on macOS, Win on Windows, Super on Linux.
}
Modifiers :: bit_set[Modifier; u8]

Chord :: struct {
	key:       sdl3.Keycode,
	modifiers: Modifiers,
}

Binding :: struct {
	chord:  Chord,
	action: Action,
}

// Linear-scan table. We're talking ~40 entries — a hash map would cost more
// in memory and code than it saves in lookup time.
Bindings :: struct {
	entries: [dynamic]Binding,
}

// --- Default per-platform JSON, embedded at compile time -----------------

// One file per OS. Selecting by `ODIN_OS` happens here so the rest of the
// package doesn't sprout `when` branches.
when ODIN_OS == .Darwin {
	DEFAULT_JSON :: #load("defaults/macos.json",   string)
} else when ODIN_OS == .Linux {
	DEFAULT_JSON :: #load("defaults/linux.json",   string)
} else {
	DEFAULT_JSON :: #load("defaults/windows.json", string)
}

// Populate `bindings` from the per-platform default JSON. Returns false if
// the embedded JSON is somehow invalid (only really possible during dev
// when editing the defaults — the build will then fail loudly at startup
// instead of silently routing every shortcut to .None).
bindings_load_defaults :: proc(bindings: ^Bindings) -> bool {
	bindings.entries = make([dynamic]Binding)
	return bindings_load_from_json(bindings, DEFAULT_JSON)
}

bindings_destroy :: proc(bindings: ^Bindings) {
	delete(bindings.entries)
	bindings.entries = nil
}

// Append every binding from `json_text` into `bindings`. Existing entries
// are kept — call `bindings_load_defaults` on a fresh `Bindings{}` if you
// want a clean slate. The JSON schema is documented above each parser
// helper below.
bindings_load_from_json :: proc(bindings: ^Bindings, json_text: string) -> bool {
	parsed_value, parse_error := json.parse(transmute([]u8)json_text, .JSON5, true, context.temp_allocator)
	if parse_error != nil { return false }

	root_object, root_is_object := parsed_value.(json.Object); if !root_is_object { return false }
	bindings_value, has_bindings := root_object["bindings"]
	if !has_bindings { return false }
	bindings_array, is_array := bindings_value.(json.Array); if !is_array { return false }

	for entry_value in bindings_array {
		entry_object, entry_is_object := entry_value.(json.Object)
		if !entry_is_object { continue }

		key_value,    has_key    := entry_object["key"]
		action_value, has_action := entry_object["action"]
		if !has_key || !has_action { continue }

		key_name,    key_is_string    := key_value.(json.String)
		action_name, action_is_string := action_value.(json.String)
		if !key_is_string || !action_is_string { continue }

		key_code, key_resolved := parse_key_name(key_name)
		if !key_resolved { continue }
		action, action_resolved := parse_action_name(action_name)
		if !action_resolved { continue }

		modifiers: Modifiers
		if modifiers_value, has_modifiers := entry_object["modifiers"]; has_modifiers {
			if modifiers_array, is_array := modifiers_value.(json.Array); is_array {
				for modifier_value in modifiers_array {
					if modifier_name, is_string := modifier_value.(json.String); is_string {
						if modifier_flag, ok := parse_modifier_name(modifier_name); ok {
							modifiers |= { modifier_flag }
						}
					}
				}
			}
		}

		append(&bindings.entries, Binding{
			chord  = Chord{ key = key_code, modifiers = modifiers },
			action = action,
		})
	}
	return true
}

// Lookup scope. Some chords (Ctrl+R, Ctrl+Z, Ctrl+P) intentionally double
// up: one meaning when an editor pane has focus (Global), a different one
// while the file-browser modal is open (Browse). The active scope is
// determined by the caller — global input dispatch passes .Global, the
// browse-modal handler passes .Browse, and `lookup` filters out matches
// for the wrong scope so the duplicates can coexist in the same table.
Scope :: enum { Global, Browse }

action_scope :: proc(action: Action) -> Scope {
	#partial switch action {
	case .BrowseRename, .BrowseNewFile, .BrowseNewFolder, .BrowseUndo, .BrowseSetProjectRoot:
		return .Browse
	}
	return .Global
}

// Look up which `Action` (if any) the given SDL chord is bound to in the
// requested scope. Returns `.None` when nothing matches — callers fall
// back to whatever default behavior they would otherwise have run.
lookup :: proc(bindings: ^Bindings, key: sdl3.Keycode, sdl_modifiers: sdl3.Keymod, scope: Scope = .Global) -> Action {
	normalized := normalize_sdl_modifiers(sdl_modifiers)
	for entry in bindings.entries {
		if entry.chord.key == key && entry.chord.modifiers == normalized && action_scope(entry.action) == scope {
			return entry.action
		}
	}
	return .None
}

// Reverse lookup: return the first chord bound to `action`, or `{}` /
// false if none exists. Used by the help screen so the rendered hotkey
// list always reflects the active config rather than hard-coded strings.
chord_for_action :: proc(bindings: ^Bindings, action: Action) -> (Chord, bool) {
	for entry in bindings.entries {
		if entry.action == action { return entry.chord, true }
	}
	return {}, false
}

// --- Helpers --------------------------------------------------------------

// Collapse SDL's left/right modifier distinction into our normalized set.
// SDL exposes both LCTRL and RCTRL separately; we don't care which one
// fired, only that "Ctrl" is held.
@(private)
normalize_sdl_modifiers :: proc(sdl_modifiers: sdl3.Keymod) -> Modifiers {
	result: Modifiers
	if .LCTRL  in sdl_modifiers || .RCTRL  in sdl_modifiers { result |= { .Ctrl  } }
	if .LSHIFT in sdl_modifiers || .RSHIFT in sdl_modifiers { result |= { .Shift } }
	if .LALT   in sdl_modifiers || .RALT   in sdl_modifiers { result |= { .Alt   } }
	if .LGUI   in sdl_modifiers || .RGUI   in sdl_modifiers { result |= { .Gui   } }
	return result
}

// Case-insensitive modifier name parser. Accepts the common aliases:
//   "Ctrl"  / "Control"
//   "Shift"
//   "Alt"   / "Option"  (macOS-y)
//   "Gui"   / "Cmd" / "Super" / "Win"
@(private)
parse_modifier_name :: proc(name: string) -> (Modifier, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "ctrl", "control":             return .Ctrl,  true
	case "shift":                       return .Shift, true
	case "alt", "option":               return .Alt,   true
	case "gui", "cmd", "super", "win":  return .Gui,   true
	}
	return .Ctrl, false // value ignored when ok=false
}

@(private)
parse_action_name :: proc(name: string) -> (Action, bool) {
	switch name {
	case "Quit":                  return .Quit, true
	case "SaveFile":              return .SaveFile, true
	case "SaveFileAs":            return .SaveFileAs, true
	case "CloseFile":             return .CloseFile, true
	case "Undo":                  return .Undo, true
	case "Redo":                  return .Redo, true
	case "Copy":                  return .Copy, true
	case "Cut":                   return .Cut, true
	case "Paste":                 return .Paste, true
	case "SelectAll":             return .SelectAll, true
	case "AddCursorAbove":        return .AddCursorAbove, true
	case "AddCursorBelow":        return .AddCursorBelow, true
	case "AddCursorAtNextMatch":  return .AddCursorAtNextMatch, true
	case "FocusLeftPane":         return .FocusLeftPane, true
	case "FocusRightPane":        return .FocusRightPane, true
	case "MoveToLeftPane":        return .MoveToLeftPane, true
	case "MoveToRightPane":       return .MoveToRightPane, true
	case "SwapPanes":             return .SwapPanes, true
	case "ToggleWrap":            return .ToggleWrap, true
	case "FindToggle":            return .FindToggle, true
	case "FindInFiles":           return .FindInFiles, true
	case "ReplaceToggle":         return .ReplaceToggle, true
	case "ReplaceInFiles":        return .ReplaceInFiles, true
	case "Help":                  return .Help, true
	case "FileBrowser":           return .FileBrowser, true
	case "GitHistory":            return .GitHistory, true
	case "OpenDocs":              return .OpenDocs, true
	case "MarkdownPreview":       return .MarkdownPreview, true
	case "Symbols":               return .Symbols, true
	case "Tasks":                 return .Tasks, true
	case "ToggleDebugPanel":      return .ToggleDebugPanel, true
	case "ToggleDiff":            return .ToggleDiff, true
	case "ToggleTerminal":        return .ToggleTerminal, true
	case "NewTerminal":           return .NewTerminal, true
	case "PickTerminal":          return .PickTerminal, true
	case "TerminalCopy":          return .TerminalCopy, true
	case "TerminalPaste":         return .TerminalPaste, true
	case "StepOver":              return .StepOver, true
	case "StepIn":                return .StepIn, true
	case "Hover":                 return .Hover, true
	case "TriggerCompletion":     return .TriggerCompletion, true
	case "BrowseRename":          return .BrowseRename, true
	case "BrowseNewFile":         return .BrowseNewFile, true
	case "BrowseNewFolder":       return .BrowseNewFolder, true
	case "BrowseUndo":            return .BrowseUndo, true
	case "BrowseSetProjectRoot": return .BrowseSetProjectRoot, true
	}
	return .None, false
}

// Map a JSON `"key"` string to its SDL keycode. We only need the keys that
// can actually appear in shortcuts — letters, F-keys, and a handful of
// named keys (Space, Tab, Return, F4 for close, etc.). Case-insensitive on
// the letter keys so "S" and "s" both work; F-keys are spelled "F1" … "F12".
@(private)
parse_key_name :: proc(name: string) -> (sdl3.Keycode, bool) {
	if len(name) == 0 { return 0, false }

	// Single-letter keys A-Z (case-insensitive).
	if len(name) == 1 {
		character := name[0]
		if character >= 'a' && character <= 'z' { character -= ('a' - 'A') }
		if character >= 'A' && character <= 'Z' {
			return sdl3.Keycode(int(sdl3.K_A) + int(character - 'A')), true
		}
		if character >= '0' && character <= '9' {
			return sdl3.Keycode(int(sdl3.K_0) + int(character - '0')), true
		}
	}

	// F-keys: "F1" … "F24" (we only use through F12 today, but accept all).
	if (name[0] == 'F' || name[0] == 'f') && len(name) >= 2 {
		number: int = 0
		valid := true
		for character_index in 1..<len(name) {
			character := name[character_index]
			if character < '0' || character > '9' { valid = false; break }
			number = number * 10 + int(character - '0')
		}
		if valid && number >= 1 && number <= 24 {
			return sdl3.Keycode(int(sdl3.K_F1) + (number - 1)), true
		}
	}

	switch strings.to_lower(name, context.temp_allocator) {
	case "space":     return sdl3.K_SPACE,     true
	case "tab":       return sdl3.K_TAB,       true
	case "return", "enter":
	                  return sdl3.K_RETURN,    true
	case "escape", "esc":
	                  return sdl3.K_ESCAPE,    true
	case "backspace": return sdl3.K_BACKSPACE, true
	case "delete":    return sdl3.K_DELETE,    true
	case "left":      return sdl3.K_LEFT,      true
	case "right":     return sdl3.K_RIGHT,     true
	case "up":        return sdl3.K_UP,        true
	case "down":      return sdl3.K_DOWN,      true
	case "home":      return sdl3.K_HOME,      true
	case "end":       return sdl3.K_END,       true
	case "pageup":    return sdl3.K_PAGEUP,    true
	case "pagedown":  return sdl3.K_PAGEDOWN,  true
	}

	return 0, false
}
