## The output of `Str.inspect` parsed back into a tree, so that the package
## can filter secrets out of it field by field and lay it out over lines.
## Internal to the package.
##
## `Str.inspect` writes a value on one line, with tags as `Name(payload)`,
## records as `{ field: value }` with the fields sorted, lists as `[a, b]`
## and tuples as `(a, b)`. In the tree a `Scalar` is a string with its quotes
## and escapes, a number, or an `<opaque>` marker. A tag is a `Tag` with its
## payloads, none for a bare tag like `True`, and a list or tuple is a
## `Sequence` with its brackets.
import Ascii

Inspected := [
	Scalar(Str),
	Tag(Str, List(Inspected)),
	Record(List({ key : Str, value : Inspected })),
	Sequence({ open : Str, close : Str, items : List(Inspected) }),
].{
	is_eq : _

	## Parse `text`, the output of `Str.inspect`. Fails on anything that is
	## not one whole value.
	parse : Str -> Try(Inspected, [Unparseable])
	parse = |text| {
		bytes = text.to_utf8()
		{ value, next } = parse_value(bytes, skip_whitespace(bytes, 0))?
		if skip_whitespace(bytes, next) == bytes.len() {
			Ok(value)
		} else {
			Err(Unparseable)
		}
	}

	## The tree on one line, the way `Str.inspect` writes it.
	to_str : Inspected -> Str
	to_str = |tree|
		match tree {
			Scalar(text) => text
			Tag(name, []) => name
			Tag(name, payloads) => "${name}(${Str.join_with(payloads.map(Inspected.to_str), ", ")})"
			Record([]) => "{}"
			Record(fields) => "{ ${Str.join_with(fields.map(|{ key, value }| "${key}: ${value.to_str()}"), ", ")} }"
			Sequence({ open, close, items }) => "${open}${Str.join_with(items.map(Inspected.to_str), ", ")}${close}"
		}

	## Whether the tree holds a record with fields anywhere in it.
	has_record : Inspected -> Bool
	has_record = |tree|
		match tree {
			Scalar(_) => Bool.False
			Tag(_, payloads) => payloads.any(Inspected.has_record)
			Record(fields) => !fields.is_empty()
			Sequence({ items, .. }) => items.any(Inspected.has_record)
		}

	## `text` without its quotes and escapes when it is a string scalar, so
	## `"say \"hi\""` gives `say "hi"`. Anything else is returned unchanged.
	unquote : Str -> Str
	unquote = |text| {
		bytes = text.to_utf8()
		if is_string(text) {
			inner = bytes.sublist({ start: 1, len: bytes.len() - 2 })
			unescaped = inner.fold(
				{ acc: [], escaping: Bool.False },
				|state, byte|
					if state.escaping {
						{ acc: state.acc.append(byte), escaping: Bool.False }
					} else if byte == backslash {
						{ acc: state.acc, escaping: Bool.True }
					} else {
						{ acc: state.acc.append(byte), escaping: Bool.False }
					},
			)
			Str.from_utf8_lossy(unescaped.acc)
		} else {
			text
		}
	}

	## `text` as a string scalar, quoted and escaped the way `Str.inspect`
	## writes it, which puts a backslash before `"` and `\` and nothing else.
	## The inverse of [unquote].
	quote : Str -> Str
	quote = |text| {
		escaped = text.to_utf8().fold(
			[double_quote],
			|acc, byte|
				if byte == double_quote or byte == backslash {
					acc.append(backslash).append(byte)
				} else {
					acc.append(byte)
				},
		)
		# Only ASCII was added to valid UTF-8, so nothing is lost here.
		Str.from_utf8_lossy(escaped.append(double_quote))
	}

	## Whether `text`, a scalar, is a string: it starts and ends with a quote.
	is_string : Str -> Bool
	is_string = |text| {
		bytes = text.to_utf8()
		bytes.len() >= 2 and bytes.first() == Ok(double_quote) and bytes.last() == Ok(double_quote)
	}
}

double_quote : U8
double_quote = 34

backslash : U8
backslash = 92

Parsed : { value : Inspected, next : U64 }

