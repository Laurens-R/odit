package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"
import "../syntax"
import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
MarkdownInlineKind :: enum {
	Plain,
	Bold,
	Italic,
	Code,
	Link,
}

@(private)
MarkdownInlineRun :: struct {
	kind: MarkdownInlineKind,
	text: string, // owned
	url:  string, // owned, only set for Link
}

@(private)
MarkdownBlockKind :: enum {
	BlankLine,
	Heading,
	Paragraph,
	CodeBlock,
	BlockQuote,
	ListItem,
	HorizontalRule,
}

@(private)
MarkdownBlock :: struct {
	kind:          MarkdownBlockKind,
	level:         int, // heading level 1..6
	ordered_index: int, // ListItem: 0 = unordered bullet, >0 = ordered (1-based) number
	inline_runs:   [dynamic]MarkdownInlineRun, // owned
}

// Pane variant rendering pre-parsed markdown blocks. State is fully self-
// contained — we re-parse on every F5 rather than tracking the source pane's
// document for live updates.
@(private)
MarkdownPreviewPane :: struct {
	blocks:           [dynamic]MarkdownBlock,
	source_file_path: string, // owned, displayed in the title bar
	scroll_y:         f32,
	scroll_y_target:  f32,
	visible_lines:    u32,
}

// --- Fonts -----------------------------------------------------------------

// Proportional + monospace font handles loaded lazily for the markdown
// preview. Headings use a true-bold variant at six progressively smaller
// sizes; body uses regular/bold/italic at one size; code stays monospace
// (we re-open the bundled font.ttf at body size).
@(private)
MarkdownFonts :: struct {
	loaded:               bool,
	body:                 ^ttf.Font,
	body_bold:            ^ttf.Font,
	body_italic:          ^ttf.Font,
	heading:              [6]^ttf.Font,
	code:                 ^ttf.Font,
	body_line_height:     i32,
	heading_line_heights: [6]i32,
	code_line_height:     i32,
}

// Body text size for the preview. Independent of editor.font_size — Ctrl+Wheel
// zoom should not bleed into the preview layout.
@(private="file")
MARKDOWN_BODY_FONT_SIZE :: 16.0

// Heading sizes, indexed by level - 1. H1 ≈ 1.75× body, H6 = body. The H6 = body
// size is intentional: the H6 font is still BOLD so it remains visually distinct
// from a paragraph even at the same point size.
@(private="file")
MARKDOWN_HEADING_SIZES := [6]f32{ 28, 24, 20, 18, 17, 16 }

// Candidate proportional-font triples to try in order. First triple whose
// regular file loads is used for body, bold, italic AND all six heading
// sizes (the bold path is used for the latter).
@(private="file")
PROPORTIONAL_FONT_CANDIDATES := [?][3]string{
	// Windows
	{"C:/Windows/Fonts/arial.ttf",       "C:/Windows/Fonts/arialbd.ttf",  "C:/Windows/Fonts/ariali.ttf"},
	{"C:/Windows/Fonts/segoeui.ttf",     "C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/segoeuii.ttf"},
	{"C:/Windows/Fonts/calibri.ttf",     "C:/Windows/Fonts/calibrib.ttf", "C:/Windows/Fonts/calibrii.ttf"},
	// Linux (common distros)
	{"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf"},
	{"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",                 "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf"},
	// macOS
	{"/Library/Fonts/Arial.ttf",         "/Library/Fonts/Arial Bold.ttf",   "/Library/Fonts/Arial Italic.ttf"},
	{"/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Helvetica.ttc"},
}

@(private="file")
MONOSPACE_FALLBACK_PATH :: "font.ttf"

// Try every font path in order. Returns the first that loads, or nil if
// none do.
@(private="file")
markdown_open_font_from_paths :: proc(paths: []string, size: f32) -> ^ttf.Font {
	for path in paths {
		c_path := strings.clone_to_cstring(path, context.temp_allocator)
		if font := ttf.OpenFont(c_path, size); font != nil { return font }
	}
	return nil
}

