## The envelope that carries one event to Sentry. Internal to the package.
##
## An envelope is three lines: a header naming the event, an item header
## saying that an event of so many bytes follows, and the event as JSON.
## The format is documented at
## https://develop.sentry.dev/sdk/data-model/envelopes/ and the event at
## https://develop.sentry.dev/sdk/data-model/event-payloads/.
import JsonText

Envelope := [].{

	## Everything the envelope for one event is built from. The text is
	## already filtered and capped where that applies. An empty
	## `environment`, `release`, `server_name` or `message` is left out of the
	## event, as are an empty `user`, `tags`, `extra` and `fingerprint`, and
	## an exception with an empty `value` is sent with only its type.
	## `sent_at`, when the envelope is posted, goes in its header.
	Input : {
		event_id : Str,
		sent_at : [SentAt(Str), NotSent],
		timestamp : Str,
		sdk_name : Str,
		sdk_version : Str,
		level : Str,
		environment : Str,
		release : Str,
		server_name : Str,
		type_name : Str,
		value : Str,
		message : Str,
		request : [WithRequest({ method : Str, url : Str }), NoRequest],
		user : List((Str, Str)),
		tags : List((Str, Str)),
		extra : List((Str, Str)),
		fingerprint : List(Str),
	}

	## Sentry rejects an event item larger than this, per its documented size
	## limits, so [build] leaves out the parts of an event that are not its
	## error until it fits.
	max_event_bytes : U64
	max_event_bytes = 1_000_000

	## The tag that names what [build] left out of an event to make it fit.
	dropped_tag : Str
	dropped_tag = "roc_sentry.dropped"

	## The envelope for `input`. An event over [max_event_bytes] is rebuilt
	## without its `extra` data, which is the one part with no bound of its
	## own, and if that is still too large without its tags, request, user
	## and fingerprint as well. Either way a [dropped_tag] tag says so.
	build : Input -> Str
	build = |input| {
		full = render(input)
		if full.event_bytes <= max_event_bytes {
			return full.text
		}
		without_extra = render({ ..input, extra: [], tags: input.tags.append((dropped_tag, "extra")) })
		if without_extra.event_bytes <= max_event_bytes {
			return without_extra.text
		}
		bare = render({ ..input, extra: [], request: NoRequest, user: [], fingerprint: [], tags: [(dropped_tag, "extra, tags, request, user, fingerprint")] })
		bare.text
	}
}

render : Envelope.Input -> { text : Str, event_bytes : U64 }
render = |input| {
	event = event_json(input)
	event_bytes = event.count_utf8_bytes()
	sent_at =
		match input.sent_at {
			SentAt(time) => [("sent_at", JsonText.string(time))]
			NotSent => []
		}
	header = JsonText.object([("event_id", JsonText.string(input.event_id))].concat(sent_at).append(("sdk", sdk_json(input))))
	item = JsonText.object([
		("type", JsonText.string("event")),
		("length", event_bytes.to_str()),
		("content_type", JsonText.string("application/json")),
	])
	{ text: "${header}\n${item}\n${event}\n", event_bytes }
}

sdk_json : Envelope.Input -> Str
sdk_json = |input|
	JsonText.object([("name", JsonText.string(input.sdk_name)), ("version", JsonText.string(input.sdk_version))])

