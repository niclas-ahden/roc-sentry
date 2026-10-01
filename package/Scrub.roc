## Filtering secrets out of an event before it leaves the process.
##
## Sentry's own SDKs leave an exception's message alone, since it is a
## sentence a developer wrote. What they filter is the structured data they
## collect, headers, cookies, query strings and request bodies, by the name of
## each field, replacing what looks sensitive with `[Filtered]`. A Roc error
## is different: it is a value, and `Str.inspect` turns every field of every
## record in it into the event's text. That text is the structured data here,
## so it gets the same treatment, with the same names and the same marker.
##
## An event's error goes through [inspect], and so does extra data that
## `Str.inspect` wrote. Its request URL and any other extra data go through
## [text]. An application can run its own log lines through either.
import Filter

Scrub := [].{

	## `Str.inspect(value)` with secrets replaced by `[Filtered]`:
	##
	## - the value of a record field whose name [is_sensitive], whatever that
	##   value is, a record or a list included
	## - the value of a header or a parameter whose name is sensitive or one
	##   that carries a client's IP address, `X-Forwarded-For`, `X-Real-IP` or
	##   `Forwarded`. It can be a `{ name, value }` or `{ key, value }` record,
	##   a `(name, value)` pair, or a tag holding the two, like
	##   `Header("X-Api-Key", key)`.
	## - inside every string, what [text] replaces
	##
	## A `Cookie` or `Set-Cookie` header, or a `cookie` field, that holds a
	## string keeps the name of each cookie and loses only its value, so the
	## event still shows which cookies were sent.
	##
	## ```
	## Scrub.inspect(LoginFailed({ password: "hunter2", user: "bob" }))
	##     == "LoginFailed({ password: [Filtered], user: \"bob\" })"
	## ```
	##
	## A tag's name does not filter its payload, as Sentry's SDKs never filter
	## an exception's message by its class. `InvalidApiKey("sk_live_abc")`
	## comes back as it is, since nothing names the string. A secret in a
	## field, `InvalidApiKey({ api_key: key })`, is filtered.
	inspect : val -> Str
	inspect = |value| Filter.inspected(Str.inspect(value))

	## `input` with secrets replaced by `[Filtered]`:
	##
	## - the user and password of every URL, so `postgres://user:pw@host/db`
	##   becomes `postgres://[Filtered]:[Filtered]@host/db`. They run to the
	##   last `@` before the host ends at a `/`, `?` or `#`, as URL parsers
	##   read them, so a password may hold `;`, `&`, `'`, `(`, `)` or `,`. One
	##   that holds an unescaped `/`, `?` or `#` is not a valid URL and is not
	##   found.
	## - the value after a name that [is_sensitive] and an `=`, as query
	##   strings and `key=value` pairs write it, or a `:`, as headers, JSON
	##   and `key: value` lines write it. A `:` counts after a quoted name or
	##   one that begins a field, at the start of a line or after `{`, `(`,
	##   `[`, `,` or `;`, so that a sentence like `unexpected token: ']'` is
	##   left alone. A quoted value is replaced inside its quotes, and the
	##   scheme of an `Authorization` value, `Bearer` or `Basic`, is kept. Any
	##   other value ends at whitespace, a quote or one of `& , ; ) ] } < >`,
	##   so what a password holds after one of those is not replaced.
	## - the value of every cookie in a `Cookie` or `Set-Cookie` header, to
	##   the end of the line, each cookie keeping its name
	## - the token after a bare `Bearer`
	##
	## ```
	## Scrub.text("GET /orders?api_key=abc&page=2") == "GET /orders?api_key=[Filtered]&page=2"
	## Scrub.text("Cookie: sessionid=abc; lang=en") == "Cookie: sessionid=[Filtered]; lang=[Filtered]"
	## ```
	text : Str -> Str
	text = |input| Filter.text(input)

	## Whether a field, header or parameter called `name` holds something
	## secret: whether it contains one of the names Sentry's Ruby SDK filters
	## by, in any case. They are `auth`, `token`, `secret`, `session`,
	## `password`, `passwd`, `pwd`, `key`, `jwt`, `bearer`, `sso`, `saml`,
	## `csrf`, `xsrf`, `credentials`, `sid`, `identity` and `cookie`.
	##
	## So `api_key`, `X-Api-Key`, `sessionid`, `PHPSESSID`, `X-CSRFToken` and
	## `password2` are sensitive. So are `monkey`, `author` and `inside`, which
	## is the price of matching anywhere in a name, as Ruby does.
	is_sensitive : Str -> Bool
	is_sensitive = |name| Filter.is_sensitive(name)
}

