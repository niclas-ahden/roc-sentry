app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.27.0/HZanbveSUDoJF8LypR663eH7PpaKEKG36eErEQzmV1Qs.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.6.0/9ThTkhd7zrviwQpM3LvGd7pvzGhr4ZXNmWJV7pTJc9AJ.tar.zst",
	sentry: "../package/main.roc",
}

import pf.OsStr
import http.Request
import spec.Assert
import sentry.Sentry
import Support

## `capture!` posts one envelope to the DSN's endpoint, authenticated by the
## public key, and returns the id the envelope carries.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	hooks = Support.checking(
		|request| {
			Assert.eq(Request.method_str(request), "POST") ? MethodShouldBePost
			Assert.eq(Request.uri(request), Support.endpoint) ? UriShouldBeTheEnvelopeEndpoint
			Assert.eq(Request.timeout(request), TimeoutMilliseconds(5_000)) ? TimeoutShouldBeTheDefault
			Assert.eq(Support.header(request, "X-Sentry-Auth"), Ok("Sentry sentry_version=7,sentry_client=roc-sentry/${Sentry.version},sentry_key=publickey")) ? AuthHeaderShouldNameTheKey
			Assert.eq(Support.header(request, "Content-Type"), Ok("application/x-sentry-envelope")) ? ContentTypeShouldBeEnvelope

			{ header, item, event } = Support.envelope(request)?

			header_json : Try({ event_id : Str, sent_at : Str, sdk : { name : Str, version : Str } }, _)
			header_json = Json.parse(header)
			Assert.eq(header_json, Ok({ event_id: Support.event_id, sent_at: "2025-01-01T00:00:00.000Z", sdk: { name: "roc-sentry", version: Sentry.version } })) ? EnvelopeHeaderShouldMatch

			item_json : Try({ type : Str, length : U64 }, _)
			item_json = Json.parse(item)
			Assert.eq(item_json, Ok({ type: "event", length: event.count_utf8_bytes() })) ? ItemHeaderShouldMatch

			event_json : Try(
				{
					event_id : Str,
					timestamp : Str,
					level : Str,
					environment : Str,
					release : Str,
					message : { formatted : Str },
					exception : { values : List({ type : Str, value : Str }) },
				},
				_,
			)
			event_json = Json.parse(event)
			Assert.eq(
				event_json,
				Ok({
					event_id: Support.event_id,
					timestamp: "2025-01-01T00:00:00.000Z",
					level: "warning",
					environment: "test",
					release: "roc-sentry-test@0.1.0",
					message: { formatted: "PaymentFailed\n  order: 42\n  reason: Declined" },
					exception: { values: [{ type: "PaymentFailed", value: "{ order: 42, reason: Declined }" }] },
				}),
			)
				? EventShouldMatch
			Ok({})
		},
	)

	client = Support.client(hooks)?
	event_id = client.capture!(error, Warning)?
	Assert.eq(event_id, Support.event_id) ? ReturnedIdShouldBeTheEnvelopesId
	Ok({})
}

error : [PaymentFailed({ order : U64, reason : [Declined] })]
error = PaymentFailed({ order: 42, reason: Declined })
