package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../document"
import "../markdown"
import "../syntax"
import "../ui"

// F5 markdown preview pane. Holds the parsed block tree + layout cache;
// the layout/parse/render machinery itself lives in `src/markdown` and is
// shared with the LSP hover popup and the signature-help popup. This file
// is now just the editor-side modal glue: open / close, source ↔ preview
// pairing, idle auto-refresh, pane render orchestration, scroll input.
@(private)
MarkdownPreviewPane :: struct {
	blocks:           [dynamic]markdown.Block,
	source_file_path: string, // owned, displayed in the title bar
	scroll_y:         f32,
	scroll_y_target:  f32,
	visible_lines:    u32,
	scrollbar:        ui.Scrollbar,

	// Stashed by the renderer each frame so the scrollbar drag handler
	// can reuse the same clamp range without re-running the layout pass
	// to compute total content height.
	last_max_scroll_pixels: f32,

	// Layout cache. Owns its dynamic arrays AND every `^ttf.Text` it
	// points at (via atoms / code_lines / marker_text_object). Invalidated
	// by `markdown_preview_pane_set_content` and rebuilt lazily on the
	// next render whose `usable_text_pixels` doesn't match `layout_width`.
	layouted_blocks:  [dynamic]markdown.LayoutedBlock,
	layout_width:     i32,
}

// --- Editor-side helpers --------------------------------------------------

// Build the per-call `markdown.Context` the layout / render procs read
// from. Returns by value (small struct), with `renderer` set to the
// passed-in pointer — pass nil if you only need layout.
@(private)
editor_markdown_context :: proc(editor: ^Editor, renderer: ^sdl3.Renderer) -> markdown.Context {
	return markdown.Context{
		renderer              = renderer,
		engine                = editor.text_engine,
		fonts                 = &editor.markdown_fonts,
		monospace_font        = editor.font,
		monospace_line_height = editor.line_height,
		theme                 = editor_markdown_theme(editor),
	}
}

// Map the editor's color fields into a `markdown.Theme`. Keeping this
// proc small and in one place means changing how (say) inline code looks
// in the preview is a one-line change here — every markdown surface
// (preview, hover popup, signature help) pulls through the same mapping.
@(private)
editor_markdown_theme :: proc(editor: ^Editor) -> markdown.Theme {
	return markdown.Theme{
		text             = editor.foreground_color,
		bold             = editor.cursor_color,
		italic           = editor.syntax_preprocessor_foreground,
		code_inline      = editor.syntax_keyword_foreground,
		code_inline_bg   = editor.status_bar_background,
		code_block       = editor.syntax_keyword_foreground,
		code_block_bg    = editor.status_bar_background,
		link             = editor.syntax_type_foreground,
		quote_bar        = editor.line_number_color,
		quote_text       = editor.syntax_comment_foreground,
		horizontal_rule  = editor.line_number_color,
		list_marker     = editor.syntax_keyword_foreground,
	}
}

// Invalidate every layout cache that holds `^ttf.Text*` pointers bound to
// the markdown fonts. Called from the Ctrl+Wheel zoom path right BEFORE
// the fonts get closed + reloaded — without it, the next render would
// reach for now-freed glyph data.
@(private)
editor_invalidate_markdown_caches :: proc(editor: ^Editor) {
	for pane_index in 0..<len(editor.panes) {
		#partial switch &content_value in editor.panes[pane_index].content {
		case MarkdownPreviewPane:
			markdown.clear_layouted_blocks(&content_value.layouted_blocks)
			content_value.layout_width = 0
		}
	}
	markdown.clear_layouted_blocks(&editor.hover_popup.layouted_blocks)
	editor.hover_popup.layout_width = 0
	markdown.clear_layouted_blocks(&editor.signature_popup.doc_layouted_blocks)
	editor.signature_popup.doc_layout_width = 0
}

// --- Lifecycle ------------------------------------------------------------

@(private)
markdown_preview_pane_destroy :: proc(pane: ^MarkdownPreviewPane) {
	markdown_clear_layout_cache(pane)
	if cap(pane.layouted_blocks) > 0 { delete(pane.layouted_blocks) }
	markdown.clear_blocks(&pane.blocks)
	if cap(pane.blocks) > 0 { delete(pane.blocks) }
	if len(pane.source_file_path) > 0 { delete(pane.source_file_path) }
	pane^ = MarkdownPreviewPane{}
}

// Invalidates the layout cache and resets layout_width.
@(private="file")
markdown_clear_layout_cache :: proc(pane: ^MarkdownPreviewPane) {
	markdown.clear_layouted_blocks(&pane.layouted_blocks)
	pane.layout_width = 0
}

