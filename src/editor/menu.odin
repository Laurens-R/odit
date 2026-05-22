package editor

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../dap"
import "../terminal"
import "../ui"

// --- Action vocabulary -----------------------------------------------------
//
// Every menu item points at one of these. The execute proc at the bottom of
// this file is the single dispatch table — adding a new menu item only
// requires extending the enum, the static menu tables, and one case in the
// switch.

@(private)
MenuActionKind :: enum {
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

@(private)
MenuItemDef :: struct {
	label:    string,
	shortcut: string,
	action:   MenuActionKind,
}

@(private)
MenuDef :: struct {
	title: string,
	// Lowercase ASCII letter that triggers this menu from Alt+<letter>.
	// Must appear somewhere in `title` (case-insensitively); the renderer
	// draws an underline beneath the first matching letter when Alt is
	// held, matching the standard Windows menu mnemonic affordance.
	mnemonic_letter: u8,
	items: []MenuItemDef,
}

// --- Static menu structure -------------------------------------------------
//
// Action labels left of the shortcut column; separators are MenuItemDef with
// action == .None and an empty label.

@(private="file")
FILE_ITEMS := [?]MenuItemDef{
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
EDIT_ITEMS := [?]MenuItemDef{
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
VIEW_ITEMS := [?]MenuItemDef{
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
NAV_ITEMS := [?]MenuItemDef{
	{label = "Jump to Symbol", shortcut = "F6", action = .NavSymbolJump},
	{label = "Git History",    shortcut = "F3", action = .NavGitHistory},
}

@(private="file")
TERMINAL_ITEMS := [?]MenuItemDef{
	{label = "Show / Hide",          shortcut = "F9",            action = .TerminalShowHide},
	{label = "New Terminal",         shortcut = "Ctrl+F9",       action = .TerminalNew},
	{label = "Switch Terminal...",   shortcut = "Ctrl+Shift+F9", action = .TerminalSwitch},
	{},
	{label = "Close Active Terminal", shortcut = "Ctrl+F4",      action = .TerminalCloseActive},
}

@(private="file")
DEBUG_ITEMS := [?]MenuItemDef{
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
HELP_ITEMS := [?]MenuItemDef{
	{label = "Help...",         shortcut = "F1",     action = .HelpToggle},
	{label = "Hover Info",      shortcut = "Ctrl+K", action = .NavLspHover},
}

@(private)
MENUS := [?]MenuDef{
	{title = "File",     mnemonic_letter = 'f', items = FILE_ITEMS[:]},
	{title = "Edit",     mnemonic_letter = 'e', items = EDIT_ITEMS[:]},
	{title = "View",     mnemonic_letter = 'v', items = VIEW_ITEMS[:]},
	{title = "Navigate", mnemonic_letter = 'n', items = NAV_ITEMS[:]},
	{title = "Terminal", mnemonic_letter = 't', items = TERMINAL_ITEMS[:]},
	{title = "Debug",    mnemonic_letter = 'd', items = DEBUG_ITEMS[:]},
	{title = "Help",     mnemonic_letter = 'h', items = HELP_ITEMS[:]},
}

// --- State ----------------------------------------------------------------

@(private)
MenuBarState :: struct {
	open_menu_index:    int, // -1 when no dropdown is open
	hovered_item_index: int, // -1 when no item is hovered; index into MENUS[open].items

	// True while either Alt key is physically held. Toggled by the per-
	// frame poll in `editor_update`; the renderer reads this to decide
	// whether to underline each title's mnemonic letter. Cached state (vs.
	// always querying GetModState in render) lets us mark the editor
	// dirty exactly once on each press/release rather than every frame.
	alt_held:           bool,

	// Flipped true when a menu action executes; cleared on the next Alt
	// PRESS transition. Implements "after picking an item the menu hides
	// even if Alt is still held — user must release Alt and press again
	// to bring the menu back". Without this the bar would pop right back
	// up while Alt is held, which is jarring.
	alt_press_consumed: bool,

	// Rewritten by the renderer every frame so the input handler can do hit
	// tests against the same rectangles the user sees.
	title_rectangles: [16]sdl3.FRect,
	title_count:      int,
	item_rectangles:  [32]sdl3.FRect,
	item_count:       int,
	dropdown_x:       i32,
	dropdown_y:       i32,
	dropdown_width:   i32,
}

// Final composed visibility rule. The bar is shown when either:
//   * Alt is currently held AND the user hasn't already used Alt to pick
//     something this press cycle, OR
//   * A dropdown is open right now (a click on a title with no Alt at all
//     is enough to surface the bar; releasing Alt while a menu is open
//     also keeps it visible).
@(private)
menu_bar_is_visible :: proc(menu_bar: ^MenuBarState) -> bool {
	if menu_bar.open_menu_index >= 0 { return true }
	return menu_bar.alt_held && !menu_bar.alt_press_consumed
}

@(private)
menu_bar_init :: proc(menu_bar: ^MenuBarState) {
	menu_bar.open_menu_index    = -1
	menu_bar.hovered_item_index = -1
}

// Polled from `editor_update`. SDL3's KEY_UP events aren't routed through
// `editor_handle_event` (the main loop drops them), so we can't track Alt
// release via the event stream — query the live modifier mask instead.
// Marking dirty only on transitions keeps idle frames from repainting.
//
// Also drives the visibility lifecycle:
//   * Alt PRESS  → clear `alt_press_consumed` so the bar can show again
//                  after a previous action execution.
//   * Alt RELEASE → no special action; visibility derives from the
//                   composed rule in `menu_bar_is_visible`.
@(private)
menu_bar_poll_alt_state :: proc(editor: ^Editor) {
	current_modifiers := sdl3.GetModState()
	alt_currently_held := .LALT in current_modifiers || .RALT in current_modifiers
	if alt_currently_held != editor.menu_bar.alt_held {
		if alt_currently_held && !editor.menu_bar.alt_held {
			editor.menu_bar.alt_press_consumed = false
		}
		editor.menu_bar.alt_held = alt_currently_held
		editor_mark_dirty(editor)
	}
}

// Find the position in `title` of the first byte that case-insensitively
// matches `mnemonic_letter` (already lowercase). Returns -1 when there's
// no match — the title is rendered without an underline in that case.
@(private="file")
mnemonic_index_in_title :: proc(title: string, mnemonic_letter: u8) -> int {
	for character_index in 0..<len(title) {
		current_byte := title[character_index]
		lowered := current_byte
		if current_byte >= 'A' && current_byte <= 'Z' { lowered = current_byte + 32 }
		if lowered == mnemonic_letter { return character_index }
	}
	return -1
}

// --- Layout ----------------------------------------------------------------

// Pixel height of the menu strip when visible. Matches the status bar so
// the framing top and bottom feel symmetrical. Returns 0 when the bar is
// hidden so panes get the full window height — the bar overlays whatever's
// below it the instant Alt is pressed, then yields the space back when it
// disappears, avoiding a pane reflow on each show/hide.
@(private)
editor_menu_bar_height :: proc(editor: ^Editor) -> i32 {
	if !menu_bar_is_visible(&editor.menu_bar) { return 0 }
	return editor.line_height + 8
}

// Always-positive height for the actual menu paint — even when the bar is
// "logically hidden" (no layout space reserved), the renderer needs the
// real height to draw the strip and lay out the dropdowns.
@(private="file")
editor_menu_bar_paint_height :: proc(editor: ^Editor) -> i32 {
	return editor.line_height + 8
}

@(private="file")
MENU_TITLE_PADDING:    i32 = 12
@(private="file")
MENU_ITEM_VERTICAL_PADDING: i32 = 4
@(private="file")
MENU_ITEM_HORIZONTAL_PADDING: i32 = 12
@(private="file")
MENU_SHORTCUT_GAP:     i32 = 24
@(private="file")
MENU_SEPARATOR_HEIGHT: i32 = 8

// --- Open / close ---------------------------------------------------------

@(private)
menu_bar_close :: proc(editor: ^Editor) {
	editor.menu_bar.open_menu_index    = -1
	editor.menu_bar.hovered_item_index = -1
}

@(private="file")
menu_bar_open :: proc(editor: ^Editor, menu_index: int) {
	if menu_index < 0 || menu_index >= len(MENUS) { return }
	editor.menu_bar.open_menu_index    = menu_index
	editor.menu_bar.hovered_item_index = -1
}

// --- Input ----------------------------------------------------------------

// Returns true when the event was consumed by the menu (so the caller — the
// top of editor_handle_event — should NOT pass it through to panes or other
// modals). When no menu is open and the event isn't a click on the bar, the
// proc reports false and the caller proceeds normally.
@(private)
menu_bar_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) -> bool {
	menu_bar := &editor.menu_bar

	#partial switch event.type {
	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return menu_bar.open_menu_index >= 0 }
		mouse_x, mouse_y := event.button.x, event.button.y

		// Click on a top-level title — toggle that menu.
		for title_index in 0..<menu_bar.title_count {
			if ui.point_in_rect(menu_bar.title_rectangles[title_index], mouse_x, mouse_y) {
				if menu_bar.open_menu_index == title_index {
					menu_bar_close(editor)
				} else {
					menu_bar_open(editor, title_index)
				}
				return true
			}
		}

		// Click inside the open dropdown — pick the hit item.
		if menu_bar.open_menu_index >= 0 {
			items := MENUS[menu_bar.open_menu_index].items
			for item_index in 0..<min(menu_bar.item_count, len(items)) {
				if !ui.point_in_rect(menu_bar.item_rectangles[item_index], mouse_x, mouse_y) { continue }
				item := items[item_index]
				if item.action == .None { return true } // separator — eat the click without acting
				menu_bar_close(editor)
				menu_execute_action(editor, item.action)
				return true
			}

			// Click outside both the title row and the dropdown — close the
			// menu and let the event propagate so the click also lands on
			// whatever's underneath (pane focus / scrollbar / etc.).
			menu_bar_close(editor)
			return false
		}
		return false

	case .MOUSE_MOTION:
		mouse_x, mouse_y := event.motion.x, event.motion.y

		// Slide the open dropdown from one title to the next when the user
		// drags / hovers across the menu bar — classic menu behavior. Only
		// fires when a menu is already open so plain hover-over-the-bar
		// doesn't pop dropdowns unprompted.
		if menu_bar.open_menu_index >= 0 {
			for title_index in 0..<menu_bar.title_count {
				if ui.point_in_rect(menu_bar.title_rectangles[title_index], mouse_x, mouse_y) {
					if menu_bar.open_menu_index != title_index { menu_bar_open(editor, title_index) }
					return true
				}
			}

			// Update hovered item inside the dropdown.
			menu_bar.hovered_item_index = -1
			items := MENUS[menu_bar.open_menu_index].items
			for item_index in 0..<min(menu_bar.item_count, len(items)) {
				if ui.point_in_rect(menu_bar.item_rectangles[item_index], mouse_x, mouse_y) {
					if items[item_index].action != .None {
						menu_bar.hovered_item_index = item_index
					}
					break
				}
			}
			return true
		}
		return false

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		alt_held      := .LALT in key_modifiers || .RALT in key_modifiers
		ctrl_held     := .LCTRL in key_modifiers || .RCTRL in key_modifiers

		// Alt+<mnemonic> opens (or switches to) the matching menu. Works
		// whether a menu is already open or not. Ctrl held alongside is
		// rejected so Ctrl+Alt-style combos don't accidentally pop menus.
		if alt_held && !ctrl_held {
			for menu_def, menu_index in MENUS {
				if menu_def.mnemonic_letter == 0 { continue }
				if u32(pressed_key) == u32(menu_def.mnemonic_letter) {
					if menu_bar.open_menu_index == menu_index {
						menu_bar_close(editor)
					} else {
						menu_bar_open(editor, menu_index)
					}
					return true
				}
			}
		}

		if menu_bar.open_menu_index < 0 { return false }
		switch pressed_key {
		case sdl3.K_ESCAPE:
			menu_bar_close(editor)
			return true
		case sdl3.K_LEFT:
			new_index := menu_bar.open_menu_index - 1
			if new_index < 0 { new_index = len(MENUS) - 1 }
			menu_bar_open(editor, new_index)
			return true
		case sdl3.K_RIGHT:
			new_index := menu_bar.open_menu_index + 1
			if new_index >= len(MENUS) { new_index = 0 }
			menu_bar_open(editor, new_index)
			return true
		case sdl3.K_DOWN:
			menu_bar_navigate_item(editor, +1)
			return true
		case sdl3.K_UP:
			menu_bar_navigate_item(editor, -1)
			return true
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			items := MENUS[menu_bar.open_menu_index].items
			if menu_bar.hovered_item_index < 0 || menu_bar.hovered_item_index >= len(items) { return true }
			selected := items[menu_bar.hovered_item_index]
			if selected.action == .None { return true }
			menu_bar_close(editor)
			menu_execute_action(editor, selected.action)
			return true
		}
		// Swallow other keys while a menu is open so they can't bleed into
		// the active pane.
		return true
	}

	return menu_bar.open_menu_index >= 0
}

@(private="file")
menu_bar_navigate_item :: proc(editor: ^Editor, direction: int) {
	menu_bar := &editor.menu_bar
	items    := MENUS[menu_bar.open_menu_index].items
	if len(items) == 0 { return }

	cursor := menu_bar.hovered_item_index
	if cursor < 0 { cursor = direction > 0 ? -1 : len(items) }

	// Skip past separators in the chosen direction; wrap when we run off
	// either end.
	for safety_step_count in 0..<len(items) {
		cursor += direction
		if cursor < 0             { cursor = len(items) - 1 }
		if cursor >= len(items)   { cursor = 0 }
		if items[cursor].action != .None {
			menu_bar.hovered_item_index = cursor
			return
		}
		_ = safety_step_count
	}
}

// --- Rendering ------------------------------------------------------------

@(private)
menu_bar_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, window_width: i32) {
	menu_bar := &editor.menu_bar
	// Hidden — don't paint the strip and don't update any title rects so
	// the input path can't accidentally hit-test against stale geometry.
	if !menu_bar_is_visible(menu_bar) {
		menu_bar.title_count = 0
		return
	}
	bar_height := editor_menu_bar_paint_height(editor)

	// Background strip.
	bar_rectangle := sdl3.FRect{0, 0, f32(window_width), f32(bar_height)}
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &bar_rectangle)

	// Hairline underneath the strip so it visually separates from the panes.
	hairline_rectangle := sdl3.FRect{0, f32(bar_height - 1), f32(window_width), 1}
	sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
	sdl3.RenderFillRect(renderer, &hairline_rectangle)

	// Title row — measure each title, store its rect for hit-testing, paint
	// a tinted highlight under the open one.
	current_x: i32 = 0
	menu_bar.title_count = 0
	for menu_def, menu_index in MENUS {
		if menu_bar.title_count >= len(menu_bar.title_rectangles) { break }

		title_width: i32 = 0
		ttf.GetStringSize(editor.font, cstring_for_label(menu_def.title), 0, &title_width, nil)
		// title_width is the actual rendered width; pad both sides.
		cell_width  := title_width + MENU_TITLE_PADDING * 2
		title_rect := sdl3.FRect{f32(current_x), 0, f32(cell_width), f32(bar_height)}
		menu_bar.title_rectangles[menu_bar.title_count] = title_rect
		menu_bar.title_count += 1

		is_open := menu_index == menu_bar.open_menu_index
		if is_open {
			sdl3.SetRenderDrawColorFloat(renderer, editor.selection_color.r, editor.selection_color.g, editor.selection_color.b, editor.selection_color.a)
			sdl3.RenderFillRect(renderer, &title_rect)
		}

		text_color := is_open ? editor.cursor_color : editor.status_bar_foreground
		text_y    := (bar_height - editor.line_height) / 2
		title_x   := current_x + MENU_TITLE_PADDING
		render_string(editor, renderer, menu_def.title, title_x, text_y, text_color)

		// Mnemonic affordance: while Alt is held, underline the letter
		// that triggers this menu from Alt+<letter>. Doing the underline
		// instead of a color swap matches the platform-standard visual
		// and stays readable when the title is also highlighted by hover.
		if menu_bar.alt_held || is_open {
			mnemonic_position := mnemonic_index_in_title(menu_def.title, menu_def.mnemonic_letter)
			if mnemonic_position >= 0 {
				prefix_width:    i32 = 0
				if mnemonic_position > 0 {
					prefix_c := strings.clone_to_cstring(menu_def.title[:mnemonic_position], context.temp_allocator)
					ttf.GetStringSize(editor.font, prefix_c, 0, &prefix_width, nil)
				}
				mnemonic_char_width: i32 = 0
				mnemonic_char_c := strings.clone_to_cstring(menu_def.title[mnemonic_position:mnemonic_position+1], context.temp_allocator)
				ttf.GetStringSize(editor.font, mnemonic_char_c, 0, &mnemonic_char_width, nil)

				underline_y := text_y + editor.line_height - 2
				underline_x := title_x + prefix_width
				sdl3.SetRenderDrawColorFloat(renderer, text_color.r, text_color.g, text_color.b, text_color.a)
				sdl3.RenderLine(renderer, f32(underline_x), f32(underline_y), f32(underline_x + mnemonic_char_width - 1), f32(underline_y))
			}
		}

		current_x += cell_width
	}
}

