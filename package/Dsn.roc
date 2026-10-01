## A Sentry DSN, the `https://<public key>@<host>/<project id>` string a
## project's settings hand out, parsed into the parts a client needs. Sentry
## reads it as a URL: the scheme and host say where to post, the user info is
## the public key that authenticates the client, and the last path segment is
## the project. A path in front of it is kept for a Sentry served under a
## prefix.
##
## Everything in a DSN is safe to log except that it is the credential to
## write into a project, so treat it as a secret. [Scrub.text] hides the key
## of a DSN that ends up in an error value.
import url.Uri

Dsn :: {
	scheme : Str,
	public_key : Str,
	host : Str,
	port : [Port(U16), NoPort],
	path : Str,
	project_id : Str,
}.{
	is_eq : _

	## Why a string is not a DSN.
	##
	## `NoScheme`: it does not start with `http://` or `https://`.
	##
	## `UnsupportedScheme`: it starts with another scheme, carried.
	##
	## `NoPublicKey`: there is no `<key>@` before the host, or the key is
	## empty.
	##
	## `NoHost`: the host is empty.
	##
	## `InvalidPort`: what follows the host's `:` is not a port, carried.
	##
	## `NoProjectId`: the path is empty, so there is no project.
	Problem : [
		NoScheme,
		UnsupportedScheme(Str),
		NoPublicKey,
		NoHost,
		InvalidPort(Str),
		NoProjectId,
	]

	## Parse a DSN. The secret key that older DSNs carry after the public key
	## is ignored, as Sentry itself ignores it, and so are a query and a
	## fragment. Surrounding whitespace is trimmed, and the scheme is
	## lowercased.
	##
	## ```
	## Dsn.parse("https://key@o1.ingest.sentry.io/123")
	##     == Ok({ scheme: "https", public_key: "key", host: "o1.ingest.sentry.io", port: NoPort, path: "", project_id: "123" })
	## ```
	parse : Str -> Try(Dsn, [InvalidDsn(Problem)])
	parse = |text| {
		uri = Uri.parse(text.trim())
		scheme = Uri.require_scheme(uri) ? |_| InvalidDsn(NoScheme)
		lowered = scheme.with_ascii_lowercased()
		if lowered != "http" and lowered != "https" {
			return Err(InvalidDsn(UnsupportedScheme(scheme)))
		}
		public_key = public_key_of(uri) ? |_| InvalidDsn(NoPublicKey)
		host = Uri.require_host(uri) ? |_| InvalidDsn(NoHost)
		port = Uri.port(uri) ? |PortParseErr(raw)| InvalidDsn(InvalidPort(raw))
		project = split_project(Uri.path(uri)) ? |_| InvalidDsn(NoProjectId)
		Ok({ scheme: lowered, public_key, host, port, path: project.path, project_id: project.project_id })
	}

	## The URL that envelopes are posted to.
	##
	## ```
	## Dsn.parse("https://key@sentry.io/123").map_ok(Dsn.endpoint) == Ok("https://sentry.io/api/123/envelope/")
	## ```
	endpoint : Dsn -> Str
	endpoint = |dsn| {
		port =
			match dsn.port {
				Port(number) => ":${number.to_str()}"
				NoPort => ""
			}
		"${dsn.scheme}://${dsn.host}${port}${dsn.path}/api/${dsn.project_id}/envelope/"
	}

	## The value of the `X-Sentry-Auth` header that authenticates a request,
	## naming the client as `<name>/<version>`.
	auth_header : Dsn, Str -> Str
	auth_header = |dsn, client| "Sentry sentry_version=7,sentry_client=${client},sentry_key=${dsn.public_key}"
}

## The public key: the user info up to its `:`, when there is one.
public_key_of : Uri.Uri -> Try(Str, [NoPublicKey])
public_key_of = |uri|
	match Uri.userinfo(uri) {
		Userinfo(info) => {
			key =
				match info.split_first(":") {
					Ok({ before, .. }) => before
					Err(NotFound) => info
				}
			if key.is_empty() {
				Err(NoPublicKey)
			} else {
				Ok(key)
			}
		}
		NoUserinfo => Err(NoPublicKey)
	}

