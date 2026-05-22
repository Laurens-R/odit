// Font loading + lifecycle for the markdown package. Headings use a true-
// bold variant at six progressively smaller sizes; body uses
// regular/bold/italic at one size; code stays monospace (re-opens the
// bundled `font.ttf` at body size).
//
// The "scale" knob lets a caller (the editor's Ctrl+Wheel zoom) blow every
// glyph size up or down by a single multiplier; the body / heading /
// code line heights stay in sync automatically.
package markdown

import "core:strings"
import "vendor:sdl3/ttf"

Fonts :: struct {
	loaded:               bool,
	// Multiplier applied to every baseline size when the fonts open.
	// Driven by the host (typically the editor's monospace font_size):
	// when the user zooms, the markdown body/heading/code fonts scale
	// proportionally so the whole reading surface grows together.
	current_scale:        f32,
	body:                 ^ttf.Font,
	body_bold:            ^ttf.Font,
	body_italic:          ^ttf.Font,
	heading:              [6]^ttf.Font,
	code:                 ^ttf.Font,
	body_line_height:     i32,
	heading_line_heights: [6]i32,
	code_line_height:     i32,
}

// Body text size. Independent of the host's monospace font_size — host
// zoom controls `current_scale` instead, which multiplies everything below.
@(private="file")
BODY_FONT_SIZE :: 16.0

// Heading sizes, indexed by level-1. H1 ≈ 1.75× body, H6 = body. The H6 =
// body size is intentional: the H6 font is still BOLD so it remains
// visually distinct from a paragraph even at the same point size.
@(private="file")
HEADING_SIZES := [6]f32{ 28, 24, 20, 18, 17, 16 }

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

// Bundled proportional font. Staged into the build output by
// `scripts/build.{sh,ps1}` (sits in `vendor/md.ttf` → next to the binary
// at runtime). When present, this trumps the system probe so the preview
// is consistent across machines. Single-file font: we point
// regular/bold/italic at it and let SDL_ttf synthesise the variants via
// BOLD / ITALIC style flags.
@(private="file")
BUNDLED_FONT_PATH :: "md.ttf"

// Baseline host font size that maps to `current_scale = 1.0`. Editors that
// use this package should drive zoom by computing
// `host_font_size / BASELINE_HOST_FONT_SIZE` and passing it to
// `fonts_apply_zoom`.
BASELINE_HOST_FONT_SIZE :: f32(16.0)

// Lazy-load every font handle. Subsequent calls are no-ops. If a handle
// can't be opened we leave it nil — the layout / render paths check and
// fall back to the host's monospace font so things degrade gracefully.
//
// Body/heading/code sizes are multiplied by `fonts.current_scale` so the
// preview keeps step with host zoom. A scale of 0 (the struct's zero
// value, never touched) is treated as 1.0.
fonts_ensure_loaded :: proc(fonts: ^Fonts) {
	if fonts.loaded { return }

	scale := fonts.current_scale
	if scale <= 0 { scale = 1.0 }
	fonts.current_scale = scale

	body_size       := BODY_FONT_SIZE * scale
	probe_size      := body_size

	bundled_probe := ttf.OpenFont(strings.clone_to_cstring(BUNDLED_FONT_PATH, context.temp_allocator), probe_size)
	use_bundled_font := bundled_probe != nil
	if bundled_probe != nil { ttf.CloseFont(bundled_probe) }

	chosen_regular_path: string
	chosen_bold_path:    string
	chosen_italic_path:  string

	if !use_bundled_font {
		// Discover which proportional triple is installed. Probe at the
		// scaled body size so a font that opens fine at default 16 px but
		// can't be sized higher (vanishingly rare) still picks correctly.
		for triple in PROPORTIONAL_FONT_CANDIDATES {
			probe := ttf.OpenFont(strings.clone_to_cstring(triple[0], context.temp_allocator), probe_size)
			if probe != nil {
				ttf.CloseFont(probe)
				chosen_regular_path = triple[0]
				chosen_bold_path    = triple[1]
				chosen_italic_path  = triple[2]
				break
			}
		}
	}

	regular_paths: []string
	bold_paths:    []string
	italic_paths:  []string
	switch {
	case use_bundled_font:
		// Single-file font: open the same file for every slot and rely on
		// the style-flag fixup below to bold/italic.
		regular_paths = []string{BUNDLED_FONT_PATH,                                       MONOSPACE_FALLBACK_PATH}
		bold_paths    = []string{BUNDLED_FONT_PATH,                                       MONOSPACE_FALLBACK_PATH}
		italic_paths  = []string{BUNDLED_FONT_PATH,                                       MONOSPACE_FALLBACK_PATH}
	case len(chosen_regular_path) > 0:
		regular_paths = []string{chosen_regular_path,                                    MONOSPACE_FALLBACK_PATH}
		bold_paths    = []string{chosen_bold_path,    chosen_regular_path,               MONOSPACE_FALLBACK_PATH}
		italic_paths  = []string{chosen_italic_path,  chosen_regular_path,               MONOSPACE_FALLBACK_PATH}
	case:
		// No proportional font found at all — fall back to the bundled
		// monospace font with style flags so we still get a usable preview.
		regular_paths = []string{MONOSPACE_FALLBACK_PATH}
		bold_paths    = []string{MONOSPACE_FALLBACK_PATH}
		italic_paths  = []string{MONOSPACE_FALLBACK_PATH}
	}

	fonts.body        = open_font_from_paths(regular_paths, body_size)
	fonts.body_bold   = open_font_from_paths(bold_paths,    body_size)
	fonts.body_italic = open_font_from_paths(italic_paths,  body_size)

	// When the bold/italic file didn't actually resolve to a true variant
	// (single-file md.ttf, or system probe found only a regular face),
	// force the style flags so the glyphs still render the way the user
	// expects.
	bold_is_synthetic   := use_bundled_font || len(chosen_bold_path)   == 0
	italic_is_synthetic := use_bundled_font || len(chosen_italic_path) == 0
	if fonts.body_bold   != nil && bold_is_synthetic   { ttf.SetFontStyle(fonts.body_bold,   {.BOLD})   }
	if fonts.body_italic != nil && italic_is_synthetic { ttf.SetFontStyle(fonts.body_italic, {.ITALIC}) }

	for level_index in 0..<6 {
		fonts.heading[level_index] = open_font_from_paths(bold_paths, HEADING_SIZES[level_index] * scale)
		if fonts.heading[level_index] != nil && bold_is_synthetic {
			ttf.SetFontStyle(fonts.heading[level_index], {.BOLD})
		}
	}

	// Code is always monospace, sized to match body.
	monospace_paths := []string{MONOSPACE_FALLBACK_PATH}
	fonts.code = open_font_from_paths(monospace_paths, body_size)

	if fonts.body != nil { fonts.body_line_height = i32(ttf.GetFontLineSkip(fonts.body)) }
	if fonts.code != nil { fonts.code_line_height = i32(ttf.GetFontLineSkip(fonts.code)) }
	for level_index in 0..<6 {
		if fonts.heading[level_index] != nil {
			fonts.heading_line_heights[level_index] = i32(ttf.GetFontLineSkip(fonts.heading[level_index]))
		}
	}

	fonts.loaded = true
}

