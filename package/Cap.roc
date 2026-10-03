## Text kept within Sentry's limits. Internal to the package.
##
## Sentry trims a text field to 8192 characters, so longer text is cut here
## instead, at a character boundary and with a note of its original size,
## which Sentry's silent trimming would not leave.
##
## Text is also cut before it is filtered, far beyond where it will be
## capped. Filtering takes about half a second per megabyte of prose, and an
## error that carries a response body can hold several megabytes, of which
## all but the first few kilobytes would be thrown away. The bytes cut there
## still count towards the size the note gives.
import Ascii
import Inspected

Cap := [].{

	## The most bytes of text a field of an event is sent with.
	max_bytes : U64
	max_bytes = 8_000

	## The most bytes of text that are filtered for one field. Far more than
	## [max_bytes], so that a secret cut in two here lies beyond what is
	## sent, unless filtering shrinks the text in front of it by more than
	## the difference.
	max_filtered_bytes : U64
	max_filtered_bytes = 65_536

	## `input` cut to [max_bytes], with a note of its size, when it is
	## longer. `dropped` is how many bytes were cut from it before it was
	## filtered, which count towards that size.
	text : Str, U64 -> Str
	text = |input, dropped| {
		bytes = input.count_utf8_bytes() + dropped
		if bytes <= max_bytes {
			input
		} else {
			"${utf8_prefix(input.to_utf8(), max_bytes)}… [truncated, was ${bytes.to_str()} bytes]"
		}
	}

	## `input` cut to [max_filtered_bytes], see [cut_point], and how many
	## bytes were cut from it.
	text_before_filtering : Str -> { kept : Str, dropped : U64 }
	text_before_filtering = |input| {
		bytes = input.to_utf8()
		if bytes.len() <= max_filtered_bytes {
			{ kept: input, dropped: 0 }
		} else {
			cut = cut_point(bytes, max_filtered_bytes)
			{ kept: Str.from_utf8_lossy(bytes.take_first(cut)), dropped: bytes.len() - cut }
		}
	}

	## `tree` with its scalars cut, in the order `Str.inspect` writes them,
	## so that together they hold at most [max_filtered_bytes]. What was cut
	## is counted twice: as `Str.inspect` writes it, for a field that shows
	## the tree, and as the text it stands for, for a field that shows a
	## string unquoted.
	tree_before_filtering : Inspected -> { tree : Inspected, dropped : { written : U64, text : U64 } }
	tree_before_filtering = |tree| {
		{ tree: cut, budget } = cut_scalars(tree, { left: max_filtered_bytes, written: 0, text: 0 })
		{ tree: cut, dropped: { written: budget.written, text: budget.text } }
	}
}

## How many bytes the scalars still to come may keep, and how many have been
## cut so far, counted both ways [Cap.tree_before_filtering] counts them.
Budget : { left : U64, written : U64, text : U64 }

cut_scalars : Inspected, Budget -> { tree : Inspected, budget : Budget }
cut_scalars = |tree, budget|
	match tree {
		Scalar(scalar) => cut_scalar(scalar, budget)
		Tag(name, payloads) => {
			{ items, budget: after } = cut_all(payloads, budget)
			{ tree: Tag(name, items), budget: after }
		}
		Record(fields) => {
			{ cut, budget: after } = fields.fold(
				{ cut: [], budget },
				|state, { key, value }| {
					{ tree: value_cut, budget: next } = cut_scalars(value, state.budget)
					{ cut: state.cut.append({ key, value: value_cut }), budget: next }
				},
			)
			{ tree: Record(cut), budget: after }
		}
		Sequence({ open, close, items }) => {
			{ items: cut, budget: after } = cut_all(items, budget)
			{ tree: Sequence({ open, close, items: cut }), budget: after }
		}
	}

cut_all : List(Inspected), Budget -> { items : List(Inspected), budget : Budget }
cut_all = |trees, budget|
	trees.fold(
		{ items: [], budget },
		|state, tree| {
			{ tree: cut, budget: next } = cut_scalars(tree, state.budget)
			{ items: state.items.append(cut), budget: next }
		},
	)

## `scalar` cut to the bytes left in `budget`. A string keeps its quotes, and
## the text it stands for is its bytes less one for each escape.
cut_scalar : Str, Budget -> { tree : Inspected, budget : Budget }
cut_scalar = |scalar, budget| {
	bytes = scalar.to_utf8()
	string = Inspected.is_string(scalar)
	inner =
		if string {
			bytes.sublist({ start: 1, len: bytes.len() - 2 })
		} else {
			bytes
		}
	if inner.len() <= budget.left {
		{ tree: Scalar(scalar), budget: { ..budget, left: budget.left - inner.len() } }
	} else {
		cut = cut_point(inner, budget.left)
		kept = inner.take_first(cut)
		gone = inner.drop_first(cut)
		{ gone_text, kept_scalar } =
			if string {
				{ gone_text: unescaped_len(gone), kept_scalar: [double_quote].concat(kept).append(double_quote) }
			} else {
				{ gone_text: gone.len(), kept_scalar: kept }
			}
		{
			tree: Scalar(Str.from_utf8_lossy(kept_scalar)),
			budget: { left: 0, written: budget.written + gone.len(), text: budget.text + gone_text },
		}
	}
}