## The last segment of `path` as the project id, and what precedes it as the
## path. One trailing slash is allowed.
split_project : Str -> Try({ path : Str, project_id : Str }, [NoProjectId])
split_project = |path|
	match path.drop_suffix("/").split_last("/") {
		Ok({ before, after }) if !after.is_empty() => Ok({ path: before, project_id: after })
		_ => Err(NoProjectId)
	}

expect Dsn.parse("https://key@sentry.io/123") == Ok({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "", project_id: "123" })
expect Dsn.parse("https://key:secret@sentry.io/123") == Ok({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "", project_id: "123" })
expect Dsn.parse("https://key@sentry.io/path/123") == Ok({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "/path", project_id: "123" })
expect Dsn.parse("https://key@o123.ingest.sentry.io/api/456") == Ok({ scheme: "https", public_key: "key", host: "o123.ingest.sentry.io", port: NoPort, path: "/api", project_id: "456" })
expect Dsn.parse("http://key@localhost:9000/789") == Ok({ scheme: "http", public_key: "key", host: "localhost", port: Port(9000), path: "", project_id: "789" })
expect Dsn.parse("HTTPS://key@sentry.io/1") == Ok({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "", project_id: "1" })
expect Dsn.parse("  https://key@sentry.io/123\n") == Ok({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "", project_id: "123" })
expect Dsn.parse("https://key@sentry.io/123/") == Ok({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "", project_id: "123" })

expect Dsn.parse("key@sentry.io/123") == Err(InvalidDsn(NoScheme))
expect Dsn.parse("") == Err(InvalidDsn(NoScheme))
expect Dsn.parse("ftp://key@sentry.io/123") == Err(InvalidDsn(UnsupportedScheme("ftp")))
expect Dsn.parse("https://sentry.io/123") == Err(InvalidDsn(NoPublicKey))
expect Dsn.parse("https://@sentry.io/123") == Err(InvalidDsn(NoPublicKey))
expect Dsn.parse("https://:secret@sentry.io/123") == Err(InvalidDsn(NoPublicKey))
expect Dsn.parse("https://key@/123") == Err(InvalidDsn(NoHost))
expect Dsn.parse("https://key@sentry.io:port/123") == Err(InvalidDsn(InvalidPort("port")))
expect Dsn.parse("https://key@sentry.io/") == Err(InvalidDsn(NoProjectId))
expect Dsn.parse("https://key@sentry.io") == Err(InvalidDsn(NoProjectId))

expect Dsn.endpoint({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "", project_id: "123" }) == "https://sentry.io/api/123/envelope/"
expect Dsn.endpoint({ scheme: "https", public_key: "key", host: "sentry.io", port: NoPort, path: "/org", project_id: "456" }) == "https://sentry.io/org/api/456/envelope/"
expect Dsn.endpoint({ scheme: "http", public_key: "key", host: "localhost", port: Port(9000), path: "", project_id: "789" }) == "http://localhost:9000/api/789/envelope/"
expect Dsn.parse("https://key@sentry.io/123").map_ok(Dsn.endpoint) == Ok("https://sentry.io/api/123/envelope/")

expect Dsn.auth_header({ scheme: "https", public_key: "mykey", host: "sentry.io", port: NoPort, path: "", project_id: "123" }, "roc-sentry/1.0.0") == "Sentry sentry_version=7,sentry_client=roc-sentry/1.0.0,sentry_key=mykey"

expect split_project("/123") == Ok({ path: "", project_id: "123" })
expect split_project("/a/b/123/") == Ok({ path: "/a/b", project_id: "123" })
expect split_project("/") == Err(NoProjectId)
expect split_project("") == Err(NoProjectId)
