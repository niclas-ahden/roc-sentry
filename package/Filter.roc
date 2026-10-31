## How secrets are found and replaced. Internal to the package: `Scrub` is
## the public face of this module and documents what is filtered, and
## `Sentry.event` filters the tree it parses an error into here, so that the
## error is parsed only once.
import Ascii
import Inspected

Filter := [].{

	## The marker that replaces a secret, as Sentry's SDKs write it.
	marker : Str
	marker = "[Filtered]"

	## Whether `name` contains one of [sensitive_names], ignoring case, as
	## Sentry's Ruby SDK matches them.
	is_sensitive : Str -> Bool
	is_sensitive = |name| {
		lowered = name.with_ascii_lowercased()
		sensitive_names.any(|sensitive| lowered.contains(sensitive))
	}

	## `input` with the credentials in its URLs and the values after its
	## sensitive names replaced.
	text : Str -> Str
	text = |input| secrets(credentials(input))

	## `tree` with its secrets replaced: the values of sensitive record
	## fields and of secret headers, and inside every string what [text]
	## replaces. A string is filtered as the text it holds, so its quotes
	## and escapes are put back around the result. Any other scalar goes
	## through [text] too: `Str.inspect` writes only numbers and markers like
	## `<opaque>` there, which it leaves alone, but text that merely parses
	## as its output, a lone URL say, has its secrets in one.
	tree : Inspected -> Inspected
	tree = |value|
		match value {
			Scalar(scalar) =>
				if Inspected.is_string(scalar) {
					Scalar(Inspected.quote(text(Inspected.unquote(scalar))))
				} else {
					Scalar(text(scalar))
				}
			Tag(name, payloads) => Tag(name, pair_items(payloads))
			Record(fields) =>
				match pair_name(fields) {
					Ok(name) =>
						Record(
							fields.map(
								|field|
									if field.key == "name" or field.key == "key" {
										{ key: field.key, value: Filter.tree(field.value) }
									} else if field.key == "value" and names_secret(name) {
										{ key: field.key, value: secret_value(name, field.value) }
									} else {
										by_name(field)
									},
							),
						)
					Err(NotAPair) => Record(fields.map(by_name))
				}
			Sequence({ open, close, items }) =>
				if open == "(" {
					Sequence({ open, close, items: pair_items(items) })
				} else {
					Sequence({ open, close, items: items.map(Filter.tree) })
				}
		}

	## What `Str.inspect` wrote, filtered as a [tree]. Text that does not
	## parse as its output, from a custom `to_inspect` say, is filtered as
	## [text].
	inspected : Str -> Str
	inspected = |written|
		match Inspected.parse(written) {
			Ok(parsed) => Filter.tree(parsed).to_str()
			Err(Unparseable) => text(written)
		}
}

## The names Sentry's Ruby SDK filters a key by when the key contains one of
## them. Its list also has `set-cookie`, which `cookie` already covers.
sensitive_names : List(Str)
sensitive_names = [
	"auth",
	"token",
	"secret",
	"session",
	"password",
	"passwd",
	"pwd",
	"key",
	"jwt",
	"bearer",
	"sso",
	"saml",
	"csrf",
	"xsrf",
	"credentials",
	"sid",
	"identity",
	"cookie",
]

## Headers that carry a client's IP address, which Sentry's SDKs leave out
## as personal data.
ip_headers : List(Str)
ip_headers = ["x-forwarded-for", "x-real-ip", "forwarded"]

## The headers that carry cookies, in lowercase, with `_` for a field name.
cookie_headers : List(Str)
cookie_headers = ["cookie", "set-cookie", "set_cookie"]

## The attributes that end a `Set-Cookie` header and have no value.
cookie_flags : List(Str)
cookie_flags = ["secure", "httponly", "partitioned"]

## A record field filtered by its name: all of its value when the name is
## sensitive, and what is secret inside the value otherwise.
by_name : { key : Str, value : Inspected } -> { key : Str, value : Inspected }
by_name = |{ key, value }|
	if Filter.is_sensitive(key) {
		{ key, value: secret_value(key, value) }
	} else {
		{ key, value: Filter.tree(value) }
	}

## What is left of `value`, the value of a sensitive header or field called
## `name`: the cookies of a cookie header with their names kept, see
## [cookie_values], and the marker for anything else.
secret_value : Str, Inspected -> Inspected
secret_value = |name, value|
	match value {
		Scalar(scalar) if is_cookie_header(name) and Inspected.is_string(scalar) => Scalar(Inspected.quote(cookie_values(Inspected.unquote(scalar))))
		_ => Scalar(Filter.marker)
	}

## Whether `name` is `Cookie` or `Set-Cookie`, in any case.
is_cookie_header : Str -> Bool
is_cookie_header = |name| cookie_headers.contains(name.with_ascii_lowercased())

