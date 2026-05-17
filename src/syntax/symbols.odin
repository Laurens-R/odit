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
// `allocator`. Each emitted lexeme is stamped with `line_idx`; the first
// lexeme of each call gets `is_first_on_line = true`.
@(private = "file")
extract_lexemes :: proc(
	def: ^Definition,
	line: string,
	line_idx: u32,
	allocator := context.temp_allocator,
) -> []Lexeme {
	out := make([dynamic]Lexeme, 0, 16, allocator)
	line_length := len(line)
	character_index := 0
	first := true

	for character_index < line_length {
		// Skip whitespace. \n / \r / \t shouldn't appear in a clean per-line
		// buffer, but we accept them defensively (CRLF strays, embedded LFs
		// from buffer joins, vertical tabs, form feeds) so they never sneak
		// into a multi-op lexeme.
		for character_index < line_length && is_lex_whitespace(line[character_index]) {character_index += 1}
		if character_index >= line_length {break}

		// Line comment → rest of line is dead to us.
		if len(def.line_comment) > 0 && lex_match_at(line, character_index, def.line_comment) {
			break
		}

		// Block comment — skip to matching end on this line; if none, give up.
		if len(def.block_comment_start) > 0 && lex_match_at(line, character_index, def.block_comment_start) {
			rest := line[character_index + len(def.block_comment_start):]
			end_off := strings.index(rest, def.block_comment_end)
			if end_off < 0 {break}
			character_index = character_index + len(def.block_comment_start) + end_off + len(def.block_comment_end)
			continue
		}

		current_character := line[character_index]

		// String literal — opaque to symbol extraction.
		if current_character == '"' || current_character == '\'' || current_character == '`' {
			quote := current_character
			next_character_index := character_index + 1
			for next_character_index < line_length {
				if line[next_character_index] == '\\' && next_character_index + 1 < line_length {next_character_index += 2; continue}
				if line[next_character_index] == quote {next_character_index += 1; break}
				next_character_index += 1
			}
			character_index = next_character_index
			continue
		}

		// Identifier or number (treated identically for lexeme purposes).
		if is_lex_word_char(current_character) {
			next_character_index := character_index + 1
			for next_character_index < line_length && is_lex_word_char(line[next_character_index]) {next_character_index += 1}
			append(
				&out,
				Lexeme{text = line[character_index:next_character_index], start = character_index, line = line_idx, is_first_on_line = first},
			)
			first = false
			character_index = next_character_index
			continue
		}

		// Single-char punctuation gets its own lexeme so patterns can match
		// `(`/`)`/`{`/etc. individually.
		if is_lex_single_op(current_character) {
			append(
				&out,
				Lexeme{text = line[character_index:character_index + 1], start = character_index, line = line_idx, is_first_on_line = first},
			)
			first = false
			character_index += 1
			continue
		}

		// Multi-char operator run (e.g. `::`, `:=`, `==`, `=>`, `<=`).
		next_character_index := character_index + 1
		for next_character_index < line_length {
			next_character := line[next_character_index]
			if is_lex_whitespace(next_character) {break}
			if is_lex_word_char(next_character) || is_lex_single_op(next_character) {break}
			if next_character == '"' || next_character == '\'' || next_character == '`' {break}
			if len(def.line_comment) > 0 && lex_match_at(line, next_character_index, def.line_comment) {break}
			if len(def.block_comment_start) > 0 &&
			   lex_match_at(line, next_character_index, def.block_comment_start) {break}
			next_character_index += 1
		}
		append(
			&out,
			Lexeme{text = line[character_index:next_character_index], start = character_index, line = line_idx, is_first_on_line = first},
		)
		first = false
		character_index = next_character_index
	}

	return out[:]
}

@(private = "file")
lex_match_at :: proc(s: string, i: int, prefix: string) -> bool {
	if i + len(prefix) > len(s) {return false}
	return s[i:i + len(prefix)] == prefix
}

@(private = "file")
is_lex_word_char :: proc(c: u8) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		c == '_' ||
		(c >= '0' && c <= '9') ||
		c >= 0x80 \
	)
}

@(private = "file")
is_lex_whitespace :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 0x0B || c == 0x0C
}

// Linear membership test for the short scope_start / scope_end lists. With
// typical input these are 1-3 entries so a hash map would be overkill.
@(private="file")
slice_contains :: proc(set: []string, t: string) -> bool {
	for s in set { if s == t { return true } }
	return false
}