parse_value : List(U8), U64 -> Try(Parsed, [Unparseable])
parse_value = |bytes, start| {
	byte = bytes.get(start) ? |_| Unparseable
	if byte == double_quote {
		parse_string(bytes, start)
	} else if byte == 123 { # {
		parse_record(bytes, start)
	} else if byte == 91 { # [
		parse_sequence(bytes, start, "[", "]", 93)
	} else if byte == 40 { # (
		parse_sequence(bytes, start, "(", ")", 41)
	} else if byte == 60 { # <
		# <opaque>, <function> and the like
		end = Ascii.token_end(bytes, start, |b| b == 62) + 1 # >
		if end > bytes.len() {
			Err(Unparseable)
		} else {
			Ok({ value: Scalar(slice(bytes, start, end)), next: end })
		}
	} else if Ascii.is_upper(byte) {
		parse_tag(bytes, start)
	} else {
		end = Ascii.token_end(bytes, start, is_delimiter)
		if end == start {
			Err(Unparseable)
		} else {
			Ok({ value: Scalar(slice(bytes, start, end)), next: end })
		}
	}
}

## A string from its opening quote to its closing one, escapes skipped.
parse_string : List(U8), U64 -> Try(Parsed, [Unparseable])
parse_string = |bytes, start| {
	len = bytes.len()
	var $i = start + 1
	var $closed = Bool.False
	while !$closed and $i < len {
		byte = bytes.get($i).ok_or(0)
		if byte == backslash {
			$i = $i + 2
		} else if byte == double_quote {
			$closed = Bool.True
			$i = $i + 1
		} else {
			$i = $i + 1
		}
	}
	if $closed {
		Ok({ value: Scalar(slice(bytes, start, $i)), next: $i })
	} else {
		Err(Unparseable)
	}
}

## A tag name, letters, digits, `_` and `.` (as in `Dict.from_list`),
## followed by its payloads in parentheses when it has any.
parse_tag : List(U8), U64 -> Try(Parsed, [Unparseable])
parse_tag = |bytes, start| {
	name_end = Ascii.token_end(bytes, start, |byte| !Ascii.is_identifier_byte(byte))
	name = slice(bytes, start, name_end)
	if bytes.get(name_end) == Ok(40) { # (
		{ value, next } = parse_sequence(bytes, name_end, "(", ")", 41)?
		match value {
			Sequence({ items, .. }) => Ok({ value: Tag(name, items), next })
			_ => Err(Unparseable)
		}
	} else {
		Ok({ value: Tag(name, []), next: name_end })
	}
}

## `open` at `start`, then comma separated values up to the `close` byte.
parse_sequence : List(U8), U64, Str, Str, U8 -> Try(Parsed, [Unparseable])
parse_sequence = |bytes, start, open, close, close_byte| {
	var $items = []
	var $i = skip_whitespace(bytes, start + 1)
	var $done = bytes.get($i) == Ok(close_byte)
	if $done {
		$i = $i + 1
	}
	while !$done {
		{ value, next } = parse_value(bytes, $i)?
		$items = $items.append(value)
		after = skip_whitespace(bytes, next)
		match bytes.get(after) {
			Ok(44) => { # ,
				$i = skip_whitespace(bytes, after + 1)
			}
			Ok(byte) if byte == close_byte => {
				$done = Bool.True
				$i = after + 1
			}
			_ => return Err(Unparseable)
		}
	}
	Ok({ value: Sequence({ open, close, items: $items }), next: $i })
}

## `{` at `start`, then `key: value` fields up to `}`.
parse_record : List(U8), U64 -> Try(Parsed, [Unparseable])
parse_record = |bytes, start| {
	var $fields = []
	var $i = skip_whitespace(bytes, start + 1)
	var $done = bytes.get($i) == Ok(125) # }
	if $done {
		$i = $i + 1
	}
	while !$done {
		key_end = Ascii.token_end(bytes, $i, |byte| !Ascii.is_identifier_byte(byte))
		if key_end == $i {
			return Err(Unparseable)
		}
		key = slice(bytes, $i, key_end)
		colon = skip_whitespace(bytes, key_end)
		if bytes.get(colon) != Ok(58) { # :
			return Err(Unparseable)
		}
		{ value, next } = parse_value(bytes, skip_whitespace(bytes, colon + 1))?
		$fields = $fields.append({ key, value })
		after = skip_whitespace(bytes, next)
		match bytes.get(after) {
			Ok(44) => { # ,
				$i = skip_whitespace(bytes, after + 1)
			}
			Ok(125) => { # }
				$done = Bool.True
				$i = after + 1
			}
			_ => return Err(Unparseable)
		}
	}
	Ok({ value: Record($fields), next: $i })
}

