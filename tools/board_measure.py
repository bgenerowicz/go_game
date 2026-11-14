#!/usr/bin/env python3
"""Measure the rendered board: grid lines, star points, coordinates, stones.

Recomputes the expected geometry from the screenshot itself (the board rect is
found from the wood-coloured region), then checks dark pixels sit on the expected
grid lines, star points are darker blobs, and stones land on the right points.
"""
import sys
import zlib
import struct


def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos, width, height, idat = 8, 0, 0, b''
    while pos < len(data):
        (ln,) = struct.unpack('>I', data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + ln]
        if kind == b'IHDR':
            width, height = struct.unpack('>II', body[:8])
        elif kind == b'IDAT':
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp, stride = 4, width * 4
    img = []
    prev = bytearray(stride)
    for y in range(height):
        ft = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 1:
                line[x] = (line[x] + a) & 255
            elif ft == 2:
                line[x] = (line[x] + b) & 255
            elif ft == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        img.append(line)
        prev = line
    return width, height, img


def px(img, x, y):
    row = img[y]
    return row[x * 4], row[x * 4 + 1], row[x * 4 + 2]


def is_wood(rgb):
    r, g, b = rgb
    return r > 190 and 140 < g < 200 and b < 140


def main():
    path = sys.argv[1]
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 19
    w, h, img = read_png(path)
    # Board rect = bounding box of wood-coloured pixels.
    xs = [x for y in range(0, h, 3) for x in range(0, w, 3) if is_wood(px(img, x, y))]
    ys = [y for y in range(0, h, 3) for x in range(0, w, 3) if is_wood(px(img, x, y))]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    print('image %dx%d  wood rect x %d..%d y %d..%d' % (w, h, x0, x1, y0, y1))

    def lum(x, y):
        return sum(px(img, x, y)) / 3.0

    def dark_cols():
        hits = []
        for x in range(x0, x1 + 1):
            dark = sum(1 for y in range(y0, y1 + 1, 3) if lum(x, y) < 120)
            hits.append((x, dark))
        peak = max(d for _, d in hits)
        cols = [x for x, d in hits if d > peak * 0.55]
        # cluster adjacent columns
        groups, cur = [], []
        for x in cols:
            if cur and x - cur[-1] > 3:
                groups.append(sum(cur) // len(cur))
                cur = []
            cur.append(x)
        if cur:
            groups.append(sum(cur) // len(cur))
        return groups, peak

    def dark_rows():
        hits = []
        for y in range(y0, y1 + 1):
            dark = sum(1 for x in range(x0, x1 + 1, 3) if lum(x, y) < 120)
            hits.append((y, dark))
        peak = max(d for _, d in hits)
        rows = [y for y, d in hits if d > peak * 0.55]
        groups, cur = [], []
        for y in rows:
            if cur and y - cur[-1] > 3:
                groups.append(sum(cur) // len(cur))
                cur = []
            cur.append(y)
        if cur:
            groups.append(sum(cur) // len(cur))
        return groups, peak

    cols, cpeak = dark_cols()
    rows, rpeak = dark_rows()
    print('vertical grid lines: %d / %d (darkest column had %d dark samples) at x=%s'
          % (len(cols), size, cpeak, cols[:3] + ['...'] + cols[-2:] if len(cols) > 5 else cols))
    print('horizontal grid lines: %d / %d at y=%s'
          % (len(rows), size, rows[:3] + ['...'] + rows[-2:] if len(rows) > 5 else rows))
    if len(cols) < 2 or len(rows) < 2:
        print('NO GRID DRAWN')
        return
    cell = (cols[-1] - cols[0]) / float(len(cols) - 1)
    spacing = [cols[i + 1] - cols[i] for i in range(len(cols) - 1)]
    print('cell from detected lines: %.1f  (min %d max %d)' % (cell, min(spacing), max(spacing)))

    # Intersections from the detected lines.
    def centre(i, j):
        return (cols[i], rows[j])

    def dark_at(i, j, rad):
        cx, cy = centre(i, j)
        return sum(1 for dy in range(-rad, rad + 1) for dx in range(-rad, rad + 1)
                   if 0 <= cx + dx < w and 0 <= cy + dy < h and lum(cx + dx, cy + dy) < 110)

    def light_at(i, j, rad):
        cx, cy = centre(i, j)
        return sum(1 for dy in range(-rad, rad + 1) for dx in range(-rad, rad + 1)
                   if 0 <= cx + dx < w and 0 <= cy + dy < h and lum(cx + dx, cy + dy) > 200)

    # Star points: compare hoshi intersections with plain ones.
    n = len(cols)
    edge = 3 if n >= 13 else 2
    hoshi = [(a, b) for a in (edge, n // 2, n - 1 - edge) for b in (edge, n // 2, n - 1 - edge)]
    plain = [(edge + 1, edge + 1), (edge + 2, n // 2), (n // 2, edge + 2)]
    rad = max(3, int(cell * 0.18))
    hoshi_scores = [dark_at(i, j, rad) for (i, j) in hoshi]
    plain_scores = [dark_at(i, j, rad) for (i, j) in plain]
    print('star-point dark counts (r=%d): %s   plain intersections: %s'
          % (rad, hoshi_scores, plain_scores))
    baseline = max(plain_scores) if plain_scores else 0
    stars = sum(1 for s in hoshi_scores if s > baseline + 8)
    print('star points clearly drawn: %d / %d' % (stars, len(hoshi)))

    # Stones: a stone covers most of the cell around an intersection.
    big = max(3, int(cell * 0.32))
    black, white = [], []
    for j in range(n):
        for i in range(n):
            if dark_at(i, j, big) >= (2 * big + 1) ** 2 * 0.7:
                black.append((i, j))
            elif light_at(i, j, big) >= (2 * big + 1) ** 2 * 0.7:
                white.append((i, j))
    print('black stones at (x,y): %s' % black)
    print('white stones at (x,y): %s' % white)

    # Coordinate labels: dark text in the wood band outside the outer grid lines
    # (grid lines stop at the outer lines, so anything dark there is a label).
    band = int(cell * 0.7)
    label_px = 0
    for y in range(max(0, rows[0] - band), rows[0] - 3):
        for x in range(max(0, cols[0] - band), min(w, cols[-1] + band + 1)):
            if lum(x, y) < 150:
                label_px += 1
    for y in range(rows[-1] + 4, min(h, rows[-1] + band + 1)):
        for x in range(max(0, cols[0] - band), min(w, cols[-1] + band + 1)):
            if lum(x, y) < 150:
                label_px += 1
    print('dark label pixels above/below the grid: %d' % label_px)

    left = 0
    for x in range(max(0, cols[0] - band), cols[0] - 3):
        for y in range(max(0, rows[0] - band), min(h, rows[-1] + band + 1)):
            if lum(x, y) < 150:
                left += 1
    right = 0
    for x in range(cols[-1] + 4, min(w, cols[-1] + band + 1)):
        for y in range(max(0, rows[0] - band), min(h, rows[-1] + band + 1)):
            if lum(x, y) < 150:
                right += 1
    print('dark label pixels left/right of the grid: %d + %d' % (left, right))


if __name__ == '__main__':
    main()
