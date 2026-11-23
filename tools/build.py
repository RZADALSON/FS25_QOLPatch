"""Build FS25_MegaPatch.zip (QOL Patch) from this repository.

A few files are derived from Farming Simulator 25 assets (GIANTS Software) and are therefore NOT
stored in the repository. This script recreates them from YOUR local game installation:

  objects/ibcDiesel/ibcDiesel.i3d          <- data/objects/pallets/liquidTank/liquidTank.i3d (renamed refs)
  objects/ibcDiesel/ibcDiesel.i3d.shapes   <- data/objects/pallets/liquidTank/liquidTank.i3d.shapes
  objects/ibcDiesel/ibcDiesel_diffuse.dds  <- fertilizerTank_diffuse.dds recoloured black + DIESEL label
  objects/ibcDiesel/store_ibcDiesel.dds    <- store_fertilizerTank.dds recoloured black + DIESEL label
  objects/paints/paintDecal.i3d.shapes     <- data/maps/mapEU/textures/dirtGroundDecal.i3d.shapes
  objects/parkingLines/paintDecal.i3d.shapes (same mesh)

Usage (needs Python 3 with Pillow and numpy):
  python tools/build.py                       -> dist/FS25_MegaPatch.zip
  python tools/build.py --game "D:/Games/Farming Simulator 25" --install
      --install copies the zip to Documents/My Games/FarmingSimulator2025/mods
"""
import argparse
import io
import os
import shutil
import struct
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_GAME = r"C:\Program Files (x86)\Steam\steamapps\common\Farming Simulator 25"
ZIP_NAME = "FS25_MegaPatch.zip"   # keep this name: savegames reference the mod by it
EXCLUDE_TOP = {".git", ".github", "tools", "dist", "README.md", "LICENSE", ".gitignore", ".gitattributes"}