# Sensitive names
expect
	[
		"password",
		"PASSWORD",
		"password2",
		"api_key",
		"apiKey",
		"X-Api-Key",
		"APIKEY",
		"idToken",
		"session_id",
		"sessionid",
		"JSESSIONID",
		"PHPSESSID",
		"connect.sid",
		"SECRETS",
		"clientsecret",
		"Set-Cookie",
		"mysql_pwd",
		"auth",
		"Authorization",
		"Proxy-Authorization",
		"csrf_token",
		"csrftoken",
		"X-CSRFToken",
		"accesstoken",
		"refreshtoken",
		"OAuth2Token",
		"private_key",
		"privatekey",
		"credentials",
	].all(Scrub.is_sensitive)
expect ["name", "value", "user", "email", "id", "credential", "otp", "", "_"].all(|name| !Scrub.is_sensitive(name))

# Ruby matches anywhere in a name, so these are sensitive too
expect ["monkey", "author", "keyboard", "tokenizer", "inside"].all(Scrub.is_sensitive)

# Errors: fields by name, whatever their value
expect Scrub.inspect(LoginFailed({ password: "hunter2", user: "bob" })) == "LoginFailed({ password: [Filtered], user: \"bob\" })"
expect Scrub.inspect({ credentials: { password: "b", user: "a" }, retries: 3.U8 }) == "{ credentials: [Filtered], retries: 3 }"
expect Scrub.inspect(Sync({ api_key: Some("k"), session_id: 42.U64, tokens: ["a", "b"] })) == "Sync({ api_key: [Filtered], session_id: [Filtered], tokens: [Filtered] })"
expect Scrub.inspect([Auth({ idToken: "t" }), Plain({ email: "a@b.c", user: "Jane" })]) == "[Auth({ idToken: [Filtered] }), Plain({ email: \"a@b.c\", user: \"Jane\" })]"
expect Scrub.inspect({ key: "sk_live_abc" }) == "{ key: [Filtered] }"

# Errors: headers and parameters as records, pairs, tags and dictionaries
expect
	Scrub.inspect(HttpErr({ headers: [{ name: "X-Api-Key", value: "abc" }, { name: "Accept", value: "*/*" }] }))
		== "HttpErr({ headers: [{ name: \"X-Api-Key\", value: [Filtered] }, { name: \"Accept\", value: \"*/*\" }] })"
expect Scrub.inspect([{ key: "X-Api-Key", value: "abc" }, { key: "page", value: "2" }]) == "[{ key: \"X-Api-Key\", value: [Filtered] }, { key: \"page\", value: \"2\" }]"
expect Scrub.inspect({ key: "user", password: "pw", value: "bob" }) == "{ key: \"user\", password: [Filtered], value: \"bob\" }"
expect
	Scrub.inspect(Dict.from_list([("Authorization", "Bearer abc"), ("X-Real-IP", "10.0.0.1"), ("Accept", "*/*")]))
		== "Dict.from_list([(\"Authorization\", [Filtered]), (\"X-Real-IP\", [Filtered]), (\"Accept\", \"*/*\")])"
expect Scrub.inspect([("Cookie", "sid=1"), ("Host", "a.b")]) == "[(\"Cookie\", \"sid=[Filtered]\"), (\"Host\", \"a.b\")]"

# Errors: cookies keep their names and lose their values
expect Scrub.inspect({ name: "Cookie", value: "lang=en; PHPSESSID=abc" }) == "{ name: \"Cookie\", value: \"lang=[Filtered]; PHPSESSID=[Filtered]\" }"
expect Scrub.inspect(Header("Set-Cookie", "id=a3f; Path=/; Secure; HttpOnly")) == "Header(\"Set-Cookie\", \"id=[Filtered]; Path=[Filtered]; Secure; HttpOnly\")"
expect Scrub.inspect({ cookie: "sid=abc==", set_cookie: "a=1" }) == "{ cookie: \"sid=[Filtered]\", set_cookie: \"a=[Filtered]\" }"
expect Scrub.inspect({ cookie: Some("sid=abc"), cookie_secret: "s3cret=" }) == "{ cookie: [Filtered], cookie_secret: [Filtered] }"
expect Scrub.inspect(("Cookie", ["a=1"])) == "(\"Cookie\", [Filtered])"
expect Scrub.inspect([Header("X-Api-Key", "abc"), Header("Accept", "*/*")]) == "[Header(\"X-Api-Key\", [Filtered]), Header(\"Accept\", \"*/*\")]"

# Only a single word names a header, so a sentence is not taken for one
expect Scrub.inspect(Failed("Invalid session for user", "bob")) == "Failed(\"Invalid session for user\", \"bob\")"
expect Scrub.inspect(("", "x")) == "(\"\", \"x\")"

