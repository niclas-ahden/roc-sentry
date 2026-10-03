## Error reporting to [Sentry](https://sentry.io) from Roc.
##
## ```
## import pf.Http
## import pf.Random
## import pf.Stdout
## import pf.Utc
## import sentry.Sentry
##
## main! = |_args| {
##     client = Sentry.init(
##         { http_send!: Http.send!, now!: Utc.now!, random_u64!: Random.seed_u64! },
##         "https://key@o1.ingest.sentry.io/123",
##         { environment: "production", release: "shop@1.4.2" },
##     )?
##
##     # Any value is an error. This one lands in Sentry as an issue titled
##     # `PaymentFailed: { order: 42, reason: Declined }`.
##     event_id = client.capture!(PaymentFailed({ order: 42, reason: Declined }), Error)?
##     Stdout.line!("Reported as ${event_id}")?
##
##     # With more context, build the event first.
##     _ = client.send!(
##         Sentry.event(PaymentFailed({ order: 42, reason: Declined }))
##             .with_level(Fatal)
##             .with_request({ method: "POST", url: "/checkout" })
##             .with_user({ id: "u-7" })
##             .with_tag("job", "checkout"),
##     )?
##     Ok({})
## }
## ```
##
## The error is rendered with `Str.inspect`, so its outermost tag becomes the
## event's type and its payload the value, see [event]. Secrets in it are
## filtered out, see [Scrub], and text is capped so that an event always fits
## Sentry's limits.
##
## Roc has no runtime stack traces and a package cannot do I/O of its own, so
## two things come from the application: [Hooks] wire in the platform's HTTP
## client, clock and random numbers, and the error value carries whatever
## context there is.
## An [Event] adds a request, a user, tags, extra data and a fingerprint on
## top of that.
import http.Request
import http.Response
import Cap
import Dsn
import Envelope
import EventId
import Filter
import Inspected
import PrettyPrint
import RateLimit
import Scrub
import Timestamp

