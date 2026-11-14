#!/usr/bin/env python3
"""Assert what the app actually drew, pixel by pixel.

Two checks feed this tool, each printing the screen coordinates it used:

  tests/render_check.gd  - the board. Prints "board origin: x,y cell: c" and
      "PIXEL col,row C x y" for stones that must be there and one point that
      must be empty wood.
  tests/render_graph.gd  - the win-rate graph. Prints "GRAPHPOINT turn value
      x y" for the win-rate line, "GRAPHMID x y" for the 50% grid line,
      "GRAPHCURSOR x y" for the cursor and "GRAPHDOT turn kind x y" for
      mistake dots. Those coordinates come from the documented mapping
      (turn -> x, win-rate -> height), not from the drawing code, so a wrong
      mapping is caught rather than reproduced.

Run both together (the image must exist before it is analysed):

    with-display godot --path . --script tests/render_check.gd > /tmp/render.txt 2>&1
    python3 tools/pixel_assert.py /tmp/render.txt /tmp/go_game_render.png

    with-display godot --path . --script tests/render_graph.gd > /tmp/graph.txt 2>&1
    python3 tools/pixel_assert.py /tmp/graph.txt /tmp/go_game_graph.png

Exits non-zero when something is missing, misplaced or the wrong colour.
Only the standard library is used, so it works on any machine with Python 3.
"""

import re
import struct
import sys
import zlib