# Errors: what is inside their strings
expect Scrub.inspect(DbErr({ url: "postgres://admin:pw@db/app" })) == "DbErr({ url: \"postgres://[Filtered]:[Filtered]@db/app\" })"
expect Scrub.inspect(Fetch("https://api.example.com/v1?api_key=abc&page=2")) == "Fetch(\"https://api.example.com/v1?api_key=[Filtered]&page=2\")"
expect Scrub.inspect(Body("{\"token\": \"abc\", \"id\": 1}")) == "Body(\"{\\\"token\\\": \\\"[Filtered]\\\", \\\"id\\\": 1}\")"
expect Scrub.inspect("Bearer abc123 was refused") == "\"Bearer [Filtered] was refused\""

# A string is filtered as the text it holds, so its escapes stay whole
expect Scrub.inspect(Failed("password=ab\"cd")) == "Failed(\"password=[Filtered]\\\"cd\")"
expect Scrub.inspect(Failed("token: 'abc")) == "Failed(\"token: '[Filtered]\")"
expect Scrub.inspect(Failed("token: \"abc")) == "Failed(\"token: \\\"[Filtered]\")"
expect Scrub.inspect(Failed("token=a\\b c")) == "Failed(\"token=[Filtered] c\")"

# Errors without secrets come back as they were
expect Scrub.inspect(PaymentFailed({ order: 42.U64, reason: Declined })) == "PaymentFailed({ order: 42, reason: Declined })"
expect Scrub.inspect("héllo wörld") == "\"héllo wörld\""
expect Scrub.inspect(Said("a \"quote\" and a \\")) == "Said(\"a \\\"quote\\\" and a \\\\\")"
expect Filter.inspected("not { inspect output password=x") == "not { inspect output password=[Filtered]"

# Text that parses as one bare value is still filtered
expect Filter.inspected("https://k@h/1") == "https://[Filtered]@h/1"
expect Filter.inspected("password=x") == "password=[Filtered]"
expect Filter.inspected("[password=x, 2]") == "[password=[Filtered], 2]"

# Text: values after a name
expect Scrub.text("password=hunter2 rest") == "password=[Filtered] rest"
expect Scrub.text("Password: hunter2") == "Password: [Filtered]"
expect Scrub.text("\"password\": \"hunter2\"") == "\"password\": \"[Filtered]\""
expect Scrub.text("password = \"a b\"") == "password = \"[Filtered]\""
expect Scrub.text("?api_key=abc&x=1") == "?api_key=[Filtered]&x=1"
expect Scrub.text("x-api-key: abc") == "x-api-key: [Filtered]"
expect Scrub.text("idToken=abc") == "idToken=[Filtered]"
expect Scrub.text("secret_key=abc") == "secret_key=[Filtered]"
expect Scrub.text("token: abc, next") == "token: [Filtered], next"
expect Scrub.text("a=1 session_id=abc secret=def") == "a=1 session_id=[Filtered] secret=[Filtered]"
expect Scrub.text("--auth-token=abc") == "--auth-token=[Filtered]"
expect Scrub.text("X-CSRFToken: abc") == "X-CSRFToken: [Filtered]"
expect Scrub.text("Bearer abc123 extra") == "Bearer [Filtered] extra"
expect Scrub.text("Authorization: Bearer abc") == "Authorization: Bearer [Filtered]"
expect Scrub.text("authorization: Basic dXNlcg==") == "authorization: Basic [Filtered]"
expect Scrub.text("Authorization: abc") == "Authorization: [Filtered]"
expect Scrub.text("monkey=abc author=Jane") == "monkey=[Filtered] author=[Filtered]"

# Text: a `:` gives a value at the start of a field, not in a sentence
expect Scrub.text("user: bob, password: hunter2") == "user: bob, password: [Filtered]"
expect Scrub.text("config:\n  password: hunter2") == "config:\n  password: [Filtered]"
expect Scrub.text("{ token: abc; secret: def }") == "{ token: [Filtered]; secret: [Filtered] }"
expect Scrub.text("Failed(token: abc)") == "Failed(token: [Filtered])"
expect Scrub.text("unexpected token: expected digit at 4") == "unexpected token: expected digit at 4"
expect Scrub.text("Invalid side: Left") == "Invalid side: Left"
expect Scrub.text("Please consider: retrying later") == "Please consider: retrying later"
expect Scrub.text("Missing cookie: please sign in") == "Missing cookie: please sign in"
expect Scrub.text("sent with token=abc") == "sent with token=[Filtered]"
expect Scrub.text("sent headers \"token\": \"abc\"") == "sent headers \"token\": \"[Filtered]\""
expect Scrub.inspect(ParseErr("unexpected token: ']'")) == "ParseErr(\"unexpected token: ']'\")"

