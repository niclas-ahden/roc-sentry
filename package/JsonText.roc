## JSON text built by hand. Internal to the package.
##
## The event payload has fields that are present or absent depending on what
## the event carries, which the builtin encoder cannot express from one record
## type, so the envelope is assembled from these pieces instead. The values
## handed to [object] and [array] are already JSON text.
import Hex

JsonText := [].{

	## `s` as a JSON string literal, quoted and escaped per RFC 8259: `"` and
	## `\` get a backslash, the control characters U+0000 to U+001F become
	## `\n`, `\r`, `\t`, `\b`, `\f` or `\u00XX`, and everything else, multi-byte
	## UTF-8 included, is copied as it is.
	string : Str -> Str
	string = |s| {
		# WORKAROUND: https://github.com/roc-lang/roc/issues/11972
		# A fold that appends each byte, escaped, makes an optimized build of
		# the envelope run out of memory in the range prover, so the builtin
		# `replace_each` does the escaping instead.
		body = escapes.fold(s, |text, (raw, escaped)| text.replace_each(raw, escaped))
		"\"${body}\""
	}

	## A JSON object from `fields`, each a key and its value as JSON text, in
	## the order given.
	object : List((Str, Str)) -> Str
	object = |fields| {
		inner = fields.map(|(key, value)| string(key).concat(":").concat(value)) |> Str.join_with(",")
		"{${inner}}"
	}

	## A JSON array from `items`, each already JSON text.
	array : List(Str) -> Str
	array = |items| "[${Str.join_with(items, ",")}]"
}

## What JSON escapes in a string, each with its escaped form. The backslash
## comes first, so that the backslashes the others add stay single.
escapes : List((Str, Str))
escapes = [("\\", "\\\\"), ("\"", "\\\"")].concat(List.repeat({}, 32).map_with_index(|{}, index| control_escape(index.to_u8_wrap())))

## A control character U+0000 to U+001F and how JSON writes it.
control_escape : U8 -> (Str, Str)
control_escape = |byte| {
	escaped =
		if byte == 10 {
			"\\n"
		} else if byte == 13 {
			"\\r"
		} else if byte == 9 {
			"\\t"
		} else if byte == 8 {
			"\\b"
		} else if byte == 12 {
			"\\f"
		} else {
			Str.from_utf8_lossy([92, 117, 48, 48, Hex.digit(byte // 16), Hex.digit(byte % 16)])
		}
	(Str.from_utf8_lossy([byte]), escaped)
}

expect JsonText.string("plain") == "\"plain\""
expect JsonText.string("") == "\"\""
expect JsonText.string("say \"hi\"") == "\"say \\\"hi\\\"\""
expect JsonText.string("back\\slash") == "\"back\\\\slash\""
expect JsonText.string("line\nbreak\ttab\rcr") == "\"line\\nbreak\\ttab\\rcr\""
expect JsonText.string("\u(8)\u(c)") == "\"\\b\\f\""
expect JsonText.string("\u(0)\u(1)\u(1f)") == "\"\\u0000\\u0001\\u001f\""
expect JsonText.string("héllo €") == "\"héllo €\""

# The DEL character and everything above the control range are copied as is
expect JsonText.string("\u(7f)") == "\"\u(7f)\""

# What is written is what the builtin parser reads back
expect {
	original = "a\"b\\c\nd\u(1)é/"
	decoded : Try(Str, _)
	decoded = Json.parse(JsonText.string(original))
	decoded == Ok(original)
}

expect JsonText.object([]) == "{}"
expect JsonText.object([("a", "1"), ("b", "\"x\"")]) == "{\"a\":1,\"b\":\"x\"}"
expect JsonText.object([("we\"ird", "null")]) == "{\"we\\\"ird\":null}"
expect JsonText.array([]) == "[]"
expect JsonText.array(["1", "\"x\"", "{}"]) == "[1,\"x\",{}]"