Sentry := [].{

	## The version of this package, reported to Sentry as the `sdk` of every
	## event and in the `X-Sentry-Auth` header. Bumped with each release.
	version : Str
	version = "0.1.1"

	## The platform's effects, wired in at [init]. Roc has no parameterized
	## modules, so they arrive as plain function values. With
	## [basic-cli](https://github.com/niclas-ahden/basic-cli):
	##
	## ```
	## { http_send!: Http.send!, now!: Utc.now!, random_u64!: Random.seed_u64! }
	## ```
	##
	## `http_send!` posts a [roc-lang/http](https://github.com/roc-lang/http)
	## `Request` and returns its `Response`, or the platform's own error
	## `http_err`. `now!` is the time in nanoseconds since the Unix epoch,
	## which stamps events. `random_u64!` is a random number from the
	## operating system, or the platform's error `random_err`. Two of them
	## make each event's id, which Sentry needs to be unique, since it drops
	## an event whose id it has seen before.
	Hooks(http_err, random_err) := {
		http_send! : Request => Try(Response, http_err),
		now! : () => U128,
		random_u64! : () => Try(U64, random_err),
	}

	## What every event from a client carries. `environment` and `release` are
	## how Sentry files events, so set them to what the deployment is. An
	## empty `release` or `server_name` is left out of events. `timeout_ms`
	## bounds each request to Sentry, which the application waits for.
	Options := {
		environment : Str ?? "production",
		release : Str ?? "",
		server_name : Str ?? "",
		timeout_ms : U64 ?? 5_000,
	}

	## Sentry's severity levels, least severe first.
	Level := [Debug, Info, Warning, Error, Fatal].{
		is_eq : _

		## The level as Sentry spells it.
		to_str : Level -> Str
		to_str = |level|
			match level {
				Debug => "debug"
				Info => "info"
				Warning => "warning"
				Error => "error"
				Fatal => "fatal"
			}
	}

	## The HTTP request that was being served when the error happened.
	RequestContext := { method : Str, url : Str }.{
		is_eq : _
	}

	## Who was affected. Sentry needs at least one field to show a user, and
	## an empty field is left out.
	User := {
		id : Str ?? "",
		email : Str ?? "",
		username : Str ?? "",
		ip_address : Str ?? "",
	}.{
		is_eq : _
	}

	## An error with everything Sentry will show about it. [event] makes one
	## from an error value, and the `with_` methods add to it:
	##
	## ```
	## Sentry.event(err).with_level(Fatal).with_tag("job", "sync")
	## ```
	##
	## Secrets are filtered out as things go into the event, see [Scrub], and
	## text is capped there too.
	Event :: {
		type_name : Str,
		value : Str,
		message : Str,
		level : Level,
		request : [WithRequest(RequestContext), NoRequest],
		user : [WithUser(User), NoUser],
		tags : List((Str, Str)),
		extra : List((Str, Str)),
		fingerprint : List(Str),
	}.{
		is_eq : _

		## The event at `level` instead of `Error`.
		with_level : Event, Level -> Event
		with_level = |ev, level| { ..ev, level }

		## The event with the request that was being served. The URL goes
		## through [Scrub.text], so credentials and secret query parameters
		## are filtered out of it.
		with_request : Event, RequestContext -> Event
		with_request = |ev, { method, url }| { ..ev, request: WithRequest({ method, url: filtered_text(url) }) }

		## The event with the user it affected.
		with_user : Event, User -> Event
		with_user = |ev, user| { ..ev, user: WithUser(user) }

		## The event with a tag, replacing one with the same key. Tags are
		## what Sentry searches and filters by, so keep values short and few:
		## Sentry cuts a value at 200 characters. Tags are sent as they are,
		## nothing is filtered out of them.
		with_tag : Event, Str, Str -> Event
		with_tag = |ev, key, value|
			{ ..ev, tags: ev.tags.drop_if(|(existing, _)| existing == key).append((key, value)) }

		## The event with a piece of extra data, replacing one with the same
		## key. Extra data is shown with the event but not searchable. A
		## `value` under a key that [Scrub.is_sensitive] is sent as
		## `[Filtered]`. Any other value that reads as what `Str.inspect`
		## writes, `Str.inspect(config)` say, is filtered field by field as
		## [Scrub.inspect] does, and other text as [Scrub.text] does.
		with_extra : Event, Str, Str -> Event
		with_extra = |ev, key, value| {
			filtered = if Scrub.is_sensitive(key) {
				Filter.marker
			} else {
				filtered_value(value)
			}
			{ ..ev, extra: ev.extra.drop_if(|(existing, _)| existing == key).append((key, filtered)) }
		}

		## The event grouped by `fingerprint` instead of by Sentry's default,
		## which is the exception's type and value. Events with the same
		## fingerprint land in the same issue, so this is how an error that
		## carries varying data, an id or a timestamp, is kept from opening an
		## issue per occurrence. `"{{ default }}"` in the list stands for the
		## default grouping, to refine it rather than replace it.
		with_fingerprint : Event, List(Str) -> Event
		with_fingerprint = |ev, fingerprint| { ..ev, fingerprint }
	}

	## Why an event did not reach Sentry.
	##
	## `SentryRejected`: Sentry answered with a status other than 2xx, carried
	## with the response body. A 429 means the project is rate limited and a
	## 413 that the event was too large after all. `retry_after_seconds` is
	## how long Sentry asks for no more error events, which Sentry's own SDKs
	## respect by dropping events until it has passed. It comes from Sentry's
	## `X-Sentry-Rate-Limits` header, or else its `Retry-After` header, and
	## is 60 for a 429 that has neither, as those SDKs assume. It is 0 when
	## Sentry asks for no wait.
	##
	## `SentryRequestFailed`: `http_send!` failed. Its error is carried as
	## `Str.inspect` renders it, so that a [Client] is the same type whatever
	## the platform.
	SendError : [
		SentryRejected({ status : U16, body : Str, retry_after_seconds : U64 }),
		SentryRequestFailed(Str),
	]

	## A client for one Sentry project, made by [init]. A client made from an
	## empty DSN, and [disabled], send nothing, see [Client.is_enabled].
	Client :: {
		http_send! : Request => Try(Response, Str),
		now! : () => U128,
		random_u64! : () => Try(U64, [RandomFailed]),
		target : [Enabled(Dsn), Disabled],
		options : Options,
	}.{

		## Whether the client sends events. Only [disabled] and a client made
		## from an empty DSN do not, as with Sentry's own SDKs, so that
		## reporting can be switched off by leaving the DSN unset.
		is_enabled : Client -> Bool
		is_enabled = |client|
			match client.target {
				Enabled(_) => Bool.True
				Disabled => Bool.False
			}

		## Send `error` at `level`, returning the event's id: 32 hex
		## characters that Sentry's search finds the event by. Shorthand for
		## [send!] of [event] at that level. A disabled client returns
		## [nil_event_id] without making the event at all.
		capture! : Client, val, Level => Try(Str, SendError)
		capture! = |client, error, level|
			match client.target {
				Enabled(_) => send!(client, event(error).with_level(level))
				Disabled => Ok(nil_event_id)
			}

		## Send `ev`, returning its id. The event is put in an envelope and
		## posted in one HTTP request. Nothing is retried: a `SentryRejected`
		## with status 429 is Sentry asking for no events for its
		## `retry_after_seconds`, and any other failure is the application's
		## to log.
		##
		## A disabled client sends nothing and returns [nil_event_id], as
		## Sentry's Rust SDK does.
		send! : Client, Event => Try(Str, SendError)
		send! = |client, ev| {
			dsn =
				match client.target {
					Enabled(target) => target
					Disabled => return Ok(nil_event_id)
				}
			now! = client.now!
			http_send! = client.http_send!
			random_u64! = client.random_u64!
			now = now!()
			# Should the platform fail to give random numbers, the event still
			# goes out, with an id made from what it is and when it happened.
			random =
				match (random_u64!(), random_u64!()) {
					(Ok(high), Ok(low)) => high.to_u128().shl_wrap(64).bitwise_or(low.to_u128())
					_ => EventId.derived(now, ev.value)
				}
			{ event_id, envelope } = build(client, ev, { now, random }, SentAt(Timestamp.to_iso_8601(now)))
			request =
				Request.from_method(POST)
					.with_uri(Dsn.endpoint(dsn))
					.add_header("X-Sentry-Auth", Dsn.auth_header(dsn, "${sdk_name}/${version}"))
					.add_header("Content-Type", "application/x-sentry-envelope")
					.with_body(envelope.to_utf8())
					.with_timeout(TimeoutMilliseconds(client.options.timeout_ms))
			response = http_send!(request) ? SentryRequestFailed
			status = Response.status(response)
			if status >= 200 and status < 300 {
				Ok(event_id)
			} else {
				Err(
					SentryRejected({
						status,
						body: Str.from_utf8_lossy(Response.body(response)),
						retry_after_seconds: RateLimit.retry_after_seconds(status, header_value(response, "x-sentry-rate-limits"), header_value(response, "retry-after")),
					}),
				)
			}
		}

		## The id and the envelope for `ev` captured at `now`, nanoseconds
		## since the Unix epoch, with an id made from the 128 bits of
		## `random`. Pure, so a test can check what would be sent, and an
		## application that posts envelopes itself, from a queue say, gets
		## them here.
		##
		## The envelope is the one [send!] posts less its `sent_at` header,
		## which [send!] sets to when it posts. Sentry takes the difference
		## between that and when the envelope arrives for the client's clock
		## being off, and moves the event's time to match, so only the time of
		## posting belongs there.
		prepare : Client, Event, { now : U128, random : U128 } -> { event_id : Str, envelope : Str }
		prepare = |client, ev, at| build(client, ev, at, NotSent)
	}

	## A client for the project `dsn` names, with `options`. An empty or blank
	## `dsn` gives a disabled client, which sends nothing. Fails only on a DSN
	## that does not parse, see [Dsn.Problem].
	init : Hooks(http_err, random_err), Str, Options -> Try(Client, [InvalidDsn(Dsn.Problem)])
	init = |hooks, dsn, options| {
		target =
			if dsn.trim().is_empty() {
				Disabled
			} else {
				Enabled(Dsn.parse(dsn)?)
			}
		hooks_http_send! = hooks.http_send!
		hooks_random_u64! = hooks.random_u64!
		Ok({
			http_send!: |request| hooks_http_send!(request).map_err(|err| Str.inspect(err)),
			now!: hooks.now!,
			random_u64!: || hooks_random_u64!().map_err(|_| RandomFailed),
			target,
			options,
		})
	}

	## A client that sends nothing, as one made from an empty DSN does. For
	## tests, and for an application that would rather run without
	## reporting than fail to start on a malformed DSN:
	##
	## ```
	## client =
	##     match Sentry.init(hooks, dsn, options) {
	##         Ok(client) => client
	##         Err(InvalidDsn(problem)) => {
	##             _ = Stderr.line!("SENTRY_DSN is malformed: ${Str.inspect(problem)}")
	##             Sentry.disabled
	##         }
	##     }
	## ```
	disabled : Client
	disabled = {
		http_send!: |_request| Err("disabled"),
		now!: || 0,
		random_u64!: || Err(RandomFailed),
		target: Disabled,
		options: {},
	}

	## The id [Client.send!] returns for an event that a disabled client did
	## not send: 32 zeros.
	nil_event_id : Str
	nil_event_id = "00000000000000000000000000000000"

	## An [Event] for `error` at level `Error`, with nothing else set. `error`
	## can be any value, rendered with [Scrub.inspect], so `Str.inspect` with
	## secrets filtered out.
	##
	## Sentry titles an issue `<type>: <value>`. For a tag the type is the
	## tag's name and the value its payload, and anything else, a string say,
	## has the type `Error` and itself as the value. A string is sent without
	## the quotes `Str.inspect` puts around it:
	##
	## - `PaymentFailed({ order: 42, reason: Declined })` is titled
	##   `PaymentFailed: { order: 42, reason: Declined }`
	## - `AdDisapproved("Ad 123 was disapproved")` is titled
	##   `AdDisapproved: Ad 123 was disapproved`
	## - `Timeout` is titled `Timeout`
	## - `"connection lost"` is titled `Error: connection lost`
	##
	## A failed `Try` is reported as its error, so `Err(Timeout)` is titled
	## `Timeout` too. An error that holds a record is also sent laid out over
	## lines, one field each, which Sentry shows as the event's message.
	event : val -> Event
	event = |error| describe(Str.inspect(error))

	## An [Event] for an error described as text rather than held in a Roc
	## value, titled `<type_name>: <value>`. For an error whose type is only
	## known at run time, a category that alerts are routed by say, or one
	## that comes from outside Roc. [event] is the way for a Roc value.
	##
	## ```
	## Sentry.exception("InvoiceSyncFailed", "Customer 42 has no address")
	## ```
	##
	## `value` is filtered as [Event.with_extra] filters extra data.
	## `type_name` is a name, so like a tag it is sent as it is, less the
	## whitespace around it. An empty `type_name` is `Error`.
	exception : Str, Str -> Event
	exception = |type_name, value| {
		trimmed = type_name.trim()
		named = if trimmed.is_empty() {
			"Error"
		} else {
			Cap.text(trimmed, 0)
		}
		bare_event({ type_name: named, value: filtered_value(value), message: "" })
	}
}