slice : List(U8), U64, U64 -> Str
slice = |bytes, start, end| Str.from_utf8_lossy(bytes.sublist({ start, len: end - start }))

## What ends a bare scalar such as a number.
is_delimiter : U8 -> Bool
is_delimiter = |byte| Ascii.is_whitespace(byte) or byte == 44 or byte == 41 or byte == 93 or byte == 125

skip_whitespace : List(U8), U64 -> U64
skip_whitespace = |bytes, start| Ascii.token_end(bytes, start, |byte| !Ascii.is_whitespace(byte))

# The parser
expect Inspected.parse("A") == Ok(Tag("A", []))
expect Inspected.parse("A(1, B)") == Ok(Tag("A", [Scalar("1"), Tag("B", [])]))
expect Inspected.parse(" { a: 1 } ") == Ok(Record([{ key: "a", value: Scalar("1") }]))
expect Inspected.parse("[1, [2]]") == Ok(Sequence({ open: "[", close: "]", items: [Scalar("1"), Sequence({ open: "[", close: "]", items: [Scalar("2")] })] }))
expect Inspected.parse("\"a\\\"b\"") == Ok(Scalar("\"a\\\"b\""))
expect Inspected.parse("Dict.from_list([(\"k\", 1.0)])") == Ok(Tag("Dict.from_list", [Sequence({ open: "[", close: "]", items: [Sequence({ open: "(", close: ")", items: [Scalar("\"k\""), Scalar("1.0")] })] })]))
expect Inspected.parse("<opaque>") == Ok(Scalar("<opaque>"))
expect Inspected.parse("A B") == Err(Unparseable)
expect Inspected.parse("[1,]") == Err(Unparseable)
expect Inspected.parse("Tag(") == Err(Unparseable)
expect Inspected.parse("{ a: }") == Err(Unparseable)
expect Inspected.parse("\"unterminated") == Err(Unparseable)
expect Inspected.parse("") == Err(Unparseable)

# What is parsed renders back as it was written
expect {
	written = [
		"PaymentFailed({ order: 42.0, reason: Declined })",
		"DbErr({ maybe: Some(-3), pair: (1.0, \"x\"), ratio: 0.5, tags: [\"a\", \"b\"], url: \"postgres://u:p@h/db\" })",
		"Dict.from_list([(\"Authorization\", \"Bearer abc\")])",
		"Wrapped({})",
		"Req(<opaque>)",
		"\"say \\\"hi\\\"\nbye\"",
		"[]",
	]
	written.all(|text| Inspected.parse(text).map_ok(Inspected.to_str) == Ok(text))
}

expect Inspected.parse("A(B(C))").map_ok(Inspected.has_record) == Ok(Bool.False)
expect Inspected.parse("A(B({}))").map_ok(Inspected.has_record) == Ok(Bool.False)
expect Inspected.parse("A([B({ x: 1 })])").map_ok(Inspected.has_record) == Ok(Bool.True)

expect Inspected.unquote("\"a \\\"b\\\" \\\\ c\"") == "a \"b\" \\ c"
expect Inspected.unquote("\"\"") == ""
expect Inspected.unquote("Tag") == "Tag"
expect Inspected.unquote("\"") == "\""
expect Inspected.unquote("42") == "42"

expect Inspected.quote("a \"b\" \\ c\nd") == "\"a \\\"b\\\" \\\\ c\nd\""
expect Inspected.quote("") == "\"\""
expect Inspected.quote("a\"\\b") == Str.inspect("a\"\\b")
expect ["", "plain", "say \"hi\"", "back\\slash", "ends with \\", "héllo\n"].all(|text| Inspected.unquote(Inspected.quote(text)) == text)
