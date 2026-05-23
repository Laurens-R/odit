// Package `menu` is the in-app menu bar (File / Edit / View /
// Navigate / Terminal / Debug / Help) shown on Windows + Linux.
// macOS uses the native NSMenu and this package is effectively a
// no-op there.
//
// File layout:
//   * `state.odin`    — ActionKind enum + static MENUS table +
//                       MenuBarState + lifecycle + visibility +
//                       layout helpers.
//   * `dispatch.odin` — open/close, Alt-poll, mnemonic helpers,
//                       keyboard item navigation.
//   * `view.odin`     — handle_event + render (bar + dropdown).
//   * `binding.odin`  — vtable + Hooks (execute_action callback).
package menu

import "vendor:sdl3"

// Every menu item points at one of these. The editor's
// execute_action proc is the single dispatch table — adding a new
// menu item only requires extending the enum, the static menu
// tables, and one case in that switch.
ActionKind :: enum {
	None, // separator placeholder

	FileOpen,
	FileSave,
	FileSaveAs,
	FileSwitchDocument,
	FileClose,
	FileQuit,

	EditUndo,
	EditRedo,
	EditCopy,
	EditPaste,
	EditFind,
	EditReplace,
	EditFindInFiles,
	EditReplaceInFiles,
	EditCompletion,

	ViewToggleWrap,
	ViewToggleDiff,
	ViewMarkdownPreview,
	ViewSwapPanes,
	ViewFocusLeftPane,
	ViewFocusRightPane,
	ViewMoveToLeftPane,
	ViewMoveToRightPane,

	NavSymbolJump,
	NavGitHistory,
	NavLspHover,

	TerminalShowHide,
	TerminalNew,
	TerminalSwitch,
	TerminalCloseActive,

	DebugTasks,
	DebugTogglePanel,
	DebugContinue,
	DebugStop,
	DebugStepOver,
	DebugStepInto,
	DebugStepOut,

	HelpToggle,
}

ItemDef :: struct {
	label:    string,
	shortcut: string,
	action:   ActionKind,
}

MenuDef :: struct {
	title: string,
	// Lowercase ASCII letter that triggers this menu from
	// Alt+<letter>.
	mnemonic_letter: u8,
	items: []ItemDef,
}

// --- Static menu structure --------------------------------------------

@(private="file")
FILE_ITEMS := [?]ItemDef{
	{label = "Open...",         shortcut = "F2",           action = .FileOpen},
	{label = "Save",            shortcut = "Ctrl+S",       action = .FileSave},
	{label = "Save As...",      shortcut = "Ctrl+Shift+S", action = .FileSaveAs},
	{},
	{label = "Switch Document", shortcut = "F4",           action = .FileSwitchDocument},
	{label = "Close",           shortcut = "Ctrl+F4",      action = .FileClose},
	{},
	{label = "Quit",            shortcut = "Ctrl+Q",       action = .FileQuit},
}

@(private="file")
EDIT_ITEMS := [?]ItemDef{
	{label = "Undo",             shortcut = "Ctrl+Z",       action = .EditUndo},
	{label = "Redo",             shortcut = "Ctrl+Shift+Z", action = .EditRedo},
	{},
	{label = "Copy",             shortcut = "Ctrl+C",       action = .EditCopy},
	{label = "Paste",            shortcut = "Ctrl+V",       action = .EditPaste},
	{},
	{label = "Find",             shortcut = "Ctrl+F",       action = .EditFind},
	{label = "Replace",          shortcut = "Ctrl+R",       action = .EditReplace},
	{label = "Find in Files",    shortcut = "Ctrl+Shift+F", action = .EditFindInFiles},
	{label = "Replace in Files", shortcut = "Ctrl+Shift+R", action = .EditReplaceInFiles},
	{},
	{label = "Complete",         shortcut = "Ctrl+Space",   action = .EditCompletion},
}

@(private="file")
VIEW_ITEMS := [?]ItemDef{
	{label = "Toggle Word Wrap",     shortcut = "Ctrl+W",  action = .ViewToggleWrap},
	{label = "Toggle Diff",          shortcut = "F8",      action = .ViewToggleDiff},
	{label = "Markdown Preview",     shortcut = "F5",      action = .ViewMarkdownPreview},
	{},
	{label = "Swap Pane Focus",        shortcut = "Ctrl+Tab",         action = .ViewSwapPanes},
	{label = "Focus Left Pane",        shortcut = "Ctrl+Left",        action = .ViewFocusLeftPane},
	{label = "Focus Right Pane",       shortcut = "Ctrl+Right",       action = .ViewFocusRightPane},
	{label = "Move to Left Pane",      shortcut = "Ctrl+Shift+Left",  action = .ViewMoveToLeftPane},
	{label = "Move to Right Pane",     shortcut = "Ctrl+Shift+Right", action = .ViewMoveToRightPane},
}