@(private)
markdown_preview_pane_set_content :: proc(pane: ^MarkdownPreviewPane, content_text, source_file_path: string) {
	// Invalidate the layout cache first — it holds `^ttf.Text` handles
	// that reference (string content of) the blocks we're about to
	// delete. Destroy order is independent in practice, but doing it
	// here keeps the cache's invariant "every entry's text_object is
	// alive" honest.
	markdown_clear_layout_cache(pane)

	markdown.clear_blocks(&pane.blocks)
	if len(pane.source_file_path) > 0 {
		delete(pane.source_file_path)
		pane.source_file_path = ""
	}
	pane.source_file_path = strings.clone(source_file_path)
	markdown.parse_into(content_text, &pane.blocks)
}

// --- F5 entry point -------------------------------------------------------

@(private)
markdown_preview_open :: proc(editor: ^Editor) {
	active_pane_index := editor.active_pane_index
	if active_pane_index < 0 || active_pane_index >= len(editor.panes) { return }
	active_pane := &editor.panes[active_pane_index]

	#partial switch &content_value in active_pane.content {
	case EditorPane:
		if !is_markdown_language(content_value.language) { return }
		markdown.fonts_ensure_loaded_at_host_scale(&editor.markdown_fonts, editor.font_size)
		markdown_preview_open_in_opposite(editor, active_pane_index, &content_value)
		// Preview is now in sync with the source.
		content_value.markdown_dirty = false

	case MarkdownPreviewPane:
		// F5 from the preview itself is a CLOSE — tear the preview down
		// and collapse the split so the source MD pane gets the full
		// width back. (Auto-refresh handles "keep the preview current"
		// without the user needing to mash F5.)
		markdown_preview_close_active(editor)
	}
}

// Tear down the preview pane and collapse the split, leaving the source
// editor pane as the single visible pane. Symmetric with the post-Ctrl+F4
// editor-close collapse in save_close.odin.
@(private="file")
markdown_preview_close_active :: proc(editor: ^Editor) {
	active_pane_index := editor.active_pane_index
	if active_pane_index < 0 || active_pane_index >= len(editor.panes) { return }
	if _, is_preview := editor.panes[active_pane_index].content.(MarkdownPreviewPane); !is_preview { return }

	if !editor.split_active {
		pane_destroy(&editor.panes[active_pane_index])
		editor.panes[active_pane_index].content = PaneContent{}
		editor.active_pane_index = 0
		return
	}

	// Same shape as the editor close in save_close.odin: the surviving
	// pane always ends up in pane[0], which is the canonical home for
	// single-pane mode.
	if active_pane_index == 0 {
		pane_content_destroy(&editor.panes[0].content)
		editor.panes[0].content = editor.panes[1].content
		editor.panes[1].content = PaneContent{}
		if editor.panes[1].has_saved_content {
			pane_content_destroy(&editor.panes[1].saved_content)
			editor.panes[1].saved_content   = PaneContent{}
			editor.panes[1].has_saved_content = false
		}
	} else {
		pane_destroy(&editor.panes[1])
	}

	editor.split_active      = false
	editor.active_pane_index = 0

	// Any markdown_dirty on the surviving source pane is now meaningless
	// — there's nothing to auto-refresh into anymore.
	if surviving := pane_as_editor(&editor.panes[0]); surviving != nil {
		surviving.markdown_dirty = false
	}
}

// Idle auto-refresh. Called from `editor_update` once per frame. For
// every EditorPane that (a) has the Markdown language, (b) has been
// edited since the last refresh, and (c) is paired with a preview in the
// opposite pane, re-parse the document into that preview — but only
// after a 2s pause from the most recent keystroke, so we don't thrash
// the layout mid-typing.
@(private)
markdown_preview_auto_refresh_tick :: proc(editor: ^Editor) {
	for pane_index in 0..<len(editor.panes) {
		source_pane := pane_as_editor(&editor.panes[pane_index]); if source_pane == nil { continue }
		if !source_pane.markdown_dirty { continue }

		opposite_pane_index := 1 - pane_index
		if opposite_pane_index < 0 || opposite_pane_index >= len(editor.panes) {
			source_pane.markdown_dirty = false
			continue
		}

		preview_value, is_preview := &editor.panes[opposite_pane_index].content.(MarkdownPreviewPane)
		if !is_preview {
			// No counterpart preview is open — there's nothing to
			// refresh, and the next F5 will pull fresh content from the
			// source anyway.
			source_pane.markdown_dirty = false
			continue
		}

		// Only refresh when the file is still markdown — language could
		// have changed (Save As, browser-driven retarget) since the flag
		// was set.
		if !is_markdown_language(source_pane.language) {
			source_pane.markdown_dirty = false
			continue
		}

		// Wait until the user has actually paused. `last_keystroke_time`
		// is stamped on every key event in input.odin, so this debounces
		// across all panes, which is what we want — clicking around
		// between panes shouldn't trigger a refresh, but typing should
		// reset the clock.
		if editor.clock - editor.last_keystroke_time < 2.0 { continue }

		fresh_content_text := document.document_get_text(&source_pane.document, context.temp_allocator)
		markdown_preview_pane_set_content(preview_value, fresh_content_text, source_pane.file_path)
		source_pane.markdown_dirty = false
		editor_mark_dirty(editor)
	}
}