@(private = "file")
is_lex_single_op :: proc(c: u8) -> bool {
	return(
		c == '(' ||
		c == ')' ||
		c == '[' ||
		c == ']' ||
		c == '{' ||
		c == '}' ||
		c == ',' ||
		c == ';' \
	)
}

@(private = "file")
is_identifier_lex :: proc(s: string) -> bool {
	if len(s) == 0 {return false}
	c := s[0]
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80
}

// Match the language's symbol patterns against the WHOLE-FILE lexeme stream
// derived from `lines`, and append captured symbols to `out`. The symbol's
// name string is cloned with `name_allocator`, so the caller owns it.
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
	def: ^Definition,
	lines: []string,
	out: ^[dynamic]Symbol,
	known_types: ^map[string]bool = nil,
	name_allocator := context.allocator,
) {
	if def == nil {return}

	// Build a single lexeme stream spanning every line in the file. Each
	// lexeme carries its source line and a flag for whether it was the
	// first non-whitespace token on that line, so `{NOTHING}` keeps working.
	all_lex := make([dynamic]Lexeme, 0, len(lines) * 8, context.temp_allocator)
	for line, idx in lines {
		per_line := extract_lexemes(def, line, u32(idx))
		for l in per_line {append(&all_lex, l)}
	}

	lexemes := all_lex[:]
	n := len(lexemes)

	// Precompute, in a single pass:
	//   * `depths[k]` — scope-nesting depth in effect BEFORE lex k.
	//   * `barriers[k]` — whether lex k is something the `...` ellipsis must
	//                     not cross (scope-open / scope-close tokens plus
	//                     the universal statement-separator `;`).
	// Both tables are independent of pattern matching, so patterns that
	// consume a scope-open lex (e.g. Bash's `NAME ( ) {`) still nest
	// subsequent symbols correctly.
	depths   := make([]i32,  n + 1, context.temp_allocator)
	barriers := make([]bool, n,     context.temp_allocator)
	d := i32(0)
	for k in 0 ..< n {
		depths[k] = d
		t := lexemes[k].text
		is_open  := slice_contains(def.scope_start, t)
		is_close := !is_open && slice_contains(def.scope_end, t)
		// Avoid double-counting a `Sub`/`Class`/etc. that follows an `End`
		// keyword: in VB-style languages the close token leads the pair, so
		// the next lexeme would otherwise re-open immediately.
		if is_open && k > 0 && slice_contains(def.scope_end, lexemes[k-1].text) {
			is_open = false
		}
		if is_open  { d += 1 }
		if is_close { d -= 1; if d < 0 { d = 0 } }
		barriers[k] = is_open || is_close || t == ";"
	}
	depths[n] = d

	if len(def.symbol_patterns) == 0 {return}

	i := 0
	for i < n {
		matched := false
		for &pattern in def.symbol_patterns {
			ok, name_idx, end_pos := try_match_pattern(
				pattern.tokens,
				lexemes,
				barriers,
				i,
				def,
				known_types,
				-1,
			)
			if !ok {continue}

			captured := lexemes[name_idx]
			sym_depth := depths[name_idx]
			if sym_depth < 0 {sym_depth = 0}
			if sym_depth > 255 {sym_depth = 255}
			append(
				out,
				Symbol {
					name = strings.clone(captured.text, name_allocator),
					kind = pattern.kind,
					line = captured.line,
					column = u32(captured.start),
					depth = u8(sym_depth),
				},
			)
			step := end_pos - i
			if step < 1 {step = 1} 	// safety: never stall on a zero-width-only pattern
			i += step
			matched = true
			break
		}
		if !matched {i += 1}
	}
}