## An event at level `Error` with nothing set but its exception and message.
bare_event : { type_name : Str, value : Str, message : Str } -> Sentry.Event
bare_event = |{ type_name, value, message }| {
	type_name,
	value,
	message,
	level: Error,
	request: NoRequest,
	user: NoUser,
	tags: [],
	extra: [],
	fingerprint: [],
}

sdk_name : Str
sdk_name = "roc-sentry"

## The event for `inspected`, what `Str.inspect` wrote for an error, with its
## secrets filtered out as [Scrub.inspect] does and capped, see [Cap]. See
## [Sentry.event]. Its message is empty when it would add nothing to its
## value.
describe : Str -> Sentry.Event
describe = |inspected|
	match Inspected.parse(inspected) {
		Ok(parsed) => {
			{ tree: cut, dropped } = Cap.tree_before_filtering(unwrap_err(parsed))
			tree = Filter.tree(cut)
			# A lone string is shown without its quotes and escapes, so what
			# was cut from it counts as the text it held.
			{ type_name, value } =
				match tree {
					Tag(name, [Scalar(text)]) => { type_name: name, value: Cap.text(Inspected.unquote(text), dropped.text) }
					Tag(name, payloads) => { type_name: name, value: Cap.text(Str.join_with(payloads.map(Inspected.to_str), ", "), dropped.written) }
					Scalar(text) => { type_name: "Error", value: Cap.text(Inspected.unquote(text), dropped.text) }
					_ => { type_name: "Error", value: Cap.text(tree.to_str(), dropped.written) }
				}
			message = if tree.has_record() {
				Cap.text(PrettyPrint.format(tree), dropped.written)
			} else {
				""
			}
			bare_event({ type_name, value, message })
		}
		Err(Unparseable) => bare_event({ type_name: "Error", value: filtered_text(inspected), message: "" })
	}

