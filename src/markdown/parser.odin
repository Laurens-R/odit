// Block + inline parser. Pure: input is a `string`, output is a
// caller-owned `[dynamic]Block` populated with `InlineRun` slices. No
// editor coupling, no SDL dependencies — these procs can be unit-tested
// in isolation.
//
// The grammar accepted is a small commonmark-flavoured subset that covers
// what the editor's three callers (F5 preview, LSP hover popup, signature
// help popup) actually receive in practice:
//
//   * ATX headings  (# .. ######)
//   * Fenced code blocks (```)
//   * Horizontal rules (---, ***, ___)
//   * Block quotes (>)
//   * Unordered list items (- * +)
//   * Ordered list items (1. 1))
//   * Paragraphs (everything else, joined with spaces)
//
// Inline runs recognised: **bold**, _italic_ / *italic*, `code`,
// `[link](url)`, `![image](url)`.
package markdown

import "core:strings"

// Parse `content_text` into `blocks`. Appends — caller is responsible for
// clearing `blocks` first if they want a fresh slate. All inline-run
// strings are heap-cloned in `context.allocator`; the caller takes
// ownership and must hand back to `clear_blocks` at teardown.
parse_into :: proc(content_text: string, blocks: ^[dynamic]Block) {
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
		fully_trimmed := strings.trim_space(current_line) // shared by blank/rule checks

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

			runs: [dynamic]InlineRun
			runs.allocator = context.allocator
			append(&runs, InlineRun{kind = .Plain, text = strings.clone(strings.to_string(code_builder))})
			append(blocks, Block{kind = .CodeBlock, inline_runs = runs})
			continue
		}

		if len(fully_trimmed) == 0 {
			append(blocks, Block{kind = .BlankLine})
			line_index += 1
			continue
		}

		if is_horizontal_rule_line(fully_trimmed) {
			append(blocks, Block{kind = .HorizontalRule})
			line_index += 1
			continue
		}

		if heading_level := count_atx_heading_marker(left_trimmed); heading_level > 0 {
			heading_text := strings.trim_left(left_trimmed[heading_level:], " \t")
			heading_text  = strings.trim_right(heading_text, " #\t")
			runs := parse_inline_runs(heading_text)
			append(blocks, Block{kind = .Heading, level = heading_level, inline_runs = runs})
			line_index += 1
			continue
		}

		if strings.has_prefix(left_trimmed, ">") {
			quote_text := strings.trim_left(left_trimmed[1:], " \t")
			runs := parse_inline_runs(quote_text)
			append(blocks, Block{kind = .BlockQuote, inline_runs = runs})
			line_index += 1
			continue
		}

		// Count leading whitespace so we can pick up nesting depth for
		// bullets and tell whether following lines belong to the same item.
		leading_whitespace_count := 0
		for leading_whitespace_count < len(current_line) && (current_line[leading_whitespace_count] == ' ' || current_line[leading_whitespace_count] == '\t') {
			leading_whitespace_count += 1
		}

		if is_unordered_list_marker(left_trimmed) {
			parse_list_item_into_blocks(lines, &line_index, blocks,
				leading_whitespace_count, 2, 0 /*ordered_value*/, leading_whitespace_count / 2)
			continue
		}

		if ordered_value, marker_byte_length := parse_ordered_list_marker(left_trimmed); ordered_value > 0 {
			parse_list_item_into_blocks(lines, &line_index, blocks,
				leading_whitespace_count, marker_byte_length, ordered_value, leading_whitespace_count / 2)
			continue
		}

		// Paragraph — collect consecutive non-block-starting lines and join
		// with single spaces.
		paragraph_builder: strings.Builder
		strings.builder_init(&paragraph_builder, 0, 128, context.temp_allocator)
		for line_index < len(lines) {
			inner_line          := lines[line_index]
			inner_left_trimmed  := strings.trim_left(inner_line, " \t")
			inner_fully_trimmed := strings.trim_space(inner_line)
			if len(inner_fully_trimmed) == 0                                          { break }
			if is_horizontal_rule_line(inner_fully_trimmed)                           { break }
			if count_atx_heading_marker(inner_left_trimmed) > 0                       { break }
			if strings.has_prefix(inner_left_trimmed, ">")                            { break }
			if strings.has_prefix(inner_left_trimmed, "```")                          { break }
			if is_unordered_list_marker(inner_left_trimmed)                           { break }
			if ordered_value, _ := parse_ordered_list_marker(inner_left_trimmed); ordered_value > 0 { break }

			if strings.builder_len(paragraph_builder) > 0 { strings.write_byte(&paragraph_builder, ' ') }
			strings.write_string(&paragraph_builder, inner_fully_trimmed)
			line_index += 1
		}
		paragraph_text := strings.to_string(paragraph_builder)
		runs := parse_inline_runs(paragraph_text)
		append(blocks, Block{kind = .Paragraph, inline_runs = runs})
	}
}