## `header`, the value of a `Cookie` or `Set-Cookie` header, with the name of
## each cookie kept and its value replaced, so that the event still shows
## which cookies were sent. A part without a name is replaced whole, unless
## it is one of the [cookie_flags].
cookie_values : Str -> Str
cookie_values = |header|
	Str.join_with(header.split_on(";").map(cookie_value), ";")

## One part of a cookie header, see [cookie_values].
cookie_value : Str -> Str
cookie_value = |part|
	match part.split_first("=") {
		Ok({ before, after }) =>
			if after.trim().is_empty() {
				part
			} else {
				"${before}=${Filter.marker}"
			}
		Err(NotFound) =>
			if part.trim().is_empty() or cookie_flags.contains(part.trim().with_ascii_lowercased()) {
				part
			} else if part.starts_with(" ") {
				" ${Filter.marker}"
			} else {
				Filter.marker
			}
	}

## The name that a `{ name, value }` or `{ key, value }` record gives its
## value, the way a header or a parameter is written, or `NotAPair`.
pair_name : List({ key : Str, value : Inspected }) -> Try(Str, [NotAPair])
pair_name = |fields|
	if fields.any(|field| field.key == "value") {
		fields
			.keep_oks(
				|field|
					if field.key == "name" or field.key == "key" {
						header_name(field.value)
					} else {
						Err(NotAPair)
					},
			)
			.first()
			.map_err(|_| NotAPair)
	} else {
		Err(NotAPair)
	}

## The items of a tuple or the payloads of a tag. A pair whose first item
## names a secret header, `("Cookie", "...")` or `Header("X-Api-Key", "...")`,
## has its second filtered.
pair_items : List(Inspected) -> List(Inspected)
pair_items = |items|
	match items {
		[first, second] =>
			match header_name(first) {
				Ok(name) if names_secret(name) => [first, secret_value(name, second)]
				_ => items.map(Filter.tree)
			}
		_ => items.map(Filter.tree)
	}

## The text of `tree` when it is a string that could name a header or a
## parameter: one word of name characters, so that a sentence that happens
## to say `session` is not taken for one.
header_name : Inspected -> Try(Str, [NotAPair])
header_name = |tree|
	match tree {
		Scalar(scalar) if Inspected.is_string(scalar) => {
			name = Inspected.unquote(scalar)
			if !name.is_empty() and name.to_utf8().all(is_name_byte) {
				Ok(name)
			} else {
				Err(NotAPair)
			}
		}
		_ => Err(NotAPair)
	}

## Whether the header or parameter called `name` has its value filtered.
names_secret : Str -> Bool
names_secret = |name| Filter.is_sensitive(name) or ip_headers.contains(name.with_ascii_lowercased())

## The user info of every URL replaced, as Sentry's Rust SDK replaces it: a
## user that is not empty, and a password that is not empty. The user info
## runs from `://` to the last `@` in the authority, see
## [is_authority_byte].
credentials : Str -> Str
credentials = |input| {
	bytes = input.to_utf8()
	len = bytes.len()
	var $out = []
	var $i = 0
	while $i < len {
		if matches_at(bytes, $i, "://") {
			after = $i + 3
			end = Ascii.token_end(bytes, after, |byte| !is_authority_byte(byte))
			$out = $out.concat([58, 47, 47]) # ://
			match last_index_of(bytes, 64, after, end) { # @
				Ok(at) => {
					userinfo = Str.from_utf8_lossy(bytes.sublist({ start: after, len: at - after }))
					hidden =
						match userinfo.split_first(":") {
							Ok({ before, after: password }) => "${hide(before)}:${hide(password)}"
							Err(NotFound) => hide(userinfo)
						}
					$out = $out.concat(hidden.to_utf8())
					# The `@` itself is copied by the next round
					$i = at
				}
				Err(NotFound) => {
					$i = after
				}
			}
		} else {
			$out = $out.append(bytes.get($i).ok_or(0))
			$i = $i + 1
		}
	}
	# Only ASCII was spliced into valid UTF-8 at ASCII boundaries
	Str.from_utf8_lossy($out)
}