// Drawn AFTER pane content so the dropdown overlays the editor body, but
// BEFORE modal dialogs so a modal opened by a menu action paints over the
// (already-closed) dropdown without flicker.
@(private)
menu_bar_render_dropdown :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, window_width, window_height: i32) {
	menu_bar := &editor.menu_bar
	if menu_bar.open_menu_index < 0 || menu_bar.open_menu_index >= len(MENUS) { return }

	// Dropdown anchors below the strip — even though the strip's layout
	// height is 0 when "hidden", the paint height is always the visible
	// pixel height we want to anchor against.
	bar_height := editor_menu_bar_paint_height(editor)
	menu_def   := MENUS[menu_bar.open_menu_index]
	items      := menu_def.items

	// Measure the widest "label + gap + shortcut" so the panel is exactly
	// as wide as it needs to be.
	max_label_width:    i32 = 0
	max_shortcut_width: i32 = 0
	has_any_shortcut := false
	for item in items {
		if item.action == .None { continue }
		label_width: i32
		ttf.GetStringSize(editor.font, cstring_for_label(item.label), 0, &label_width, nil)
		if label_width > max_label_width { max_label_width = label_width }
		if len(item.shortcut) > 0 {
			shortcut_width: i32
			ttf.GetStringSize(editor.font, cstring_for_label(item.shortcut), 0, &shortcut_width, nil)
			if shortcut_width > max_shortcut_width { max_shortcut_width = shortcut_width }
			has_any_shortcut = true
		}
	}

	dropdown_width := MENU_ITEM_HORIZONTAL_PADDING * 2 + max_label_width
	if has_any_shortcut {
		dropdown_width += MENU_SHORTCUT_GAP + max_shortcut_width
	}
	// Anchor under the menu title; clamp to the window so a right-edge
	// menu doesn't run off-screen.
	dropdown_x: i32 = i32(menu_bar.title_rectangles[menu_bar.open_menu_index].x)
	if dropdown_x + dropdown_width > window_width - 4 {
		dropdown_x = window_width - 4 - dropdown_width
		if dropdown_x < 0 { dropdown_x = 0 }
	}
	dropdown_y: i32 = bar_height

	// Compute total height by summing per-item heights.
	row_height := editor.line_height + MENU_ITEM_VERTICAL_PADDING * 2
	total_height: i32 = 4 // small top inset
	for item in items {
		if item.action == .None { total_height += MENU_SEPARATOR_HEIGHT }
		else                    { total_height += row_height }
	}
	total_height += 4 // bottom inset

	if dropdown_y + total_height > window_height { total_height = window_height - dropdown_y - 4 }

	dropdown_rect := sdl3.FRect{f32(dropdown_x), f32(dropdown_y), f32(dropdown_width), f32(total_height)}

	// Panel background + border.
	sdl3.SetRenderDrawColorFloat(renderer, editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a)
	sdl3.RenderFillRect(renderer, &dropdown_rect)
	sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
	sdl3.RenderRect(renderer, &dropdown_rect)

	// Row layout.
	menu_bar.dropdown_x     = dropdown_x
	menu_bar.dropdown_y     = dropdown_y
	menu_bar.dropdown_width = dropdown_width
	menu_bar.item_count     = 0

	current_y := dropdown_y + 4
	for item, item_index in items {
		if menu_bar.item_count >= len(menu_bar.item_rectangles) { break }

		if item.action == .None {
			// Separator: thin horizontal rule, no hit-test rect.
			menu_bar.item_rectangles[menu_bar.item_count] = sdl3.FRect{0, 0, 0, 0}
			menu_bar.item_count += 1
			rule_y := current_y + MENU_SEPARATOR_HEIGHT / 2
			sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
			sdl3.RenderLine(renderer, f32(dropdown_x + 6), f32(rule_y), f32(dropdown_x + dropdown_width - 6), f32(rule_y))
			current_y += MENU_SEPARATOR_HEIGHT
			continue
		}

		row_rect := sdl3.FRect{f32(dropdown_x + 2), f32(current_y), f32(dropdown_width - 4), f32(row_height)}
		menu_bar.item_rectangles[menu_bar.item_count] = row_rect
		menu_bar.item_count += 1

		is_hovered := item_index == menu_bar.hovered_item_index
		if is_hovered {
			sdl3.SetRenderDrawColorFloat(renderer, editor.selection_color.r, editor.selection_color.g, editor.selection_color.b, editor.selection_color.a)
			sdl3.RenderFillRect(renderer, &row_rect)
		}

		label_text_color    := is_hovered ? editor.cursor_color           : editor.status_bar_foreground
		shortcut_text_color := is_hovered ? editor.status_bar_foreground  : editor.line_number_color

		render_string(editor, renderer, item.label,
			dropdown_x + MENU_ITEM_HORIZONTAL_PADDING,
			current_y + MENU_ITEM_VERTICAL_PADDING,
			label_text_color)

		if len(item.shortcut) > 0 {
			shortcut_width: i32
			ttf.GetStringSize(editor.font, cstring_for_label(item.shortcut), 0, &shortcut_width, nil)
			shortcut_x := dropdown_x + dropdown_width - MENU_ITEM_HORIZONTAL_PADDING - shortcut_width
			render_string(editor, renderer, item.shortcut, shortcut_x, current_y + MENU_ITEM_VERTICAL_PADDING, shortcut_text_color)
		}

		current_y += row_height
	}
}