// Try to match the remaining `tokens` against `lexemes` starting at lex
// index `start_index`. Returns the captured-name index (an absolute lex index) and
// the absolute lex position one past the matched run.
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
	barriers: []bool,
	start_index: int,
	language_definition: ^Definition,
	known_types: ^map[string]bool,
	name_idx_in: int,
) -> (
	ok: bool,
	name_lex_idx: int,
	end_pos: int,
) {
	current_lex_index := start_index
	name_idx := name_idx_in

	for token_index in 0 ..< len(tokens) {
		current_token := tokens[token_index]

		if current_token.kind == .Ellipsis {
			// Non-greedy: try the tail starting at p, then p+1, then p+2, …
			// First match wins. `skip == 0` covers an empty run (the
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
			tail := tokens[token_index + 1:]
			for skip in 0 ..= (len(lexemes) - current_lex_index) {
				recursive_ok, recursive_name_index, recursive_end_pos := try_match_pattern(
					tail,
					lexemes,
					barriers,
					current_lex_index + skip,
					language_definition,
					known_types,
					name_idx,
				)
				if recursive_ok {return true, recursive_name_index, recursive_end_pos}
				if current_lex_index + skip >= len(lexemes) {break}
				if barriers[current_lex_index + skip] {break}
			}
			return false, -1, current_lex_index
		}

		if current_token.kind == .Optional {
			// Try the inner sub-token; on failure the wrapper is a
			// zero-width no-op. The inner may itself be a nested operator
			// (e.g. an OPTION alternation) — `match_single_token` handles
			// that uniformly.
			if current_token.inner != nil {
				matched, c := match_single_token(
					current_token.inner^,
					lexemes,
					current_lex_index,
					language_definition,
					known_types,
					&name_idx,
				)
				if matched {current_lex_index += c}
			}
			continue
		}

		if current_token.kind == .Not {
			// Zero-width negative lookahead: fail the pattern if the inner
			// would match here. Pass a dummy name_idx so probes like
			// `{NOT:NAME}` don't accidentally capture the lexeme we're
			// rejecting.
			if current_token.inner != nil {
				dummy: int = -1
				matched, _ := match_single_token(current_token.inner^, lexemes, current_lex_index, language_definition, known_types, &dummy)
				if matched {return false, -1, current_lex_index}
			}
			continue
		}

		ok2, c := match_single_token(current_token, lexemes, current_lex_index, language_definition, known_types, &name_idx)
		if !ok2 {return false, -1, current_lex_index}
		current_lex_index += c
	}

	if name_idx < 0 {return false, -1, current_lex_index}
	return true, name_idx, current_lex_index
}

// Try to match a single PatternToken (anything except top-level Ellipsis,
// Optional, or Not, which the outer matcher handles inline) at lex index
// `pos`. Returns whether it matched and how many lexemes were consumed
// (0 for zero-width Nothing, 1 otherwise). On success for .Name, updates
// `name_idx^` with the absolute lex index of the captured identifier.
@(private = "file")
match_single_token :: proc(
	tok: PatternToken,
	lexemes: []Lexeme,
	pos: int,
	language_definition: ^Definition,
	known_types: ^map[string]bool,
	name_idx: ^int,
) -> (
	matched: bool,
	consumed: int,
) {
	switch tok.kind {
	case .Nothing:
		// Zero-width anchor: succeeds only when the current lexeme is the
		// first non-whitespace token on its source line. With a whole-file
		// lexeme stream this is how "start of line" is expressed.
		if pos >= len(lexemes) || !lexemes[pos].is_first_on_line {return false, 0}
		return true, 0

	case .Literal:
		if pos >= len(lexemes) || lexemes[pos].text != tok.text {return false, 0}
		return true, 1

	case .Name:
		if pos >= len(lexemes) {return false, 0}
		t := lexemes[pos].text
		if !is_identifier_lex(t) {return false, 0}
		for kw in language_definition.keywords {if kw == t {return false, 0}}
		name_idx^ = pos
		return true, 1

	case .Type:
		if pos >= len(lexemes) {return false, 0}
		t := lexemes[pos].text
		if !is_identifier_lex(t) {return false, 0}
		is_type := false
		for ty in language_definition.types {if ty == t {is_type = true; break}}
		if !is_type && known_types != nil {
			if _, exists := known_types[t]; exists {is_type = true}
		}
		if !is_type {return false, 0}
		return true, 1

	case .Any:
		if pos >= len(lexemes) {return false, 0}
		return true, 1

	case .Ellipsis:
		// Ellipsis as a single token (i.e. inside {OPTIONAL:...}) is
		// redundant — the outer ellipsis would already consume any run —
		// so treat it as a zero-width "always succeeds" no-op.
		return true, 0

	case .Option:
		// Mandatory alternation. Try each alternative in source order;
		// the first hit wins and we forward its consume count.
		for option in tok.options {
			m, c := match_single_token(
				option,
				lexemes,
				pos,
				language_definition,
				known_types,
				name_idx,
			)
			if m {return true, c}
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