## The error in `tree` when it is a failed `Try`, `Err(error)`, and `tree`
## itself otherwise.
unwrap_err : Inspected -> Inspected
unwrap_err = |tree|
	match tree {
		Tag(name, [error]) if name == "Err" => error
		_ => tree
	}

## `text` with its secrets filtered out as [Scrub.text] does, and capped.
filtered_text : Str -> Str
filtered_text = |text| {
	{ kept, dropped } = Cap.text_before_filtering(text)
	Cap.text(Filter.text(kept), dropped)
}

## `value`, extra data or the value of a [Sentry.exception], with its secrets
## filtered out as [Scrub.inspect] does when it parses as what `Str.inspect`
## writes, and as [Scrub.text] does otherwise, and capped.
filtered_value : Str -> Str
filtered_value = |value|
	match Inspected.parse(value) {
		Ok(parsed) => {
			{ tree, dropped } = Cap.tree_before_filtering(parsed)
			Cap.text(Filter.tree(tree).to_str(), dropped.written)
		}
		Err(Unparseable) => filtered_text(value)
	}

## The id and the envelope for `ev`, see [Sentry.Client.prepare]. `sent_at`
## is when [Sentry.Client.send!] posts it, for the envelope's header.
build : Sentry.Client, Sentry.Event, { now : U128, random : U128 }, [SentAt(Str), NotSent] -> { event_id : Str, envelope : Str }
build = |client, ev, { now, random }, sent_at| {
	event_id = EventId.new(random)
	envelope = Envelope.build({
		event_id,
		sent_at,
		timestamp: Timestamp.to_iso_8601(now),
		sdk_name,
		sdk_version: Sentry.version,
		level: Sentry.Level.to_str(ev.level),
		environment: client.options.environment,
		release: client.options.release,
		server_name: client.options.server_name,
		type_name: ev.type_name,
		value: ev.value,
		message: ev.message,
		request: match ev.request {
			WithRequest({ method, url }) => WithRequest({ method, url })
			NoRequest => NoRequest
		},
		user: match ev.user {
			WithUser(user) =>
				[("id", user.id), ("email", user.email), ("username", user.username), ("ip_address", user.ip_address)]
					.keep_if(|(_, field)| !field.is_empty())
			NoUser => []
		},
		tags: ev.tags,
		extra: ev.extra,
		fingerprint: ev.fingerprint,
	})
	{ event_id, envelope }
}

