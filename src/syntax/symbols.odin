package syntax

import "core:strings"

// One identifier or operator chunk extracted from a line of source. Strings,
// comments, and whitespace are skipped during extraction so symbol matching
// doesn't pick up identifiers inside `"strings"` or `// comments`. `line` and
// `is_first_on_line` are populated so the matcher can run across a whole
// file without losing location info or the `{NOTHING}` start-of-line anchor.
@(private = "file")
Lexeme :: struct {
	text:             string, // slice into the input line
	start:            int, // byte offset within `line`
	line:             u32, // 0-based source line index
	is_first_on_line: bool,
}

// Walk `line` and extract identifiers and operator-runs, skipping strings,
// line comments, and (single-line) block comments. Output is allocated from
// `allocator`. Each emitted lexeme is stamped with `line_index`; the first
// lexeme of each call gets `is_first_on_line = true`.
@(private = "file")
extract_lexemes :: proc(
	language_definition: ^Definition,
	line: string,
	line_index: u32,
	allocator := context.temp_allocator,
) -> []Lexeme {
	output_lexemes := make([dynamic]Lexeme, 0, 16, allocator)
	line_length := len(line)
	character_index := 0
	is_first_lexeme_on_line := true

	for character_index < line_length {
		// Skip whitespace. \n / \r / \t shouldn't appear in a clean per-line
		// buffer, but we accept them defensively (CRLF strays, embedded LFs
		// from buffer joins, vertical tabs, form feeds) so they never sneak
		// into a multi-op lexeme.
		for character_index < line_length && is_lex_whitespace(line[character_index]) { character_index += 1 }
		if character_index >= line_length { break }

		// Line comment → rest of line is dead to us.
		if len(language_definition.line_comment) > 0 && lex_match_at(line, character_index, language_definition.line_comment) {
			break
		}

		// Block comment — skip to matching end on this line; if none, give up.
		if len(language_definition.block_comment_start) > 0 && lex_match_at(line, character_index, language_definition.block_comment_start) {
			remaining_line := line[character_index + len(language_definition.block_comment_start):]
			end_marker_offset := strings.index(remaining_line, language_definition.block_comment_end)
			if end_marker_offset < 0 { break }
			character_index = character_index + len(language_definition.block_comment_start) + end_marker_offset + len(language_definition.block_comment_end)
			continue
		}

		current_character := line[character_index]

		// String literal — opaque to symbol extraction.
		if current_character == '"' || current_character == '\'' || current_character == '`' {
			quote_character := current_character
			next_character_index := character_index + 1
			for next_character_index < line_length {
				if line[next_character_index] == '\\' && next_character_index + 1 < line_length { next_character_index += 2; continue }
				if line[next_character_index] == quote_character { next_character_index += 1; break }
				next_character_index += 1
			}
			character_index = next_character_index
			continue
		}

		// Identifier or number (treated identically for lexeme purposes).
		if is_lex_word_char(current_character) {
			next_character_index := character_index + 1
			for next_character_index < line_length && is_lex_word_char(line[next_character_index]) { next_character_index += 1 }
			append(
				&output_lexemes,
				Lexeme{text = line[character_index:next_character_index], start = character_index, line = line_index, is_first_on_line = is_first_lexeme_on_line},
			)
			is_first_lexeme_on_line = false
			character_index = next_character_index
			continue
		}

		// Single-char punctuation gets its own lexeme so patterns can match
		// `(`/`)`/`{`/etc. individually.
		if is_lex_single_op(current_character) {
			append(
				&output_lexemes,
				Lexeme{text = line[character_index:character_index + 1], start = character_index, line = line_index, is_first_on_line = is_first_lexeme_on_line},
			)
			is_first_lexeme_on_line = false
			character_index += 1
			continue
		}

		// Multi-char operator run (e.g. `::`, `:=`, `==`, `=>`, `<=`).
		next_character_index := character_index + 1
		for next_character_index < line_length {
			next_character := line[next_character_index]
			if is_lex_whitespace(next_character) { break }
			if is_lex_word_char(next_character) || is_lex_single_op(next_character) { break }
			if next_character == '"' || next_character == '\'' || next_character == '`' { break }
			if len(language_definition.line_comment) > 0 && lex_match_at(line, next_character_index, language_definition.line_comment) { break }
			if len(language_definition.block_comment_start) > 0 &&
			   lex_match_at(line, next_character_index, language_definition.block_comment_start) { break }
			next_character_index += 1
		}
		append(
			&output_lexemes,
			Lexeme{text = line[character_index:next_character_index], start = character_index, line = line_index, is_first_on_line = is_first_lexeme_on_line},
		)
		is_first_lexeme_on_line = false
		character_index = next_character_index
	}

	return output_lexemes[:]
}