def save_dds(img, path, fmt):
    """RGBA PIL image -> DDS (DXT1/DXT5) with a full mipmap chain."""
    from PIL import Image
    img = img.convert("RGBA")
    levels = []
    w, h = img.size
    cur = img
    while True:
        buf = io.BytesIO()
        cur.save(buf, format="DDS", pixel_format=fmt)
        data = buf.getvalue()
        levels.append((data[:128], data[128:]))
        if w == 1 and h == 1:
            break
        w, h = max(1, w // 2), max(1, h // 2)
        cur = img.resize((w, h), Image.LANCZOS)
    header = bytearray(levels[0][0])
    struct.pack_into("<I", header, 8, struct.unpack_from("<I", header, 8)[0] | 0x20000)
    struct.pack_into("<I", header, 28, len(levels))
    struct.pack_into("<I", header, 108, struct.unpack_from("<I", header, 108)[0] | 0x8 | 0x400000 | 0x1000)
    with open(path, "wb") as f:
        f.write(header)
        for _, d in levels:
            f.write(d)


def font(size):
    from PIL import ImageFont
    for name in ("arialbd.ttf", "Arial Bold.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def recolor_black(img, need_alpha):
    """Cream tank plastic -> black, blue fertilizer pictogram removed."""
    import numpy as np
    from PIL import Image
    a = np.asarray(img.convert("RGBA")).astype(np.float32)
    r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    cream = (r > 120) & (g > 110) & (b > 90) & ((r - b) > 2) & ((r - b) < 45) & ((mx - mn) < 50)
    blue = (b > r + 40) & (b > 120)
    if need_alpha:
        cream &= al > 200
        blue &= al > 100
    lum = (0.3 * r + 0.59 * g + 0.11 * b) / 205.0
    base = np.array([34, 35, 37], np.float32)
    for c in range(3):
        a[..., c] = np.where(cream, np.clip(base[c] * (0.2 + 1.05 * lum), 0, 255), a[..., c])
    for c in range(3):
        a[..., c] = np.where(blue, base[c], a[..., c])
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def make_ibc_texture(src, dst):
    from PIL import Image, ImageDraw
    img = recolor_black(Image.open(src), False)
    d = ImageDraw.Draw(img)
    img.paste(img.crop((1060, 500, 1142, 590)), (958, 500))
    x0, y0, x1, y1 = 858, 158, 1132, 362
    d.rectangle([x0, y0, x1, y1], fill=(240, 196, 24, 255), outline=(20, 20, 20, 255), width=5)
    d.text(((x0 + x1) / 2, y0 + 48), "DIESEL", font=font(58), fill=(15, 15, 15, 255), anchor="mm")
    d.text(((x0 + x1) / 2, y0 + 94), "UN 1202", font=font(30), fill=(15, 15, 15, 255), anchor="mm")
    cx, cy, s = x0 + 58, y1 - 50, 38
    d.polygon([(cx, cy - s), (cx + s, cy), (cx, cy + s), (cx - s, cy)], fill=(205, 30, 30, 255), outline=(15, 15, 15, 255))
    d.text((cx, cy - 8), "\u25B2", font=font(22), fill=(15, 15, 15, 255), anchor="mm")
    d.text((cx, cy + 22), "3", font=font(18), fill=(15, 15, 15, 255), anchor="mm")
    d.text((x0 + 178, y1 - 66), "1000 L", font=font(30), fill=(15, 15, 15, 255), anchor="mm")
    d.text((x0 + 178, y1 - 32), "max 1000 kg", font=font(18), fill=(15, 15, 15, 255), anchor="mm")
    save_dds(img, dst, "DXT1")


def make_ibc_store_icon(src, dst):
    from PIL import Image, ImageDraw
    img = recolor_black(Image.open(src), True)
    d = ImageDraw.Draw(img)
    img.paste(img.crop((262, 405, 286, 442)), (233, 405))
    d.polygon([(190, 297), (300, 294), (300, 380), (190, 384)], fill=(240, 196, 24, 255), outline=(15, 15, 15, 255))
    d.text((245, 318), "DIESEL", font=font(25), fill=(15, 15, 15, 255), anchor="mm")
    d.text((245, 340), "UN 1202", font=font(13), fill=(15, 15, 15, 255), anchor="mm")
    cx, cy, s = 210, 364, 13
    d.polygon([(cx, cy - s), (cx + s, cy), (cx, cy + s), (cx - s, cy)], fill=(205, 30, 30, 255), outline=(15, 15, 15, 255))
    d.text((262, 364), "1000 L", font=font(14), fill=(15, 15, 15, 255), anchor="mm")
    save_dds(img, dst, "DXT5")


def make_ibc_i3d(src, dst):
    s = open(src, encoding="iso-8859-1").read()
    repl = [
        ('<i3D name="liquidTank"', '<i3D name="ibcDiesel"'),
        ('filename="$data/objects/pallets/liquidTank/fertilizerTank_diffuse.png"', 'filename="ibcDiesel_diffuse.png"'),
        ('name="fertilizerTank_mat"', 'name="ibcDiesel_mat"'),
        ('externalShapesFile="liquidTank.i3d.shapes"', 'externalShapesFile="ibcDiesel.i3d.shapes"'),
    ]
    for a, b in repl:
        if a not in s:
            sys.exit("liquidTank.i3d changed in this game version - cannot find: " + a)
        s = s.replace(a, b)
    open(dst, "w", encoding="iso-8859-1", newline="\n").write(s)


def game_assets(game):
    data = os.path.join(game, "data")
    tank = os.path.join(data, "objects", "pallets", "liquidTank")
    decal = os.path.join(data, "maps", "mapEU", "textures", "dirtGroundDecal.i3d.shapes")
    for p in (tank, decal):
        if not os.path.exists(p):
            sys.exit("Game files not found: %s\nUse --game to point at your Farming Simulator 25 folder." % p)
    ibc = os.path.join(ROOT, "objects", "ibcDiesel")
    shutil.copyfile(os.path.join(tank, "liquidTank.i3d.shapes"), os.path.join(ibc, "ibcDiesel.i3d.shapes"))
    make_ibc_i3d(os.path.join(tank, "liquidTank.i3d"), os.path.join(ibc, "ibcDiesel.i3d"))
    make_ibc_texture(os.path.join(tank, "fertilizerTank_diffuse.dds"), os.path.join(ibc, "ibcDiesel_diffuse.dds"))
    make_ibc_store_icon(os.path.join(tank, "store_fertilizerTank.dds"), os.path.join(ibc, "store_ibcDiesel.dds"))
    for folder in ("paints", "parkingLines"):
        shutil.copyfile(decal, os.path.join(ROOT, "objects", folder, "paintDecal.i3d.shapes"))
    print("game-derived assets created")


def build_zip(out):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(ROOT):
            rel_root = os.path.relpath(root, ROOT)
            if rel_root == ".":
                dirs[:] = [d for d in dirs if d not in EXCLUDE_TOP]
                files = [f for f in files if f not in EXCLUDE_TOP]
            for f in files:
                if f.endswith((".py", ".pyc", ".tmp", ".log")):
                    continue
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, ROOT).replace(os.sep, "/"))
                n += 1
    print("%s: %d files" % (out, n))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=DEFAULT_GAME, help="Farming Simulator 25 install folder")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", ZIP_NAME))
    ap.add_argument("--install", action="store_true", help="copy the zip into your FS25 mods folder")
    args = ap.parse_args()
    game_assets(args.game)
    build_zip(args.out)
    if args.install:
        mods = os.path.join(os.path.expanduser("~"), "Documents", "My Games", "FarmingSimulator2025", "mods")
        shutil.copyfile(args.out, os.path.join(mods, ZIP_NAME))
        print("installed to", mods)


if __name__ == "__main__":
    main()