## The value of `response`'s header called `name`, given in lowercase, or ""
## when it has none.
header_value : Response, Str -> Str
header_value = |response, name|
	Response.headers(response)
		.find_first(|h| h.name.with_ascii_lowercased() == name)
		.map_ok(|h| h.value)
		.ok_or("")

# --- Tests ---

## Hooks that never send: the tests below only prepare envelopes.
hooks : Sentry.Hooks([Unused], [Unused])
hooks = { http_send!: |_request| Err(Unused), now!: || 0, random_u64!: || Err(Unused) }

now : U128
now = 1_735_689_600_000_000_000

## The time and the random bits the tests prepare envelopes with.
at : { now : U128, random : U128 }
at = { now, random: 0x0123456789ABCDEF0123456789ABCDEF }

## The event line of the envelope that a client with the usual options would
## post for `ev`.
event_json : Sentry.Event -> Str
event_json = |ev|
	Sentry.init(hooks, "https://key@sentry.io/123", { environment: "test", release: "app@1.0.0" })
		.map_ok(|client| client.prepare(ev, at).envelope.split_on("\n").get(2).ok_or(""))
		.ok_or("")

expect Sentry.Level.to_str(Debug) == "debug"
expect Sentry.Level.to_str(Info) == "info"
expect Sentry.Level.to_str(Warning) == "warning"
expect Sentry.Level.to_str(Error) == "error"
expect Sentry.Level.to_str(Fatal) == "fatal"