// Lazy-load every font handle we need for the preview. Subsequent calls are
// no-ops. If a particular handle can't be opened we leave it nil — the
// renderer checks for that and falls back to the editor's monospace font, so
// the preview degrades gracefully when no proportional font is on the system.
@(private)
markdown_fonts_ensure_loaded :: proc(fonts: ^MarkdownFonts) {
	if fonts.loaded { return }

	// Discover which proportional triple is installed.
	chosen_regular_path: string
	chosen_bold_path:    string
	chosen_italic_path:  string
	for triple in PROPORTIONAL_FONT_CANDIDATES {
		probe := ttf.OpenFont(strings.clone_to_cstring(triple[0], context.temp_allocator), MARKDOWN_BODY_FONT_SIZE)
		if probe != nil {
			ttf.CloseFont(probe)
			chosen_regular_path = triple[0]
			chosen_bold_path    = triple[1]
			chosen_italic_path  = triple[2]
			break
		}
	}

	regular_paths: []string
	bold_paths:    []string
	italic_paths:  []string
	if len(chosen_regular_path) > 0 {
		regular_paths = []string{chosen_regular_path,                              MONOSPACE_FALLBACK_PATH}
		bold_paths    = []string{chosen_bold_path,    chosen_regular_path,         MONOSPACE_FALLBACK_PATH}
		italic_paths  = []string{chosen_italic_path,  chosen_regular_path,         MONOSPACE_FALLBACK_PATH}
	} else {
		// No proportional font found at all — fall back to the bundled
		// monospace font with style flags so we still get a usable preview.
		regular_paths = []string{MONOSPACE_FALLBACK_PATH}
		bold_paths    = []string{MONOSPACE_FALLBACK_PATH}
		italic_paths  = []string{MONOSPACE_FALLBACK_PATH}
	}

	fonts.body        = markdown_open_font_from_paths(regular_paths, MARKDOWN_BODY_FONT_SIZE)
	fonts.body_bold   = markdown_open_font_from_paths(bold_paths,    MARKDOWN_BODY_FONT_SIZE)
	fonts.body_italic = markdown_open_font_from_paths(italic_paths,  MARKDOWN_BODY_FONT_SIZE)

	// When the bold/italic file didn't actually resolve to a true variant
	// (i.e. we fell back to the regular path), force the style flags so the
	// glyphs still render the way the user expects.
	if fonts.body_bold != nil && len(chosen_bold_path) == 0 {
		ttf.SetFontStyle(fonts.body_bold, {.BOLD})
	}
	if fonts.body_italic != nil && len(chosen_italic_path) == 0 {
		ttf.SetFontStyle(fonts.body_italic, {.ITALIC})
	}

	for level_index in 0..<6 {
		fonts.heading[level_index] = markdown_open_font_from_paths(bold_paths, MARKDOWN_HEADING_SIZES[level_index])
		if fonts.heading[level_index] != nil && len(chosen_bold_path) == 0 {
			ttf.SetFontStyle(fonts.heading[level_index], {.BOLD})
		}
	}

	// Code is always monospace, sized to match body.
	monospace_paths := []string{MONOSPACE_FALLBACK_PATH}
	fonts.code = markdown_open_font_from_paths(monospace_paths, MARKDOWN_BODY_FONT_SIZE)

	if fonts.body        != nil { fonts.body_line_height        = i32(ttf.GetFontLineSkip(fonts.body)) }
	if fonts.code        != nil { fonts.code_line_height        = i32(ttf.GetFontLineSkip(fonts.code)) }
	for level_index in 0..<6 {
		if fonts.heading[level_index] != nil {
			fonts.heading_line_heights[level_index] = i32(ttf.GetFontLineSkip(fonts.heading[level_index]))
		}
	}

	fonts.loaded = true
}

@(private)
markdown_fonts_destroy :: proc(fonts: ^MarkdownFonts) {
	if fonts.body        != nil { ttf.CloseFont(fonts.body)        }
	if fonts.body_bold   != nil { ttf.CloseFont(fonts.body_bold)   }
	if fonts.body_italic != nil { ttf.CloseFont(fonts.body_italic) }
	for level_index in 0..<6 {
		if fonts.heading[level_index] != nil { ttf.CloseFont(fonts.heading[level_index]) }
	}
	if fonts.code != nil { ttf.CloseFont(fonts.code) }
	fonts^ = MarkdownFonts{}
}

// --- Font selection per atom / block --------------------------------------

@(private="file")
markdown_inline_font :: proc(editor: ^Editor, kind: MarkdownInlineKind, block_default_font: ^ttf.Font) -> ^ttf.Font {
	fonts := &editor.markdown_fonts
	switch kind {
	case .Plain:  if block_default_font   != nil { return block_default_font   }
	case .Bold:   if fonts.body_bold      != nil { return fonts.body_bold      }
	case .Italic: if fonts.body_italic    != nil { return fonts.body_italic    }
	case .Code:   if fonts.code           != nil { return fonts.code           }
	case .Link:   if block_default_font   != nil { return block_default_font   }
	}
	if editor.font != nil { return editor.font }
	return nil
}

@(private="file")
markdown_block_default_font :: proc(editor: ^Editor, block: ^MarkdownBlock) -> ^ttf.Font {
	fonts := &editor.markdown_fonts
	#partial switch block.kind {
	case .Heading:
		level_index := block.level - 1
		if level_index < 0 { level_index = 0 }
		if level_index > 5 { level_index = 5 }
		if fonts.heading[level_index] != nil { return fonts.heading[level_index] }
	case .CodeBlock:
		if fonts.code != nil { return fonts.code }
	}
	if fonts.body != nil { return fonts.body }
	return editor.font
}

// --- TTF measurement / drawing helpers ------------------------------------

@(private="file")
markdown_measure_text_pixels :: proc(font: ^ttf.Font, text: string) -> (width: i32, height: i32) {
	if len(text) == 0 || font == nil { return 0, 0 }
	c_text := strings.clone_to_cstring(text, context.temp_allocator)
	ttf.GetStringSize(font, c_text, 0, &width, &height)
	return
}

@(private="file")
markdown_draw_text :: proc(engine: ^ttf.TextEngine, font: ^ttf.Font, text: string, x, y: i32, color: sdl3.FColor) {
	if len(text) == 0 || font == nil || engine == nil { return }
	c_text := strings.clone_to_cstring(text, context.temp_allocator)
	text_object := ttf.CreateText(engine, font, c_text, 0)
	if text_object == nil { return }
	defer ttf.DestroyText(text_object)
	_ = ttf.SetTextColorFloat(text_object, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_object, f32(x), f32(y))
}

// --- Lifecycle -------------------------------------------------------------

@(private)
markdown_preview_pane_destroy :: proc(pane: ^MarkdownPreviewPane) {
	markdown_preview_clear_blocks(pane)
	if cap(pane.blocks) > 0 { delete(pane.blocks) }
	if len(pane.source_file_path) > 0 { delete(pane.source_file_path) }
	pane^ = MarkdownPreviewPane{}
}

