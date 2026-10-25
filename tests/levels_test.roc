app [main!] {
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.30.0/6XAUy48Jp34GANurMrMf74DtF7NdpkhnqFLHE4gHNzJy.tar.zst",
	sentry: "../package/main.roc",
	spec: "https://github.com/niclas-ahden/roc-spec/releases/download/0.7.0/BGjQKbG9U3V8cH6mRbypUAFVqFoVEu6n9bsA3QmFL1f4.tar.zst",
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