# Titles: the type is the tag, the value its payload
expect {
	ev = Sentry.event(PaymentFailed({ order: 42.U64, reason: Declined }))
	ev.type_name == "PaymentFailed" and ev.value == "{ order: 42, reason: Declined }" and ev.level == Error
}
expect {
	ev = Sentry.event(AdDisapproved("Ad 123 was \"disapproved\""))
	ev.type_name == "AdDisapproved" and ev.value == "Ad 123 was \"disapproved\"" and ev.message == ""
}
expect {
	ev = Sentry.event(Timeout)
	ev.type_name == "Timeout" and ev.value == "" and ev.message == ""
}
expect Sentry.event(Failed(404.U16, "not found")).value == "404, \"not found\""
expect Sentry.event(HttpErr(Timeout(Read))).value == "Timeout(Read)"

# A failed Try is reported as its error
expect {
	failed : Try({}, [HttpErr([Timeout])])
	failed = Err(HttpErr(Timeout))
	ev = Sentry.event(failed)
	ev.type_name == "HttpErr" and ev.value == "Timeout"
}
expect {
	ev = Sentry.event(Err("connection lost"))
	ev.type_name == "Error" and ev.value == "connection lost"
}

# Only a tag named exactly Err is unwrapped
expect Sentry.event(Errs("a")).type_name == "Errs"
expect Sentry.event(Err("a", "b")).type_name == "Err"

# A sentence that names a secret is left alone
expect Sentry.event(ParseErr("unexpected token: ']' at line 3")).value == "unexpected token: ']' at line 3"

# Anything else is of type Error, and a string is sent without its quotes
expect {
	ev = Sentry.event("connection lost")
	ev.type_name == "Error" and ev.value == "connection lost" and ev.message == ""
}
expect {
	ev = Sentry.event({ code: 7.U8 })
	ev.type_name == "Error" and ev.value == "{ code: 7 }" and ev.message == "code: 7"
}

# An error that holds a record is also laid out over lines
expect Sentry.event(SomeErr({ cause: Upstream({ host: "api" }), status: 502.U16 })).message == "SomeErr\n  cause: Upstream\n    host: \"api\"\n  status: 502"
expect Sentry.event(Wrapped([Item({ id: 1.U8 })])).message == "Wrapped\n  [\n    Item\n      id: 1\n  ]"

# Secrets are filtered out as the event is made
expect {
	ev = Sentry.event(DbError({ password: "hunter2", url: "postgres://admin:pw@db/app" }))
	ev.value == "{ password: [Filtered], url: \"postgres://[Filtered]:[Filtered]@db/app\" }"
		and ev.message == "DbError\n  password: [Filtered]\n  url: \"postgres://[Filtered]:[Filtered]@db/app\""
}

# Filtering a string keeps its quotes and escapes whole, so the title holds
expect {
	ev = Sentry.event(Failed("token: 'abc"))
	ev.type_name == "Failed" and ev.value == "token: '[Filtered]"
}
expect {
	ev = Sentry.event(Failed("password=ab\"cd"))
	ev.type_name == "Failed" and ev.value == "password=[Filtered]\"cd"
}

