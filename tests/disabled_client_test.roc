app [main!] {
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.28.0/AP9SGT1yrhCKcFxKcoA5tBkNCM6ibBjBxcQGMTb6krev.tar.zst",
	sentry: "../package/main.roc",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.6.0/9ThTkhd7zrviwQpM3LvGd7pvzGhr4ZXNmWJV7pTJc9AJ.tar.zst",
}

import pf.OsStr
import spec.Assert
import sentry.Sentry
import Support

## An empty DSN switches reporting off, as it does in Sentry's own SDKs: the
## client is made, sends nothing, and answers every event with the nil id.
## `Sentry.disabled` is such a client without a DSN or hooks.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	for dsn in ["", "  "] {
		client = Sentry.init(Support.failing(ShouldNotBeSent), dsn, { environment: "test" }) ? |e| EmptyDsnShouldGiveAClient(dsn, e)
		Assert.false(client.is_enabled()) ? |e| ClientShouldBeDisabled(dsn, e)
		Assert.eq(client.capture!(Oops, Error), Ok(Sentry.nil_event_id)) ? |e| CaptureShouldSendNothing(dsn, e)
		Assert.eq(client.send!(Sentry.event(Oops).with_tag("job", "sync")), Ok(Sentry.nil_event_id)) ? |e| SendShouldSendNothing(dsn, e)
	}
	Assert.false(Sentry.disabled.is_enabled()) ? DisabledShouldBeDisabled
	Assert.eq(Sentry.disabled.capture!(Oops, Error), Ok(Sentry.nil_event_id)) ? DisabledShouldSendNothing
	Ok({})
}
