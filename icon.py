from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math
S = 2048
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# fond : dégradé diagonal + halo
bg = Image.new('RGB', (S, S))
px = bg.load()
c1, c2 = (8, 16, 24), (16, 52, 62)
for y in range(S):
    for x in range(0, S):
        t = min(1, max(0, (x * 0.35 + y * 0.65) / S))
        px[x, y] = lerp(c2, c1, t)
glow = Image.new('L', (S, S), 0)
ImageDraw.Draw(glow).ellipse((S*0.18, S*0.12, S*0.82, S*0.88), fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
bg = Image.composite(Image.new('RGB', (S, S), (30, 90, 100)), bg, glow)

def layer(): return Image.new('RGBA', (S, S), (0, 0, 0, 0))
cx = S * 0.47
W, H = S * 0.38, S * 0.74
top = S * 0.13
L, R = cx - W / 2, cx + W / 2

# ombre
sh = layer(); ImageDraw.Draw(sh).rounded_rectangle((L - 30, top + 40, R + 30, top + H + 60), radius=W * 0.32, fill=(0, 0, 0, 190))
sh = sh.filter(ImageFilter.GaussianBlur(60)); bg.paste(sh, (0, 0), sh)

# roues
d = ImageDraw.Draw(bg)
for yy in (top + H * 0.16, top + H * 0.70):
    for xx in (L - W * 0.07, R - W * 0.13):
        d.rounded_rectangle((xx, yy, xx + W * 0.20, yy + H * 0.15), radius=40, fill=(10, 12, 14))

# carrosserie : dégradé rouge horizontal masqué
body_mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(body_mask).rounded_rectangle((L, top, R, top + H), radius=W * 0.30, fill=255)
paint = Image.new('RGB', (S, S)); pp = paint.load()
stops = [(0, (60, 6, 12)), (0.25, (150, 18, 28)), (0.47, (222, 56, 66)), (0.72, (160, 20, 30)), (1, (60, 6, 12))]
for x in range(S):
    t = (x - L) / W
    t = min(1, max(0, t))
    for i in range(len(stops) - 1):
        if stops[i][0] <= t <= stops[i + 1][0]:
            k = (t - stops[i][0]) / (stops[i + 1][0] - stops[i][0]); col = lerp(stops[i][1], stops[i + 1][1], k); break
    for y in range(int(top), int(top + H) + 1): pp[x, y] = col
bg.paste(paint, (0, 0), body_mask)

g = layer(); gd = ImageDraw.Draw(g)
# pare-brise, toit, lunette
gd.rounded_rectangle((L + W * 0.13, top + H * 0.27, R - W * 0.13, top + H * 0.40), radius=70, fill=(14, 22, 30, 255))
gd.rounded_rectangle((L + W * 0.15, top + H * 0.40, R - W * 0.15, top + H * 0.70), radius=50, fill=(24, 27, 31, 255))
gd.rounded_rectangle((L + W * 0.14, top + H * 0.70, R - W * 0.14, top + H * 0.80), radius=60, fill=(14, 22, 30, 255))
# barres de toit
for xx in (L + W * 0.20, R - W * 0.20):
    gd.line((xx, top + H * 0.42, xx, top + H * 0.68), fill=(150, 160, 170, 255), width=14)
for side in (-1, 1):
    x0 = L - W * 0.10 if side < 0 else R
    gd.rounded_rectangle((x0, top + H * 0.30, x0 + W * 0.10, top + H * 0.335), radius=18, fill=(120, 14, 22, 255))
bg.paste(g, (0, 0), g)
bolt = layer(); bd = ImageDraw.Draw(bolt)
bx, by, bs = cx, top + H * 0.55, W * 0.30
bd.polygon([(bx + bs*0.10, by - bs*0.62), (bx - bs*0.32, by + bs*0.06), (bx - bs*0.02, by + bs*0.06), (bx - bs*0.12, by + bs*0.62), (bx + bs*0.32, by - bs*0.08), (bx + bs*0.02, by - bs*0.08)], fill=(127, 224, 191, 255))
bglow = bolt.filter(ImageFilter.GaussianBlur(30))
bg.paste(bglow, (0, 0), bglow); bg.paste(bolt, (0, 0), bolt)
# reflet sur le pare-brise
rf = layer(); ImageDraw.Draw(rf).polygon([(L + W*0.2, top + H*0.395), (L + W*0.42, top + H*0.28), (L + W*0.55, top + H*0.28), (L + W*0.33, top + H*0.395)], fill=(255, 255, 255, 40))
bg.paste(rf, (0, 0), rf)

# feux : avant blancs, arrière rouges, avec halo
lights = layer(); ld = ImageDraw.Draw(lights)
ld.polygon([(L + W*0.10, top + H*0.075), (L + W*0.40, top + H*0.045), (L + W*0.40, top + H*0.068), (L + W*0.12, top + H*0.098)], fill=(245, 250, 255, 255))
ld.polygon([(R - W*0.10, top + H*0.075), (R - W*0.40, top + H*0.045), (R - W*0.40, top + H*0.068), (R - W*0.12, top + H*0.098)], fill=(245, 250, 255, 255))
ld.rounded_rectangle((L + W * 0.10, top + H * 0.935, R - W * 0.10, top + H * 0.955), radius=16, fill=(255, 50, 64, 255))
halo = lights.filter(ImageFilter.GaussianBlur(28))
bg.paste(halo, (0, 0), halo); bg.paste(lights, (0, 0), lights)

# ondes radio (relais) en haut à droite
waves = layer(); wd = ImageDraw.Draw(waves)
ox, oy = S * 0.80, S * 0.25
for i, r in enumerate((150, 255, 360)):
    wd.arc((ox - r, oy - r, ox + r, oy + r), start=-60, end=30, fill=(127, 224, 191, 255 - i * 45), width=56)
wd.ellipse((ox - 52, oy - 52, ox + 52, oy + 52), fill=(127, 224, 191, 255))
wg = waves.filter(ImageFilter.GaussianBlur(22))
bg.paste(wg, (0, 0), wg); bg.paste(waves, (0, 0), waves)

bg = bg.resize((1024, 1024), Image.LANCZOS)
bg.save('AppIcon.png', optimize=True)
