## Lowercase hexadecimal text. Internal to the package.
Hex := [].{

	## `bytes` as lowercase hex, two characters per byte.
	encode : List(U8) -> Str
	encode = |bytes|
		Str.from_utf8_lossy(bytes.fold([], |acc, byte| acc.append(digit(byte // 16)).append(digit(byte % 16))))

	## The lowercase hex character for a value below 16.
	digit : U8 -> U8
	digit = |n| if n < 10 {
		48 + n
	} else {
		87 + n
	}
}

expect Hex.encode([]) == ""
expect Hex.encode([0, 15, 16, 255]) == "000f10ff"
expect Hex.encode([0xDE, 0xAD, 0xBE, 0xEF]) == "deadbeef"
expect Hex.digit(0) == 48
expect Hex.digit(9) == 57
expect Hex.digit(10) == 97
expect Hex.digit(15) == 102