// --- Action dispatch -------------------------------------------------------

@(private)
menu_execute_action :: proc(editor: ^Editor, action: MenuActionKind) {
	if action == .None { return }
	// Forces the bar to hide on the next visibility check, even if Alt is
	// still held. User has to release + re-press Alt to bring it back —
	// matches the platform-standard "menu disappears after selection".
	editor.menu_bar.alt_press_consumed = true
	switch action {
	case .None: return

	case .FileOpen:            browse_open(editor)
	case .FileSave:            editor_save_active_file(editor)
	case .FileSaveAs:          editor_save_as_active_file(editor)
	case .FileSwitchDocument:  open_docs_dialog_open(editor)
	case .FileClose:           editor_close_active_file(editor)
	case .FileQuit:            editor.quit_requested = true

	case .EditUndo:            editor_undo_active(editor)
	case .EditRedo:            editor_redo_active(editor)
	case .EditCopy:            menu_copy_in_active_pane(editor)
	case .EditPaste:           menu_paste_in_active_pane(editor)
	case .EditFind:            menu_toggle_find(editor)
	case .EditReplace:         menu_toggle_replace(editor)
	case .EditFindInFiles:     find_in_files_open(editor)
	case .EditReplaceInFiles:  replace_in_files_open(editor)
	case .EditCompletion:      completion_popup_trigger_at_cursor(editor)

	case .ViewToggleWrap:      editor_toggle_wrap(editor)
	case .ViewToggleDiff:      diff_toggle(editor)
	case .ViewMarkdownPreview: markdown_preview_open(editor)
	case .ViewSwapPanes:       editor_focus_other_pane(editor)
	case .ViewFocusLeftPane:   editor_focus_pane(editor, 0)
	case .ViewFocusRightPane:  editor_focus_pane(editor, 1)
	case .ViewMoveToLeftPane:  editor_move_active_to_pane(editor, 0)
	case .ViewMoveToRightPane: editor_move_active_to_pane(editor, 1)

	case .NavSymbolJump:       symbols_dialog_open(editor)
	case .NavGitHistory:       git_history_dialog_open(editor)
	case .NavLspHover:         hover_popup_request_at_cursor(editor)

	case .TerminalShowHide:    editor_toggle_terminal(editor)
	case .TerminalNew:         editor_terminal_create_new(editor)
	case .TerminalSwitch:      terminal_picker_open(editor)
	case .TerminalCloseActive: editor_terminal_destroy_active(editor)

	case .DebugTasks:          tasks_dialog_open(editor)
	case .DebugTogglePanel:    debug_panel_toggle(editor)
	case .DebugContinue:       dap.client_continue(editor.active_dap_client)
	case .DebugStop:           editor_dap_stop_session(editor)
	case .DebugStepOver:       dap.client_step_over(editor.active_dap_client)
	case .DebugStepInto:       dap.client_step_in(editor.active_dap_client)
	case .DebugStepOut:        dap.client_step_out(editor.active_dap_client)

	case .HelpToggle:          help_toggle(editor)
	}
}