@(private = "file")
lex_match_at :: proc(text: string, character_index: int, prefix: string) -> bool {
	if character_index + len(prefix) > len(text) { return false }
	return text[character_index:character_index + len(prefix)] == prefix
}

@(private = "file")
is_lex_word_char :: proc(character_value: u8) -> bool {
	return(
		(character_value >= 'a' && character_value <= 'z') ||
		(character_value >= 'A' && character_value <= 'Z') ||
		character_value == '_' ||
		(character_value >= '0' && character_value <= '9') ||
		character_value >= 0x80 \
	)
}

@(private = "file")
is_lex_whitespace :: proc(character_value: u8) -> bool {
	return character_value == ' ' || character_value == '\t' || character_value == '\r' || character_value == '\n' || character_value == 0x0B || character_value == 0x0C
}

// Linear membership test for the short scope_start / scope_end lists. With
// typical input these are 1-3 entries so a hash map would be overkill.
@(private="file")
slice_contains :: proc(string_set: []string, query_string: string) -> bool {
	for set_string in string_set { if set_string == query_string { return true } }
	return false
}

@(private = "file")
is_lex_single_op :: proc(character_value: u8) -> bool {
	return(
		character_value == '(' ||
		character_value == ')' ||
		character_value == '[' ||
		character_value == ']' ||
		character_value == '{' ||
		character_value == '}' ||
		character_value == ',' ||
		character_value == ';' \
	)
}

@(private = "file")
is_identifier_lex :: proc(lexeme_text: string) -> bool {
	if len(lexeme_text) == 0 { return false }
	first_character := lexeme_text[0]
	return (first_character >= 'a' && first_character <= 'z') || (first_character >= 'A' && first_character <= 'Z') || first_character == '_' || first_character >= 0x80
}

// Match the language's symbol patterns against the WHOLE-FILE lexeme stream
// derived from `lines`, and append captured symbols to `output_symbols`. The
// symbol's name string is cloned with `name_allocator`, so the caller owns
// it.
//
// Pattern matching is greedy from left to right: at each lexeme position, try
// every pattern in order; on the first match, advance past the matched run.
// List more specific patterns first when they overlap.
//
// Newlines are transparent to the matcher: a pattern like
// `template ... class {NAME}` matches even when the `template<...>` clause
// and the `class Foo {` body live on different source lines. `{NOTHING}`
// anchors to the first lexeme on its line, which is exactly the right
// semantics in a multi-line world.
//
// Brace depth is precomputed once across the whole stream and the captured
// symbol records the depth at the lexeme of its name — so a function header
// like `foo :: proc() {` lands at the depth BEFORE the `{`, while symbols
// inside the body land one level deeper.
//
// `known_types` is consulted by the `{TYPE}` placeholder. Pass `nil` when no
// type set is available (the placeholder then falls back to the language's
// built-in `types` list only).
extract_symbols_from_lines :: proc(
	language_definition: ^Definition,
	lines: []string,
	output_symbols: ^[dynamic]Symbol,
	known_types: ^map[string]bool = nil,
	name_allocator := context.allocator,
) {
	if language_definition == nil { return }

	// Build a single lexeme stream spanning every line in the file. Each
	// lexeme carries its source line and a flag for whether it was the
	// first non-whitespace token on that line, so `{NOTHING}` keeps working.
	all_lexemes_dynamic := make([dynamic]Lexeme, 0, len(lines) * 8, context.temp_allocator)
	for line_text, line_index in lines {
		per_line_lexemes := extract_lexemes(language_definition, line_text, u32(line_index))
		for lexeme in per_line_lexemes { append(&all_lexemes_dynamic, lexeme) }
	}

	lexemes := all_lexemes_dynamic[:]
	lexeme_count := len(lexemes)

	// Precompute, in a single pass:
	//   * `depths_at_lexeme[k]` — scope-nesting depth in effect BEFORE lex k.
	//   * `is_barrier_lexeme[k]` — whether lex k is something the `...`
	//     ellipsis must not cross (scope-open / scope-close tokens plus
	//     the universal statement-separator `;`).
	// Both tables are independent of pattern matching, so patterns that
	// consume a scope-open lex (e.g. Bash's `NAME ( ) {`) still nest
	// subsequent symbols correctly.
	depths_at_lexeme  := make([]i32,  lexeme_count + 1, context.temp_allocator)
	is_barrier_lexeme := make([]bool, lexeme_count,     context.temp_allocator)
	current_depth := i32(0)
	for lexeme_position in 0 ..< lexeme_count {
		depths_at_lexeme[lexeme_position] = current_depth
		current_text := lexemes[lexeme_position].text
		is_scope_open  := slice_contains(language_definition.scope_start, current_text)
		is_scope_close := !is_scope_open && slice_contains(language_definition.scope_end, current_text)
		// Avoid double-counting a `Sub`/`Class`/etc. that follows an `End`
		// keyword: in VB-style languages the close token leads the pair, so
		// the next lexeme would otherwise re-open immediately.
		if is_scope_open && lexeme_position > 0 && slice_contains(language_definition.scope_end, lexemes[lexeme_position-1].text) {
			is_scope_open = false
		}
		if is_scope_open  { current_depth += 1 }
		if is_scope_close { current_depth -= 1; if current_depth < 0 { current_depth = 0 } }
		is_barrier_lexeme[lexeme_position] = is_scope_open || is_scope_close || current_text == ";"
	}
	depths_at_lexeme[lexeme_count] = current_depth

	if len(language_definition.symbol_patterns) == 0 { return }

	current_lexeme_index := 0
	for current_lexeme_index < lexeme_count {
		any_pattern_matched := false
		for &pattern in language_definition.symbol_patterns {
			pattern_matched, name_lexeme_index, end_position := try_match_pattern(
				pattern.tokens,
				lexemes,
				is_barrier_lexeme,
				current_lexeme_index,
				language_definition,
				known_types,
				-1,
			)
			if !pattern_matched { continue }

			captured_lexeme := lexemes[name_lexeme_index]
			symbol_depth := depths_at_lexeme[name_lexeme_index]
			if symbol_depth < 0 { symbol_depth = 0 }
			if symbol_depth > 255 { symbol_depth = 255 }
			append(
				output_symbols,
				Symbol {
					name = strings.clone(captured_lexeme.text, name_allocator),
					kind = pattern.kind,
					line = captured_lexeme.line,
					column = u32(captured_lexeme.start),
					depth = u8(symbol_depth),
				},
			)
			step_amount := end_position - current_lexeme_index
			if step_amount < 1 { step_amount = 1 }	// safety: never stall on a zero-width-only pattern
			current_lexeme_index += step_amount
			any_pattern_matched = true
			break
		}
		if !any_pattern_matched { current_lexeme_index += 1 }
	}
}