@(private="file")
markdown_preview_clear_blocks :: proc(pane: ^MarkdownPreviewPane) {
	for block in pane.blocks {
		for run in block.inline_runs {
			if len(run.text) > 0 { delete(run.text) }
			if len(run.url)  > 0 { delete(run.url)  }
		}
		if cap(block.inline_runs) > 0 { delete(block.inline_runs) }
	}
	clear(&pane.blocks)
}

@(private)
markdown_preview_pane_set_content :: proc(pane: ^MarkdownPreviewPane, content_text, source_file_path: string) {
	markdown_preview_clear_blocks(pane)
	if len(pane.source_file_path) > 0 {
		delete(pane.source_file_path)
		pane.source_file_path = ""
	}
	pane.source_file_path = strings.clone(source_file_path)

	if pane.blocks == nil {
		pane.blocks = make([dynamic]MarkdownBlock, 0, 32, context.allocator)
	}
	markdown_preview_parse_into(content_text, &pane.blocks)
}

// --- F5 entry point --------------------------------------------------------

@(private)
markdown_preview_open :: proc(editor: ^Editor) {
	active_pane_index := editor.active_pane_index
	if active_pane_index < 0 || active_pane_index >= len(editor.panes) { return }
	active_pane := &editor.panes[active_pane_index]

	#partial switch &content_value in active_pane.content {
	case EditorPane:
		if !is_markdown_language(content_value.language) { return }
		markdown_fonts_ensure_loaded(&editor.markdown_fonts)
		markdown_preview_open_in_opposite(editor, active_pane_index, &content_value)
		// Preview is now in sync with the source.
		content_value.markdown_dirty = false

	case MarkdownPreviewPane:
		// F5 from the preview itself is a CLOSE — tear the preview down and
		// collapse the split so the source MD pane gets the full width back.
		// (Auto-refresh handles "keep the preview current" without the user
		// needing to mash F5.)
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
		// Edge case: a preview is open with no split (shouldn't really happen,
		// since F5 forces the split on). Just blank the pane.
		pane_destroy(&editor.panes[active_pane_index])
		editor.panes[active_pane_index].content = PaneContent{}
		editor.active_pane_index = 0
		return
	}

	// Same shape as the editor close in save_close.odin: the surviving pane
	// always ends up in pane[0], which is the canonical home for
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

	// Any markdown_dirty on the surviving source pane is now meaningless —
	// there's nothing to auto-refresh into anymore.
	if surviving := pane_as_editor(&editor.panes[0]); surviving != nil {
		surviving.markdown_dirty = false
	}
}

// Idle auto-refresh. Called from `editor_update` once per frame. For every
// EditorPane that (a) has the Markdown language, (b) has been edited since
// the last refresh, and (c) is paired with a preview in the opposite pane,
// re-parse the document into that preview — but only after a 2s pause from
// the most recent keystroke, so we don't thrash the layout mid-typing.
//
// If a source has the dirty flag set but its opposite isn't a preview (the
// user closed it), we eagerly clear the flag so it doesn't linger forever.
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
			// No counterpart preview is open — there's nothing to refresh,
			// and the next F5 will pull fresh content from the source anyway.
			source_pane.markdown_dirty = false
			continue
		}

		// Only refresh when the file is still markdown — language could have
		// changed (Save As, browser-driven retarget) since the flag was set.
		if !is_markdown_language(source_pane.language) {
			source_pane.markdown_dirty = false
			continue
		}

		// Wait until the user has actually paused. `last_keystroke_time` is
		// stamped on every key event in input.odin, so this debounces across
		// all panes, which is what we want — clicking around between panes
		// shouldn't trigger a refresh, but typing should reset the clock.
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

// --- Block parser ---------------------------------------------------------

