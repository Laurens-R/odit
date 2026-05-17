package syntax

import "core:strings"

// Tokenize a single line into a list of colored runs covering every byte from
// 0..len(line). The list is appended to `tokens` (which the caller is
// responsible for clearing before the call when needed).
//
// This is a deliberately simple per-line lexer — it doesn't carry state
// across lines, so a multi-line `/* ... */` comment will only get the
// `Comment` colour on its first and last lines (where the markers appear).
// Good enough as a fallback when no LSP/tree-sitter is available; a future
// pass can add a small line-state machine to fix the multi-line case.
tokenize_line :: proc(def: ^Definition, line: string, tokens: ^[dynamic]Token, symbol_names: map[string]SymbolKind = {}) {
	if def == nil {
		if len(line) > 0 { append(tokens, Token{.Default, 0, len(line)}) }
		return
	}

	lineLength := len(line)
	if lineLength == 0 { return }

	// Whole-line preprocessor directive — when the first non-whitespace char
	// matches the language's preprocessor prefix.
	if len(def.preprocessor_prefix) > 0 {
		first := 0
		for first < lineLength && (line[first] == ' ' || line[first] == '\t') {
			first += 1
		}
		if first < lineLength && strings.has_prefix(line[first:], def.preprocessor_prefix) {
			if first > 0 { append(tokens, Token{.Default, 0, first}) }
			append(tokens, Token{.Preprocessor, first, lineLength})
			return
		}
	}

	char_index := 0
	default_start := 0

	flush_default :: proc(tokens: ^[dynamic]Token, from, to: int) {
		if to > from {
			append(tokens, Token{.Default, from, to})
		}
	}

	for char_index < lineLength {
		// Line comment — runs to EOL.
		if len(def.line_comment) > 0 && match_at(line, char_index, def.line_comment) {
			flush_default(tokens, default_start, char_index)
			append(tokens, Token{.Comment, char_index, lineLength})
			return
		}

		// Block comment — try to find the closing marker on the same line.
		if len(def.block_comment_start) > 0 && match_at(line, char_index, def.block_comment_start) {
			flush_default(tokens, default_start, char_index)
			rest := line[char_index + len(def.block_comment_start):]
			end_off := strings.index(rest, def.block_comment_end)
			block_end := lineLength
			if end_off >= 0 {
				block_end = char_index + len(def.block_comment_start) + end_off + len(def.block_comment_end)
			}
			append(tokens, Token{.Comment, char_index, block_end})
			char_index = block_end
			default_start = char_index
			continue
		}

		line_character := line[char_index]

		// String literal — " or '. Backslash-escape consumes the next byte.
		if line_character == '"' || line_character == '\'' || line_character == '`' {
			flush_default(tokens, default_start, char_index)
			quote := line_character
			next_char_index := char_index + 1
			for next_char_index < lineLength {
				if line[next_char_index] == '\\' && next_char_index + 1 < lineLength { next_char_index += 2; continue }
				if line[next_char_index] == quote { next_char_index += 1; break }
				next_char_index += 1
			}
			append(tokens, Token{.String, char_index, next_char_index})
			char_index = next_char_index
			default_start = char_index
			continue
		}

		// Numeric literal — digit prefix; consume an identifier-ish tail to
		// keep `0x1f`, `1.5e-3`, `1_000_000`, `100ul`, etc. as one token.
		if is_digit(line_character) {
			flush_default(tokens, default_start, char_index)
			next_char_index := char_index + 1
			for next_char_index < lineLength {
				next_char := line[next_char_index]
				if is_digit(next_char) || next_char == '.' || next_char == '_' || next_char == 'x' || next_char == 'X' ||
				   next_char == 'o' || next_char == 'O' || next_char == 'b' || next_char == 'B' ||
				   next_char == 'e' || next_char == 'E' || next_char == 'p' || next_char == 'P' ||
				   next_char == '+' || next_char == '-' || next_char == 'u' || next_char == 'U' || next_char == 'l' || next_char == 'L' || next_char == 'f' || next_char == 'F' ||
				   (next_char >= 'a' && next_char <= 'f') || (next_char >= 'A' && next_char <= 'F') {
					// Sign chars (+/-) only inside an exponent — refuse them
					// after the very start so `1+2` doesn't fuse.
					if (next_char == '+' || next_char == '-') {
						prev := line[next_char_index - 1]
						if !(prev == 'e' || prev == 'E' || prev == 'p' || prev == 'P') { break }
					}
					next_char_index += 1
				} else {
					break
				}
			}
			append(tokens, Token{.Number, char_index, next_char_index})
			char_index = next_char_index
			default_start = char_index
			continue
		}

		// Identifier — letters / underscore / non-ASCII bytes are word chars.
		if is_identifier_start(line_character) {
			flush_default(tokens, default_start, char_index)
			next_char_index := char_index + 1
			for next_char_index < lineLength && is_identifier_part(line[next_char_index]) { next_char_index += 1 }
			word := line[char_index:next_char_index]
			kind: TokenKind = .Default
			if is_in_list(word, def.keywords) {
				kind = .Keyword
			} else if is_in_list(word, def.types) {
				kind = .Type
			} else if len(symbol_names) > 0 {
				if _, in_symbols := symbol_names[word]; in_symbols {
					kind = .Symbol
				}
			}
			append(tokens, Token{kind, char_index, next_char_index})
			char_index = next_char_index
			default_start = char_index
			continue
		}

		// Plain default char.
		char_index += 1
	}
	flush_default(tokens, default_start, lineLength)
}

@(private="file")
match_at :: proc(str: string, char_index: int, prefix: string) -> bool {
	if char_index + len(prefix) > len(str) { return false }
	return str[char_index:char_index+len(prefix)] == prefix
}

@(private="file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private="file")
is_identifier_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80
}

@(private="file")
is_identifier_part :: proc(c: u8) -> bool {
	return is_identifier_start(c) || is_digit(c)
}

@(private="file")
is_in_list :: proc(word: string, list: []string) -> bool {
	for list_word in list {
		if list_word == word { return true }
	}
	return false
}