def read_png(path):
    """Decode a PNG without any third-party library. Returns (w, h, rows)."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG file" % path)
    pos, idat, width, height, bit_depth, colour_type = 8, b"", 0, 0, 8, 6
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, bit_depth, colour_type = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
        pos += 12 + length
    if bit_depth != 8:
        raise ValueError("only 8-bit PNGs are supported, got %d" % bit_depth)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour_type]
    raw = zlib.decompress(idat)
    stride = width * channels
    rows = []
    previous = [0] * stride
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        line = list(raw[offset:offset + stride])
        offset += stride
        if filter_type == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 255
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                up_left = previous[i - channels] if i >= channels else 0
                predicted = left + up - up_left
                pl, pu, pul = abs(predicted - left), abs(predicted - up), abs(predicted - up_left)
                chosen = left if (pl <= pu and pl <= pul) else (up if pu <= pul else up_left)
                line[i] = (line[i] + chosen) & 255
        elif filter_type != 0:
            raise ValueError("unsupported PNG filter %d" % filter_type)
        rows.append(line)
        previous = line
    return width, height, channels, rows


# Colours the graph is expected to paint, measured from a real screenshot rather
# than read off the Color constants, so anti-aliasing and rounding are included.
GRAPH_COLORS = {
    "line": (38, 115, 217),      # win-rate line
    "grid": (140, 128, 107),     # 0/25/50/75/100 percent grid lines
    "cursor": (38, 38, 38),      # vertical cursor at the current move
    "inaccuracy": (230, 204, 51),
    "mistake": (235, 128, 25),
    "blunder": (217, 38, 31),
}
# How far from the predicted point the expected colour may be found. The cursor
# is drawn over the dot of the current move, so dots get the widest window.
GRAPH_TOLERANCE = 8
GRAPH_SEARCH_RADIUS = {"line": 2, "grid": 1, "cursor": 2,
                       "inaccuracy": 5, "mistake": 6, "blunder": 8}


def near(actual, expected, tolerance=GRAPH_TOLERANCE):
    return all(abs(a - e) <= tolerance for a, e in zip(actual, expected))


def find_colour(rows, width, height, channels, x, y, expected, radius):
    """Count pixels within radius of (x, y) that match expected. Returns count."""
    hits = 0
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            px, py = int(round(x)) + dx, int(round(y)) + dy
            if not (0 <= px < width and 0 <= py < height):
                continue
            row = rows[py]
            i = px * channels
            if near((row[i], row[i + 1], row[i + 2]), expected):
                hits += 1
    return hits


def classify(rows, width, height, channels, x, y, radius):
    """Vote on what is drawn around (x, y): black stone, white stone or wood."""
    votes = {"black": 0, "white": 0, "wood": 0, "other": 0}
    for dy in range(-radius, radius + 1, 2):
        for dx in range(-radius, radius + 1, 2):
            px, py = int(x) + dx, int(y) + dy
            if not (0 <= px < width and 0 <= py < height):
                continue
            row = rows[py]
            r, g, b = row[px * channels], row[px * channels + 1], row[px * channels + 2]
            brightness = (r + g + b) / 3.0
            if brightness < 80:
                votes["black"] += 1
            elif brightness > 190 and abs(r - g) < 30 and abs(g - b) < 30:
                votes["white"] += 1
            elif r > 170 and (r - b) > 40:
                votes["wood"] += 1
            else:
                votes["other"] += 1
    return max(votes, key=lambda kind: votes[kind]), votes


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    report_path, image_path = sys.argv[1], sys.argv[2]
    width, height, channels, rows = read_png(image_path)
    print("image %dx%d from %s" % (width, height, image_path))

    wanted = {"B": "black", "W": "white", "E": "wood"}
    cell = 0.0
    checked = 0
    failed = 0

    def record(label, want, x, y, ok, detail):
        nonlocal checked, failed
        checked += 1
        failed += 0 if ok else 1
        print("  %-11s %-9s at (%.0f,%.0f) -> %s"
              % (label, want, x, y, detail if ok else "MISMATCH (%s)" % detail))

    def check_colour(label, key, x, y):
        expected = GRAPH_COLORS[key]
        hits = find_colour(rows, width, height, channels, x, y,
                           expected, GRAPH_SEARCH_RADIUS[key])
        record(label, key, x, y, hits > 0, "%d matching pixels" % hits)

    for line in open(report_path, encoding="utf-8", errors="replace"):
        line = line.strip()
        size = re.match(r"board origin: -?[\d.]+,-?[\d.]+ cell: ([\d.]+)", line)
        if size:
            cell = float(size.group(1))
            continue

        found = re.match(r"PIXEL (\d+),(\d+) ([BWE]) (-?[\d.]+) (-?[\d.]+)", line)
        if found:
            col, row_letter, want = int(found.group(1)), int(found.group(2)), found.group(3)
            x, y = float(found.group(4)), float(found.group(5))
            radius = max(4, int(cell * 0.25)) if cell else 8
            got, votes = classify(rows, width, height, channels, x, y, radius)
            ok = got == wanted[want]
            record("%d,%d" % (col, row_letter), want, x, y, ok,
                   "%s %s" % (got, votes))
            continue

        point = re.match(r"GRAPHPOINT (\d+) ([\d.]+) (-?[\d.]+) (-?[\d.]+)", line)
        if point:
            check_colour("turn %s" % point.group(1), "line",
                         float(point.group(3)), float(point.group(4)))
            continue

        mid = re.match(r"GRAPHMID (-?[\d.]+) (-?[\d.]+)", line)
        if mid:
            check_colour("50% line", "grid", float(mid.group(1)), float(mid.group(2)))
            continue

        cursor = re.match(r"GRAPHCURSOR (-?[\d.]+) (-?[\d.]+)", line)
        if cursor:
            check_colour("cursor", "cursor", float(cursor.group(1)), float(cursor.group(2)))
            continue

        dot = re.match(r"GRAPHDOT (\d+) (\w+) (-?[\d.]+) (-?[\d.]+)", line)
        if dot:
            kind = dot.group(2)
            if kind not in GRAPH_COLORS:
                print("  unknown mistake kind %r in %r" % (kind, line))
                failed += 1
                checked += 1
                continue
            check_colour("dot %s" % dot.group(1), kind,
                         float(dot.group(3)), float(dot.group(4)))
            continue

    if checked == 0:
        print("FAIL no PIXEL or GRAPH lines in %s - did the render check run?" % report_path)
        return 1
    print("=== pixel assertions: %d/%d ok, %d failed ===" % (checked - failed, checked, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
