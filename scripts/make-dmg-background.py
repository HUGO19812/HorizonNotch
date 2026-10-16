# Draws the DMG window background (Support/dmg/background.png and @2x)
# in the style of the app icon: evening sky, horizon glow, the notch.
# Needs Pillow and the Inter font:  python3 scripts/make-dmg-background.py Support/dmg/background.png
import math, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2
W, H = 640, 420
w, h = W*S, H*S
out = sys.argv[1]

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))
stops = [(0.0, (16, 14, 44)), (0.35, (40, 30, 92)), (0.62, (110, 62, 120)), (0.80, (226, 128, 96)), (0.86, (250, 186, 120))]
def sky(y):
    t = y / h
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1: return lerp(c0, c1, (t - t0) / (t1 - t0))
    return stops[-1][1]

img = Image.new("RGB", (w, h))
d = ImageDraw.Draw(img)
for y in range(h): d.line([(0, y), (w, y)], fill=sky(y))

# Warm glow above the horizon, centred.
glow = Image.new("L", (w, h), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([w*0.18, h*0.62, w*0.82, h*1.08], fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(70*S))
img = Image.composite(Image.new("RGB", (w, h), (255, 196, 130)), img, glow)

# Stars in the upper sky.
random.seed(7)
d = ImageDraw.Draw(img)
placed = 0
while placed < 46:
    x, y = random.uniform(0, w), random.uniform(0, h*0.5)
    # Keep the title, the icons and the arrow clear.
    if 130*S < x < 510*S and 40*S < y < 120*S: continue
    if 90*S < x < 550*S and 140*S < y < 290*S: continue
    placed += 1
    r = random.choice([0.8, 1.0, 1.3]) * S
    a = random.randint(90, 220)
    d.ellipse([x-r, y-r, x+r, y+r], fill=(a, a, min(255, a+20)))

# The planet: a dark arc with a bright rim.
R = w * 1.6
cx, cy = w/2, h*0.86 + R
rim = Image.new("RGBA", (w, h), (255, 210, 150, 0))
rd = ImageDraw.Draw(rim)
rd.ellipse([cx-R-3*S, cy-R-3*S, cx+R+3*S, cy+R+3*S], fill=(255, 210, 150, 255))
rim = rim.filter(ImageFilter.GaussianBlur(2*S))
img.paste(rim, (0, 0), rim)
d = ImageDraw.Draw(img)
d.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(10, 10, 20))

# The notch at the top, with the dot and bars from the icon.
nw, nh = 170*S, 30*S
nx = (w - nw) / 2
d.rounded_rectangle([nx, -nh, nx+nw, nh], radius=14*S, fill=(0, 0, 0))
d.ellipse([nx+18*S, 9*S, nx+30*S, 21*S], fill=(250, 160, 90))
for i, bh in enumerate([8, 14, 10]):
    bx = nx + nw - 40*S + i*7*S
    d.rounded_rectangle([bx, 15*S - bh*S/2, bx+3*S, 15*S + bh*S/2], radius=2*S, fill=(250, 160, 90))

font = lambda size, weight="SemiBold": ImageFont.truetype(f"InterDisplay-{weight}.otf", size*S)
def centered(text, y, f, fill):
    tw = d.textlength(text, font=f)
    d.text(((w - tw)/2, y), text, font=f, fill=fill)
centered("Horizon Notch", 58*S, font(26), (255, 255, 255))
centered("In den Ordner Programme ziehen  ·  Drag to Applications", 94*S, font(12, "Medium"), (215, 210, 235))

# Arrow between the two icons (icons at x 170 and 470, y 205).
ay = 205*S
d.line([(250*S, ay), (388*S, ay)], fill=(255, 255, 255), width=3*S)
d.line([(376*S, ay-11*S), (390*S, ay)], fill=(255, 255, 255), width=3*S)
d.line([(376*S, ay+11*S), (390*S, ay)], fill=(255, 255, 255), width=3*S)

img.save(out.replace(".png", "@2x.png"))
img.resize((W, H), Image.LANCZOS).save(out)
print("label area colours:", img.getpixel((170*S, 275*S)), img.getpixel((470*S, 275*S)))