# Nothing else is set
expect {
	ev = Sentry.event(Oops)
	ev.request == NoRequest and ev.user == NoUser and ev.tags == [] and ev.extra == [] and ev.fingerprint == []
}

# The builders
expect Sentry.event(Oops).with_level(Fatal).level == Fatal
expect Sentry.event(Oops).with_request({ method: "GET", url: "/x" }).request == WithRequest({ method: "GET", url: "/x" })
expect Sentry.event(Oops).with_request({ method: "GET", url: "/x?token=t" }).request == WithRequest({ method: "GET", url: "/x?token=[Filtered]" })
expect Sentry.event(Oops).with_user({ id: "7" }).user == WithUser({ id: "7" })
expect Sentry.event(Oops).with_tag("a", "1").with_tag("b", "2").tags == [("a", "1"), ("b", "2")]
expect Sentry.event(Oops).with_tag("a", "1").with_tag("a", "2").tags == [("a", "2")]
expect Sentry.event(Oops).with_extra("a", "1").with_extra("a", "2").with_extra("b", "3").extra == [("a", "2"), ("b", "3")]
expect Sentry.event(Oops).with_extra("api_key", "abc").with_extra("dsn", "https://k@h/1").extra == [("api_key", "[Filtered]"), ("dsn", "https://[Filtered]@h/1")]

# Extra data written by Str.inspect is filtered field by field, other text as text
expect {
	config = { credentials: { pw: "hunter2", user: "app" }, pool: 8.U8 }
	Sentry.event(Oops).with_extra("config", Str.inspect(config)).extra == [("config", "{ credentials: [Filtered], pool: 8 }")]
}
expect Sentry.event(Oops).with_extra("note", "retry with token=abc later").extra == [("note", "retry with token=[Filtered] later")]
expect Sentry.event(Oops).with_extra("body", "{\"token\": \"abc\"}").extra == [("body", "{\"token\": \"[Filtered]\"}")]
expect Sentry.event(Oops).with_fingerprint(["{{ default }}", "db"]).fingerprint == ["{{ default }}", "db"]

# init fails only on the DSN
expect
	match Sentry.init(hooks, "nope", { environment: "test" }) {
		Err(InvalidDsn(NoScheme)) => Bool.True
		_ => Bool.False
	}
expect Sentry.init(hooks, "https://key@sentry.io/123", { environment: "test" }).map_ok(Sentry.Client.is_enabled) == Ok(Bool.True)

# An empty or blank DSN switches reporting off instead of failing
expect Sentry.init(hooks, "", { environment: "test" }).map_ok(Sentry.Client.is_enabled) == Ok(Bool.False)
expect Sentry.init(hooks, " \n", { environment: "test" }).map_ok(Sentry.Client.is_enabled) == Ok(Bool.False)
expect Sentry.nil_event_id.count_utf8_bytes() == 32
expect !Sentry.disabled.is_enabled()

# The envelope for a plain event
expect {
	decoded : Try(
		{
			event_id : Str,
			timestamp : Str,
			level : Str,
			environment : Str,
			release : Str,
			sdk : { name : Str, version : Str },
			message : { formatted : Str },
			exception : { values : List({ type : Str, value : Str }) },
		},
		_,
	)
	decoded = Json.parse(event_json(Sentry.event(SomeErr({ foo: "bar" }))))
	decoded
		== Ok({
			event_id: "0123456789ab4def8123456789abcdef",
			timestamp: "2025-01-01T00:00:00.000Z",
			level: "error",
			environment: "test",
			release: "app@1.0.0",
			sdk: { name: "roc-sentry", version: Sentry.version },
			message: { formatted: "SomeErr\n  foo: \"bar\"" },
			exception: { values: [{ type: "SomeErr", value: "{ foo: \"bar\" }" }] },
		})
}

# What is not set is not sent
expect {
	event = event_json(Sentry.event(Oops))
	["server_name", "message", "request", "user", "tags", "extra", "fingerprint"].all(|field| !event.contains("\"${field}\""))
}

