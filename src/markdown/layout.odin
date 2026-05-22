// Block layout — turns parsed `Block`s into measured, render-ready
// `LayoutedBlock`s. Word-wrapping happens at this stage, against a caller-
// supplied `max_pixel_width`. Caller owns the returned `LayoutedBlock`s
// and is responsible for releasing them via `clear_layouted_blocks` when
// the layout becomes stale (font reload, width change, content swap).
package markdown

import "core:fmt"
import "core:strings"
import "vendor:sdl3/ttf"

// Extra pixels added between visual lines within a Paragraph / ListItem /
// BlockQuote so body text doesn't feel cramped. Headings keep their own
// `heading_line_height` which already breathes; code blocks stay tight.
@(private="file")
LINE_LEADING_EXTRA :: 3

// Trailing space below each block — bigger gap between paragraphs / lists
// / quotes makes the document easier to scan.
PARAGRAPH_TRAILING :: 12
LIST_ITEM_TRAILING :: 6
BLOCKQUOTE_TRAILING :: 10
CODEBLOCK_TRAILING  :: 10

// How far each nesting level shifts a list item right.
LIST_DEPTH_INDENT :: 18

// Vertical step between visual lines within a body block (paragraph, list
// item, blockquote). Body font's natural line skip + a few pixels of
// leading so paragraphs aren't visually packed. Falls back through the
// font height → host monospace height → a hardcoded floor.
body_line_step :: proc(ctx: ^Context) -> i32 {
	body_line_height := ctx.fonts.body_line_height
	if body_line_height <= 0 { body_line_height = ctx.monospace_line_height }
	if body_line_height <= 0 { body_line_height = 16 }
	return body_line_height + LINE_LEADING_EXTRA
}

// Lay one block out into a `LayoutedBlock`. Headings and code blocks have
// special height math; everything else word-wraps with the body font.
// Each `^ttf.Text` allocated here is owned by the returned block and
// freed by `clear_layouted_blocks`.
//
// Callers typically maintain a `[dynamic]LayoutedBlock` and call this
// once per block when the layout cache is invalidated.
layout_block :: proc(ctx: ^Context, block: ^Block, max_pixel_width: i32) -> LayoutedBlock {
	layouted: LayoutedBlock
	layouted.block              = block
	layouted.block_default_font = block_default_font(ctx, block)

	step := body_line_step(ctx)

	switch block.kind {
	case .BlankLine:
		layouted.height_pixels = step / 2 + 2
		return layouted

	case .HorizontalRule:
		layouted.height_pixels = step
		return layouted

	case .Heading:
		level_index := block.level - 1
		if level_index < 0 { level_index = 0 }
		if level_index > 5 { level_index = 5 }
		heading_line_height := ctx.fonts.heading_line_heights[level_index]
		if heading_line_height <= 0 { heading_line_height = step + 4 }

		atoms := flatten_runs_to_atoms(ctx, block.inline_runs[:], layouted.block_default_font)
		layouted.visual_lines = layout_atoms(atoms[:], max_pixel_width)

		line_count := len(layouted.visual_lines)
		if line_count == 0 { line_count = 1 }
		// Padding above + below the heading so it breathes; bottom padding
		// also leaves room for the full-width underline.
		heading_top_padding:    i32 = 10
		heading_bottom_padding: i32 = 14
		layouted.height_pixels = heading_top_padding + i32(line_count) * heading_line_height + heading_bottom_padding
		return layouted

	case .CodeBlock:
		code_text := ""
		if len(block.inline_runs) > 0 { code_text = block.inline_runs[0].text }
		code_font := ctx.fonts.code
		if code_font == nil { code_font = ctx.monospace_font }
		code_line_height := ctx.fonts.code_line_height
		if code_line_height <= 0 { code_line_height = step }

		// Pre-split the code block into lines and pre-build a Text object
		// per line. Render replays these directly — no per-frame string
		// splitting, no per-frame CreateText.
		layouted.code_lines = make([dynamic]CodeLine, 0, 8, context.allocator)
		remaining := code_text
		for {
			newline_offset := strings.index_byte(remaining, '\n')
			line_text: string
			if newline_offset >= 0 {
				line_text = remaining[:newline_offset]
				remaining = remaining[newline_offset + 1:]
			} else {
				line_text = remaining
				remaining = ""
			}
			append(&layouted.code_lines, CodeLine{
				text_object = create_text(ctx.engine, code_font, line_text),
			})
			if newline_offset < 0 { break }
		}
		line_count := len(layouted.code_lines)
		if line_count < 1 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * code_line_height + 12 + CODEBLOCK_TRAILING
		return layouted

	case .Paragraph:
		atoms := flatten_runs_to_atoms(ctx, block.inline_runs[:], layouted.block_default_font)
		layouted.visual_lines = layout_atoms(atoms[:], max_pixel_width)
		line_count := len(layouted.visual_lines)
		if line_count == 0 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * step + PARAGRAPH_TRAILING
		return layouted

	case .BlockQuote:
		atoms := flatten_runs_to_atoms(ctx, block.inline_runs[:], layouted.block_default_font)
		quote_indent_pixels: i32 = 16
		text_max_pixels := max_pixel_width - quote_indent_pixels
		if text_max_pixels < 80 { text_max_pixels = 80 }
		layouted.visual_lines = layout_atoms(atoms[:], text_max_pixels)
		line_count := len(layouted.visual_lines)
		if line_count == 0 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * step + BLOCKQUOTE_TRAILING
		return layouted

	case .ListItem:
		atoms := flatten_runs_to_atoms(ctx, block.inline_runs[:], layouted.block_default_font)
		// Pre-measure + pre-build the marker glyph.
		marker_text := list_marker_text(block)
		marker_width_px, _ := measure_text_pixels(layouted.block_default_font, marker_text)
		layouted.marker_width       = marker_width_px
		layouted.marker_text_object = create_text(ctx.engine, layouted.block_default_font, marker_text)

		// Nested bullets get pushed right by depth × tab-ish indent. The
		// marker still sits at column 0 relative to the block's x_start
		// at render time (the render path adds the depth offset).
		depth_indent_pixels := i32(block.list_depth) * i32(LIST_DEPTH_INDENT)
		list_indent_pixels  := marker_width_px + 4
		text_max_pixels := max_pixel_width - list_indent_pixels - depth_indent_pixels
		if text_max_pixels < 80 { text_max_pixels = 80 }
		layouted.visual_lines = layout_atoms(atoms[:], text_max_pixels)
		line_count := len(layouted.visual_lines)
		if line_count == 0 { line_count = 1 }
		layouted.height_pixels = i32(line_count) * step + LIST_ITEM_TRAILING
		return layouted
	}

	layouted.height_pixels = step
	return layouted
}

