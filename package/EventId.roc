## Event ids: 32 lowercase hex characters shaped like a version 4 UUID, which
## is what Sentry requires. Internal to the package.
##
## Sentry drops an event whose id it has already seen, so ids must not
## repeat. Sentry's own SDKs draw them at random, and so does this package,
## from the 128 bits that two calls of the `random_u64!` hook give. When the
## platform fails to give them, [EventId.derived] makes the bits from the
## time and the event's text instead.
import Hex

EventId := [].{

	## The id made of `random`, with the version and variant bits that a
	## version 4 UUID has in place of six of them.
	new : U128 -> Str
	new = |random| {
		high = random.shr_zf_wrap(64).to_u64_wrap()
		low = random.to_u64_wrap()
		bytes = big_endian(high).concat(big_endian(low)).map_with_index(
			|byte, index|
				if index == 6 {
					# The version nibble
					byte.bitwise_and(0x0F).bitwise_or(0x40)
				} else if index == 8 {
					# The RFC 4122 variant
					byte.bitwise_and(0x3F).bitwise_or(0x80)
				} else {
					byte
				},
		)
		Hex.encode(bytes)
	}

	## 128 bits for an event captured `nanos` after the Unix epoch whose text
	## is `text`, for when there are no random ones. They come from the time
	## and a hash of the text, mixed with SplitMix64 so that events close in
	## time or content share no visible bits. Two events with the same text
	## at the same nanosecond get the same bits.
	derived : U128, Str -> U128
	derived = |nanos, text| {
		low = nanos.to_u64_wrap()
		high = nanos.shr_zf_wrap(64).to_u64_wrap()
		text_hash = fnv1a(text.to_utf8())
		first = split_mix(low.bitwise_xor(text_hash))
		second = split_mix(high.bitwise_xor(text_hash.shr_zf_wrap(32)).plus_wrap(first))
		first.to_u128().shl_wrap(64).bitwise_or(second.to_u128())
	}
}

## FNV-1a, 64 bit.
fnv1a : List(U8) -> U64
fnv1a = |bytes|
	bytes.fold(0xCBF29CE484222325, |hash, byte| hash.bitwise_xor(byte.to_u64()).times_wrap(0x100000001B3))

## SplitMix64's output function: a bijection on U64 that spreads every input
## bit over the whole output.
split_mix : U64 -> U64
split_mix = |x| {
	z1 = x.plus_wrap(0x9E3779B97F4A7C15)
	z2 = z1.bitwise_xor(z1.shr_zf_wrap(30)).times_wrap(0xBF58476D1CE4E5B9)
	z3 = z2.bitwise_xor(z2.shr_zf_wrap(27)).times_wrap(0x94D049BB133111EB)
	z3.bitwise_xor(z3.shr_zf_wrap(31))
}

## The 8 bytes of `n`, most significant first.
big_endian : U64 -> List(U8)
big_endian = |n| [56, 48, 40, 32, 24, 16, 8, 0].map(|shift| n.shr_zf_wrap(shift).to_u8_wrap())

is_lower_hex : U8 -> Bool
is_lower_hex = |byte| (byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)

# The bits as hex, with the version and variant set
expect EventId.new(0x0123456789ABCDEF0123456789ABCDEF) == "0123456789ab4def8123456789abcdef"
expect EventId.new(0) == "00000000000040008000000000000000"
expect EventId.new(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) == "ffffffffffff4fffbfffffffffffffff"
expect EventId.new(1) != EventId.new(2)

# Shaped like a version 4 UUID: the 13th character is the version, the 17th
# carries the variant in its top two bits
expect {
	bytes = EventId.new(EventId.derived(1_735_689_600_000_000_000, "SomeErr")).to_utf8()
	version = bytes.get(12)
	variant = bytes.get(16)
	bytes.len() == 32 and bytes.all(is_lower_hex) and version == Ok(52) and (variant == Ok(56) or variant == Ok(57) or variant == Ok(97) or variant == Ok(98))
}

# Derived bits are the same for the same input, different for a different
# time or text
expect EventId.derived(1, "x") == EventId.derived(1, "x")
expect EventId.derived(1, "x") != EventId.derived(2, "x")
expect EventId.derived(1, "x") != EventId.derived(1, "y")

# Close timestamps do not give close ids
expect {
	a = EventId.new(EventId.derived(1_735_689_600_000_000_000, "x")).to_utf8()
	b = EventId.new(EventId.derived(1_735_689_600_000_000_001, "x")).to_utf8()
	differing = List.map_with_index(
		a,
		|byte, index| if b.get(index) == Ok(byte) {
			0
		} else {
			1
		},
	).sum()
	differing > 16
}

expect fnv1a([]) == 0xCBF29CE484222325
expect fnv1a([97]) == 0xAF63DC4C8601EC8C
expect big_endian(0x0102030405060708) == [1, 2, 3, 4, 5, 6, 7, 8]
expect big_endian(0) == [0, 0, 0, 0, 0, 0, 0, 0]
expect split_mix(0) == 0xE220A8397B1DCDAF