## Where to cut `bytes` to keep at most `limit` of them: at the last
## whitespace in the [whitespace_window] before `limit`, so that no word,
## URL or token is cut in two with a part of a secret left that the filter
## does not recognize. Failing that, at `limit`, moved back to the start of
## a character and off a backslash escape, which costs text without escapes
## a byte when it ends in an odd number of backslashes.
cut_point : List(U8), U64 -> U64
cut_point = |bytes, limit| {
	window_start =
		if limit > whitespace_window {
			limit - whitespace_window
		} else {
			0
		}
	window = bytes.sublist({ start: window_start, len: limit - window_start })
	match window.find_last_index(Ascii.is_whitespace) {
		Ok(index) => window_start + index
		Err(NotFound) => {
			var $i = limit
			while $i > 0 and is_continuation(bytes.get($i).ok_or(0)) {
				$i = $i - 1
			}
			var $backslashes = 0
			while $backslashes < $i and bytes.get($i - 1 - $backslashes) == Ok(backslash) {
				$backslashes = $backslashes + 1
			}
			if $backslashes % 2 == 1 {
				$i - 1
			} else {
				$i
			}
		}
	}
}

## How far back from the cut [cut_point] looks for whitespace.
whitespace_window : U64
whitespace_window = 1_024

## Whether `byte` continues a UTF-8 character rather than starting one.
is_continuation : U8 -> Bool
is_continuation = |byte| byte >= 0x80 and byte < 0xC0

## The bytes of the text that `escaped`, a run of a string as `Str.inspect`
## writes it, stands for. Each `"` in it is escaped as `\"` and each `\` as
## `\\`, so half of its quotes and backslashes together are escapes.
unescaped_len : List(U8) -> U64
unescaped_len = |escaped| escaped.len() - (escaped.count_if(|byte| byte == backslash) + escaped.count_if(|byte| byte == double_quote)) // 2

## The longest valid UTF-8 prefix of `bytes` that is at most `len` bytes.
utf8_prefix : List(U8), U64 -> Str
utf8_prefix = |bytes, len|
	match Str.from_utf8(bytes.take_first(len)) {
		Ok(text) => text
		Err(_) => if len == 0 {
			""
		} else {
			utf8_prefix(bytes, len - 1)
		}
	}

double_quote : U8
double_quote = 34

backslash : U8
backslash = 92

# The cap
expect Cap.text("short", 0) == "short"
expect Cap.text("é".repeat(4_000), 0) == "é".repeat(4_000)
expect Cap.text("é".repeat(5_000), 0) == "é".repeat(4_000).concat("… [truncated, was 10000 bytes]")

# The cut lands on a character boundary
expect Cap.text("a".concat("é".repeat(5_000)), 0) == "a".concat("é".repeat(3_999)).concat("… [truncated, was 10001 bytes]")
expect utf8_prefix("aé".to_utf8(), 2) == "a"
expect utf8_prefix("aé".to_utf8(), 3) == "aé"
expect utf8_prefix("aé".to_utf8(), 0) == ""

# Bytes cut before filtering count towards the size
expect Cap.text("x".repeat(9_000), 1_000) == "x".repeat(8_000).concat("… [truncated, was 10000 bytes]")
expect Cap.text("short", 10_000) == "short… [truncated, was 10005 bytes]"

# Before filtering, text is cut at whitespace
expect Cap.text_before_filtering("short") == { kept: "short", dropped: 0 }
expect {
	{ kept, dropped } = Cap.text_before_filtering("word ".repeat(20_000))
	kept.count_utf8_bytes() <= Cap.max_filtered_bytes
		and kept.count_utf8_bytes() + dropped == 100_000
			and kept.ends_with("word")
}

# A URL straddling the cut is dropped whole rather than cut in two
expect {
	input = "a ".concat("x".repeat(65_520)).concat(" postgres://user:password@db/app")
	{ kept, dropped } = Cap.text_before_filtering(input)
	!kept.contains("postgres") and kept.count_utf8_bytes() + dropped == input.count_utf8_bytes()
}

# Without whitespace near it, the cut moves back to a character boundary
expect cut_point("aé".to_utf8(), 2) == 1
expect cut_point("abc".to_utf8(), 2) == 2
expect cut_point("a b".to_utf8(), 2) == 1
expect cut_point("éé".to_utf8(), 3) == 2

# And off a backslash escape
expect cut_point("ab\\\"cd".to_utf8(), 3) == 2
expect cut_point("ab\\\\cd".to_utf8(), 4) == 4

expect unescaped_len("a\\\"b\\\\c".to_utf8()) == 5
expect unescaped_len([]) == 0

# Strings in a tree share the budget, in the order they are written
expect {
	big = "x".repeat(40_000)
	tree = Record([{ key: "a", value: Scalar("\"${big}\"") }, { key: "b", value: Scalar("\"${big}\"") }, { key: "c", value: Scalar("\"tail\"") }])
	{ tree: cut, dropped } = Cap.tree_before_filtering(tree)
	match cut {
		Record([{ value: Scalar(a), .. }, { value: Scalar(b), .. }, { value: Scalar(c), .. }]) =>
			a == "\"${big}\"" and b == "\"${"x".repeat(25_536)}\"" and c == "\"\"" and dropped == { written: 14_468, text: 14_468 }
		_ => Bool.False
	}
}

# What was cut from a string is counted as written and as the text it holds
expect {
	tree = Tag("Failed", [Scalar("\"${"\\\"".repeat(40_000)}\"")])
	{ tree: cut, dropped } = Cap.tree_before_filtering(tree)
	match cut {
		Tag("Failed", [Scalar(kept)]) => kept.count_utf8_bytes() == 65_538 and dropped == { written: 14_464, text: 7_232 }
		_ => Bool.False
	}
}

# Numbers and short strings are left as they are
expect Cap.tree_before_filtering(Tag("A", [Scalar("1"), Scalar("\"x\"")])) == { tree: Tag("A", [Scalar("1"), Scalar("\"x\"")]), dropped: { written: 0, text: 0 } }
