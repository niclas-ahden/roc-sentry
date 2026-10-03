app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.28.0/AP9SGT1yrhCKcFxKcoA5tBkNCM6ibBjBxcQGMTb6krev.tar.zst",
	sentry: "../package/main.roc",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.6.0/9ThTkhd7zrviwQpM3LvGd7pvzGhr4ZXNmWJV7pTJc9AJ.tar.zst",
}

import pf.Http
import pf.OsStr
import pf.Random
import pf.Utc
import spec.Assert
import sentry.Sentry

## basic-cli's `Http.send!`, `Utc.now!` and `Random.seed_u64!` are the hooks
## the README shows, so they have to fit as they are. Nothing is sent: the
## client only prepares an envelope, stamped with the platform's clock and
## with an id from its random numbers.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	client = Sentry.init({ http_send!: Http.send!, now!: Utc.now!, random_u64!: Random.seed_u64! }, "https://publickey@o1.ingest.sentry.io/123", { environment: "test" })?
	seed = Random.seed_u64!()?
	{ event_id, envelope } = client.prepare(Sentry.event(Oops), { now: Utc.now!(), random: seed.to_u128() })
	Assert.eq(event_id.count_utf8_bytes(), 32)?
	Assert.contains(envelope, "\"event_id\":\"${event_id}\"")?
	Assert.contains(envelope, "\"type\":\"Oops\"")
}
