// Editor binding for the Ctrl+K hover popup. Passive (doesn't
// consume input). All editor coupling flows through
// `binding.EditorAPI`.
package hover

import "vendor:sdl3"

import "../../ui"
import "../binding"

@(private="file")
BindingContext :: struct {
	state: ^State,
}

make_binding :: proc(state: ^State, allocator := context.allocator) -> binding.Binding {
	binding_context := new(BindingContext, allocator)
	binding_context.state = state
	return binding.Binding{
		name         = "hover",
		state        = rawptr(binding_context),
		passive      = true,
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Bound to Ctrl+K and the "Help on Symbol" menu item. Fires an LSP
// hover request at the active pane's cursor; the response is
// picked up by `update_via_api` next frame.
request_at_cursor_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	if api == nil { return }
	cursor := api.active_pane_cursor(api.editor)
	if !cursor.is_editor { return }

	close(state)
	if !api.lsp_request_hover(api.editor) { return }

	// Default "stickiness" range. We don't have the line text here
	// to compute the identifier span precisely, so use cursor ± 1
	// as a generous default — close enough to keep the popup open
	// while the user inspects it, tight enough to auto-close when
	// they move on.
	range_start := cursor.cursor_column
	range_end   := cursor.cursor_column
	if range_start > 0 { range_start -= 1 }
	range_end += 1
	set_anchor(state, cursor.pane_index, cursor.cursor_line, cursor.cursor_column, range_start, range_end)
}

// Called from the editor's per-frame LSP update tick. Drives
// stickiness auto-close + drains an LSP response into the popup.
update_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	if api == nil { return }

	if state.visible {
		cursor := api.active_pane_cursor(api.editor)
		cursor_state := CursorState{
			active_pane_index = cursor.pane_index,
			cursor_line       = cursor.cursor_line,
			cursor_column     = cursor.cursor_column,
			pane_is_editor    = cursor.is_editor,
		}
		if auto_close_if_cursor_moved(state, cursor_state) { return }
	}

	text, ok := api.lsp_poll_hover(api.editor, context.temp_allocator)
	if !ok { return }
	set_content(state, text)
}

@(private="file")
binding_visible :: proc(state_ptr: rawptr) -> bool {
	binding_context := cast(^BindingContext)state_ptr
	return binding_context.state.visible
}

@(private="file")
binding_destroy :: proc(state_ptr: rawptr) {
	binding_context := cast(^BindingContext)state_ptr
	destroy(binding_context.state)
	free(binding_context)
}

@(private="file")
binding_handle_event :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, event: ^sdl3.Event) -> (consumed: bool, needs_redraw: bool) {
	return false, false
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.visible { return }
	if api == nil || api.markdown_context == nil { return }

	md_ctx := api.markdown_context(api.editor, renderer)
	pa     := api.pane_anchor(api.editor, state.anchor_pane_index, state.anchor_line)
	theme  := api.theme(api.editor)

	chrome := Chrome{
		background = theme.status_bar_background,
		border     = theme.divider_color,
	}
	anchor := AnchorScreenPosition{
		cursor_screen_top_y = pa.cursor_screen_top_y,
		cursor_line_height  = pa.cursor_line_height,
		pane_left_x         = pa.pane_left_x,
		character_width     = pa.character_width,
	}
	render(state, &md_ctx, chrome, viewport_width, viewport_height, anchor)
}


