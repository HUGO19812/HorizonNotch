# Generates the liquid-chrome textures of the lock screen card styles
# (HorizonNotch/Resources/Assets.xcassets/Chrome*.imageset):
#   python3 scripts/make-chrome-textures.py <out dir> 1200 760
# Procedural liquid-chrome textures: a smooth height field rendered as a
# mirror that reflects a studio environment (bright bands, dark bands, a
# coloured sky), like a chrome/glass sculpture photographed in a studio.
import sys, numpy as np
from PIL import Image, ImageFilter

def field(w, h, seed):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    u, v = x / w, y / h
    # Domain warp for flowing, liquid shapes.
    wu = u + 0.18*np.sin(2*np.pi*(v*1.3 + rng.random())) + 0.08*np.sin(2*np.pi*(u*2.1 + v*0.7 + rng.random()))
    wv = v + 0.16*np.sin(2*np.pi*(u*1.1 + rng.random())) + 0.07*np.cos(2*np.pi*(v*2.4 - u*0.9 + rng.random()))
    hgt = np.zeros_like(u)
    for _ in range(5):
        fx, fy = rng.uniform(0.35, 1.1, 2)
        ph = rng.uniform(0, 2*np.pi, 2)
        a = rng.uniform(0.4, 1.0)
        hgt += a*np.sin(2*np.pi*fx*wu + ph[0]) * np.cos(2*np.pi*fy*wv + ph[1])
    return hgt

def render(w, h, seed, env, strength=3.2):
    hgt = field(w, h, seed)
    gy, gx = np.gradient(hgt)
    nx, ny = -gx*w*strength/ 40, -gy*h*strength/40
    nz = np.ones_like(nx)
    n = np.sqrt(nx**2 + ny**2 + nz**2)
    nx, ny, nz = nx/n, ny/n, nz/n
    # Reflect the view vector (0,0,-1) about the normal.
    rx, ry, rz = 2*nz*nx, 2*nz*ny, 2*nz*nz - 1
    return env(rx, ry, rz, hgt)

def bands(t, stops):
    # stops: list of (pos, (r,g,b)) sorted; linear interpolation
    pos = np.array([s[0] for s in stops]); cols = np.array([s[1] for s in stops], dtype=np.float64)
    out = np.stack([np.interp(t, pos, cols[:, i]) for i in range(3)], -1)
    return out

def make_env(stops, glow=None):
    def env(rx, ry, rz, hgt):
        # Studio: mostly depends on the vertical reflection angle, a little on x.
        t = 0.5 + 0.5*np.clip(ry*0.9 + rx*0.35, -1, 1)
        col = bands(t, stops)
        # Thin bright highlight streaks where the reflection grazes.
        streak = np.exp(-((ry - 0.55)**2)/0.004) + 0.6*np.exp(-((rx + 0.45)**2)/0.003)
        col += streak[..., None]*255*0.8
        if glow is not None:
            col += glow[None, None, :]*(0.5 + 0.5*hgt[..., None]/np.abs(hgt).max())*0.25
        return np.clip(col, 0, 255).astype(np.uint8)
    return env

THEMES = {
    # Blue studio, like the reference photo: blue sky, white light, dark rims, warm glints.
    "ocean": make_env([(0.0, (5, 30, 60)), (0.25, (12, 90, 140)), (0.42, (220, 235, 245)), (0.5, (25, 110, 165)),
                       (0.62, (8, 40, 70)), (0.72, (240, 190, 140)), (0.8, (20, 100, 160)), (1.0, (180, 220, 240))]),
    "graphite": make_env([(0.0, (8, 8, 10)), (0.3, (40, 42, 48)), (0.45, (210, 212, 220)), (0.52, (30, 32, 38)),
                          (0.7, (12, 12, 14)), (0.8, (150, 152, 160)), (1.0, (60, 62, 70))]),
    "prism": make_env([(0.0, (30, 10, 60)), (0.2, (120, 60, 200)), (0.38, (240, 230, 255)), (0.46, (60, 200, 230)),
                       (0.6, (20, 20, 50)), (0.7, (255, 150, 200)), (0.82, (90, 80, 220)), (1.0, (200, 240, 255))]),
    "sunset": make_env([(0.0, (20, 12, 40)), (0.25, (70, 40, 110)), (0.42, (255, 225, 190)), (0.5, (230, 120, 90)),
                        (0.62, (40, 20, 50)), (0.75, (255, 170, 110)), (0.85, (110, 60, 130)), (1.0, (250, 210, 170))]),
}

if __name__ == "__main__":
    out, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    for i, (name, env) in enumerate(THEMES.items()):
        img = Image.fromarray(render(w, h, 11 + i, env))
        img = img.filter(ImageFilter.GaussianBlur(0.6))
        img.save(f"{out}/chrome-{name}.jpg", quality=88)
        print(name)
