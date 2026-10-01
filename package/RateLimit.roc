## How long Sentry asks a client to send no more events, read from the
## headers of its answer the way Sentry's own SDKs read them, see
## https://develop.sentry.dev/sdk/expected-features/rate-limiting/.
## Internal to the package.
RateLimit := [].{

	## The seconds to send no more error events for, from an answer with
	## `status` and the values of its `X-Sentry-Rate-Limits` and `Retry-After`
	## headers, each "" when it has none.
	##
	## `X-Sentry-Rate-Limits` lists limits as `<seconds>:<categories>:...`,
	## separated by `,`, and when it is there it is all that counts: the
	## longest of its limits that covers errors, which is one whose
	## categories, separated by `;`, are empty or name `error`. Without it, a
	## 429 asks for `Retry-After` seconds, or 60 when that is missing or not
	## a number of seconds. Any other answer asks for no wait.
	retry_after_seconds : U16, Str, Str -> U64
	retry_after_seconds = |status, rate_limits, retry_after|
		if !rate_limits.trim().is_empty() {
			rate_limits.split_on(",").map(error_limit).fold(0, |longest, seconds| longest.max(seconds))
		} else if status == 429 {
			whole_seconds(retry_after).ok_or(default_seconds)
		} else {
			0
		}
}

## What Sentry's SDKs wait after a 429 that does not say how long to wait.
default_seconds : U64
default_seconds = 60

## The seconds that `limit`, one limit from `X-Sentry-Rate-Limits`, holds
## error events back, which is 0 when its categories leave them out.
error_limit : Str -> U64
error_limit = |limit| {
	parts = limit.trim().split_on(":")
	categories = parts.get(1).ok_or("")
	if categories.is_empty() or categories.split_on(";").contains("error") {
		whole_seconds(parts.get(0).ok_or("")).ok_or(0)
	} else {
		0
	}
}

## The seconds that `text` gives, rounded up when it has a fraction.
whole_seconds : Str -> Try(U64, [NotSeconds])
whole_seconds = |text|
	match text.trim().split_first(".") {
		Ok({ before, after }) => {
			whole = U64.from_str(before) ? |_| NotSeconds
			fraction = U64.from_str(after) ? |_| NotSeconds
			if fraction == 0 {
				Ok(whole)
			} else {
				Ok(whole + 1)
			}
		}
		Err(NotFound) => U64.from_str(text.trim()).map_err(|_| NotSeconds)
	}

# X-Sentry-Rate-Limits counts when it is there: the longest limit on errors
expect RateLimit.retry_after_seconds(429, "60:error;transaction:key, 2700:default:organization", "10") == 60
expect RateLimit.retry_after_seconds(429, "60:error:key, 300:error:organization", "") == 300
expect RateLimit.retry_after_seconds(429, "120::organization", "") == 120
expect RateLimit.retry_after_seconds(429, "120:transaction:key", "30") == 0
expect RateLimit.retry_after_seconds(500, "45:error:key", "") == 45

# Otherwise a 429 asks for Retry-After, or 60
expect RateLimit.retry_after_seconds(429, "", "30") == 30
expect RateLimit.retry_after_seconds(429, "", " 2.5 ") == 3
expect RateLimit.retry_after_seconds(429, "", "") == 60
expect RateLimit.retry_after_seconds(429, "", "Wed, 21 Oct 2015 07:28:00 GMT") == 60

# And anything else for no wait
expect RateLimit.retry_after_seconds(500, "", "30") == 0
expect RateLimit.retry_after_seconds(413, "", "") == 0

expect whole_seconds("60") == Ok(60)
expect whole_seconds("60.0") == Ok(60)
expect whole_seconds("0.1") == Ok(1)
expect whole_seconds("") == Err(NotSeconds)
expect whole_seconds("1.") == Err(NotSeconds)
expect whole_seconds("-1") == Err(NotSeconds)
