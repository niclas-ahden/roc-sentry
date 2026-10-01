## Unix time as the ISO 8601 text Sentry reads. Internal to the package.
Timestamp := [].{

	## Nanoseconds since the Unix epoch as `YYYY-MM-DDTHH:MM:SS.mmmZ`, which
	## is what both the envelope's `sent_at` and the event's `timestamp` take.
	to_iso_8601 : U128 -> Str
	to_iso_8601 = |nanos| {
		total_millis = nanos // 1_000_000
		secs = (total_millis // 1000).to_u64_wrap()
		millis = (total_millis % 1000).to_u64_wrap()
		{ year, month, day } = civil_from_days(secs // 86_400)
		second_of_day = secs % 86_400
		hours = second_of_day // 3600
		minutes = (second_of_day % 3600) // 60
		seconds = second_of_day % 60
		"${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}T${pad(hours, 2)}:${pad(minutes, 2)}:${pad(seconds, 2)}.${pad(millis, 3)}Z"
	}
}

## The calendar date `days` after 1970-01-01, by Howard Hinnant's
## civil_from_days algorithm. Every intermediate value is non-negative for a
## day count from the epoch onwards, so unsigned arithmetic is safe.
civil_from_days : U64 -> { year : U64, month : U64, day : U64 }
civil_from_days = |days| {
	z = days + 719_468
	era = z // 146_097
	day_of_era = z - era * 146_097
	year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36_524 - day_of_era // 146_096) // 365
	day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
	# Months counted from March, so that the leap day is last
	shifted_month = (5 * day_of_year + 2) // 153
	day = day_of_year - (153 * shifted_month + 2) // 5 + 1
	month = if shifted_month < 10 {
		shifted_month + 3
	} else {
		shifted_month - 9
	}
	year_from_march = year_of_era + era * 400
	year = if month <= 2 {
		year_from_march + 1
	} else {
		year_from_march
	}
	{ year, month, day }
}

## `n` in decimal, left padded with zeros to `width` characters.
pad : U64, U64 -> Str
pad = |n, width| {
	digits = n.to_str()
	len = digits.count_utf8_bytes()
	if len >= width {
		digits
	} else {
		"0".repeat(width - len).concat(digits)
	}
}

expect Timestamp.to_iso_8601(0) == "1970-01-01T00:00:00.000Z"
expect Timestamp.to_iso_8601(86_399_000_000_000) == "1970-01-01T23:59:59.000Z"
expect Timestamp.to_iso_8601(86_400_000_000_000) == "1970-01-02T00:00:00.000Z"
expect Timestamp.to_iso_8601(951_868_800_000_000_000) == "2000-03-01T00:00:00.000Z"
expect Timestamp.to_iso_8601(1_234_567_890_000_000_000) == "2009-02-13T23:31:30.000Z"
expect Timestamp.to_iso_8601(1_709_164_800_000_000_000) == "2024-02-29T00:00:00.000Z"
expect Timestamp.to_iso_8601(1_733_231_028_123_456_789) == "2024-12-03T13:03:48.123Z"
expect Timestamp.to_iso_8601(1_735_689_599_999_999_999) == "2024-12-31T23:59:59.999Z"
expect Timestamp.to_iso_8601(1_735_689_600_000_000_000) == "2025-01-01T00:00:00.000Z"
expect Timestamp.to_iso_8601(4_102_444_800_000_000_000) == "2100-01-01T00:00:00.000Z"

# Sub-millisecond precision is dropped, not rounded
expect Timestamp.to_iso_8601(1_999_999) == "1970-01-01T00:00:00.001Z"

expect civil_from_days(0) == { year: 1970, month: 1, day: 1 }
expect civil_from_days(59) == { year: 1970, month: 3, day: 1 }
expect civil_from_days(19_782) == { year: 2024, month: 2, day: 29 }
expect pad(7, 2) == "07"
expect pad(123, 2) == "123"
expect pad(0, 3) == "000"