## The value after every sensitive name, and the token after every bare
## `Bearer`, replaced. Each name is read once, so this is linear in `input`.
secrets : Str -> Str
secrets = |input| {
	bytes = input.to_utf8()
	len = bytes.len()
	var $out = []
	var $i = 0
	while $i < len {
		byte = bytes.get($i).ok_or(0)
		starts_name = is_name_byte(byte) and ($i == 0 or !is_name_byte(bytes.get($i - 1).ok_or(0)))
		if starts_name {
			name_end = Ascii.token_end(bytes, $i, |b| !is_name_byte(b))
			match secret_after(bytes, $i, name_end) {
				Ok({ value_start, value_end, replacement }) => {
					$out = $out.concat(bytes.sublist({ start: $i, len: value_start - $i })).concat(replacement.to_utf8())
					$i = value_end
				}
				Err(NoSecret) => {
					$out = $out.concat(bytes.sublist({ start: $i, len: name_end - $i }))
					$i = name_end
				}
			}
		} else {
			$out = $out.append(byte)
			$i = $i + 1
		}
	}
	Str.from_utf8_lossy($out)
}

## The secret that follows the name from `start` to `name_end`, as the range
## to replace and what replaces it, or `NoSecret` when none does.
secret_after : List(U8), U64, U64 -> Try({ value_start : U64, value_end : U64, replacement : Str }, [NoSecret])
secret_after = |bytes, start, name_end| {
	name = Str.from_utf8_lossy(bytes.sublist({ start, len: name_end - start }))
	if name.with_ascii_lowercased() == "bearer" and Ascii.is_whitespace(bytes.get(name_end).ok_or(0)) {
		value_start = skip_blanks(bytes, name_end)
		value_end = Ascii.token_end(bytes, value_start, is_terminator)
		return if value_end > value_start {
			Ok({ value_start, value_end, replacement: Filter.marker })
		} else {
			Err(NoSecret)
		}
	}
	if !Filter.is_sensitive(name) {
		return Err(NoSecret)
	}
	closed = is_quote(bytes.get(name_end).ok_or(0))
	quoted = start > 0 and is_quote(bytes.get(start - 1).ok_or(0)) and closed
	# The quote that closes a JSON key, then spaces, then the separator
	after_name = if closed {
		name_end + 1
	} else {
		name_end
	}
	separator = skip_blanks(bytes, after_name)
	value_start = skip_blanks(bytes, separator + 1)
	# A `=` gives a name its value wherever it is. A `:` does in a quoted key
	# or at the start of a field, but not in the middle of a sentence.
	separates =
		match bytes.get(separator) {
			Ok(61) => Bool.True # =
			Ok(58) => quoted or begins_field(bytes, start) # :
			_ => Bool.False
		}
	if !separates {
		Err(NoSecret)
	} else if is_cookie_header(name) {
		cookie_range(bytes, value_start)
	} else {
		value_range(bytes, value_start).map_ok(|{ value_start: from, value_end }| { value_start: from, value_end, replacement: Filter.marker })
	}
}

## Whether the name at `start` begins a field: only spaces and tabs stand
## between it and the start of its line, an opening bracket, a `,` or a `;`.
## That is where a header, a `key: value` line or an inline object puts a
## name, while a sentence such as `unexpected token: ']'` does not.
begins_field : List(U8), U64 -> Bool
begins_field = |bytes, start| {
	var $i = start
	while $i > 0 and is_blank(bytes.get($i - 1).ok_or(0)) {
		$i = $i - 1
	}
	$i == 0 or field_openers.contains(bytes.get($i - 1).ok_or(0))
}

## What a field can follow: a line break, an opening bracket, `,` or `;`.
field_openers : List(U8)
field_openers = "\n\r{([,;".to_utf8()

## The cookies of a cookie header's value starting at `start`, which run to
## the end of the line, or inside the quotes, with what [cookie_values]
## replaces them with.
cookie_range : List(U8), U64 -> Try({ value_start : U64, value_end : U64, replacement : Str }, [NoSecret])
cookie_range = |bytes, start| {
	{ value_start, value_end } =
		if is_quote(bytes.get(start).ok_or(0)) {
			{ value_start: start + 1, value_end: closing_quote(bytes, start) }
		} else {
			{ value_start: start, value_end: Ascii.token_end(bytes, start, |byte| byte == 10 or byte == 13) }
		}
	if value_end > value_start {
		cookies = Str.from_utf8_lossy(bytes.sublist({ start: value_start, len: value_end - value_start }))
		Ok({ value_start, value_end, replacement: cookie_values(cookies) })
	} else {
		Err(NoSecret)
	}
}