@(private="file")
markdown_preview_parse_into :: proc(content_text: string, blocks: ^[dynamic]MarkdownBlock) {
	lines: [dynamic]string
	lines.allocator = context.temp_allocator

	remaining_content := content_text
	for {
		line, ok := strings.split_lines_iterator(&remaining_content)
		if !ok { break }
		append(&lines, line)
	}

	line_index := 0
	for line_index < len(lines) {
		current_line := lines[line_index]
		left_trimmed := strings.trim_left(current_line, " \t")

		if strings.has_prefix(left_trimmed, "```") {
			line_index += 1
			code_builder: strings.Builder
			strings.builder_init(&code_builder, 0, 128, context.temp_allocator)
			first_line := true
			for line_index < len(lines) {
				inner_line := lines[line_index]
				if strings.has_prefix(strings.trim_left(inner_line, " \t"), "```") {
					line_index += 1
					break
				}
				if !first_line { strings.write_byte(&code_builder, '\n') }
				strings.write_string(&code_builder, inner_line)
				first_line = false
				line_index += 1
			}

			runs: [dynamic]MarkdownInlineRun
			runs.allocator = context.allocator
			append(&runs, MarkdownInlineRun{kind = .Plain, text = strings.clone(strings.to_string(code_builder))})
			append(blocks, MarkdownBlock{kind = .CodeBlock, inline_runs = runs})
			continue
		}

		if len(strings.trim_space(current_line)) == 0 {
			append(blocks, MarkdownBlock{kind = .BlankLine})
			line_index += 1
			continue
		}

		if is_horizontal_rule_line(strings.trim_space(current_line)) {
			append(blocks, MarkdownBlock{kind = .HorizontalRule})
			line_index += 1
			continue
		}

		if heading_level := count_atx_heading_marker(left_trimmed); heading_level > 0 {
			heading_text := strings.trim_left(left_trimmed[heading_level:], " \t")
			heading_text  = strings.trim_right(heading_text, " #\t")
			runs := parse_inline_runs(heading_text)
			append(blocks, MarkdownBlock{kind = .Heading, level = heading_level, inline_runs = runs})
			line_index += 1
			continue
		}

		if strings.has_prefix(left_trimmed, ">") {
			quote_text := strings.trim_left(left_trimmed[1:], " \t")
			runs := parse_inline_runs(quote_text)
			append(blocks, MarkdownBlock{kind = .BlockQuote, inline_runs = runs})
			line_index += 1
			continue
		}

		if is_unordered_list_marker(left_trimmed) {
			item_text := left_trimmed[2:]
			runs := parse_inline_runs(item_text)
			append(blocks, MarkdownBlock{kind = .ListItem, ordered_index = 0, inline_runs = runs})
			line_index += 1
			continue
		}

		if ordered_value, marker_byte_length := parse_ordered_list_marker(left_trimmed); ordered_value > 0 {
			item_text := left_trimmed[marker_byte_length:]
			runs := parse_inline_runs(item_text)
			append(blocks, MarkdownBlock{kind = .ListItem, ordered_index = ordered_value, inline_runs = runs})
			line_index += 1
			continue
		}

		// Paragraph — collect consecutive non-block-starting lines and join
		// with single spaces.
		paragraph_builder: strings.Builder
		strings.builder_init(&paragraph_builder, 0, 128, context.temp_allocator)
		for line_index < len(lines) {
			inner_line     := lines[line_index]
			inner_trimmed  := strings.trim_left(inner_line, " \t")
			if len(strings.trim_space(inner_line)) == 0                     { break }
			if is_horizontal_rule_line(strings.trim_space(inner_line))      { break }
			if count_atx_heading_marker(inner_trimmed) > 0                  { break }
			if strings.has_prefix(inner_trimmed, ">")                       { break }
			if strings.has_prefix(inner_trimmed, "```")                     { break }
			if is_unordered_list_marker(inner_trimmed)                      { break }
			if ordered_value, _ := parse_ordered_list_marker(inner_trimmed); ordered_value > 0 { break }

			if strings.builder_len(paragraph_builder) > 0 { strings.write_byte(&paragraph_builder, ' ') }
			strings.write_string(&paragraph_builder, strings.trim_space(inner_line))
			line_index += 1
		}
		paragraph_text := strings.to_string(paragraph_builder)
		runs := parse_inline_runs(paragraph_text)
		append(blocks, MarkdownBlock{kind = .Paragraph, inline_runs = runs})
	}
}

@(private="file")
is_unordered_list_marker :: proc(text: string) -> bool {
	if len(text) < 2 { return false }
	if text[0] != '-' && text[0] != '*' && text[0] != '+' { return false }
	return text[1] == ' '
}

@(private="file")
count_atx_heading_marker :: proc(text: string) -> int {
	hash_count := 0
	for hash_count < len(text) && hash_count < 6 && text[hash_count] == '#' { hash_count += 1 }
	if hash_count == 0                                      { return 0 }
	if hash_count >= len(text)                              { return hash_count }
	if text[hash_count] == ' ' || text[hash_count] == '\t'  { return hash_count }
	return 0
}

@(private="file")
is_horizontal_rule_line :: proc(trimmed_text: string) -> bool {
	if len(trimmed_text) < 3 { return false }
	marker_byte := trimmed_text[0]
	if marker_byte != '-' && marker_byte != '*' && marker_byte != '_' { return false }
	marker_run_count := 0
	for byte_index in 0..<len(trimmed_text) {
		current_byte := trimmed_text[byte_index]
		if current_byte == marker_byte { marker_run_count += 1; continue }
		if current_byte == ' ' || current_byte == '\t' { continue }
		return false
	}
	return marker_run_count >= 3
}

@(private="file")
parse_ordered_list_marker :: proc(text: string) -> (parsed_value: int, byte_length: int) {
	digit_count := 0
	for digit_count < len(text) && text[digit_count] >= '0' && text[digit_count] <= '9' { digit_count += 1 }
	if digit_count == 0                  { return 0, 0 }
	if digit_count + 1 >= len(text)      { return 0, 0 }
	separator_byte := text[digit_count]
	if separator_byte != '.' && separator_byte != ')' { return 0, 0 }
	if text[digit_count + 1] != ' '       { return 0, 0 }

	accumulator := 0
	for digit_index in 0..<digit_count { accumulator = accumulator * 10 + int(text[digit_index] - '0') }
	if accumulator <= 0 { return 0, 0 }
	return accumulator, digit_count + 2
}

// --- Inline parser ---------------------------------------------------------

@(private="file")
flush_plain_run :: proc(runs: ^[dynamic]MarkdownInlineRun, source_text: string, from, to: int) {
	if to > from {
		append(runs, MarkdownInlineRun{kind = .Plain, text = strings.clone(source_text[from:to])})
	}
}

