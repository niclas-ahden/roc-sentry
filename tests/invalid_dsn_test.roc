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

## `init` fails only on a DSN that does not parse, and says what is wrong
## with it.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	hooks = Support.answering(Support.accepted)
	cases = [
		("publickey@o1.ingest.sentry.io/123", NoScheme),
		("ftp://publickey@o1.ingest.sentry.io/123", UnsupportedScheme("ftp")),
		("https://o1.ingest.sentry.io/123", NoPublicKey),
		("https://publickey@/123", NoHost),
		("https://publickey@o1.ingest.sentry.io:port/123", InvalidPort("port")),
		("https://publickey@o1.ingest.sentry.io", NoProjectId),
	]
	for (dsn, problem) in cases {
		found = Assert.err(Sentry.init(hooks, dsn, { environment: "test" })) ? |e| DsnShouldBeRejected(dsn, e)
		Assert.eq(found, InvalidDsn(problem)) ? |e| ProblemShouldBeNamed(dsn, e)
	}

	# A DSN with a path prefix and a port posts to the matching endpoint
	posting = Support.checking(
		|request| {
			Assert.eq(Request.uri(request), "http://localhost:9000/sentry/api/42/envelope/") ? UriShouldKeepThePrefixAndPort
			Ok({})
		},
	)
	prefixed = Sentry.init(posting, "http://publickey@localhost:9000/sentry/42", { environment: "test" })?
	_ = prefixed.capture!(Oops, Error)?
	Ok({})
}
