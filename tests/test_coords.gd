extends RefCounted

## One test module. The runner instantiates this and calls run(a).
var a: Assertions


func run() -> void:
	_test_coords_gtp()
	_test_coords_sgf()
	_test_coords_index()


## Coords: GTP ------------------------------------------------------------

func _test_coords_gtp() -> void:
	a.section("coords: gtp")
	a.check_eq(Coords.LETTERS.length(), 19, "19 column letters")
	a.check(not ("I" in Coords.LETTERS), "the letter I is skipped")
	a.check_eq(Coords.LETTERS[7], "H", "letter 7 is H")
	a.check_eq(Coords.LETTERS[8], "J", "letter 8 is J")
	a.check_eq(Coords.to_gtp(0, 0, 19), "A19", "top-left of 19x19")
	a.check_eq(Coords.to_gtp(18, 18, 19), "T1", "bottom-right of 19x19")
	a.check_eq(Coords.to_gtp(15, 3, 19), "Q16", "Q16 star point")
	a.check_eq(Coords.from_gtp("Q16", 19), Vector2i(15, 3), "Q16 back to x,y")
	a.check_eq(Coords.to_gtp(7, 0, 19), "H19", "H is column 7")
	a.check_eq(Coords.to_gtp(8, 0, 19), "J19", "J is column 8")
	a.check_eq(Coords.to_gtp(0, 8, 9), "A1", "bottom-left of 9x9")
	a.check_eq(Coords.to_gtp(8, 0, 9), "J9", "top-right of 9x9")
	a.check_eq(Coords.to_gtp(12, 0, 13), "N13", "top-right of 13x13 skips I")
	# Round-trip every point of every supported size.
	for size in Coords.SIZES:
		var round_ok := true
		for y in size:
			for x in size:
				var gtp: String = Coords.to_gtp(x, y, size)
				if Coords.from_gtp(gtp, size) != Vector2i(x, y):
					round_ok = false
		a.check(round_ok, "round-trip over all %d points on %dx%d" % [size * size, size, size])
	# Rejected input. ("Q1" is a legal 19x19 point, so it is not in this list.)
	for bad in ["", "I19", "A0", "A20", "Z1", "1A", "pass", "AA1", "Q16 ", "A-1", "Q", "16"]:
		a.check(not Coords.is_valid_gtp(bad, 19), "rejects <%s>" % bad)
	a.check_eq(Coords.from_gtp("I19", 19), Coords.INVALID, "I19 is not a point")
	a.check(Coords.is_valid_gtp("a19", 19), "accepts lower-case gtp")
	a.check(Coords.is_pass("pass"), "\"pass\" is recognised as a pass")
	a.check(not Coords.is_valid_gtp("A19", 9), "A19 is off a 9x9 board")
	a.check_eq(Coords.to_gtp(-1, 0, 19), "", "off-board to_gtp is empty")
	a.check(not Coords.is_valid_size(18), "18x18 is not a supported size")


## Coords: SGF ------------------------------------------------------------

func _test_coords_sgf() -> void:
	a.section("coords: sgf")
	a.check_eq(Coords.to_sgf(0, 0), "aa", "sgf top-left")
	a.check_eq(Coords.to_sgf(18, 18), "ss", "sgf bottom-right of 19x19")
	a.check_eq(Coords.from_sgf("dd"), Vector2i(3, 3), "sgf dd")
	# SGF does NOT skip "i", unlike GTP.
	a.check_eq(Coords.to_sgf(8, 8), "ii", "sgf uses the letter i")
	a.check_eq(Coords.from_sgf("ii"), Vector2i(8, 8), "sgf ii decodes")
	var round_ok := true
	for y in 19:
		for x in 19:
			if Coords.from_sgf(Coords.to_sgf(x, y)) != Vector2i(x, y):
				round_ok = false
	a.check(round_ok, "sgf round-trip over all 361 points")
	# from_sgf is size independent, so callers must still bounds-check it.
	a.check_eq(Coords.from_sgf("tt"), Coords.INVALID, "tt is outside the a..s range")
	a.check(not Coords.in_grid(19, 19, 19), "and index 19 is off every supported board")
	a.check_eq(Coords.to_sgf(19, 19), "", "to_sgf refuses out-of-range points")
	for bad in ["", "a", "abc", "aA", "!!", "a1", "1", "tt"]:
		a.check(not Coords.is_valid_sgf(bad), "rejects sgf <%s>" % bad)


## Coords: flat indices (engine ownership / policy arrays) ------------------

func _test_coords_index() -> void:
	a.section("coords: flat index")
	for size in Coords.SIZES:
		var ok := true
		for y in size:
			for x in size:
				if Coords.from_index(Coords.to_index(x, y, size), size) != Vector2i(x, y):
					ok = false
		a.check(ok, "index round-trip on %dx%d" % [size, size])
	a.check_eq(Coords.to_index(0, 0, 19), 0, "top-left is index 0")
	a.check_eq(Coords.to_index(18, 18, 19), 360, "bottom-right is the last index")
