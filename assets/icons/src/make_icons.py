# -*- coding: utf-8 -*-
"""Compose pgsql/redis start-stop icons: logo as the body, win-style play/stop badge bottom-right.

Output: assets/icons/{pgsql,redis}-{start,stop}.ico  (16/24/32/48/64/128/256)
        .tmp-icons/preview.png (2x2 strip for human review)
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, 'assets', 'icons')
os.makedirs(OUT, exist_ok=True)

S = 2048          # supersampled canvas
FINAL = 512       # design-space canvas (all coords below are in this space)
K = S // FINAL    # supersample factor

GREEN = (22, 163, 74, 255)    # start
RED = (220, 38, 38, 255)      # stop
WHITE = (255, 255, 255, 255)
RING = (255, 255, 255, 255)

BADGE_C = (386, 386)   # badge center in 512-space
BADGE_RO = 104         # outer (white ring) radius
BADGE_RI = 86          # inner colored disc radius


def fit_logo(img, box):
    """Scale img (RGBA) to fit inside box=(x0,y0,x1,y1), centered; return pasted-on-transparent canvas."""
    canvas = Image.new('RGBA', (FINAL, FINAL), (0, 0, 0, 0))
    w, h = img.size
    bw, bh = box[2] - box[0], box[3] - box[1]
    scale = min(bw / w, bh / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    resized = img.resize((nw, nh), Image.LANCZOS)
    # small sharpen for upscaled small sources
    if scale > 2.0:
        try:
            from PIL import ImageFilter
            resized = resized.filter(ImageFilter.UnsharpMask(radius=2, percent=90, threshold=2))
        except Exception:
            pass
    cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
    canvas.paste(resized, (cx - nw // 2, cy - nh // 2), resized)
    return canvas


def glyph_play(draw, cx, cy):
    """Right-pointing triangle, optically centered."""
    pts = [(cx - 30, cy - 52), (cx - 30, cy + 52), (cx + 54, cy)]
    draw.polygon(pts, fill=WHITE)


def glyph_stop(draw, cx, cy):
    side = 112
    r = 26
    x0, y0 = cx - side // 2 + 4, cy - side // 2  # +4 optical shift left
    draw.rounded_rectangle([x0, y0, x0 + side, y0 + side], radius=r, fill=WHITE)


def build(logo_path, kind, out_path):
    logo = Image.open(logo_path).convert('RGBA')
    base = fit_logo(logo, (16, 12, 396, 392))

    canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    big = base.resize((S, S), Image.NEAREST)
    canvas.alpha_composite(big)

    draw = ImageDraw.Draw(canvas)
    cx, cy = BADGE_C[0] * K, BADGE_C[1] * K
    ro, ri = BADGE_RO * K, BADGE_RI * K
    color = GREEN if kind == 'start' else RED
    draw.ellipse([cx - ro, cy - ro, cx + ro, cy + ro], fill=RING)
    draw.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=color)
    if kind == 'start':
        glyph_play(draw, cx, cy)
    else:
        glyph_stop(draw, cx, cy)

    final = canvas.resize((FINAL, FINAL), Image.LANCZOS)
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    final.save(out_path, format='ICO', sizes=sizes)
    print('saved', out_path, os.path.getsize(out_path), 'bytes')
    return final


pg = os.path.join(HERE, 'pgsql-logo.png')
rd = os.path.join(HERE, 'redis-logo.png')

results = {}
results[('pgsql', 'start')] = build(pg, 'start', os.path.join(OUT, 'pgsql-start.ico'))
results[('pgsql', 'stop')] = build(pg, 'stop', os.path.join(OUT, 'pgsql-stop.ico'))
results[('redis', 'start')] = build(rd, 'start', os.path.join(OUT, 'redis-start.ico'))
results[('redis', 'stop')] = build(rd, 'stop', os.path.join(OUT, 'redis-stop.ico'))

# ---- preview strip: 2 rows (pgsql, redis) x 2 cols (start, stop) on light bg ----
cell = 256
pad = 24
w = pad * 3 + cell * 2
h = pad * 3 + cell * 2
prev = Image.new('RGBA', (w, h), (243, 244, 246, 255))
for (key, img) in results.items():
    row, col = 0 if key[0] == 'pgsql' else 1, 0 if key[1] == 'start' else 1
    icon = img.resize((cell, cell), Image.LANCZOS)
    prev.alpha_composite(icon, (pad + col * (cell + pad), pad + row * (cell + pad)))
prev.convert('RGB').save(os.path.join(HERE, 'preview.png'))
print('preview saved')

# ---- programmatic verification ----
print('--- verify ---')
for key, img in results.items():
    px = img.load()
    bx, by = BADGE_C
    def sample(x, y):
        return px[x, y]
    disc = sample(bx - 40, by)     # inside colored disc, left of glyph
    ring = sample(bx - 97, by)     # on white ring
    center = sample(bx, by)        # glyph center -> white
    logo = sample(200, 200)        # logo body area
    print(key,
          'disc=%s' % (disc[:3],),
          'ring=%s' % (ring[:3],),
          'center=%s' % (center[:3],),
          'logo_alpha=%d' % logo[3])
    assert ring[:3] == (255, 255, 255), 'ring should be white'
    assert center[0] > 240 and center[1] > 240 and center[2] > 240, 'glyph center should be white'
    assert logo[3] > 0, 'logo area should not be empty'
    if key[1] == 'start':
        assert disc[1] > 120 and disc[0] < 90, 'start disc should be green'
    else:
        assert disc[0] > 170 and disc[1] < 90, 'stop disc should be red'
print('pixel checks OK')

# ico frame inventory
for name in ('pgsql-start', 'pgsql-stop', 'redis-start', 'redis-stop'):
    ico = Image.open(os.path.join(OUT, name + '.ico'))
    print(name, 'frames:', sorted(ico.ico.sizes()))
