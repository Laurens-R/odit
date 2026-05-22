// Package `markdown` is the reusable layout / parse / render machinery for
// markdown content. It has no editor coupling — callers feed in strings,
// receive `Block` slices they can layout against a `Context` and render
// onto an SDL renderer. Shared by the F5 markdown preview pane, the LSP
// hover popup, and the signature-help popup, all of which sit in the
// `editor` package and used to call into the same procs inside
// `markdown_preview.odin` before this split.
//
// The Context is the dependency-inversion surface — it carries the
// renderer, font handles, theme colors, and engine reference the package
// needs. Callers build one per render pass and hand it through.
package markdown

import "vendor:sdl3"
import "vendor:sdl3/ttf"

// --- Parse-tree types -----------------------------------------------------

InlineKind :: enum {
	Plain,
	Bold,
	Italic,
	Code,
	Link,
}

InlineRun :: struct {
	kind: InlineKind,
	text: string, // owned
	url:  string, // owned, only set for Link
}

BlockKind :: enum {
	BlankLine,
	Heading,
	Paragraph,
	CodeBlock,
	BlockQuote,
	ListItem,
	HorizontalRule,
}

Block :: struct {
	kind:          BlockKind,
	level:         int, // heading level 1..6
	ordered_index: int, // ListItem: 0 = unordered bullet, >0 = ordered (1-based) number
	// ListItem only: 0 = top-level. Counts the leading whitespace at parse
	// time (rounded down to 2-space units) so nested bullets indent further
	// during render.
	list_depth:    int,
	inline_runs:   [dynamic]InlineRun, // owned
}

// --- Layout cache types ---------------------------------------------------

LayoutAtom :: struct {
	text:        string,
	kind:        InlineKind,
	url:         string,
	font:        ^ttf.Font, // chosen at flatten time so layout/render measure with the same handle
	pixel_width: i32,
	is_space:    bool,
	// Pre-built `ttf.Text*` for non-space atoms — avoids a CreateText/Destroy
	// roundtrip per atom per frame. nil for whitespace atoms (never drawn).
	// Owned by the enclosing `LayoutedBlock`'s cache.
	text_object: ^ttf.Text,
}

VisualLine :: struct {
	atoms: [dynamic]LayoutAtom,
}

// One pre-split line of a fenced code block, with its pre-built `ttf.Text*`
// so the render path can reuse the same handle every frame.
CodeLine :: struct {
	text_object: ^ttf.Text, // owned by the enclosing LayoutedBlock's cache
}

// Layout cache for one block — computed once on (re)layout and held on the
// caller (typically a preview pane or popup) until the content or render
// width changes. Both the height-accumulation pass and the render pass
// walk the same cache so geometry stays in sync.
LayoutedBlock :: struct {
	block:              ^Block,
	block_default_font: ^ttf.Font,
	visual_lines:       [dynamic]VisualLine,
	height_pixels:      i32,
	// .CodeBlock only: pre-split lines + their text objects.
	code_lines:         [dynamic]CodeLine,
	// .ListItem only: pre-measured + pre-built marker glyph. Marker text
	// itself isn't stored — its contents are captured inside the Text object.
	marker_width:       i32,
	marker_text_object: ^ttf.Text, // owned by the enclosing cache
}

// --- Rendering context ----------------------------------------------------

// Per-pass dependencies threaded into layout / render. Callers build one
// per render frame; the markdown procs never look outside it. The renderer
// pointer may be nil on layout-only paths (height measurement before the
// surface is ready).
Context :: struct {
	renderer:        ^sdl3.Renderer,
	engine:          ^ttf.TextEngine,
	fonts:           ^Fonts,
	// Editor's monospace font + line height — used as a fallback when
	// `fonts.code` failed to load and as the baseline body line step when
	// `fonts.body` is missing. Keeping these out of `Fonts` lets the
	// markdown package stay agnostic to the host's editor font choice.
	monospace_font:  ^ttf.Font,
	monospace_line_height: i32,
	theme:           Theme,
}

// Color palette the renderer reads from. Callers (editor) hand us their
// theme so markdown rendering matches the surrounding UI without us having
// to know about editor-side color fields. Most callers can populate this
// once at startup and reuse the same struct every frame.
Theme :: struct {
	// Body / list-item / paragraph default foreground.
	text:               sdl3.FColor,
	// Bold inline runs.
	bold:               sdl3.FColor,
	// Italic inline runs.
	italic:             sdl3.FColor,
	// Inline `code` foreground.
	code_inline:        sdl3.FColor,
	// Inline `code` background slab.
	code_inline_bg:     sdl3.FColor,
	// Fenced ```code``` block foreground.
	code_block:         sdl3.FColor,
	// Fenced ```code``` block background slab.
	code_block_bg:      sdl3.FColor,
	// Link text + underline.
	link:               sdl3.FColor,
	// Block-quote vertical bar.
	quote_bar:          sdl3.FColor,
	// Block-quote default body color.
	quote_text:         sdl3.FColor,
	// Horizontal rule line.
	horizontal_rule:    sdl3.FColor,
	// List item bullet/number marker.
	list_marker:        sdl3.FColor,
}