event_json : Envelope.Input -> Str
event_json = |input| {
	exception_value = if input.value.is_empty() {
		[]
	} else {
		[("value", JsonText.string(input.value))]
	}
	exception = JsonText.object([("type", JsonText.string(input.type_name))].concat(exception_value))
	always = [
		("event_id", JsonText.string(input.event_id)),
		("timestamp", JsonText.string(input.timestamp)),
		# Sentry accepts a fixed list of platform names, and "other" is the one for a language it does not know
		("platform", JsonText.string("other")),
		("level", JsonText.string(input.level)),
		("sdk", sdk_json(input)),
		("exception", JsonText.object([("values", JsonText.array([exception]))])),
	]
	when_set =
		[("environment", input.environment), ("release", input.release), ("server_name", input.server_name)]
			.keep_if(|(_, value)| !value.is_empty())
			.map(|(key, value)| (key, JsonText.string(value)))
	message = if input.message.is_empty() {
		[]
	} else {
		[("message", JsonText.object([("formatted", JsonText.string(input.message))]))]
	}
	request =
		match input.request {
			WithRequest({ method, url }) => [("request", string_object([("method", method), ("url", url)]))]
			NoRequest => []
		}
	user = if input.user.is_empty() {
		[]
	} else {
		[("user", string_object(input.user))]
	}
	tags = if input.tags.is_empty() {
		[]
	} else {
		[("tags", string_object(input.tags))]
	}
	extra = if input.extra.is_empty() {
		[]
	} else {
		[("extra", string_object(input.extra))]
	}
	fingerprint = if input.fingerprint.is_empty() {
		[]
	} else {
		[("fingerprint", JsonText.array(input.fingerprint.map(JsonText.string)))]
	}
	JsonText.object(always.concat(when_set).concat(message).concat(request).concat(user).concat(tags).concat(extra).concat(fingerprint))
}

## A JSON object whose values are all strings.
string_object : List((Str, Str)) -> Str
string_object = |pairs| JsonText.object(pairs.map(|(key, value)| (key, JsonText.string(value))))

# --- Tests ---

sample : Envelope.Input
sample = {
	event_id: "0123456789abcdef0123456789abcdef",
	sent_at: SentAt("2025-01-01T00:00:05.000Z"),
	timestamp: "2025-01-01T00:00:00.000Z",
	sdk_name: "roc-sentry",
	sdk_version: "0.1.0",
	level: "error",
	environment: "test",
	release: "app@1.0.0",
	server_name: "web-1",
	type_name: "SomeErr",
	value: "SomeErr({ foo: 1 })",
	message: "SomeErr\n  foo: 1",
	request: WithRequest({ method: "POST", url: "/api/users" }),
	user: [("id", "42")],
	tags: [("job", "sync")],
	extra: [("attempt", "3")],
	fingerprint: ["sync-failed"],
}

## Everything left out that can be left out.
bare : Envelope.Input
bare = { ..sample, environment: "", release: "", server_name: "", message: "", request: NoRequest, user: [], tags: [], extra: [], fingerprint: [] }

## The envelope's three lines.
parts : Str -> { header : Str, item : Str, event : Str }
parts = |envelope| {
	lines = envelope.split_on("\n")
	{ header: lines.get(0).ok_or(""), item: lines.get(1).ok_or(""), event: lines.get(2).ok_or("") }
}

# Three lines, each ended by a newline
expect Envelope.build(sample).split_on("\n").len() == 4
expect Envelope.build(sample).ends_with("\n")

expect {
	header : Try({ event_id : Str, sent_at : Str, sdk : { name : Str, version : Str } }, _)
	header = Json.parse(parts(Envelope.build(sample)).header)
	header == Ok({ event_id: "0123456789abcdef0123456789abcdef", sent_at: "2025-01-01T00:00:05.000Z", sdk: { name: "roc-sentry", version: "0.1.0" } })
}

# An envelope that is not being posted has no sent_at
expect {
	header = parts(Envelope.build({ ..sample, sent_at: NotSent })).header
	decoded : Try({ event_id : Str, sdk : { name : Str, version : Str } }, _)
	decoded = Json.parse(header)
	decoded == Ok({ event_id: "0123456789abcdef0123456789abcdef", sdk: { name: "roc-sentry", version: "0.1.0" } }) and !header.contains("sent_at")
}

# The item header's length is the event's byte count
expect {
	{ item, event, .. } = parts(Envelope.build(sample))
	decoded : Try({ type : Str, length : U64, content_type : Str }, _)
	decoded = Json.parse(item)
	decoded == Ok({ type: "event", length: event.count_utf8_bytes(), content_type: "application/json" })
}

