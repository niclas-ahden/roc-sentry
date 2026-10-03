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

## A platform that fails to give random numbers does not stop an event: it
## is sent with an id made from its time and text, which is still a version
## 4 UUID and the one the envelope carries.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	hooks = {
		http_send!: |request| {
			{ header, .. } = Support.envelope(request)?
			header_json : Try({ event_id : Str }, _)
			header_json = Json.parse(header)
			match header_json {
				Ok({ event_id }) if event_id.count_utf8_bytes() == 32 => Ok(Support.accepted)
				_ => Err(EnvelopeShouldCarryAnId(header))
			}
		},
		now!: || Support.now,
		random_u64!: || Err(NoEntropy),
	}
	client = Support.client(hooks)?
	event_id = client.capture!(Oops, Error)?
	Assert.eq(event_id.count_utf8_bytes(), 32)?
	Assert.true(event_id != Sentry.nil_event_id and event_id != Support.event_id) ? IdShouldBeDerived
	Assert.eq(event_id.to_utf8().get(12), Ok(52)) ? IdShouldBeVersion4 # the character 4
	Ok({})
}