// Find / Replace bars toggle from the menu the same way the Ctrl+F / Ctrl+R
// hotkeys do — close if already open on the active pane, open otherwise.
@(private="file")
menu_toggle_find :: proc(editor: ^Editor) {
	if find_active(editor) { find_close(editor) } else { find_open(editor) }
}

@(private="file")
menu_toggle_replace :: proc(editor: ^Editor) {
	if replace_active(editor) { replace_close(editor, false) } else { replace_open(editor) }
}

// Copy/Paste dispatch based on the active pane's content type. In a terminal
// pane these route to the shell's copy/paste (selection-to-clipboard, paste-
// from-clipboard with bracketed-paste); elsewhere they hit the editor's
// document clipboard procs.
@(private="file")
menu_copy_in_active_pane :: proc(editor: ^Editor) {
	#partial switch &content_value in editor_active_pane(editor).content {
	case TerminalPane:
		if content_value.terminal != nil { terminal.terminal_copy_selection_to_clipboard(content_value.terminal) }
	case EditorPane:
		clipboard_copy(editor)
	}
}

@(private="file")
menu_paste_in_active_pane :: proc(editor: ^Editor) {
	#partial switch &content_value in editor_active_pane(editor).content {
	case TerminalPane:
		if content_value.terminal != nil { terminal.terminal_paste_from_clipboard(content_value.terminal) }
	case EditorPane:
		if !editor.diff_state.active { clipboard_paste(editor) }
	}
}

// `ttf.GetStringSize` wants a cstring; the small allocations land in
// temp_allocator (cleared once per frame) so this is cheap to call from the
// render path.
@(private="file")
cstring_for_label :: proc(label: string) -> cstring {
	return strings.clone_to_cstring(label, context.temp_allocator)
}
