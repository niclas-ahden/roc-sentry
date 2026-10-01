## Tests on the bytes of ASCII text, shared by the modules that scan text
## byte by byte. Internal to the package.
Ascii := [].{

	is_upper : U8 -> Bool
	is_upper = |byte| byte >= 65 and byte <= 90

	is_lower : U8 -> Bool
	is_lower = |byte| byte >= 97 and byte <= 122

	is_digit : U8 -> Bool
	is_digit = |byte| byte >= 48 and byte <= 57

	## Space, tab, newline, carriage return.
	is_whitespace : U8 -> Bool
	is_whitespace = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13

	## Letters, digits, `_` and `.`: what a tag or a record field is named
	## with in `Str.inspect` output, `Dict.from_list` included.
	is_identifier_byte : U8 -> Bool
	is_identifier_byte = |byte| is_upper(byte) or is_lower(byte) or is_digit(byte) or byte == 95 or byte == 46

	## The index of the first byte from `start` that satisfies `stop`, or the
	## end.
	token_end : List(U8), U64, (U8 -> Bool) -> U64
	token_end = |bytes, start, stop| {
		len = bytes.len()
		var $i = start
		while $i < len and !stop(bytes.get($i).ok_or(0)) {
			$i = $i + 1
		}
		$i
	}
}

expect "AZaz09_.".to_utf8().all(Ascii.is_identifier_byte)
expect !"-:( ".to_utf8().any(Ascii.is_identifier_byte)
expect Ascii.token_end("ab cd".to_utf8(), 0, Ascii.is_whitespace) == 2
expect Ascii.token_end("abcd".to_utf8(), 1, Ascii.is_whitespace) == 4