// Free every `^ttf.Text` and owned dynamic array referenced by a slice of
// LayoutedBlocks, then `clear()` the slice. Idempotent. Pairs with
// `layout_block` — call this when the layout cache is invalidated (font
// reload, content swap, max width change).
clear_layouted_blocks :: proc(layouted_blocks: ^[dynamic]LayoutedBlock) {
	for layouted_index in 0..<len(layouted_blocks^) {
		layouted := &layouted_blocks[layouted_index]
		for visual_line_index in 0..<len(layouted.visual_lines) {
			visual_line := &layouted.visual_lines[visual_line_index]
			for atom_index in 0..<len(visual_line.atoms) {
				atom := &visual_line.atoms[atom_index]
				if atom.text_object != nil {
					ttf.DestroyText(atom.text_object)
					atom.text_object = nil
				}
			}
			if cap(visual_line.atoms) > 0 { delete(visual_line.atoms) }
		}
		if cap(layouted.visual_lines) > 0 { delete(layouted.visual_lines) }

		for code_line_index in 0..<len(layouted.code_lines) {
			code_line := &layouted.code_lines[code_line_index]
			if code_line.text_object != nil {
				ttf.DestroyText(code_line.text_object)
				code_line.text_object = nil
			}
		}
		if cap(layouted.code_lines) > 0 { delete(layouted.code_lines) }

		if layouted.marker_text_object != nil {
			ttf.DestroyText(layouted.marker_text_object)
			layouted.marker_text_object = nil
		}
	}
	clear(layouted_blocks)
}

// --- Font selection per atom / block --------------------------------------

@(private="file")
inline_font :: proc(ctx: ^Context, kind: InlineKind, block_default_font: ^ttf.Font) -> ^ttf.Font {
	fonts := ctx.fonts
	switch kind {
	case .Plain:  if block_default_font != nil { return block_default_font }
	case .Bold:   if fonts.body_bold    != nil { return fonts.body_bold    }
	case .Italic: if fonts.body_italic  != nil { return fonts.body_italic  }
	case .Code:   if fonts.code         != nil { return fonts.code         }
	case .Link:   if block_default_font != nil { return block_default_font }
	}
	if ctx.monospace_font != nil { return ctx.monospace_font }
	return nil
}

@(private="file")
block_default_font :: proc(ctx: ^Context, block: ^Block) -> ^ttf.Font {
	fonts := ctx.fonts
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
	return ctx.monospace_font
}

// --- Atom flattening + line packing ---------------------------------------

