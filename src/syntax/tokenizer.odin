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
tokenize_line :: proc(def: ^Definition, line: string, tokens: ^[dynamic]Token) {
	if def == nil {
		if len(line) > 0 { append(tokens, Token{.Default, 0, len(line)}) }
		return
	}

	n := len(line)
	if n == 0 { return }

	// Whole-line preprocessor directive — when the first non-whitespace char
	// matches the language's preprocessor prefix.
	if len(def.preprocessor_prefix) > 0 {
		first := 0
		for first < n && (line[first] == ' ' || line[first] == '\t') {
			first += 1
		}
		if first < n && strings.has_prefix(line[first:], def.preprocessor_prefix) {
			if first > 0 { append(tokens, Token{.Default, 0, first}) }
			append(tokens, Token{.Preprocessor, first, n})
			return
		}
	}

	i := 0
	default_start := 0

	flush_default :: proc(tokens: ^[dynamic]Token, from, to: int) {
		if to > from {
			append(tokens, Token{.Default, from, to})
		}
	}

	for i < n {
		// Line comment — runs to EOL.
		if len(def.line_comment) > 0 && match_at(line, i, def.line_comment) {
			flush_default(tokens, default_start, i)
			append(tokens, Token{.Comment, i, n})
			return
		}

		// Block comment — try to find the closing marker on the same line.
		if len(def.block_comment_start) > 0 && match_at(line, i, def.block_comment_start) {
			flush_default(tokens, default_start, i)
			rest := line[i + len(def.block_comment_start):]
			end_off := strings.index(rest, def.block_comment_end)
			block_end := n
			if end_off >= 0 {
				block_end = i + len(def.block_comment_start) + end_off + len(def.block_comment_end)
			}
			append(tokens, Token{.Comment, i, block_end})
			i = block_end
			default_start = i
			continue
		}

		c := line[i]

		// String literal — " or '. Backslash-escape consumes the next byte.
		if c == '"' || c == '\'' || c == '`' {
			flush_default(tokens, default_start, i)
			quote := c
			j := i + 1
			for j < n {
				if line[j] == '\\' && j + 1 < n { j += 2; continue }
				if line[j] == quote { j += 1; break }
				j += 1
			}
			append(tokens, Token{.String, i, j})
			i = j
			default_start = i
			continue
		}

		// Numeric literal — digit prefix; consume an identifier-ish tail to
		// keep `0x1f`, `1.5e-3`, `1_000_000`, `100ul`, etc. as one token.
		if is_digit(c) {
			flush_default(tokens, default_start, i)
			j := i + 1
			for j < n {
				cj := line[j]
				if is_digit(cj) || cj == '.' || cj == '_' || cj == 'x' || cj == 'X' ||
				   cj == 'o' || cj == 'O' || cj == 'b' || cj == 'B' ||
				   cj == 'e' || cj == 'E' || cj == 'p' || cj == 'P' ||
				   cj == '+' || cj == '-' || cj == 'u' || cj == 'U' || cj == 'l' || cj == 'L' || cj == 'f' || cj == 'F' ||
				   (cj >= 'a' && cj <= 'f') || (cj >= 'A' && cj <= 'F') {
					// Sign chars (+/-) only inside an exponent — refuse them
					// after the very start so `1+2` doesn't fuse.
					if (cj == '+' || cj == '-') {
						prev := line[j - 1]
						if !(prev == 'e' || prev == 'E' || prev == 'p' || prev == 'P') { break }
					}
					j += 1
				} else {
					break
				}
			}
			append(tokens, Token{.Number, i, j})
			i = j
			default_start = i
			continue
		}

		// Identifier — letters / underscore / non-ASCII bytes are word chars.
		if is_identifier_start(c) {
			flush_default(tokens, default_start, i)
			j := i + 1
			for j < n && is_identifier_part(line[j]) { j += 1 }
			word := line[i:j]
			kind: TokenKind = .Default
			if is_in_list(word, def.keywords) {
				kind = .Keyword
			} else if is_in_list(word, def.types) {
				kind = .Type
			}
			append(tokens, Token{kind, i, j})
			i = j
			default_start = i
			continue
		}

		// Plain default char.
		i += 1
	}
	flush_default(tokens, default_start, n)
}

@(private="file")
match_at :: proc(s: string, i: int, prefix: string) -> bool {
	if i + len(prefix) > len(s) { return false }
	return s[i:i+len(prefix)] == prefix
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
	for w in list {
		if w == word { return true }
	}
	return false
}