@(private="file")
is_markdown_language :: proc(language: ^syntax.Definition) -> bool {
	if language == nil { return false }
	return language.name == "Markdown"
}

@(private="file")
markdown_preview_open_in_opposite :: proc(editor: ^Editor, source_pane_index: int, source_pane: ^EditorPane) {
	opposite_pane_index := 1 - source_pane_index
	if opposite_pane_index < 0 || opposite_pane_index >= len(editor.panes) { return }

	source_content_text := document.document_get_text(&source_pane.document, context.temp_allocator)

	if existing_preview, is_preview := &editor.panes[opposite_pane_index].content.(MarkdownPreviewPane); is_preview {
		markdown_preview_pane_set_content(existing_preview, source_content_text, source_pane.file_path)
		editor.split_active = true
		return
	}

	pane_destroy(&editor.panes[opposite_pane_index])
	new_preview: MarkdownPreviewPane
	markdown_preview_pane_set_content(&new_preview, source_content_text, source_pane.file_path)
	editor.panes[opposite_pane_index].content = new_preview
	editor.split_active = true
}

// --- Pane update + render -------------------------------------------------

@(private)
markdown_preview_pane_update :: proc(editor: ^Editor, pane: ^MarkdownPreviewPane, delta_time: f64) {
	if pane.scroll_y == pane.scroll_y_target { return }
	interpolation_factor := f32(delta_time * SCROLL_SMOOTHNESS)
	if interpolation_factor > 1.0 { interpolation_factor = 1.0 }
	pane.scroll_y += (pane.scroll_y_target - pane.scroll_y) * interpolation_factor
	if abs(pane.scroll_y_target - pane.scroll_y) < 0.5 { pane.scroll_y = pane.scroll_y_target }
	editor_mark_dirty(editor)
}

