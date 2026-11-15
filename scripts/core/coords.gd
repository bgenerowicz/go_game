class_name Coords
extends RefCounted

## The ONLY place that converts between coordinate systems.
##
## Internal convention: x is 0..size-1 from the left, y is 0..size-1 from the TOP.
## GTP (engine): column letter + row number, where the letter "I" is skipped and
##   row 1 is the BOTTOM row.  gtp = LETTERS[x] + str(size - y)
## SGF: lowercase letters a..s with NO skipped letter, y counted from the TOP.

const LETTERS: String = "ABCDEFGHJKLMNOPQRST"
## SGF letters for the supported sizes (max 19): a..s, no skipped letter.
const SGF_LETTERS: String = "abcdefghijklmnopqrs"
const PASS: String = "pass"
const INVALID: Vector2i = Vector2i(-1, -1)
const SIZES: Array[int] = [9, 13, 19]


static func is_valid_size(size: int) -> bool:
	return size in SIZES


static func in_grid(x: int, y: int, size: int) -> bool:
	return x >= 0 and x < size and y >= 0 and y < size


## GTP --------------------------------------------------------------

static func to_gtp(x: int, y: int, size: int) -> String:
	if not in_grid(x, y, size):
		return ""
	return LETTERS[x] + str(size - y)


## Returns INVALID for "pass", malformed input or out-of-range points.
static func from_gtp(gtp: String, size: int) -> Vector2i:
	if gtp == PASS or gtp.length() < 2:
		return INVALID
	var col: String = gtp.substr(0, 1).to_upper()
	var column: int = LETTERS.find(col)
	if column == -1:
		return INVALID
	var row_text: String = gtp.substr(1)
	if not _all_digits(row_text):
		return INVALID
	var row: int = int(row_text)
	if row < 1 or row > size:
		return INVALID
	return Vector2i(column, size - row)


static func is_valid_gtp(gtp: String, size: int) -> bool:
	return from_gtp(gtp, size) != INVALID


static func is_pass(gtp: String) -> bool:
	return gtp == PASS


## Flat array index, used for the engine's ownership / policy arrays, which are
## row-major starting at the TOP-left (same row order as the internal y axis).
static func to_index(x: int, y: int, size: int) -> int:
	return y * size + x


static func from_index(index: int, size: int) -> Vector2i:
	return Vector2i(index % size, int(index / size))


## SGF --------------------------------------------------------------

static func to_sgf(x: int, y: int) -> String:
	if x < 0 or y < 0:
		return PASS_SGF
	if x >= SGF_LETTERS.length() or y >= SGF_LETTERS.length():
		return ""
	return SGF_LETTERS[x] + SGF_LETTERS[y]


## A pass in SGF is an empty value, or two letters beyond 's' ("tt" is the usual).
static func is_sgf_pass(sgf: String) -> bool:
	if sgf.is_empty():
		return true
	if sgf.length() != 2:
		return false
	return sgf[0] > "s" and sgf[1] > "s"


const PASS_SGF: String = "tt"


## Returns INVALID for a pass value, malformed input or out-of-range points.
## Check is_sgf_pass() first if a pass is meaningful to the caller.
static func from_sgf(sgf: String) -> Vector2i:
	if sgf.length() != 2:
		return INVALID
	var column: int = SGF_LETTERS.find(sgf.substr(0, 1))
	var row: int = SGF_LETTERS.find(sgf.substr(1, 1))
	if column == -1 or row == -1:
		return INVALID
	return Vector2i(column, row)


static func is_valid_sgf(sgf: String) -> bool:
	return from_sgf(sgf) != INVALID


static func _all_digits(text: String) -> bool:
	if text.is_empty():
		return false
	for i in text.length():
		if not (text[i] in "0123456789"):
			return false
	return true
