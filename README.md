# roc-sentry

Report errors from Roc to [Sentry](https://sentry.io). Any Roc value can be
an error, and secrets are filtered out before anything is sent.

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.27.0/HZanbveSUDoJF8LypR663eH7PpaKEKG36eErEQzmV1Qs.tar.zst",
    sentry: "https://github.com/niclas-ahden/roc-sentry/releases/download/0.1.0/29xBJk1dfEyW3qiKtLmenSoEEsnE5rfUSrCtfCEuYhPF.tar.zst",
}

import pf.Env
import pf.Http
import pf.Random
import pf.Stdout
import pf.Utc
import sentry.Sentry

main! = |_args| {
    client = Sentry.init(
        { http_send!: Http.send!, now!: Utc.now!, random_u64!: Random.seed_u64! },
        Env.var_str!("SENTRY_DSN") ?? "",
        { environment: "production", release: "shop@1.4.2" },
    )?

    event_id = client.capture!(PaymentFailed({ order: 42, reason: Declined }), Error)?
    Stdout.line!("Reported as ${event_id}")?
    Ok({})
}
```

Set `SENTRY_DSN` to your project's DSN. The event shows up as an issue titled
`PaymentFailed: { order: 42, reason: Declined }`.

When `SENTRY_DSN` is unset or empty, the client is disabled and sends
nothing, so local runs and tests need no setup. `Sentry.init` only fails on a
malformed DSN.

## Capturing errors

`client.capture!(error, level)` sends `error` at `Debug`, `Info`,
`Warning`, `Error` or `Fatal` and returns the event id. The error can be any
value:

| Error | Issue title in Sentry |
|---|---|
| `PaymentFailed({ order: 42, reason: Declined })` | `PaymentFailed: { order: 42, reason: Declined }` |
| `AdDisapproved("Ad 123 was disapproved")` | `AdDisapproved: Ad 123 was disapproved` |
| `Timeout` | `Timeout` |
| `"connection lost"` | `Error: connection lost` |

An error that holds a record is also shown one field per line in the event.
Roc has no stack traces, so put the context you need into the error value.

When the type is only known as text, a category your alerts are routed by
say, `Sentry.exception("InvoiceSyncFailed", "Customer 42 has no address")`
makes the event.

## Adding context

Build an event, then send it:

```roc
event =
    Sentry.event(PaymentFailed({ order: 43, reason: Timeout }))
        .with_level(Warning)
        .with_request({ method: "POST", url: "/checkout" })
        .with_user({ id: "u-7" })
        .with_tag("job", "checkout")
        .with_extra("attempt", "2")
        .with_fingerprint(["payment-timeout"])
event_id = client.send!(event)?
```

- **`with_tag`:** tags are searchable in Sentry. Keep them short and few.
- **`with_extra`:** extra data is shown with the event but is not
  searchable.
- **`with_fingerprint`:** controls grouping. Sentry groups by the error's
  type and value, so an error that carries an id or a timestamp opens a new
  issue every time. Give those a fingerprint to group them together. Put
  `"{{ default }}"` in the list to refine the default grouping instead.

## Secrets

roc-sentry replaces secrets with `[Filtered]` before sending:

- **Fields** whose name contains `password`, `token`, `secret`, `key`,
  `auth`, `session`, `cookie` or a similar word (see `Scrub.is_sensitive`):
  `LoginFailed({ password: [Filtered], user: "bob" })`. Names match
  anywhere, so `monkey` and `author` are filtered too.
- **Headers** with such a name, or one carrying an IP address like
  `X-Forwarded-For`, written as `{ name, value }`, `{ key, value }`,
  `(name, value)` or `Header(name, value)`. Cookies keep their names:
  `Cookie: sessionid=[Filtered]; lang=[Filtered]`.
- **Inside strings**, including the request URL and extra data: URL
  credentials (`postgres://[Filtered]:[Filtered]@db/app`), values after a
  sensitive name (`?api_key=[Filtered]`, `password: [Filtered]` at the start
  of a line) and bearer tokens.
- **Extra data** written with `Str.inspect` is filtered field by field, like
  the error.

Tags, the user and a bare tag payload are sent as they are.
`InvalidApiKey("sk_live_abc")` sends the key. Put it in a field,
`InvalidApiKey({ api_key: key })`, and it is filtered.

`Scrub.inspect(value)` and `Scrub.text(text)` do the same filtering for your
own logs.

## When sending fails

`capture!` and `send!` return `SentryRejected` with the `status`, `body` and
`retry_after_seconds` when Sentry answers with a non-2xx status, and
`SentryRequestFailed(text)` when the HTTP request fails. Nothing is retried or
logged, so log the error yourself if you need it.

When Sentry rate limits the project, `retry_after_seconds` says how long it
asks for no more events. Skip sending until then, as Sentry's own SDKs do.

## Good to know

- **Options:** `environment` (default `production`), `release`,
  `server_name` and `timeout_ms` (default `5_000`). Write the record inline
  in `Sentry.init`. Bound to a name, it needs the annotation
  `options : Sentry.Options`.
- **Other platforms:** any platform works whose HTTP client takes a
  [roc-lang/http](https://github.com/roc-lang/http) `Request`. `now!`
  returns nanoseconds since the Unix epoch and `random_u64!` a random `U64`.
  With [basic-webserver](https://github.com/niclas-ahden/basic-webserver):
  ```roc
  { http_send!: Http.send!, now!: || UnixTime.now!().nanos_since_epoch().to_u128_wrap(), random_u64!: Random.seed_u64! }
  ```
- **Malformed DSN:** `Sentry.init` fails with `InvalidDsn(problem)`. To run
  without reporting instead, log it and use `Sentry.disabled`, a client that
  sends nothing.
- **Size:** text over 8,000 bytes is cut and ends with
  `… [truncated, was N bytes]`. An event over 1 MB is sent without its extra
  data.
- **Scope:** each event is one HTTP request, made when you capture it. There
  are no breadcrumbs, transactions or retries.

## Testing

In tests, `Sentry.disabled` is a client that sends nothing and needs no
hooks. To check what would be sent, `client.prepare(event, { now, random })`
returns the event id and envelope without any I/O. `tests/Support.roc` has
hooks that answer with a canned response.

## More

- [API documentation](https://niclas-ahden.github.io/roc-sentry/)
- [`examples/main.roc`](examples/main.roc) sends events when `SENTRY_DSN` is
  set and prints them otherwise.

## Development

```
nix develop
roc check package/main.roc
roc test package/main.roc
./tests.roc
```