// Free every inline run owned by `blocks` and `clear()` the slice. Pairs
// with `parse_into`. Idempotent on an already-cleared slice.
clear_blocks :: proc(blocks: ^[dynamic]Block) {
	for block in blocks^ {
		for run in block.inline_runs {
			if len(run.text) > 0 { delete(run.text) }
			if len(run.url)  > 0 { delete(run.url)  }
		}
		if cap(block.inline_runs) > 0 { delete(block.inline_runs) }
	}
	clear(blocks)
}

// Parse one list item starting at `lines[line_index]`. Consumes the
// marker line, then any indented continuation lines (each line indented
// at least one column past the original `leading_whitespace_count`)
// until a blank line or a new block construct shows up. Continuation
// lines are joined into the item text with a single space separator —
// the visual-line wrapper handles further breakage.
@(private="file")
parse_list_item_into_blocks :: proc(
	lines: [dynamic]string,
	line_index: ^int,
	blocks: ^[dynamic]Block,
	leading_whitespace_count, marker_byte_length, ordered_value, list_depth: int,
) {
	first_line := lines[line_index^]
	left_trimmed := first_line[leading_whitespace_count:]

	item_text_builder: strings.Builder
	strings.builder_init(&item_text_builder, 0, 64, context.temp_allocator)
	strings.write_string(&item_text_builder, left_trimmed[marker_byte_length:])
	line_index^ += 1

	// Continuation must be indented past the marker — at least
	// `leading_whitespace_count + 1` columns. We accept any indent that
	// exceeds the parent marker's indent so loosely-formatted docs
	// (e.g. "    continuation") still attach to the bullet.
	min_continuation_indent := leading_whitespace_count + 1

	for line_index^ < len(lines) {
		cont_line := lines[line_index^]
		if len(strings.trim_space(cont_line)) == 0 { break }

		cont_leading := 0
		for cont_leading < len(cont_line) && (cont_line[cont_leading] == ' ' || cont_line[cont_leading] == '\t') { cont_leading += 1 }
		if cont_leading < min_continuation_indent { break }

		cont_trimmed := cont_line[cont_leading:]
		// Don't swallow a new block as continuation.
		if is_unordered_list_marker(cont_trimmed)                                   { break }
		if count_atx_heading_marker(cont_trimmed) > 0                               { break }
		if strings.has_prefix(cont_trimmed, "```")                                  { break }
		if strings.has_prefix(cont_trimmed, ">")                                    { break }
		if v, _ := parse_ordered_list_marker(cont_trimmed); v > 0                   { break }
		if is_horizontal_rule_line(strings.trim_space(cont_trimmed))                { break }

		if strings.builder_len(item_text_builder) > 0 { strings.write_byte(&item_text_builder, ' ') }
		strings.write_string(&item_text_builder, cont_trimmed)
		line_index^ += 1
	}

	runs := parse_inline_runs(strings.to_string(item_text_builder))
	append(blocks, Block{
		kind          = .ListItem,
		ordered_index = ordered_value,
		list_depth    = list_depth,
		inline_runs   = runs,
	})
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

// --- Inline parser --------------------------------------------------------

@(private="file")
parse_inline_runs :: proc(text: string) -> [dynamic]InlineRun {
	runs: [dynamic]InlineRun
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
				append(&runs, InlineRun{kind = .Code, text = strings.clone(code_text)})
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
				append(&runs, InlineRun{kind = .Bold, text = strings.clone(bold_text)})
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
					append(&runs, InlineRun{kind = .Italic, text = strings.clone(italic_text)})
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
					append(&runs, InlineRun{
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
flush_plain_run :: proc(runs: ^[dynamic]InlineRun, source_text: string, from, to: int) {
	if to > from {
		append(runs, InlineRun{kind = .Plain, text = strings.clone(source_text[from:to])})
	}
}

@(private="file")
find_inline_close :: proc(text: string, search_from: int, marker: string) -> int {
	if search_from >= len(text) { return -1 }
	relative_index := strings.index(text[search_from:], marker)
	if relative_index < 0 { return -1 }
	return search_from + relative_index
}