// Public entrypoint for host zoom — recomputes scale from `host_font_size`
// and reloads handles when the value moved enough to be visible. No-op
// when the scale change is below a floating-point fuzz factor so jitter
// doesn't thrash the font system.
fonts_apply_zoom :: proc(fonts: ^Fonts, host_font_size: f32) {
	new_scale := host_font_size / BASELINE_HOST_FONT_SIZE
	if new_scale < 0.4 { new_scale = 0.4 }
	if new_scale > 4.0 { new_scale = 4.0 }

	current := fonts.current_scale; if current <= 0 { current = 1.0 }
	if abs(current - new_scale) < 0.001 { return }

	fonts_close_handles(fonts)
	fonts.current_scale = new_scale
	// ensure_loaded picks up the new scale on next render (or now, since
	// the host doesn't redraw until after this call returns).
	fonts_ensure_loaded(fonts)
}

// Lazy-load wrapper that also picks up the host's current `font_size`
// BEFORE the first load — without this, a popup opened at a zoom level
// the user reached via the keyboard before ever opening the preview would
// load at 1.0 scale instead of the host's actual size.
//
// Safe to call every frame: once `loaded` is true, this short-circuits
// (the destructive reload path lives in `fonts_apply_zoom`, which the
// host invokes only after invalidating caches).
fonts_ensure_loaded_at_host_scale :: proc(fonts: ^Fonts, host_font_size: f32) {
	if fonts.loaded {
		fonts_ensure_loaded(fonts)
		return
	}
	desired := host_font_size / BASELINE_HOST_FONT_SIZE
	if desired < 0.4 { desired = 0.4 }
	if desired > 4.0 { desired = 4.0 }
	fonts.current_scale = desired
	fonts_ensure_loaded(fonts)
}

fonts_destroy :: proc(fonts: ^Fonts) {
	fonts_close_handles(fonts)
	fonts^ = Fonts{}
}

// Close every ttf.Font handle but leave `current_scale` intact. Used by
// the zoom path (about to reload) and the final teardown (followed by
// zeroing the struct).
@(private="file")
fonts_close_handles :: proc(fonts: ^Fonts) {
	if fonts.body        != nil { ttf.CloseFont(fonts.body);        fonts.body        = nil }
	if fonts.body_bold   != nil { ttf.CloseFont(fonts.body_bold);   fonts.body_bold   = nil }
	if fonts.body_italic != nil { ttf.CloseFont(fonts.body_italic); fonts.body_italic = nil }
	for level_index in 0..<6 {
		if fonts.heading[level_index] != nil {
			ttf.CloseFont(fonts.heading[level_index])
			fonts.heading[level_index] = nil
		}
	}
	if fonts.code != nil { ttf.CloseFont(fonts.code); fonts.code = nil }
	fonts.loaded                = false
	fonts.body_line_height      = 0
	fonts.code_line_height      = 0
	for level_index in 0..<6 { fonts.heading_line_heights[level_index] = 0 }
}

// Try every font path in order. Returns the first that loads, or nil if
// none do.
@(private="file")
open_font_from_paths :: proc(paths: []string, size: f32) -> ^ttf.Font {
	for path in paths {
		c_path := strings.clone_to_cstring(path, context.temp_allocator)
		if font := ttf.OpenFont(c_path, size); font != nil { return font }
	}
	return nil
}
