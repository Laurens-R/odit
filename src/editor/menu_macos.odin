#+build darwin
package editor

import "base:runtime"

import NS "core:sys/darwin/Foundation"

// macOS-only: drives the system menu bar at the top of the screen from the
// same `MENUS` table used by the in-app strip on Windows/Linux. The in-app
// strip is force-hidden on Darwin (see `menu_bar_is_visible`) so this is the
// only menu surface on macOS.
//
// Click → callback flow:
//   1. AppKit fires `menu_action_callback` with the clicked NSMenuItem.
//   2. The item's `tag` was set to `int(MenuActionKind)` at build time.
//   3. We dispatch via the same `menu_execute_action` the in-app menu uses.
//
// Key equivalents are intentionally NOT set on the NSMenuItems. Shortcuts
// keep flowing through SDL → the keybindings table (which is already
// per-platform correct, e.g. Cmd+S on macOS). Setting a keyEquivalent here
// would make AppKit swallow the keystroke before SDL ever sees it, which
// would either duplicate-fire the action or bypass our keybindings layer
// entirely. The native menu acts purely as a discoverable surface.

// Editor pointer captured at install time so the c-callback can route into
// the same dispatch the in-app menu uses. Single-window app, so a single
// global suffices.
@(private="file")
macos_menu_editor: ^Editor

// AppKit invokes this via a selector registered on NSObject. The selector
// name doesn't matter — what matters is that every NSMenuItem points at it,
// and each item carries its `MenuActionKind` in its `tag`.
@(private="file")
menu_action_callback :: proc "c" (unused: rawptr, selector: NS.SEL, sender: ^NS.Object) {
	if macos_menu_editor == nil { return }
	// `proc "c"` has no implicit Odin context — install the default one so
	// `menu_execute_action` (and everything it transitively calls) can use
	// allocators, the temp arena, etc. AppKit dispatches menu callbacks on
	// the main thread, the same thread the SDL event loop runs on, so this
	// is functionally equivalent to a synthesized event from PollEvent.
	context = runtime.default_context()
	menu_item := cast(^NS.MenuItem)sender
	action_tag := NS.MenuItem_tag(menu_item)
	action := MenuActionKind(action_tag)
	menu_execute_action(macos_menu_editor, action)
}

@(private)
editor_install_native_menu :: proc(editor: ^Editor) {
	macos_menu_editor = editor

	app := NS.Application_sharedApplication()

	action_selector := NS.MenuItem_registerActionCallback("oditMenuAction", menu_action_callback)

	main_menu := NS.Menu_alloc()
	main_menu = NS.Menu_init(main_menu)

	// Standard macOS app menu (leftmost, bold). AppKit displays it under the
	// process name regardless of the title we set here, so we leave it empty.
	// Only Quit lives here for now — matches the platform-standard location
	// for that command.
	app_menu_item := NS.MenuItem_alloc()
	app_menu_item = NS.MenuItem_init(app_menu_item)
	NS.Menu_addItem(main_menu, app_menu_item)

	app_menu := NS.Menu_alloc()
	app_menu = NS.Menu_init(app_menu)
	macos_menu_append_action(app_menu, "Quit Odit", .FileQuit, action_selector)
	NS.Menu_setSubmenu(main_menu, app_menu, app_menu_item)

	for menu_def in MENUS {
		title_string := macos_nsstring(menu_def.title)
		container_item := NS.MenuItem_alloc()
		container_item = NS.MenuItem_init(container_item)
		NS.Menu_addItem(main_menu, container_item)

		submenu := NS.Menu_alloc()
		submenu = NS.Menu_initWithTitle(submenu, title_string)

		for item_def in menu_def.items {
			if item_def.action == .None {
				// Separator placeholder in `MenuItemDef` → NSMenuItem
				// `separatorItem`. AppKit draws the horizontal rule.
				NS.Menu_addItem(submenu, NS.MenuItem_separatorItem())
				continue
			}
			// Skip File > Quit — Quit already lives in the app menu, per the
			// macOS Human Interface Guidelines. Avoids a duplicate entry that
			// fires the same action twice.
			if item_def.action == .FileQuit { continue }

			macos_menu_append_action(submenu, item_def.label, item_def.action, action_selector)
		}

		NS.Menu_setSubmenu(main_menu, submenu, container_item)
	}

	NS.Application_setMainMenu(app, main_menu)
}

@(private="file")
macos_menu_append_action :: proc(parent: ^NS.Menu, label: string, action: MenuActionKind, selector: NS.SEL) {
	title := macos_nsstring(label)
	// `Menu_addItemWithTitle` allocates an NSMenuItem with the title, action
	// selector, and an empty key-equivalent — exactly what we want. The
	// returned item is owned by `parent` so we don't release it.
	empty_key := NS.AT("")
	menu_item := NS.Menu_addItemWithTitle(parent, title, selector, empty_key)
	NS.MenuItem_setTag(menu_item, NS.Integer(action))
}

// Build an NSString from a runtime Odin string. `NS.AT` only accepts
// compile-time constants, so for `menu_def.title` etc. (which come from
// arrays initialized at runtime) we go through the standard
// alloc/initWithOdinString two-step.
@(private="file")
macos_nsstring :: proc(s: string) -> ^NS.String {
	allocated := NS.String_alloc()
	return NS.String_initWithOdinString(allocated, s)
}