@(private="file")
parse_inline_runs :: proc(text: string) -> [dynamic]MarkdownInlineRun {
	runs: [dynamic]MarkdownInlineRun
	runs.allocator = context.allocator

	plain_start := 0
	scan_index  := 0
	text_length := len(text)

	for scan_index < text_length {
		current_byte := text[scan_index]

		// Inline code (`code`)
		if current_byte == '`' {
			closing_offset := find_inline_close(text, scan_index + 1, "`")
			if closing_offset >= 0 {
				flush_plain_run(&runs, text, plain_start, scan_index)
				code_text := text[scan_index + 1:closing_offset]
				append(&runs, MarkdownInlineRun{kind = .Code, text = strings.clone(code_text)})
				scan_index  = closing_offset + 1
				plain_start = scan_index
				continue
			}
		}

		// Bold (** or __)
		if scan_index + 1 < text_length && (current_byte == '*' || current_byte == '_') && text[scan_index + 1] == current_byte {
			marker_pair    := text[scan_index:scan_index + 2]
			closing_offset := find_inline_close(text, scan_index + 2, marker_pair)
			if closing_offset >= 0 {
				flush_plain_run(&runs, text, plain_start, scan_index)
				bold_text := text[scan_index + 2:closing_offset]
				append(&runs, MarkdownInlineRun{kind = .Bold, text = strings.clone(bold_text)})
				scan_index  = closing_offset + 2
				plain_start = scan_index
				continue
			}
		}

		// Italic (single * or _)
		if current_byte == '*' || current_byte == '_' {
			next_byte_is_same_marker := scan_index + 1 < text_length && text[scan_index + 1] == current_byte
			if !next_byte_is_same_marker {
				marker_string  := text[scan_index:scan_index + 1]
				closing_offset := find_inline_close(text, scan_index + 1, marker_string)
				if closing_offset >= 0 {
					flush_plain_run(&runs, text, plain_start, scan_index)
					italic_text := text[scan_index + 1:closing_offset]
					append(&runs, MarkdownInlineRun{kind = .Italic, text = strings.clone(italic_text)})
					scan_index  = closing_offset + 1
					plain_start = scan_index
					continue
				}
			}
		}

		// Link or image
		if current_byte == '[' || (current_byte == '!' && scan_index + 1 < text_length && text[scan_index + 1] == '[') {
			link_open_index := scan_index
			bracket_open    := scan_index
			if current_byte == '!' { bracket_open = scan_index + 1 }
			close_bracket_offset := find_inline_close(text, bracket_open + 1, "]")
			if close_bracket_offset > 0 && close_bracket_offset + 1 < text_length && text[close_bracket_offset + 1] == '(' {
				close_paren_offset := find_inline_close(text, close_bracket_offset + 2, ")")
				if close_paren_offset > 0 {
					flush_plain_run(&runs, text, plain_start, link_open_index)
					link_text_segment := text[bracket_open + 1:close_bracket_offset]
					link_url_segment  := text[close_bracket_offset + 2:close_paren_offset]
					append(&runs, MarkdownInlineRun{
						kind = .Link,
						text = strings.clone(link_text_segment),
						url  = strings.clone(link_url_segment),
					})
					scan_index  = close_paren_offset + 1
					plain_start = scan_index
					continue
				}
			}
		}

		scan_index += 1
	}

	flush_plain_run(&runs, text, plain_start, scan_index)
	return runs
}

@(private="file")
find_inline_close :: proc(text: string, search_from: int, marker: string) -> int {
	if search_from >= len(text) { return -1 }
	relative_index := strings.index(text[search_from:], marker)
	if relative_index < 0 { return -1 }
	return search_from + relative_index
}

// --- Pixel-based layout ----------------------------------------------------

@(private="file")
MarkdownLayoutAtom :: struct {
	text:        string,
	kind:        MarkdownInlineKind,
	url:         string,
	font:        ^ttf.Font, // chosen at flatten time so layout/render measure with the same handle
	pixel_width: i32,
	is_space:    bool,
}

@(private="file")
MarkdownVisualLine :: struct {
	atoms: [dynamic]MarkdownLayoutAtom,
}

// Layout cache for one block — computed once per frame and consulted by both
// the height pass and the render pass so we never disagree about geometry.
@(private="file")
LayoutedBlock :: struct {
	block:              ^MarkdownBlock,
	block_default_font: ^ttf.Font,
	visual_lines:       [dynamic]MarkdownVisualLine,
	height_pixels:      i32,
}

// Walks the inline runs once and produces width-measured atoms. Whitespace
// runs (one or more spaces / tabs) become space atoms. Code atoms keep the
// whole run as one indivisible token so a code span never breaks mid-word.
@(private="file")
flatten_runs_to_atoms_pixel :: proc(editor: ^Editor, runs: []MarkdownInlineRun, block_default_font: ^ttf.Font) -> [dynamic]MarkdownLayoutAtom {
	atoms: [dynamic]MarkdownLayoutAtom
	atoms.allocator = context.temp_allocator

	for run in runs {
		atom_font := markdown_inline_font(editor, run.kind, block_default_font)

		if run.kind == .Code {
			width_pixels, _ := markdown_measure_text_pixels(atom_font, run.text)
			append(&atoms, MarkdownLayoutAtom{
				text        = run.text,
				kind        = run.kind,
				url         = run.url,
				font        = atom_font,
				pixel_width = width_pixels,
				is_space    = false,
			})
			continue
		}

		byte_index := 0
		for byte_index < len(run.text) {
			if run.text[byte_index] == ' ' || run.text[byte_index] == '\t' {
				start_index := byte_index
				for byte_index < len(run.text) && (run.text[byte_index] == ' ' || run.text[byte_index] == '\t') { byte_index += 1 }
				whitespace_text := run.text[start_index:byte_index]
				width_pixels, _ := markdown_measure_text_pixels(atom_font, whitespace_text)
				append(&atoms, MarkdownLayoutAtom{
					text        = whitespace_text,
					kind        = run.kind,
					url         = run.url,
					font        = atom_font,
					pixel_width = width_pixels,
					is_space    = true,
				})
				continue
			}
			start_index := byte_index
			for byte_index < len(run.text) && run.text[byte_index] != ' ' && run.text[byte_index] != '\t' { byte_index += 1 }
			word_text := run.text[start_index:byte_index]
			width_pixels, _ := markdown_measure_text_pixels(atom_font, word_text)
			append(&atoms, MarkdownLayoutAtom{
				text        = word_text,
				kind        = run.kind,
				url         = run.url,
				font        = atom_font,
				pixel_width = width_pixels,
				is_space    = false,
			})
		}
	}

	return atoms
}

