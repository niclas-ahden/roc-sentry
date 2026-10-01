app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.27.0/HZanbveSUDoJF8LypR663eH7PpaKEKG36eErEQzmV1Qs.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	sentry: "../package/main.roc",
}

import pf.Env
import pf.Http
import pf.OsStr exposing [OsStr]
import pf.Random
import pf.Stdout
import pf.Utc
import http.Request exposing [Request]
import http.Response exposing [Response]
import sentry.Sentry

## An error the way an application has one: a tag with a record payload,
## nested as deep as it needs to be. Any value works.
OrderError : [PaymentFailed({ order : U64, reason : [Declined, Timeout({ after_ms : U64 })] })]

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# With a DSN in the environment the events go to that project. Without one
	# they are printed instead, so this runs anywhere.
	client =
		match Env.var_str!("SENTRY_DSN") {
			Ok(dsn) =>
				# The hooks are the platform's HTTP client, clock and random numbers, as they are.
				Sentry.init(
					{ http_send!: Http.send!, now!: Utc.now!, random_u64!: Random.seed_u64! },
					dsn,
					{ environment: "example", release: "roc-sentry-example@0.1.0" },
				)?
			Err(_) => {
				Stdout.line!("SENTRY_DSN is not set, so the envelopes are printed instead of sent.\n")?
				Sentry.init(
					{ http_send!: print_envelope!, now!: Utc.now!, random_u64!: Random.seed_u64! },
					"https://examplePublicKey@o0.ingest.sentry.io/0",
					{ environment: "example", release: "roc-sentry-example@0.1.0" },
				)?
			}
		}
	report!(client)
}

## Every way to report, with whichever client.
report! : Sentry.Client => Try({}, _)
report! = |client| {
	# A value and a level. It arrives titled
	# `PaymentFailed: { order: 42, reason: Declined }`, with the value laid out
	# over lines as its message.
	declined : OrderError
	declined = PaymentFailed({ order: 42, reason: Declined })
	event_id = client.capture!(declined, Error)?
	Stdout.line!("Captured the declined payment as event ${event_id}\n")?

	# With context: the request being served, the user, tags to search by,
	# extra data to read, and a fingerprint to group by. The token in the URL
	# is filtered out before it is sent.
	timed_out : OrderError
	timed_out = PaymentFailed({ order: 43, reason: Timeout({ after_ms: 3000 }) })
	event =
		Sentry.event(timed_out)
			.with_level(Warning)
			.with_request({ method: "POST", url: "/checkout?token=s3cret" })
			.with_user({ id: "u-7" })
			.with_tag("job", "checkout")
			.with_extra("attempt", "2")
			.with_fingerprint(["payment-timeout"])
	timeout_id = client.send!(event)?
	Stdout.line!("Sent the payment timeout as event ${timeout_id}\n")?

	# A string is an event of type Error with the string as its text.
	info_id = client.capture!("Nightly sync finished with 3 skipped rows", Info)?
	Stdout.line!("Sent the sync note as event ${info_id}")?

	Ok({})
}

## Stands in for `Http.send!`: prints the request and answers as Sentry does
## when it accepts an event.
print_envelope! : Request => Try(Response, [PrintFailed(_)])
print_envelope! = |request| {
	auth = Request.headers(request).find_first(|h| h.name == "X-Sentry-Auth").map_ok(|h| h.value).ok_or("")
	Stdout.line!("POST ${Request.uri(request)}\nX-Sentry-Auth: ${auth}\n") ? PrintFailed
	Stdout.line!(Str.from_utf8_lossy(Request.body(request))) ? PrintFailed
	Ok(Response.from_status(200).with_body(Str.to_utf8("{\"id\":\"accepted\"}")))
}
