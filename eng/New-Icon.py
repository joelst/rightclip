from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent
assets = root / "assets"
assets.mkdir(exist_ok=True)
scale = 4
size = 256 * scale
image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
gradient = Image.new("RGBA", (size, size))
pixels = gradient.load()
start = (23, 59, 87)
end = (12, 113, 117)
for y in range(size):
    for x in range(size):
        amount = (x + y) / (2 * (size - 1))
        pixels[x, y] = tuple(round(a + (b - a) * amount) for a, b in zip(start, end)) + (255,)
mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle((4 * scale, 4 * scale, 252 * scale, 252 * scale), radius=56 * scale, fill=255)
image.paste(gradient, (0, 0), mask)
draw = ImageDraw.Draw(image, "RGBA")
draw.line((53 * scale, 53 * scale, 53 * scale, 203 * scale), fill=(112, 238, 204, 255), width=13 * scale)
draw.line((203 * scale, 53 * scale, 203 * scale, 203 * scale), fill=(255, 255, 255, 87), width=9 * scale)
for y in (77, 110, 143, 176):
    draw.line((52 * scale, y * scale, 70 * scale, y * scale), fill=(23, 59, 87, 255), width=7 * scale)
draw.polygon([(84 * scale, 76 * scale), (84 * scale, 180 * scale), (184 * scale, 128 * scale)], fill=(255, 255, 255, 255))
image = image.resize((256, 256), Image.Resampling.LANCZOS)
image.save(assets / "RightClip.png", optimize=True)
image.resize((150, 150), Image.Resampling.LANCZOS).save(assets / "Square150x150Logo.png", optimize=True)
image.resize((44, 44), Image.Resampling.LANCZOS).save(assets / "Square44x44Logo.png", optimize=True)
image.save(assets / "RightClip.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (256, 256)])
print(assets / "RightClip.ico")