// Try to match the remaining `tokens` against `lexemes` starting at lex
// index `start_index`. Returns the captured-name index (an absolute lex
// index) and the absolute lex position one past the matched run.
//
// The matcher is recursive only to backtrack across `...`: an ellipsis tries
// the shortest possible run first (zero lexemes), and if the tail fails it
// retries with one more lexeme consumed, and so on. Patterns are tiny so
// recursion depth is bounded by the number of ellipses in the pattern.
//
// A pattern with no `{NAME}` token never matches — without a capture there is
// no symbol to record.
@(private = "file")
try_match_pattern :: proc(
	tokens: []PatternToken,
	lexemes: []Lexeme,
	is_barrier_lexeme: []bool,
	start_index: int,
	language_definition: ^Definition,
	known_types: ^map[string]bool,
	incoming_name_index: int,
) -> (
	matched: bool,
	name_lexeme_index: int,
	end_position: int,
) {
	current_lex_index := start_index
	captured_name_index := incoming_name_index

	for token_index in 0 ..< len(tokens) {
		current_token := tokens[token_index]

		if current_token.kind == .Ellipsis {
			// Non-greedy: try the tail starting at p, then p+1, then p+2, …
			// First match wins. `skip_count == 0` covers an empty run (the
			// ellipsis matches nothing and we splice straight into the tail).
			//
			// Bounded by statement-barrier lexemes (`{`, `}`, `;`): the
			// ellipsis is allowed to STOP at one (so a pattern ending in
			// `{` still matches) but never to CROSS one. Without this,
			// whole-file matching lets a pattern like
			// `{NOTHING} ... class {NAME}` reach forward past method
			// bodies, swallow `RestoreBackupAsync(...)` along the way, and
			// capture a class declared dozens of lines later — leaving
			// nothing for the function pattern to match here.
			tail_tokens := tokens[token_index + 1:]
			for skip_count in 0 ..= (len(lexemes) - current_lex_index) {
				recursive_matched, recursive_name_index, recursive_end_position := try_match_pattern(
					tail_tokens,
					lexemes,
					is_barrier_lexeme,
					current_lex_index + skip_count,
					language_definition,
					known_types,
					captured_name_index,
				)
				if recursive_matched { return true, recursive_name_index, recursive_end_position }
				if current_lex_index + skip_count >= len(lexemes) { break }
				if is_barrier_lexeme[current_lex_index + skip_count] { break }
			}
			return false, -1, current_lex_index
		}

		if current_token.kind == .Optional {
			// Try the inner sub-token; on failure the wrapper is a
			// zero-width no-op. The inner may itself be a nested operator
			// (e.g. an OPTION alternation) — `match_single_token` handles
			// that uniformly.
			if current_token.inner_token != nil {
				inner_matched, consumed_count := match_single_token(
					current_token.inner_token^,
					lexemes,
					current_lex_index,
					language_definition,
					known_types,
					&captured_name_index,
				)
				if inner_matched { current_lex_index += consumed_count }
			}
			continue
		}

		if current_token.kind == .Not {
			// Zero-width negative lookahead: fail the pattern if the inner
			// would match here. Pass a dummy name_idx so probes like
			// `{NOT:NAME}` don't accidentally capture the lexeme we're
			// rejecting.
			if current_token.inner_token != nil {
				dummy_name_index: int = -1
				inner_matched, _ := match_single_token(current_token.inner_token^, lexemes, current_lex_index, language_definition, known_types, &dummy_name_index)
				if inner_matched { return false, -1, current_lex_index }
			}
			continue
		}

		token_matched, consumed_count := match_single_token(current_token, lexemes, current_lex_index, language_definition, known_types, &captured_name_index)
		if !token_matched { return false, -1, current_lex_index }
		current_lex_index += consumed_count
	}

	if captured_name_index < 0 { return false, -1, current_lex_index }
	return true, captured_name_index, current_lex_index
}