# The id in the envelope is the id returned
expect
	match Sentry.init(hooks, "https://key@sentry.io/123", { environment: "test" }) {
		Ok(client) => {
			{ event_id, envelope } = client.prepare(Sentry.event(Oops), at)
			header : Try({ event_id : Str }, _)
			header = Json.parse(envelope.split_on("\n").get(0).ok_or(""))
			header == Ok({ event_id: event_id }) and event_id.count_utf8_bytes() == 32 and !envelope.contains("sent_at")
		}
		Err(_) => Bool.False
	}

# Context goes out filtered, and a user only with the fields that are set
expect {
	ev =
		Sentry.event(DbError({ url: "postgres://admin:pw@db/app" }))
			.with_level(Warning)
			.with_request({ method: "POST", url: "/login?token=abc123&next=/home" })
			.with_user({ id: "7", email: "a@b.c" })
			.with_tag("job", "sync")
			.with_extra("config", "{ password: \"hunter2\" }")
			.with_fingerprint(["db"])
	decoded : Try(
		{
			level : Str,
			exception : { values : List({ value : Str }) },
			message : { formatted : Str },
			request : { method : Str, url : Str },
			user : { id : Str, email : Str },
			tags : { job : Str },
			extra : { config : Str },
			fingerprint : List(Str),
		},
		_,
	)
	decoded = Json.parse(event_json(ev))
	decoded
		== Ok({
			level: "warning",
			exception: { values: [{ value: "{ url: \"postgres://[Filtered]:[Filtered]@db/app\" }" }] },
			message: { formatted: "DbError\n  url: \"postgres://[Filtered]:[Filtered]@db/app\"" },
			request: { method: "POST", url: "/login?token=[Filtered]&next=/home" },
			user: { id: "7", email: "a@b.c" },
			tags: { job: "sync" },
			extra: { config: "{ password: [Filtered] }" },
			fingerprint: ["db"],
		})
		and !event_json(ev).contains("username")
}

# Long text is capped with a note
expect {
	long = "x".repeat(20_000)
	decoded : Try({ exception : { values : List({ value : Str }) } }, _)
	decoded = Json.parse(event_json(Sentry.event(long)))
	match decoded {
		Ok({ exception }) => {
			value = exception.values.first().map_ok(|v| v.value).ok_or("")
			value.count_utf8_bytes() < 8_100 and value.ends_with("… [truncated, was 20000 bytes]")
		}
		Err(_) => Bool.False
	}
}

# A large error is cut before it is filtered, and the note still gives its
# whole size
expect {
	ev = Sentry.event(Resp({ body: "x ".repeat(100_000) }))
	ev.value.count_utf8_bytes() < 8_100
		and ev.value.ends_with("… [truncated, was 200012 bytes]")
			and ev.message.ends_with("… [truncated, was 200015 bytes]")
}
expect {
	ev = Sentry.event(Body("a \"b\" ".repeat(200_000)))
	ev.value.ends_with("… [truncated, was 1200000 bytes]")
}
expect {
	ev = Sentry.event(Oops).with_extra("body", "word ".repeat(200_000)).with_request({ method: "GET", url: "/".concat("a".repeat(100_000)) })
	ev.extra.all(|(_, value)| value.ends_with("… [truncated, was 1000000 bytes]"))
		and ev.request == WithRequest({ method: "GET", url: "/".concat("a".repeat(7_999)).concat("… [truncated, was 100001 bytes]") })
}

# An error described as text keeps its type and has its value filtered
expect {
	ev = Sentry.exception("InvoiceSyncFailed", "Customer 42: postgres://app:pw@db/app")
	ev.type_name == "InvoiceSyncFailed" and ev.value == "Customer 42: postgres://[Filtered]:[Filtered]@db/app" and ev.message == "" and ev.level == Error
}
expect Sentry.exception("Failed", Str.inspect({ api_key: "k", id: 7.U8 })).value == "{ api_key: [Filtered], id: 7 }"
expect Sentry.exception(" ", "lost").type_name == "Error"
expect Sentry.exception(" JobError\n", "lost").type_name == "JobError"
expect Sentry.exception("Failed", "").value == ""
