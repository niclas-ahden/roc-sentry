app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.30.0/6XAUy48Jp34GANurMrMf74DtF7NdpkhnqFLHE4gHNzJy.tar.zst",
	sentry: "../package/main.roc",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.7.0/BGjQKbG9U3V8cH6mRbypUAFVqFoVEu6n9bsA3QmFL1f4.tar.zst",
}

import pf.Http
import pf.OsStr
import pf.Random
import pf.Utc
import spec.Assert
import sentry.Sentry

## basic-cli's `Utc.now!` and `Random.seed_u64!` are the hooks the README
## shows, so they have to fit as they are. `Http.send!` goes through a lambda
## until roc-lang/roc#12606 is fixed. Nothing is sent: the client only
## prepares an envelope, stamped with the platform's clock and with an id
## from its random numbers.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# WORKAROUND: a lambda rather than `Http.send!` itself, because a package
	# passing a bare `{}` as its `SendOptions` crashes Roc 54283d4. Pass
	# `Http.send!` once roc-lang/roc#12606 is fixed.
	client = Sentry.init({ http_send!: |request| Http.send!(request, {}), now!: Utc.now!, random_u64!: Random.seed_u64! }, "https://publickey@o1.ingest.sentry.io/123", { environment: "test" })?
	seed = Random.seed_u64!()?
	{ event_id, envelope } = client.prepare(Sentry.event(Oops), { now: Utc.now!().to_nanos_since_epoch().to_u128_wrap(), random: seed.to_u128() })
	Assert.eq(event_id.count_utf8_bytes(), 32)?
	Assert.contains(envelope, "\"event_id\":\"${event_id}\"")?
	Assert.contains(envelope, "\"type\":\"Oops\"")
}