// Try to match a single PatternToken (anything except top-level Ellipsis,
// Optional, or Not, which the outer matcher handles inline) at lex index
// `lex_position`. Returns whether it matched and how many lexemes were
// consumed (0 for zero-width Nothing, 1 otherwise). On success for .Name,
// updates `name_index_pointer^` with the absolute lex index of the captured
// identifier.
@(private = "file")
match_single_token :: proc(
	pattern_token: PatternToken,
	lexemes: []Lexeme,
	lex_position: int,
	language_definition: ^Definition,
	known_types: ^map[string]bool,
	name_index_pointer: ^int,
) -> (
	matched: bool,
	consumed: int,
) {
	switch pattern_token.kind {
	case .Nothing:
		// Zero-width anchor: succeeds only when the current lexeme is the
		// first non-whitespace token on its source line. With a whole-file
		// lexeme stream this is how "start of line" is expressed.
		if lex_position >= len(lexemes) || !lexemes[lex_position].is_first_on_line { return false, 0 }
		return true, 0

	case .Literal:
		if lex_position >= len(lexemes) || lexemes[lex_position].text != pattern_token.text { return false, 0 }
		return true, 1

	case .Name:
		if lex_position >= len(lexemes) { return false, 0 }
		candidate_text := lexemes[lex_position].text
		if !is_identifier_lex(candidate_text) { return false, 0 }
		for keyword in language_definition.keywords { if keyword == candidate_text { return false, 0 } }
		name_index_pointer^ = lex_position
		return true, 1

	case .Type:
		if lex_position >= len(lexemes) { return false, 0 }
		candidate_text := lexemes[lex_position].text
		if !is_identifier_lex(candidate_text) { return false, 0 }
		is_known_type := false
		for type_name in language_definition.types { if type_name == candidate_text { is_known_type = true; break } }
		if !is_known_type && known_types != nil {
			if _, exists_in_known_types := known_types[candidate_text]; exists_in_known_types { is_known_type = true }
		}
		if !is_known_type { return false, 0 }
		return true, 1

	case .Any:
		if lex_position >= len(lexemes) { return false, 0 }
		return true, 1

	case .Ellipsis:
		// Ellipsis as a single token (i.e. inside {OPTIONAL:...}) is
		// redundant — the outer ellipsis would already consume any run —
		// so treat it as a zero-width "always succeeds" no-op.
		return true, 0

	case .Option:
		// Mandatory alternation. Try each alternative in source order;
		// the first hit wins and we forward its consume count.
		for alternative_token in pattern_token.alternatives {
			alternative_matched, alternative_consumed_count := match_single_token(
				alternative_token,
				lexemes,
				lex_position,
				language_definition,
				known_types,
				name_index_pointer,
			)
			if alternative_matched { return true, alternative_consumed_count }
		}
		return false, 0

	case .Optional, .Not:
		// These wrap a sub-token and are handled by the outer matcher.
		// Calling them as a single-token slot has no meaningful semantics,
		// so refuse.
		return false, 0
	}
	return false, 0
}