# Text: a cookie header keeps the names of its cookies, to the end of the line
expect Scrub.text("Cookie: sessionid=abc123; csrftoken=def\nHost: x") == "Cookie: sessionid=[Filtered]; csrftoken=[Filtered]\nHost: x"
expect Scrub.text("cookie: lang=en; PHPSESSID=abc") == "cookie: lang=[Filtered]; PHPSESSID=[Filtered]"
expect Scrub.text("Set-Cookie: id=a3f; Expires=Thu, 21 Oct 2021 07:28:00 GMT; Secure\r\n") == "Set-Cookie: id=[Filtered]; Expires=[Filtered]; Secure\r\n"
expect Scrub.text("{\"Cookie\": \"a=1; b=2\", \"Host\": \"x\"}") == "{\"Cookie\": \"a=[Filtered]; b=[Filtered]\", \"Host\": \"x\"}"
expect Scrub.text("Cookie: abc123; theme=") == "Cookie: [Filtered]; theme="
expect Scrub.text("Cookie: sid=[Filtered]") == "Cookie: sid=[Filtered]"
expect Scrub.text("cookie_secret=abc; next") == "cookie_secret=[Filtered]; next"

# Text: what is left alone
expect Scrub.text("user=bob page: 2") == "user=bob page: 2"
expect Scrub.text("key=") == "key="
expect Scrub.text("password: \"\"") == "password: \"\""
expect Scrub.text("the password is secret") == "the password is secret"
expect Scrub.text("credentials: { user: 1 }") == "credentials: { user: 1 }"
expect Scrub.text("token: [Filtered]") == "token: [Filtered]"
expect Scrub.text("Bearer") == "Bearer"
expect Scrub.text("https://example.com:8443/path") == "https://example.com:8443/path"
expect Scrub.text("héllo wörld") == "héllo wörld"
expect Scrub.text("") == ""

# Text: credentials in URLs
expect Scrub.text("postgres://user:secret@localhost/db") == "postgres://[Filtered]:[Filtered]@localhost/db"
expect Scrub.text("postgres://user@localhost/db") == "postgres://[Filtered]@localhost/db"
expect Scrub.text("https://key@o1.ingest.sentry.io/123") == "https://[Filtered]@o1.ingest.sentry.io/123"
expect Scrub.text("https://example.com/path?email=a@b.com") == "https://example.com/path?email=a@b.com"
expect Scrub.text("mailto:a@b.com") == "mailto:a@b.com"
expect Scrub.text("first postgres://a:b@h/x then redis://c@h2") == "first postgres://[Filtered]:[Filtered]@h/x then redis://[Filtered]@h2"
expect Scrub.text("a p@ss in user: postgres://user:p@ss@host/db") == "a p@ss in user: postgres://[Filtered]:[Filtered]@host/db"
expect Scrub.text("://") == "://"

# Text: a password holds whatever RFC 3986 allows in it
expect
	["p;ss", "p&ss", "p)ss", "p,ss", "p'ss", "(p)", "p=s!$*+~", "p%2Fss", "pässword"].all(
		|password| Scrub.text("postgres://app:${password}@db/app") == "postgres://[Filtered]:[Filtered]@db/app",
	)
expect Scrub.text("DbErr(postgres://app:Xy;9&k@db:5432)") == "DbErr(postgres://[Filtered]:[Filtered]@db:5432)"
expect Scrub.text("https://user:pw@[::1]:8080/x") == "https://[Filtered]:[Filtered]@[::1]:8080/x"

# Text: an empty user or password stays empty, as in Sentry's Rust SDK
expect Scrub.text("redis://:secret@cache:6379") == "redis://:[Filtered]@cache:6379"
expect Scrub.text("redis://user:@cache") == "redis://[Filtered]:@cache"

# Text: a URL ends where text ends it, so an address after it is left alone
expect Scrub.text("[\"redis://cache\",\"admin@example.com\"]") == "[\"redis://cache\",\"admin@example.com\"]"
expect Scrub.text("redis://cache <admin@example.com>") == "redis://cache <admin@example.com>"

# Text: an unescaped "/" ends the host, as URL parsers read it, so the "@"
# after it is not taken for the end of a password
expect Scrub.text("postgres://app:p/ss@db/app") == "postgres://app:p/ss@db/app"

# Linear in the input, so a megabyte is no slower than it should be
expect Scrub.text("x".repeat(1_000_000)).count_utf8_bytes() == 1_000_000

# A tag's name does not filter its payload, a field's name does
expect Scrub.inspect(InvalidApiKey("sk_live_abc")) == "InvalidApiKey(\"sk_live_abc\")"
expect Scrub.inspect(InvalidApiKey({ api_key: "sk_live_abc" })) == "InvalidApiKey({ api_key: [Filtered] })"
expect Scrub.text("Cookie: sessionid=abc; lang=en") == "Cookie: sessionid=[Filtered]; lang=[Filtered]"
