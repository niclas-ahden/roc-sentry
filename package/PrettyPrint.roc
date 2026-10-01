## Errors laid out over lines, for the message an event shows in Sentry.
## Internal to the package.
##
## `Str.inspect` writes a value on one line. That is precise but hard to read
## once an error carries a few records, so [format] lays it out over several
## lines instead:
##
## ```
## HttpError({ cause: Upstream({ host: "api" }), status: 502 })
## ```
##
## becomes
##
## ```
## HttpError
##   cause: Upstream
##     host: "api"
##   status: 502
## ```
##
## Records break onto their own lines, one field each. A value without a
## record in it stays on one line, so `Timeout(Read(Socket))` is left as it
## is.
import Inspected exposing [Inspected]

PrettyPrint := [].{

	## `tree` over several lines with two spaces of indentation per level. A
	## top-level record is written without its braces and a top-level string
	## without its quotes.
	format : Inspected -> Str
	format = |tree|
		match tree {
			Record(fields) if !fields.is_empty() => Str.join_with(field_lines(fields, 0), "\n")
			Scalar(text) => Inspected.unquote(text)
			_ => Str.join_with(lines(tree, 0), "\n")
		}
}

## Whether `value` renders on one line: it holds no record with fields and no
## string with a line break.
is_flat : Inspected -> Bool
is_flat = |value|
	match value {
		Scalar(text) => !text.contains("\n")
		Tag(_, payloads) => payloads.all(|payload| is_flat(payload) and !is_record(payload))
		Record(fields) => fields.is_empty()
		Sequence({ items, .. }) => items.all(|item| is_flat(item) and !is_record(item))
	}

is_record : Inspected -> Bool
is_record = |value|
	match value {
		Record(fields) => !fields.is_empty()
		_ => Bool.False
	}

## `value` as lines, each indented by `indent` spaces or more. A tag's
## payloads go under its name, a record's fields under its braces, a
## sequence's items between its brackets, and a string's continuation lines
## under its first.
lines : Inspected, U64 -> List(Str)
lines = |value, indent| {
	pad = " ".repeat(indent)
	if is_flat(value) {
		[pad.concat(value.to_str())]
	} else {
		match value {
			Scalar(text) =>
				text.split_on("\n").map_with_index(
					|line, index| if index == 0 {
						pad.concat(line)
					} else {
						"${pad}  ${line}"
					},
				)
			Tag(name, payloads) =>
				[pad.concat(name)].concat(
					payloads.join_map(
						|payload|
							match payload {
								Record(fields) if !fields.is_empty() => field_lines(fields, indent + 2)
								_ => lines(payload, indent + 2)
							},
					),
				)
			Record(fields) => [pad.concat("{")].concat(field_lines(fields, indent + 2)).append(pad.concat("}"))
			Sequence({ open, close, items }) => [pad.concat(open)].concat(items.join_map(|item| lines(item, indent + 2))).append(pad.concat(close))
		}
	}
}

## `key: value` lines, the value's first line on the key's line and the rest
## indented under it. A record value's fields go straight under the key.
field_lines : List({ key : Str, value : Inspected }), U64 -> List(Str)
field_lines = |fields, indent| {
	pad = " ".repeat(indent)
	fields.join_map(
		|{ key, value }|
			match value {
				Record(nested) if !nested.is_empty() => ["${pad}${key}:"].concat(field_lines(nested, indent + 2))
				_ => {
					value_lines = lines(value, indent)
					first = value_lines.first().ok_or("")
					["${pad}${key}: ${first.trim_start()}"].concat(value_lines.drop_first(1))
				}
			},
	)
}

## `text`, the output of `Str.inspect`, laid out over lines.
layout : Str -> Str
layout = |text| Inspected.parse(text).map_ok(PrettyPrint.format).ok_or("<unparseable>")

# One line stays one line
expect layout("Simple") == "Simple"
expect layout("Yikes(Ouch)") == "Yikes(Ouch)"
expect layout("Nested(Inner(Deep(\"s\")))") == "Nested(Inner(Deep(\"s\")))"
expect layout("Multi(\"a\", 2.0)") == "Multi(\"a\", 2.0)"
expect layout("[Ouch, Yikes]") == "[Ouch, Yikes]"
expect layout("(1.0, \"two\")") == "(1.0, \"two\")"
expect layout("Dict.from_list([(\"k\", 1.0)])") == "Dict.from_list([(\"k\", 1.0)])"
expect layout("Err(Timeout)") == "Err(Timeout)"
expect layout("-3") == "-3"
expect layout("<opaque>") == "<opaque>"
expect layout("{}") == "{}"
expect layout("[]") == "[]"
expect layout("Wrapped({})") == "Wrapped({})"

# Records break out, one field per line
expect layout("{ a: 1.0, b: \"x\" }") == "a: 1.0\nb: \"x\""
expect layout("UnexpectedStatus({ status: 403 })") == "UnexpectedStatus\n  status: 403"
expect layout("Tag({ nested: { deep: { x: 1 } } })") == "Tag\n  nested:\n    deep:\n      x: 1"
expect layout("Multi(A(B), { x: 1 })") == "Multi\n  A(B)\n  x: 1"
expect layout("[A({ x: 1 }), B]") == "[\n  A\n    x: 1\n  B\n]"
expect layout("[{ a: 1 }, { a: 2 }]") == "[\n  {\n    a: 1\n  }\n  {\n    a: 2\n  }\n]"
expect layout("Tag({ list: [Item({ id: 1 }), Item({ id: 2 })] })") == "Tag\n  list: [\n    Item\n      id: 1\n    Item\n      id: 2\n  ]"

# What Str.inspect gives for a realistic error
expect
	layout("SomeErr({ bar: [1.0, 2.0, 3.0], cause: AnotherErr({ baz: \"hurray!\", cause: Yikes(Ouch) }), flag: True, foo: \"oh, \\\"no\\\"!\nline2\", n: 1.5 })")
		== "SomeErr\n  bar: [1.0, 2.0, 3.0]\n  cause: AnotherErr\n    baz: \"hurray!\"\n    cause: Yikes(Ouch)\n  flag: True\n  foo: \"oh, \\\"no\\\"!\n    line2\"\n  n: 1.5"

# A top-level string loses its quotes and escapes
expect layout("\"plain\"") == "plain"
expect layout("\"a \\\"q\\\" \\\\ b\"") == "a \"q\" \\ b"
