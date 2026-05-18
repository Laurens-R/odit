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
tokenize_line :: proc(
	language_definition: ^Definition,
	line: string,
	tokens: ^[dynamic]Token,
	symbol_names: map[string]SymbolKind = {},
) {
	if language_definition == nil {
		if len(line) > 0 {append(tokens, Token{.Default, 0, len(line)})}
		return
	}

	line_length := len(line)
	if line_length == 0 {return}

	// Whole-line preprocessor directive — when the first non-whitespace char
	// matches the language's preprocessor prefix.
	if len(language_definition.preprocessor_prefix) > 0 {
		first_non_whitespace_index := 0
		for first_non_whitespace_index < line_length &&
		    (line[first_non_whitespace_index] == ' ' || line[first_non_whitespace_index] == '\t') {
			first_non_whitespace_index += 1
		}
		if first_non_whitespace_index < line_length &&
		   strings.has_prefix(
			   line[first_non_whitespace_index:],
			   language_definition.preprocessor_prefix,
		   ) {
			if first_non_whitespace_index >
			   0 {append(tokens, Token{.Default, 0, first_non_whitespace_index})}
			append(tokens, Token{.Preprocessor, first_non_whitespace_index, line_length})
			return
		}
	}

	character_index := 0
	default_run_start := 0

	flush_default_run :: proc(tokens: ^[dynamic]Token, from_index, to_index: int) {
		if to_index > from_index {
			append(tokens, Token{.Default, from_index, to_index})
		}
	}

	for character_index < line_length {
		// Line comment — runs to EOL.
		if len(language_definition.line_comment) > 0 &&
		   match_at(line, character_index, language_definition.line_comment) {
			flush_default_run(tokens, default_run_start, character_index)
			append(tokens, Token{.Comment, character_index, line_length})
			return
		}

		// Block comment — try to find the closing marker on the same line.
		if len(language_definition.block_comment_start) > 0 &&
		   match_at(line, character_index, language_definition.block_comment_start) {
			flush_default_run(tokens, default_run_start, character_index)
			remaining_line := line[character_index + len(language_definition.block_comment_start):]
			end_marker_offset := strings.index(
				remaining_line,
				language_definition.block_comment_end,
			)
			block_comment_end := line_length
			if end_marker_offset >= 0 {
				block_comment_end =
					character_index +
					len(language_definition.block_comment_start) +
					end_marker_offset +
					len(language_definition.block_comment_end)
			}
			append(tokens, Token{.Comment, character_index, block_comment_end})
			character_index = block_comment_end
			default_run_start = character_index
			continue
		}

		line_character := line[character_index]

		// String literal — " or '. Backslash-escape consumes the next byte.
		if line_character == '"' || line_character == '\'' || line_character == '`' {
			flush_default_run(tokens, default_run_start, character_index)
			quote_character := line_character
			next_character_index := character_index + 1
			for next_character_index < line_length {
				if line[next_character_index] == '\\' &&
				   next_character_index + 1 < line_length {next_character_index += 2; continue}
				if line[next_character_index] == quote_character {next_character_index += 1; break}
				next_character_index += 1
			}
			append(tokens, Token{.String, character_index, next_character_index})
			character_index = next_character_index
			default_run_start = character_index
			continue
		}

		// Numeric literal — digit prefix; consume an identifier-ish tail to
		// keep `0x1f`, `1.5e-3`, `1_000_000`, `100ul`, etc. as one token.
		if is_digit(line_character) {
			flush_default_run(tokens, default_run_start, character_index)
			next_character_index := character_index + 1
			for next_character_index < line_length {
				next_character := line[next_character_index]
				if is_digit(next_character) ||
				   next_character == '.' ||
				   next_character == '_' ||
				   next_character == 'x' ||
				   next_character == 'X' ||
				   next_character == 'o' ||
				   next_character == 'O' ||
				   next_character == 'b' ||
				   next_character == 'B' ||
				   next_character == 'e' ||
				   next_character == 'E' ||
				   next_character == 'p' ||
				   next_character == 'P' ||
				   next_character == '+' ||
				   next_character == '-' ||
				   next_character == 'u' ||
				   next_character == 'U' ||
				   next_character == 'l' ||
				   next_character == 'L' ||
				   next_character == 'f' ||
				   next_character == 'F' ||
				   (next_character >= 'a' && next_character <= 'f') ||
				   (next_character >= 'A' && next_character <= 'F') {
					// Sign chars (+/-) only inside an exponent — refuse them
					// after the very start so `1+2` doesn't fuse.
					if (next_character == '+' || next_character == '-') {
						previous_character := line[next_character_index - 1]
						if !(previous_character == 'e' ||
							   previous_character == 'E' ||
							   previous_character == 'p' ||
							   previous_character == 'P') {break}
					}
					next_character_index += 1
				} else {
					break
				}
			}
			append(tokens, Token{.Number, character_index, next_character_index})
			character_index = next_character_index
			default_run_start = character_index
			continue
		}

		// Identifier — letters / underscore / non-ASCII bytes are word chars.
		if is_identifier_start(line_character) {
			flush_default_run(tokens, default_run_start, character_index)
			next_character_index := character_index + 1
			for next_character_index < line_length &&
			    is_identifier_part(line[next_character_index]) {next_character_index += 1}
			identifier_word := line[character_index:next_character_index]
			identifier_kind: TokenKind = .Default
			if is_in_list(identifier_word, language_definition.keywords) {
				identifier_kind = .Keyword
			} else if is_in_list(identifier_word, language_definition.types) {
				identifier_kind = .Type
			} else if len(symbol_names) > 0 {
				if _, exists_in_symbols := symbol_names[identifier_word]; exists_in_symbols {
					identifier_kind = .Symbol
				}
			}
			append(tokens, Token{identifier_kind, character_index, next_character_index})
			character_index = next_character_index
			default_run_start = character_index
			continue
		}

		// Plain default char.
		character_index += 1
	}
	flush_default_run(tokens, default_run_start, line_length)
}

@(private = "file")
match_at :: proc(text: string, character_index: int, prefix: string) -> bool {
	if character_index + len(prefix) > len(text) {return false}
	return text[character_index:character_index + len(prefix)] == prefix
}

@(private = "file")
is_digit :: proc(character_value: u8) -> bool {
	return character_value >= '0' && character_value <= '9'
}

@(private = "file")
is_identifier_start :: proc(character_value: u8) -> bool {
	return(
		(character_value >= 'a' && character_value <= 'z') ||
		(character_value >= 'A' && character_value <= 'Z') ||
		character_value == '_' ||
		character_value >= 0x80 \
	)
}

@(private = "file")
is_identifier_part :: proc(character_value: u8) -> bool {
	return is_identifier_start(character_value) || is_digit(character_value)
}

@(private = "file")
is_in_list :: proc(word: string, word_list: []string) -> bool {
	for list_word in word_list {
		if list_word == word {return true}
	}
	return false
}
