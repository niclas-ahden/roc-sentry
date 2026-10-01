app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.27.0/HZanbveSUDoJF8LypR663eH7PpaKEKG36eErEQzmV1Qs.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.6.0/9ThTkhd7zrviwQpM3LvGd7pvzGhr4ZXNmWJV7pTJc9AJ.tar.zst",
	sentry: "../package/main.roc",
}

import pf.OsStr exposing [OsStr]
import http.Response
import spec.Assert
import sentry.Sentry
import Support

## An HTTP error of a platform that gives it a type of its own, which need
## not match the type of its random number error.
PlatformError := [ConnectionRefused]

## Any 2xx is an accepted event. Anything else is `SentryRejected` with the
## status, the body and how long Sentry asks for no more events, and a failed
## request is `SentryRequestFailed` with the platform's error as text.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	for status in [200, 201, 204] {
		client = Support.client(Support.answering(Response.from_status(status)))?
		Assert.true(client.capture!(Oops, Error).is_ok()) ? |e| StatusShouldBeAccepted(status, e)
	}

	rate_limited = Support.client(Support.answering(Response.from_status(429).with_body(Str.to_utf8("rate limited"))))?
	Assert.eq(rate_limited.capture!(Oops, Error), Err(SentryRejected({ status: 429, body: "rate limited", retry_after_seconds: 60 }))) ? RateLimitShouldBeReported

	# The wait comes from Sentry's headers, its own one first
	retry_after = Response.from_status(429).add_header("Retry-After", "30")
	waiting = Support.client(Support.answering(retry_after))?
	Assert.eq(waiting.capture!(Oops, Error), Err(SentryRejected({ status: 429, body: "", retry_after_seconds: 30 }))) ? RetryAfterShouldBeCarried
	limited = Support.client(Support.answering(retry_after.add_header("X-Sentry-Rate-Limits", "120:error:key, 3600:transaction:organization")))?
	Assert.eq(limited.capture!(Oops, Error), Err(SentryRejected({ status: 429, body: "", retry_after_seconds: 120 }))) ? RateLimitsShouldBeCarried

	broken = Support.client(Support.answering(Response.from_status(500)))?
	Assert.eq(broken.capture!(Oops, Error), Err(SentryRejected({ status: 500, body: "", retry_after_seconds: 0 }))) ? ServerErrorShouldBeReported

	unreachable = Support.client(Support.failing(ConnectionRefused))?
	Assert.eq(unreachable.capture!(Oops, Error), Err(SentryRequestFailed("ConnectionRefused"))) ? TransportErrorShouldBePassedThrough

	refused : PlatformError
	refused = ConnectionRefused
	typed = Support.client(Support.failing(refused))?
	Assert.eq(typed.capture!(Oops, Error), Err(SentryRequestFailed(Str.inspect(refused)))) ? TypedErrorShouldBePassedThrough
	Ok({})
}
