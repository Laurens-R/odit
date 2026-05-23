// Leaf package for byte-level text helpers shared by Find,
// Replace, Find-in-Files, Replace-in-Files. Pure functions —
// no editor or subpackage dependencies, so anyone in the
// `editor/` tree can import this without cycles.
package textutil

import "core:strings"
import "core:unicode/utf8"

// Glob match at the start of `text` against `pattern`. Pattern
// supports `?` (single char) and `*` (zero-or-more, non-greedy).
// `*` never crosses newlines.
// Returns:
//   consumed — number of bytes of `text` matched on success; 0 on
//              failure.
//   matched  — true on success.
glob_match_at :: proc(text: []byte, pattern: []byte) -> (consumed: int, matched: bool) {
	text_index    := 0
	pattern_index := 0
	star_text_index    := -1
	star_pattern_index := -1

	for text_index < len(text) {
		if pattern_index < len(pattern) && pattern[pattern_index] == '*' {
			star_text_index    = text_index
			star_pattern_index = pattern_index
			pattern_index += 1
			if pattern_index == len(pattern) {
				return text_index, true
			}
			continue
		}
		if pattern_index < len(pattern) {
			pattern_byte := pattern[pattern_index]
			text_byte    := text[text_index]
			if text_byte == '\n' {
				if star_pattern_index == -1 { return 0, false }
				return 0, false
			}
			if pattern_byte == '?' || pattern_byte == text_byte {
				text_index += 1
				pattern_index += 1
				if pattern_index == len(pattern) { return text_index, true }
				continue
			}
		}
		if star_pattern_index != -1 {
			star_text_index += 1
			if star_text_index > len(text) { return 0, false }
			text_index    = star_text_index
			pattern_index = star_pattern_index + 1
			if pattern_index == len(pattern) { return text_index, true }
			continue
		}
		return 0, false
	}

	for pattern_index < len(pattern) && pattern[pattern_index] == '*' { pattern_index += 1 }
	if pattern_index == len(pattern) { return text_index, true }
	return 0, false
}

// Decimal digit count for a u32 — used by code that pre-sizes
// row prefix widths without a sprintf round-trip per item.
digit_count_u32 :: proc(value: u32) -> int {
	if value == 0 { return 1 }
	count := 0
	for remaining := value; remaining > 0; remaining /= 10 { count += 1 }
	return count
}

// Strip / fold characters that would break a single-row preview.
// Skips leading indent, folds tabs to spaces, replaces control
// bytes with '?', preserves UTF-8 sequences. Output lives in
// `allocator`.
sanitize_snippet :: proc(line_bytes: []byte, allocator := context.allocator) -> string {
	leading_skip := 0
	for leading_skip < len(line_bytes) && (line_bytes[leading_skip] == ' ' || line_bytes[leading_skip] == '\t') {
		leading_skip += 1
	}
	trimmed := line_bytes[leading_skip:]

	builder: strings.Builder
	strings.builder_init(&builder, 0, len(trimmed), allocator)
	byte_index := 0
	for byte_index < len(trimmed) {
		current_byte := trimmed[byte_index]
		switch {
		case current_byte == '\t':
			strings.write_byte(&builder, ' ')
			byte_index += 1
		case current_byte == '\r' || current_byte == '\n':
			byte_index += 1
		case current_byte < 0x20 || current_byte == 0x7F:
			strings.write_byte(&builder, '?')
			byte_index += 1
		case current_byte >= 0x80:
			rune_length: int = 1
			switch {
			case current_byte < 0xC0: rune_length = 1
			case current_byte < 0xE0: rune_length = 2
			case current_byte < 0xF0: rune_length = 3
			case:                     rune_length = 4
			}
			if byte_index + rune_length > len(trimmed) { rune_length = len(trimmed) - byte_index }
			for offset in 0..<rune_length {
				strings.write_byte(&builder, trimmed[byte_index + offset])
			}
			byte_index += rune_length
		case:
			strings.write_byte(&builder, current_byte)
			byte_index += 1
		}
	}
	return strings.to_string(builder)
}

// Cell-aware right-truncate. Returns `text` unchanged when it
// already fits in `max_runes`; otherwise keeps the leading runes
// and appends "..." for a single-line row.
truncate_to_runes_with_ellipsis :: proc(text: string, max_runes: int, allocator := context.temp_allocator) -> string {
	if max_runes <= 0 { return "" }
	rune_count := utf8.rune_count_in_string(text)
	if rune_count <= max_runes { return text }
	if max_runes <= 3 {
		return strings.repeat(".", max_runes, allocator)
	}
	keep_runes := max_runes - 3
	byte_index := 0
	runes_kept := 0
	for runes_kept < keep_runes && byte_index < len(text) {
		_, byte_count := utf8.decode_rune_in_string(text[byte_index:])
		byte_index += byte_count
		runes_kept += 1
	}
	return strings.concatenate({text[:byte_index], "..."}, allocator)
}