expect {
	decoded : Try(
		{
			event_id : Str,
			timestamp : Str,
			level : Str,
			sdk : { name : Str, version : Str },
			message : { formatted : Str },
			exception : { values : List({ type : Str, value : Str }) },
			environment : Str,
			release : Str,
			server_name : Str,
			request : { method : Str, url : Str },
			user : { id : Str },
			tags : { job : Str },
			extra : { attempt : Str },
			fingerprint : List(Str),
		},
		_,
	)
	decoded = Json.parse(parts(Envelope.build(sample)).event)
	decoded
		== Ok({
			event_id: "0123456789abcdef0123456789abcdef",
			timestamp: "2025-01-01T00:00:00.000Z",
			level: "error",
			sdk: { name: "roc-sentry", version: "0.1.0" },
			message: { formatted: "SomeErr\n  foo: 1" },
			exception: { values: [{ type: "SomeErr", value: "SomeErr({ foo: 1 })" }] },
			environment: "test",
			release: "app@1.0.0",
			server_name: "web-1",
			request: { method: "POST", url: "/api/users" },
			user: { id: "42" },
			tags: { job: "sync" },
			extra: { attempt: "3" },
			fingerprint: ["sync-failed"],
		})
		and parts(Envelope.build(sample)).event.contains("\"platform\":\"other\"")
}

# What is empty is left out rather than sent empty
expect {
	event = parts(Envelope.build(bare)).event
	["environment", "release", "server_name", "message", "request", "user", "tags", "extra", "fingerprint"].all(|field| !event.contains("\"${field}\""))
}
expect {
	decoded : Try({ level : Str, exception : { values : List({ type : Str, value : Str }) } }, _)
	decoded = Json.parse(parts(Envelope.build(bare)).event)
	decoded == Ok({ level: "error", exception: { values: [{ type: "SomeErr", value: "SomeErr({ foo: 1 })" }] } })
}

# A bare tag has a type and no value
expect {
	event = parts(Envelope.build({ ..bare, type_name: "Timeout", value: "" })).event
	event.contains("\"exception\":{\"values\":[{\"type\":\"Timeout\"}]}")
}

# Text is escaped on the way in
expect {
	envelope = Envelope.build({ ..bare, value: "quote \" backslash \\ newline \n", message: "\u(1)" })
	envelope.contains("\"value\":\"quote \\\" backslash \\\\ newline \\n\"") and envelope.contains("\"formatted\":\"\\u0001\"")
}

# An event too large for Sentry loses its extra data first
expect {
	envelope = Envelope.build({ ..sample, extra: [("blob", "x".repeat(1_100_000))] })
	event = parts(envelope).event
	decoded : Try({ tags : { job : Str }, request : { method : Str } }, _)
	decoded = Json.parse(event)
	!event.contains("blob")
		and event.contains("\"${Envelope.dropped_tag}\":\"extra\"")
			and decoded == Ok({ tags: { job: "sync" }, request: { method: "POST" } })
}

# And everything but its error after that
expect {
	huge_tags = List.repeat("v".repeat(200), 6000).map_with_index(|value, index| ("tag${index.to_str()}", value))
	envelope = Envelope.build({ ..sample, tags: huge_tags })
	event = parts(envelope).event
	decoded : Try({ exception : { values : List({ type : Str }) } }, _)
	decoded = Json.parse(event)
	event.count_utf8_bytes() <= Envelope.max_event_bytes
		and event.contains("\"tags\":{\"${Envelope.dropped_tag}\":\"extra, tags, request, user, fingerprint\"}")
			and !event.contains("\"request\"")
				and !event.contains("\"user\"")
					and !event.contains("\"fingerprint\"")
						and decoded == Ok({ exception: { values: [{ type: "SomeErr" }] } })
}

# Up to the limit nothing is dropped
expect {
	envelope = Envelope.build({ ..sample, extra: [("blob", "x".repeat(900_000))] })
	envelope.contains("\"blob\"") and !envelope.contains(Envelope.dropped_tag)
}
