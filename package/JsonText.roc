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
		escaped = s.to_utf8().fold([quote], |acc, byte| escape(acc, byte))
		# Only ASCII was added to valid UTF-8, so nothing is lost here.
		Str.from_utf8_lossy(escaped.append(quote))
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

quote : U8
quote = 34

backslash : U8
backslash = 92

## `acc` with `byte` appended, escaped when JSON requires it.
escape : List(U8), U8 -> List(U8)
escape = |acc, byte|
	if byte == quote {
		acc.append(backslash).append(quote)
	} else if byte == backslash {
		acc.append(backslash).append(backslash)
	} else if byte == 10 {
		acc.append(backslash).append(110) # \n
	} else if byte == 13 {
		acc.append(backslash).append(114) # \r
	} else if byte == 9 {
		acc.append(backslash).append(116) # \t
	} else if byte == 8 {
		acc.append(backslash).append(98) # \b
	} else if byte == 12 {
		acc.append(backslash).append(102) # \f
	} else if byte < 32 {
		# \u00XX
		acc.append(backslash).append(117).append(48).append(48).append(Hex.digit(byte // 16)).append(Hex.digit(byte % 16))
	} else {
		acc.append(byte)
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
