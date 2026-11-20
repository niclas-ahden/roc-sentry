app [main!] {
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
	sentry: "../package/main.roc",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.7.1/GXr8UJ7VDaJ8HYykmVYtTjLs7X4bZeE9YDTzAHoVXFJ9.tar.zst",
}

import pf.OsStr
import spec.Assert
import sentry.Sentry
import Support

## Every level is sent as Sentry spells it.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	levels : List((Sentry.Level, Str))
	levels = [(Debug, "debug"), (Info, "info"), (Warning, "warning"), (Error, "error"), (Fatal, "fatal")]
	for (level, name) in levels {
		hooks = Support.checking(
			|request| {
				{ event, .. } = Support.envelope(request)?
				decoded : Try({ level : Str }, _)
				decoded = Json.parse(event)
				Assert.eq(decoded, Ok({ level: name })) ? |e| LevelShouldBeSpelledOut(name, e)
				Ok({})
			},
		)
		client = Support.client(hooks)?
		_ = client.capture!(Oops, level)?
	}
	Ok({})
}
