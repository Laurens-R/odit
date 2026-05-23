// Editor binding for the F6 symbol picker. The symbol data itself
// lives on the editor pane (it's also consumed by syntax
// highlighting), so the editor supplies subpackage-specific
// callbacks via `Hooks` at registration time. Generic editor
// primitives still flow through `binding.EditorAPI`.
package symbols

import "base:runtime"
import "vendor:sdl3"

import "../../syntax"
import "../../ui"
import "../binding"

// Subpackage-specific callbacks the editor provides. Kept out of
// `binding.EditorAPI` because they touch types (syntax.Symbol,
// per-pane state) that aren't generic editor primitives.
Hooks :: struct {
	user_data:      rawptr,
	source_symbols: proc(user_data: rawptr) -> []syntax.Symbol,
	dialog_title:   proc(user_data: rawptr, allocator: runtime.Allocator) -> string,
	apply_activate: proc(user_data: rawptr, symbol_index: int),
}

@(private="file")
BindingContext :: struct {
	state: ^State,
	hooks: Hooks,
}

make_binding :: proc(state: ^State, hooks: Hooks, allocator := context.allocator) -> binding.Binding {
	binding_context := new(BindingContext, allocator)
	binding_context.state = state
	binding_context.hooks = hooks

	return binding.Binding{
		name         = "symbols",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Convenience used by the editor's F6 hotkey + menu entry: refresh
// the pane's symbol cache, then open the picker.
open_with_hooks :: proc(state: ^State, source_pane_index: int, symbols: []syntax.Symbol) {
	open(state, source_pane_index, symbols)
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
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return false, false }

	symbols_slice: []syntax.Symbol
	if binding_context.hooks.source_symbols != nil {
		symbols_slice = binding_context.hooks.source_symbols(binding_context.hooks.user_data)
	}
	intent, redraw := handle_event(binding_context.state, event, symbols_slice)
	if intent != nil {
		#partial switch intent_value in intent {
		case Activate:
			if binding_context.hooks.apply_activate != nil {
				binding_context.hooks.apply_activate(binding_context.hooks.user_data, intent_value.symbol_index)
			}
		}
	}
	return true, redraw
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	if !binding_context.state.visible { return }

	symbols_slice: []syntax.Symbol
	if binding_context.hooks.source_symbols != nil {
		symbols_slice = binding_context.hooks.source_symbols(binding_context.hooks.user_data)
	}

	dialog_title := "Symbols"
	if binding_context.hooks.dialog_title != nil {
		dialog_title = binding_context.hooks.dialog_title(binding_context.hooks.user_data, context.temp_allocator)
	}

	render(binding_context.state, ui_context, symbols_slice, dialog_title, viewport_width, viewport_height)
}