// Pack atoms into visual lines that fit within `max_pixel_width`. Leading
// whitespace of each line is dropped; trailing whitespace is trimmed at wrap.
@(private="file")
layout_atoms_pixel :: proc(atoms: []MarkdownLayoutAtom, max_pixel_width: i32) -> [dynamic]MarkdownVisualLine {
	visual_lines: [dynamic]MarkdownVisualLine
	visual_lines.allocator = context.temp_allocator

	current_atoms: [dynamic]MarkdownLayoutAtom
	current_atoms.allocator = context.temp_allocator
	current_width: i32 = 0

	for atom in atoms {
		if atom.is_space {
			if len(current_atoms) == 0 { continue }
			append(&current_atoms, atom)
			current_width += atom.pixel_width
			continue
		}

		if current_width + atom.pixel_width > max_pixel_width && len(current_atoms) > 0 {
			markdown_flush_visual_line(&visual_lines, &current_atoms)
			current_width = 0
		}

		append(&current_atoms, atom)
		current_width += atom.pixel_width
	}

	markdown_flush_visual_line(&visual_lines, &current_atoms)
	return visual_lines
}

@(private="file")
markdown_flush_visual_line :: proc(visual_lines: ^[dynamic]MarkdownVisualLine, current_atoms: ^[dynamic]MarkdownLayoutAtom) {
	for len(current_atoms^) > 0 && current_atoms[len(current_atoms^) - 1].is_space {
		resize(current_atoms, len(current_atoms^) - 1)
	}
	if len(current_atoms^) == 0 { return }
	line_atoms: [dynamic]MarkdownLayoutAtom
	line_atoms.allocator = context.temp_allocator
	for atom_value in current_atoms { append(&line_atoms, atom_value) }
	append(visual_lines, MarkdownVisualLine{atoms = line_atoms})
	clear(current_atoms)
}

// Lay one block out into a LayoutedBlock. Headings and code blocks have
// special height math; everything else word-wraps with the body font.
@(private="file")
layout_block :: proc(editor: ^Editor, block: ^MarkdownBlock, max_pixel_width: i32) -> LayoutedBlock {
	layouted: LayoutedBlock
	layouted.block              = block
	layouted.block_default_font = markdown_block_default_font(editor, block)

	body_line_height := editor.markdown_fonts.body_line_height
	if body_line_height <= 0 { body_line_height = editor.line_height }
	if body_line_height <= 0 { body_line_height = 16 }

	switch block.kind {
	case .BlankLine:
		layouted.height_pixels = body_line_height / 2 + 2
		return layouted

	case .HorizontalRule:
		layouted.height_pixels = body_line_height
		return layouted

	case .Heading:
		level_index := block.level - 1
		if level_index < 0 { level_index = 0 }
		if level_index > 5 { level_index = 5 }
		heading_line_height := editor.markdown_fonts.heading_line_heights[level_index]
		if heading_line_height <= 0 { heading_line_height = body_line_height + 4 }

		atoms := flatten_runs_to_atoms_pixel(editor, block.inline_runs[:], layouted.block_default_font)
		lines := layout_atoms_pixel(atoms[:], max_pixel_width)
		layouted.visual_lines = lines

		line_count := len(lines)
		if line_count == 0 { line_count = 1 }
		// Padding above + below the heading so it breathes; bottom padding
		// also leaves room for the full-width underline.
		heading_top_padding:    i32 = 8
		heading_bottom_padding: i32 = 10
		layouted.height_pixels = heading_top_padding + i32(line_count) * heading_line_height + heading_bottom_padding
		return layouted

	case .CodeBlock:
		code_text := ""
		if len(block.inline_runs) > 0 { code_text = block.inline_runs[0].text }
		code_line_count := 1
		for byte_index in 0..<len(code_text) {
			if code_text[byte_index] == '\n' { code_line_count += 1 }
		}
		code_line_height := editor.markdown_fonts.code_line_height
		if code_line_height <= 0 { code_line_height = body_line_height }
		layouted.height_pixels = i32(code_line_count) * code_line_height + 8
		return layouted

	case .Paragraph:
		atoms := flatten_runs_to_atoms_pixel(editor, block.inline_runs[:], layouted.block_default_font)
		lines := layout_atoms_pixel(atoms[:], max_pixel_width)
		layouted.visual_lines = lines
		line_count := len(lines)
		if line_count == 0 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * body_line_height + 4
		return layouted

	case .BlockQuote:
		atoms := flatten_runs_to_atoms_pixel(editor, block.inline_runs[:], layouted.block_default_font)
		quote_indent_pixels: i32 = 16
		text_max_pixels := max_pixel_width - quote_indent_pixels
		if text_max_pixels < 80 { text_max_pixels = 80 }
		lines := layout_atoms_pixel(atoms[:], text_max_pixels)
		layouted.visual_lines = lines
		line_count := len(lines)
		if line_count == 0 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * body_line_height + 2
		return layouted

	case .ListItem:
		atoms := flatten_runs_to_atoms_pixel(editor, block.inline_runs[:], layouted.block_default_font)
		marker_text       := list_marker_text(block)
		marker_width_px, _ := markdown_measure_text_pixels(layouted.block_default_font, marker_text)
		list_indent_pixels := marker_width_px + 4
		text_max_pixels := max_pixel_width - list_indent_pixels
		if text_max_pixels < 80 { text_max_pixels = 80 }
		lines := layout_atoms_pixel(atoms[:], text_max_pixels)
		layouted.visual_lines = lines
		line_count := len(lines)
		if line_count == 0 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * body_line_height
		return layouted
	}

	layouted.height_pixels = body_line_height
	return layouted
}

