## What every test in this directory shares: a DSN, hooks that answer from a
## canned response or check the request they are given, and a decoder for the
## envelope a client posts. No test touches the network.
import http.Request exposing [Request]
import http.Response exposing [Response]
import sentry.Sentry

Support := [].{

	dsn : Str
	dsn = "https://publickey@o1.ingest.sentry.io/123"

	## The endpoint [dsn] posts to.
	endpoint : Str
	endpoint = "https://o1.ingest.sentry.io/api/123/envelope/"

	## A fixed clock: 2025-01-01T00:00:00Z.
	now : U128
	now = 1_735_689_600_000_000_000

	## A fixed random number, the same at every call.
	random_u64 : U64
	random_u64 = 0x0123456789ABCDEF

	## The id of every event sent with these hooks: [random_u64] twice, with
	## the bits of a version 4 UUID set.
	event_id : Str
	event_id = "0123456789ab4def8123456789abcdef"

	## What Sentry answers with when it accepts an event.
	accepted : Response
	accepted = Response.from_status(200).with_body(Str.to_utf8("{\"id\":\"${event_id}\"}"))

	## Hooks whose `http_send!` answers every request with `response`.
	answering : Response -> Sentry.Hooks([Unreachable], [Unreachable])
	answering = |response| { http_send!: |_request| Ok(response), now!: || now, random_u64!: || Ok(random_u64) }

	## Hooks whose `http_send!` fails with `err`.
	failing : err -> Sentry.Hooks(err, [Unreachable])
	failing = |err| { http_send!: |_request| Err(err), now!: || now, random_u64!: || Ok(random_u64) }

	## Hooks whose `http_send!` runs `check` on the request and fails with what
	## it finds wrong, and otherwise answers as Sentry does when it accepts.
	checking : (Request -> Try({}, err)) -> Sentry.Hooks(err, [Unreachable])
	checking = |check| {
		http_send!: |request| {
			check(request)?
			Ok(accepted)
		},
		now!: || now,
		random_u64!: || Ok(random_u64),
	}

	## A client for [dsn] with the test environment and release.
	client : Sentry.Hooks(http_err, random_err) -> Try(Sentry.Client, _)
	client = |hooks| Sentry.init(hooks, dsn, { environment: "test", release: "roc-sentry-test@0.1.0" })

	## The three lines of the envelope in `request`'s body.
	envelope : Request -> Try({ header : Str, item : Str, event : Str }, [MalformedEnvelope(Str)])
	envelope = |request| {
		body = Str.from_utf8_lossy(Request.body(request))
		match body.split_on("\n") {
			[header, item, event, ""] => Ok({ header, item, event })
			_ => Err(MalformedEnvelope(body))
		}
	}

	## The value of the `name` header of `request`.
	header : Request, Str -> Try(Str, [MissingHeader(Str)])
	header = |request, name|
		Request.headers(request)
			.find_first(|h| h.name == name)
			.map_ok(|h| h.value)
			.map_err(|_| MissingHeader(name))
}