## The range of a value starting at `start`: the inside of its quotes, or the
## token up to the next terminator. An `Authorization` scheme is kept and the
## token after it is the value. A value that opens a bracket is left alone,
## since the names inside it are checked on their own, and so is one that is
## already filtered.
value_range : List(U8), U64 -> Try({ value_start : U64, value_end : U64 }, [NoSecret])
value_range = |bytes, start| {
	first = bytes.get(start).ok_or(0)
	if first == 91 or first == 123 or first == 40 { # [ { (
		Err(NoSecret)
	} else if is_quote(first) {
		value_start = start + 1
		value_end = closing_quote(bytes, start)
		if value_end > value_start {
			Ok({ value_start, value_end })
		} else {
			Err(NoSecret)
		}
	} else {
		value_end = Ascii.token_end(bytes, start, is_terminator)
		if value_end == start {
			Err(NoSecret)
		} else if is_auth_scheme(bytes.sublist({ start, len: value_end - start })) {
			token_start = skip_blanks(bytes, value_end)
			token_stop = Ascii.token_end(bytes, token_start, is_terminator)
			if token_stop > token_start {
				Ok({ value_start: token_start, value_end: token_stop })
			} else {
				Ok({ value_start: start, value_end })
			}
		} else {
			Ok({ value_start: start, value_end })
		}
	}
}

is_auth_scheme : List(U8) -> Bool
is_auth_scheme = |word| {
	lowered = Str.from_utf8_lossy(word).with_ascii_lowercased()
	lowered == "bearer" or lowered == "basic"
}

## Whether `needle` is at `index` of `bytes`.
matches_at : List(U8), U64, Str -> Bool
matches_at = |bytes, index, needle| {
	needle_bytes = needle.to_utf8()
	bytes.sublist({ start: index, len: needle_bytes.len() }) == needle_bytes
}

## Letters, digits, `_`, `.` and `-`: what a field, header or parameter name
## is made of. The `-` is what a Roc name does not have, as in `X-Api-Key`.
is_name_byte : U8 -> Bool
is_name_byte = |byte| Ascii.is_identifier_byte(byte) or byte == 45

## `"` or `'`.
is_quote : U8 -> Bool
is_quote = |byte| byte == 34 or byte == 39

## What ends an unquoted value: whitespace, a quote, a closing
## bracket, or punctuation that separates values.
is_terminator : U8 -> Bool
is_terminator = |byte|
	Ascii.is_whitespace(byte) or is_quote(byte) or byte == 38 or byte == 44 or byte == 59 or byte == 41 or byte == 93 or byte == 125 or byte == 60 or byte == 62

## What a URL's authority is made of, per RFC 3986: letters, digits,
## [authority_punctuation], and any byte of a non-ASCII character, which a
## URL parser would percent-encode. Anything else ends it, so a `/`, `?` or
## `#` does, as in the URL parser of Sentry's Rust SDK, and so do
## whitespace, `"`, `<` and `>`, which end a URL in text.
is_authority_byte : U8 -> Bool
is_authority_byte = |byte|
	Ascii.is_upper(byte) or Ascii.is_lower(byte) or Ascii.is_digit(byte) or byte >= 128 or authority_punctuation.contains(byte)

## The punctuation RFC 3986 allows in an authority: the unreserved `-._~`,
## the `%` of an escape, the sub-delimiters `!$&'()*+,;=`, the `:` before a
## password or a port, the `@` after the user info, and the brackets around
## an IPv6 host.
authority_punctuation : List(U8)
authority_punctuation = "-._~%!$&'()*+,;=:@[]".to_utf8()

## `part` of the user info, a user or a password, replaced unless it is
## empty.
hide : Str -> Str
hide = |part| if part.is_empty() {
	""
} else {
	Filter.marker
}

## The last `needle` in `bytes` at an index in `start..end`.
last_index_of : List(U8), U8, U64, U64 -> Try(U64, [NotFound])
last_index_of = |bytes, needle, start, end| {
	var $found = Err(NotFound)
	var $i = start
	while $i < end {
		if bytes.get($i) == Ok(needle) {
			$found = Ok($i)
		}
		$i = $i + 1
	}
	$found
}

## The index after the spaces and tabs from `start`.
skip_blanks : List(U8), U64 -> U64
skip_blanks = |bytes, start| Ascii.token_end(bytes, start, |byte| !is_blank(byte))

## A space or a tab.
is_blank : U8 -> Bool
is_blank = |byte| byte == 32 or byte == 9

## The index of the quote that closes the one at `open`, the same quote not
## escaped by a backslash, or the end.
closing_quote : List(U8), U64 -> U64
closing_quote = |bytes, open| {
	len = bytes.len()
	opening = bytes.get(open).ok_or(0)
	var $i = open + 1
	var $done = Bool.False
	while !$done and $i < len {
		byte = bytes.get($i).ok_or(0)
		if byte == opening {
			$done = Bool.True
		} else if byte == 92 { # \
			$i = $i + 2
		} else {
			$i = $i + 1
		}
	}
	if $i > len {
		len
	} else {
		$i
	}
}

expect closing_quote("'ab' c".to_utf8(), 0) == 3
expect closing_quote("\"a\\\"b\" c".to_utf8(), 0) == 5
expect closing_quote("'abc".to_utf8(), 0) == 4
expect closing_quote("'ab\\".to_utf8(), 0) == 4