@(private)
markdown_preview_pane_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane, content: ^MarkdownPreviewPane, is_active: bool) {
	markdown.fonts_ensure_loaded_at_host_scale(&editor.markdown_fonts, editor.font_size)

	view_x := pane.rectangle.x
	view_y := pane.rectangle.y
	view_w := pane.rectangle.w
	view_h := pane.rectangle.h

	title_bar_height := editor_title_bar_height(editor)
	title_label: string
	if len(content.source_file_path) > 0 {
		title_label = fmt.tprintf("Preview — %s", markdown_filepath_base(content.source_file_path))
	} else {
		title_label = "Markdown Preview"
	}
	render_pane_title_strip(editor, renderer, view_x, view_y, view_w, title_bar_height, title_label, is_active)

	text_origin_y := view_y + title_bar_height
	text_area_h   := view_h - title_bar_height
	if text_area_h < editor.line_height { text_area_h = editor.line_height }

	body_line_height := editor.markdown_fonts.body_line_height
	if body_line_height <= 0 { body_line_height = editor.line_height }
	content.visible_lines = u32(text_area_h / body_line_height)
	if content.visible_lines == 0 { content.visible_lines = 1 }

	clip_rectangle := sdl3.Rect{view_x, text_origin_y, view_w, text_area_h}
	sdl3.SetRenderClipRect(renderer, &clip_rectangle)
	defer sdl3.SetRenderClipRect(renderer, nil)

	horizontal_padding: i32 = 18
	vertical_padding:   i32 = 12
	text_left_x := view_x + horizontal_padding
	usable_text_pixels := view_w - horizontal_padding * 2
	if usable_text_pixels < 100 { usable_text_pixels = 100 }

	md_ctx := editor_markdown_context(editor, renderer)

	// Lay out only when the cache is stale: usable width changed, the
	// block count drifted from the cache, or the cache is empty
	// (post-set_content). Idle re-renders (cursor blink, mouse motion)
	// hit the fast path and reuse the previous frame's measurements +
	// Text objects unchanged.
	cache_is_stale := content.layout_width != usable_text_pixels ||
	                  len(content.layouted_blocks) != len(content.blocks)
	if cache_is_stale {
		markdown_clear_layout_cache(content)
		if cap(content.layouted_blocks) < len(content.blocks) {
			if cap(content.layouted_blocks) > 0 { delete(content.layouted_blocks) }
			content.layouted_blocks = make([dynamic]markdown.LayoutedBlock, 0, len(content.blocks), context.allocator)
		}
		for block_index in 0..<len(content.blocks) {
			block := &content.blocks[block_index]
			append(&content.layouted_blocks, markdown.layout_block(&md_ctx, block, usable_text_pixels))
		}
		content.layout_width = usable_text_pixels
	}

	total_content_height := i32(0)
	for layouted in content.layouted_blocks {
		total_content_height += layouted.height_pixels
	}

	max_scroll_pixels := total_content_height + vertical_padding * 2 - text_area_h
	if max_scroll_pixels < 0 { max_scroll_pixels = 0 }
	content.last_max_scroll_pixels = f32(max_scroll_pixels)
	if content.scroll_y_target > f32(max_scroll_pixels) { content.scroll_y_target = f32(max_scroll_pixels) }
	if content.scroll_y_target < 0                      { content.scroll_y_target = 0 }
	if content.scroll_y        > f32(max_scroll_pixels) { content.scroll_y = f32(max_scroll_pixels) }
	if content.scroll_y        < 0                      { content.scroll_y = 0 }

	scroll_pixels := i32(content.scroll_y)
	current_y := text_origin_y + vertical_padding - scroll_pixels
	bottom_y  := text_origin_y + text_area_h

	for layouted_index in 0..<len(content.layouted_blocks) {
		layouted := &content.layouted_blocks[layouted_index]
		block_height := layouted.height_pixels
		if current_y + block_height >= text_origin_y && current_y < bottom_y {
			markdown.render_layouted_block(&md_ctx, layouted, text_left_x, current_y, usable_text_pixels)
		}
		current_y += block_height
		if current_y >= bottom_y { break }
	}

	// Scrollbar — same shape as the editor pane's: 6px normally, 14px
	// on hover/drag. Track + thumb rectangles get saved back to
	// `content.scrollbar` so the mouse handlers can hit-test them next
	// frame.
	{
		full_content_height := f32(total_content_height + vertical_padding * 2)
		viewport_height_f   := f32(text_area_h)
		ui_context := editor_make_ui_context(editor, renderer)
		theme := ui.default_theme()
		ui.scrollbar_render(&ui_context, &content.scrollbar, view_x + view_w - 2, text_origin_y, text_area_h,
			viewport_height_f, full_content_height, content.scroll_y, theme)
	}
}

@(private="file")
markdown_filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

// --- Input ----------------------------------------------------------------

@(private)
markdown_preview_pane_scroll :: proc(editor: ^Editor, pane: ^MarkdownPreviewPane, line_delta: i32) {
	body_line_height := editor.markdown_fonts.body_line_height
	if body_line_height <= 0 { body_line_height = editor.line_height }
	if body_line_height <= 0 { return }
	new_target := pane.scroll_y_target + f32(line_delta * body_line_height)
	if new_target < 0 { new_target = 0 }
	pane.scroll_y_target = new_target
}

@(private)
markdown_preview_handle_key :: proc(editor: ^Editor, content: ^MarkdownPreviewPane, event: ^sdl3.Event) {
	if event.type != .KEY_DOWN { return }
	switch event.key.key {
	case sdl3.K_UP:       markdown_preview_pane_scroll(editor, content, -1)
	case sdl3.K_DOWN:     markdown_preview_pane_scroll(editor, content, +1)
	case sdl3.K_PAGEUP:
		step := i32(content.visible_lines)
		if step > 1 { step -= 1 }
		if step < 1 { step = 1 }
		markdown_preview_pane_scroll(editor, content, -step)
	case sdl3.K_PAGEDOWN:
		step := i32(content.visible_lines)
		if step > 1 { step -= 1 }
		if step < 1 { step = 1 }
		markdown_preview_pane_scroll(editor, content, +step)
	case sdl3.K_HOME:
		content.scroll_y_target = 0
	case sdl3.K_END:
		content.scroll_y_target = 1e9 // renderer clamps to the actual max
	}
}