// Walks the inline runs once and produces width-measured atoms. Whitespace
// runs (one or more spaces / tabs) become space atoms. Code atoms keep
// the whole run as one indivisible token so a code span never breaks
// mid-word. Non-space atoms get a pre-built `^ttf.Text` so the render
// path doesn't have to CreateText/Destroy per atom per frame.
@(private="file")
flatten_runs_to_atoms :: proc(ctx: ^Context, runs: []InlineRun, block_default_font: ^ttf.Font) -> [dynamic]LayoutAtom {
	atoms: [dynamic]LayoutAtom
	// Atoms here are a scratch buffer — layout_atoms copies each one
	// (including the text_object pointer) into a per-visual-line dynamic
	// array allocated on context.allocator, after which this buffer can
	// be discarded.
	atoms.allocator = context.temp_allocator
	engine := ctx.engine

	for run in runs {
		atom_font := inline_font(ctx, run.kind, block_default_font)

		if run.kind == .Code {
			width_pixels, _ := measure_text_pixels(atom_font, run.text)
			append(&atoms, LayoutAtom{
				text        = run.text,
				kind        = run.kind,
				url         = run.url,
				font        = atom_font,
				pixel_width = width_pixels,
				is_space    = false,
				text_object = create_text(engine, atom_font, run.text),
			})
			continue
		}

		byte_index := 0
		for byte_index < len(run.text) {
			if run.text[byte_index] == ' ' || run.text[byte_index] == '\t' {
				start_index := byte_index
				for byte_index < len(run.text) && (run.text[byte_index] == ' ' || run.text[byte_index] == '\t') { byte_index += 1 }
				whitespace_text := run.text[start_index:byte_index]
				width_pixels, _ := measure_text_pixels(atom_font, whitespace_text)
				append(&atoms, LayoutAtom{
					text        = whitespace_text,
					kind        = run.kind,
					url         = run.url,
					font        = atom_font,
					pixel_width = width_pixels,
					is_space    = true,
					// Whitespace is never drawn as glyphs — leave
					// text_object nil to avoid burning a TTF text object
					// on each space run.
				})
				continue
			}
			start_index := byte_index
			for byte_index < len(run.text) && run.text[byte_index] != ' ' && run.text[byte_index] != '\t' { byte_index += 1 }
			word_text := run.text[start_index:byte_index]
			width_pixels, _ := measure_text_pixels(atom_font, word_text)
			append(&atoms, LayoutAtom{
				text        = word_text,
				kind        = run.kind,
				url         = run.url,
				font        = atom_font,
				pixel_width = width_pixels,
				is_space    = false,
				text_object = create_text(engine, atom_font, word_text),
			})
		}
	}

	return atoms
}

// Pack atoms into visual lines that fit within `max_pixel_width`. Leading
// whitespace of each line is dropped; trailing whitespace is trimmed at
// wrap. Output lives on `context.allocator` so the caller can stash it on
// its layout cache.
@(private="file")
layout_atoms :: proc(atoms: []LayoutAtom, max_pixel_width: i32) -> [dynamic]VisualLine {
	visual_lines: [dynamic]VisualLine
	visual_lines.allocator = context.allocator

	// `current_atoms` is built per visual line and then donated to the
	// line (its buffer becomes the line's atoms slice). After each flush
	// we start fresh — append on a zero-valued [dynamic] picks up the
	// context allocator.
	current_atoms: [dynamic]LayoutAtom
	current_atoms.allocator = context.allocator
	current_width: i32 = 0

	for atom in atoms {
		if atom.is_space {
			if len(current_atoms) == 0 { continue }
			append(&current_atoms, atom)
			current_width += atom.pixel_width
			continue
		}

		if current_width + atom.pixel_width > max_pixel_width && len(current_atoms) > 0 {
			flush_visual_line(&visual_lines, &current_atoms)
			current_width = 0
		}

		append(&current_atoms, atom)
		current_width += atom.pixel_width
	}

	flush_visual_line(&visual_lines, &current_atoms)
	return visual_lines
}

@(private="file")
flush_visual_line :: proc(visual_lines: ^[dynamic]VisualLine, current_atoms: ^[dynamic]LayoutAtom) {
	// Drop trailing whitespace so wraps don't leave a phantom indent on
	// the next visual line.
	for len(current_atoms^) > 0 && current_atoms[len(current_atoms^)-1].is_space {
		pop(current_atoms)
	}
	if len(current_atoms^) == 0 { return }

	// Hand the dynamic-array header (data, len, cap, allocator) over to
	// the new visual line; reset our local builder so the next line
	// allocates a fresh buffer on first append.
	donated := current_atoms^
	current_atoms^ = [dynamic]LayoutAtom{}
	current_atoms.allocator = donated.allocator
	append(visual_lines, VisualLine{atoms = donated})
}

@(private="file")
list_marker_text :: proc(block: ^Block) -> string {
	if block.ordered_index <= 0 { return "• " }
	return fmt.tprintf("%d. ", block.ordered_index)
}

// --- TTF helpers (text measurement + object creation) --------------------

@(private="file")
measure_text_pixels :: proc(font: ^ttf.Font, text: string) -> (width: i32, height: i32) {
	if len(text) == 0 || font == nil { return 0, 0 }
	c_text := strings.clone_to_cstring(text, context.temp_allocator)
	ttf.GetStringSize(font, c_text, 0, &width, &height)
	return
}

// Build a `ttf.Text*` that the layout cache will hand back to the
// renderer every frame, avoiding a CreateText/Destroy roundtrip per atom
// per frame. Callers own the returned handle and must `ttf.DestroyText`
// it on invalidation (this happens via `clear_layouted_blocks`).
@(private="file")
create_text :: proc(engine: ^ttf.TextEngine, font: ^ttf.Font, text: string) -> ^ttf.Text {
	if len(text) == 0 || font == nil || engine == nil { return nil }
	c_text := strings.clone_to_cstring(text, context.temp_allocator)
	return ttf.CreateText(engine, font, c_text, 0)
}
