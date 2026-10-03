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

## Everything an event is built up with reaches the payload, with secrets
## filtered out on the way.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	hooks = Support.checking(
		|request| {
			{ event, .. } = Support.envelope(request)?
			decoded : Try(
				{
					level : Str,
					exception : { values : List({ type : Str, value : Str }) },
					request : { method : Str, url : Str },
					user : { id : Str, email : Str },
					tags : { job : Str, attempt : Str },
					extra : { config : Str },
					fingerprint : List(Str),
				},
				_,
			)
			decoded = Json.parse(event)
			Assert.eq(
				decoded,
				Ok({
					level: "fatal",
					exception: { values: [{ type: "DbError", value: "{ url: \"postgres://[Filtered]:[Filtered]@db.internal/app\" }" }] },
					request: { method: "POST", url: "/login?token=[Filtered]&next=/home" },
					user: { id: "u-7", email: "a@example.com" },
					tags: { job: "sync", attempt: "2" },
					extra: { config: "{ password: [Filtered], pool: 8.0 }" },
					fingerprint: ["{{ default }}", "db"],
				}),
			)
				? EventShouldCarryTheContext
			Assert.not_contains(event, "username") ? UnsetUserFieldsShouldBeLeftOut
			Assert.not_contains(event, "hunter2") ? SecretsShouldBeScrubbed
			Ok({})
		},
	)

	client = Support.client(hooks)?
	event =
		Sentry.event(DbError({ url: "postgres://app:hunter2@db.internal/app" }))
			.with_level(Fatal)
			.with_request({ method: "POST", url: "/login?token=abc123&next=/home" })
			.with_user({ id: "u-7", email: "a@example.com" })
			.with_tag("job", "sync")
			.with_tag("attempt", "1")
			.with_tag("attempt", "2")
			.with_extra("config", "{ password: \"hunter2\", pool: 8.0 }")
			.with_fingerprint(["{{ default }}", "db"])
	_ = client.send!(event)?
	Ok({})
}