@(private="file")
NAV_ITEMS := [?]ItemDef{
	{label = "Jump to Symbol", shortcut = "F6", action = .NavSymbolJump},
	{label = "Git History",    shortcut = "F3", action = .NavGitHistory},
}

@(private="file")
TERMINAL_ITEMS := [?]ItemDef{
	{label = "Show / Hide",          shortcut = "F9",            action = .TerminalShowHide},
	{label = "New Terminal",         shortcut = "Ctrl+F9",       action = .TerminalNew},
	{label = "Switch Terminal...",   shortcut = "Ctrl+Shift+F9", action = .TerminalSwitch},
	{},
	{label = "Close Active Terminal", shortcut = "Ctrl+F4",      action = .TerminalCloseActive},
}

@(private="file")
DEBUG_ITEMS := [?]ItemDef{
	{label = "Tasks...",                shortcut = "F7",       action = .DebugTasks},
	{label = "Toggle Debugger Panel",   shortcut = "Shift+F7", action = .DebugTogglePanel},
	{},
	{label = "Continue",                shortcut = "",         action = .DebugContinue},
	{label = "Stop",                    shortcut = "",         action = .DebugStop},
	{},
	{label = "Step Over",               shortcut = "F10",      action = .DebugStepOver},
	{label = "Step Into",               shortcut = "F11",      action = .DebugStepInto},
	{label = "Step Out",                shortcut = "",         action = .DebugStepOut},
}

@(private="file")
HELP_ITEMS := [?]ItemDef{
	{label = "Help...",         shortcut = "F1",     action = .HelpToggle},
	{label = "Hover Info",      shortcut = "Ctrl+K", action = .NavLspHover},
}

// Exposed so the macOS native-menu installer can iterate the same
// table to build NSMenuItems.
MENUS := [?]MenuDef{
	{title = "File",     mnemonic_letter = 'f', items = FILE_ITEMS[:]},
	{title = "Edit",     mnemonic_letter = 'e', items = EDIT_ITEMS[:]},
	{title = "View",     mnemonic_letter = 'v', items = VIEW_ITEMS[:]},
	{title = "Navigate", mnemonic_letter = 'n', items = NAV_ITEMS[:]},
	{title = "Terminal", mnemonic_letter = 't', items = TERMINAL_ITEMS[:]},
	{title = "Debug",    mnemonic_letter = 'd', items = DEBUG_ITEMS[:]},
	{title = "Help",     mnemonic_letter = 'h', items = HELP_ITEMS[:]},
}

// --- State -----------------------------------------------------------

State :: struct {
	open_menu_index:    int, // -1 when no dropdown is open
	hovered_item_index: int, // -1 when no item is hovered

	// True while either Alt key is physically held.
	alt_held:           bool,

	// Flipped true when a menu action executes; cleared on the next
	// Alt PRESS transition.
	alt_press_consumed: bool,

	// Rewritten by the renderer every frame so the input handler
	// can do hit tests against the same rectangles the user sees.
	title_rectangles: [16]sdl3.FRect,
	title_count:      int,
	item_rectangles:  [32]sdl3.FRect,
	item_count:       int,
	dropdown_x:       i32,
	dropdown_y:       i32,
	dropdown_width:   i32,
}

// Final composed visibility rule. The bar is shown when either:
//   * Alt is currently held AND the user hasn't already used Alt to
//     pick something this press cycle, OR
//   * A dropdown is open right now.
//
// On macOS the in-app menu is always hidden (the native NSMenu is
// the only menu surface).
is_visible :: proc(state: ^State) -> bool {
	when ODIN_OS == .Darwin { return false }
	if state.open_menu_index >= 0 { return true }
	return state.alt_held && !state.alt_press_consumed
}

init :: proc(state: ^State) {
	state.open_menu_index    = -1
	state.hovered_item_index = -1
}

@(private)
mnemonic_index_in_title :: proc(title: string, mnemonic_letter: u8) -> int {
	for character_index in 0..<len(title) {
		current_byte := title[character_index]
		lowered := current_byte
		if current_byte >= 'A' && current_byte <= 'Z' { lowered = current_byte + 32 }
		if lowered == mnemonic_letter { return character_index }
	}
	return -1
}

// --- Layout constants ------------------------------------------------

@(private)
TITLE_PADDING:    i32 = 12
@(private)
ITEM_VERTICAL_PADDING: i32 = 4
@(private)
ITEM_HORIZONTAL_PADDING: i32 = 12
@(private)
SHORTCUT_GAP:     i32 = 24
@(private)
SEPARATOR_HEIGHT: i32 = 8

// Always-positive paint height (even when the bar is logically
// hidden, the dropdown layout uses this). The bar's reserved height
// in the editor layout is 0 when hidden, this when shown.
bar_paint_height :: proc(line_height: i32) -> i32 {
	return line_height + 8
}

// Layout height the editor reserves for the bar. 0 when hidden.
bar_layout_height :: proc(state: ^State, line_height: i32) -> i32 {
	if !is_visible(state) { return 0 }
	return bar_paint_height(line_height)
}