@(private="file")
list_marker_text :: proc(block: ^MarkdownBlock) -> string {
	if block.ordered_index <= 0 { return "• " }
	return fmt.tprintf("%d. ", block.ordered_index)
}

// --- Update / render -------------------------------------------------------

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
	markdown_fonts_ensure_loaded(&editor.markdown_fonts)

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

	// Single layout pass: each block computes once and is consulted twice
	// (height accumulation for scroll clamp, then actual paint).
	layouted_blocks: [dynamic]LayoutedBlock
	layouted_blocks.allocator = context.temp_allocator
	total_content_height := i32(0)
	for block_index in 0..<len(content.blocks) {
		block := &content.blocks[block_index]
		lb := layout_block(editor, block, usable_text_pixels)
		total_content_height += lb.height_pixels
		append(&layouted_blocks, lb)
	}

	max_scroll_pixels := total_content_height + vertical_padding * 2 - text_area_h
	if max_scroll_pixels < 0 { max_scroll_pixels = 0 }
	if content.scroll_y_target > f32(max_scroll_pixels) { content.scroll_y_target = f32(max_scroll_pixels) }
	if content.scroll_y_target < 0                      { content.scroll_y_target = 0 }
	if content.scroll_y        > f32(max_scroll_pixels) { content.scroll_y = f32(max_scroll_pixels) }
	if content.scroll_y        < 0                      { content.scroll_y = 0 }

	scroll_pixels := i32(content.scroll_y)
	current_y := text_origin_y + vertical_padding - scroll_pixels
	bottom_y  := text_origin_y + text_area_h

	for &layouted in layouted_blocks {
		block_height := layouted.height_pixels
		if current_y + block_height >= text_origin_y && current_y < bottom_y {
			markdown_render_layouted_block(editor, renderer, &layouted, text_left_x, current_y, usable_text_pixels)
		}
		current_y += block_height
		if current_y >= bottom_y { break }
	}
}

@(private="file")
markdown_render_layouted_block :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, layouted: ^LayoutedBlock, x_start, y_start, usable_text_pixels: i32) {
	block := layouted.block
	engine := editor.text_engine

	body_line_height := editor.markdown_fonts.body_line_height
	if body_line_height <= 0 { body_line_height = editor.line_height }

	switch block.kind {
	case .BlankLine:
		return

	case .HorizontalRule:
		rule_y := y_start + body_line_height / 2
		sdl3.SetRenderDrawColorFloat(renderer, editor.line_number_color.r, editor.line_number_color.g, editor.line_number_color.b, editor.line_number_color.a)
		sdl3.RenderLine(renderer, f32(x_start), f32(rule_y), f32(x_start + usable_text_pixels), f32(rule_y))
		return

	case .Heading:
		level_index := block.level - 1
		if level_index < 0 { level_index = 0 }
		if level_index > 5 { level_index = 5 }
		heading_line_height := editor.markdown_fonts.heading_line_heights[level_index]
		if heading_line_height <= 0 { heading_line_height = body_line_height + 4 }
		heading_color := markdown_heading_color(block.level)

		// Top padding pushes the first heading line away from the previous block.
		top_padding: i32 = 8
		current_y := y_start + top_padding

		for visual_line in layouted.visual_lines {
			markdown_render_visual_line(engine, renderer, editor, visual_line, x_start, current_y, heading_color)
			current_y += heading_line_height
		}

		// Full-width underline beneath the last rendered line.
		underline_y := current_y + 2
		underline_color := markdown_heading_color(block.level)
		sdl3.SetRenderDrawColorFloat(renderer, underline_color.r, underline_color.g, underline_color.b, underline_color.a)
		// Make the underline noticeable on H1/H2 (2 px), thin (1 px) on lower levels.
		thickness: i32 = block.level <= 2 ? 2 : 1
		for offset_index in 0..<thickness {
			sdl3.RenderLine(renderer, f32(x_start), f32(underline_y + offset_index), f32(x_start + usable_text_pixels), f32(underline_y + offset_index))
		}
		return

	case .CodeBlock:
		code_text := ""
		if len(block.inline_runs) > 0 { code_text = block.inline_runs[0].text }
		code_line_count := 1
		for byte_index in 0..<len(code_text) {
			if code_text[byte_index] == '\n' { code_line_count += 1 }
		}
		code_line_height := editor.markdown_fonts.code_line_height
		if code_line_height <= 0 { code_line_height = body_line_height }

		background_rectangle := sdl3.FRect{
			f32(x_start - 6),
			f32(y_start),
			f32(usable_text_pixels + 12),
			f32(code_line_count * int(code_line_height) + 8),
		}
		bg := editor.status_bar_background
		sdl3.SetRenderDrawColorFloat(renderer, bg.r, bg.g, bg.b, bg.a)
		sdl3.RenderFillRect(renderer, &background_rectangle)

		code_color := editor.syntax_keyword_foreground
		code_font  := editor.markdown_fonts.code
		if code_font == nil { code_font = editor.font }
		current_y := y_start + 4
		remaining_text := code_text
		for {
			newline_offset := strings.index_byte(remaining_text, '\n')
			line_text: string
			if newline_offset >= 0 {
				line_text     = remaining_text[:newline_offset]
				remaining_text = remaining_text[newline_offset + 1:]
			} else {
				line_text     = remaining_text
				remaining_text = ""
			}
			markdown_draw_text(engine, code_font, line_text, x_start, current_y, code_color)
			current_y += code_line_height
			if newline_offset < 0 { break }
		}
		return

	case .BlockQuote:
		quote_indent: i32 = 16
		quote_text_x := x_start + quote_indent
		bar_height_pixels: i32 = body_line_height
		if len(layouted.visual_lines) > 0 { bar_height_pixels = i32(len(layouted.visual_lines)) * body_line_height }
		bar_color := editor.line_number_color
		bar_rectangle := sdl3.FRect{f32(x_start + 4), f32(y_start), 3, f32(bar_height_pixels)}
		sdl3.SetRenderDrawColorFloat(renderer, bar_color.r, bar_color.g, bar_color.b, bar_color.a)
		sdl3.RenderFillRect(renderer, &bar_rectangle)

		quote_default_color := editor.syntax_comment_foreground
		current_y := y_start
		for visual_line in layouted.visual_lines {
			markdown_render_visual_line(engine, renderer, editor, visual_line, quote_text_x, current_y, quote_default_color)
			current_y += body_line_height
		}
		return

	case .ListItem:
		marker_text := list_marker_text(block)
		marker_font := layouted.block_default_font
		marker_color := editor.syntax_keyword_foreground
		markdown_draw_text(engine, marker_font, marker_text, x_start, y_start, marker_color)
		marker_width_px, _ := markdown_measure_text_pixels(marker_font, marker_text)
		text_left_x := x_start + marker_width_px + 4

		current_y := y_start
		for visual_line in layouted.visual_lines {
			markdown_render_visual_line(engine, renderer, editor, visual_line, text_left_x, current_y, editor.foreground_color)
			current_y += body_line_height
		}
		return

	case .Paragraph:
		current_y := y_start
		for visual_line in layouted.visual_lines {
			markdown_render_visual_line(engine, renderer, editor, visual_line, x_start, current_y, editor.foreground_color)
			current_y += body_line_height
		}
		return
	}
}

@(private="file")
markdown_render_visual_line :: proc(
	engine: ^ttf.TextEngine, renderer: ^sdl3.Renderer, editor: ^Editor,
	visual_line: MarkdownVisualLine,
	x_start, y: i32,
	default_color: sdl3.FColor,
) {
	current_x := x_start
	for atom in visual_line.atoms {
		span_pixel_width := atom.pixel_width

		if atom.is_space {
			current_x += span_pixel_width
			continue
		}

		// Inline code spans get a faint background slab so they read as code
		// against the surrounding text.
		if atom.kind == .Code {
			code_line_height := editor.markdown_fonts.code_line_height
			if code_line_height <= 0 { code_line_height = editor.line_height }
			code_bg_rectangle := sdl3.FRect{f32(current_x - 2), f32(y), f32(span_pixel_width + 4), f32(code_line_height)}
			bg := editor.status_bar_background
			sdl3.SetRenderDrawColorFloat(renderer, bg.r, bg.g, bg.b, bg.a)
			sdl3.RenderFillRect(renderer, &code_bg_rectangle)
		}

		atom_color := default_color
		switch atom.kind {
		case .Plain:  // default_color (per-block: paragraph color, quote color, etc.)
		case .Bold:   atom_color = editor.cursor_color
		case .Italic: atom_color = editor.syntax_preprocessor_foreground
		case .Code:   atom_color = editor.syntax_keyword_foreground
		case .Link:   atom_color = editor.syntax_type_foreground
		}

		markdown_draw_text(engine, atom.font, atom.text, current_x, y, atom_color)

		if atom.kind == .Link {
			body_line_height := editor.markdown_fonts.body_line_height
			if body_line_height <= 0 { body_line_height = editor.line_height }
			underline_y := y + body_line_height - 2
			sdl3.SetRenderDrawColorFloat(renderer, atom_color.r, atom_color.g, atom_color.b, atom_color.a)
			sdl3.RenderLine(renderer, f32(current_x), f32(underline_y), f32(current_x + span_pixel_width - 1), f32(underline_y))
		}

		current_x += span_pixel_width
	}
}

@(private="file")
markdown_heading_color :: proc(level: int) -> sdl3.FColor {
	switch level {
	case 1: return sdl3.FColor{0.96, 0.86, 0.60, 1.0}
	case 2: return sdl3.FColor{0.92, 0.82, 0.58, 1.0}
	case 3: return sdl3.FColor{0.86, 0.78, 0.58, 1.0}
	case 4: return sdl3.FColor{0.80, 0.74, 0.60, 1.0}
	case 5: return sdl3.FColor{0.76, 0.72, 0.62, 1.0}
	}
	return sdl3.FColor{0.72, 0.70, 0.64, 1.0}
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

// --- ui import keepalive ---------------------------------------------------

// Touch the ui package so the import doesn't drop when nothing else in this
// file references it directly — keeps `ui.Context`-shaped extensions easy.
@(private="file") _ui_keepalive := ui.Theme{}
