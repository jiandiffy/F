#!/usr/bin/env python3
"""生成 F 的应用图标：白色圆角方块 + 涂鸦感黑色 F。"""
import math
import os
import random
import subprocess
from PIL import Image, ImageDraw

SIZE = 1024
random.seed(7)


def catmull_rom(points, samples=24):
    """把控制点插值成平滑曲线。"""
    pts = [points[0]] + list(points) + [points[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(samples):
            t = s / samples
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t +
                       (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 +
                       (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t +
                       (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 +
                       (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    return out


def jitter(points, amount):
    return [(x + random.uniform(-amount, amount), y + random.uniform(-amount, amount))
            for x, y in points]


def draw_stroke(draw, points, width, alpha):
    draw.line(points, fill=(0, 0, 0, alpha), width=width, joint="curve")
    r = width // 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(0, 0, 0, alpha))


# --- 白色圆角底板 ---
canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
board = ImageDraw.Draw(canvas)
radius = int(SIZE * 0.2237)
board.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=radius, fill=(255, 255, 255, 255))
board.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=radius,
                        outline=(232, 232, 236, 255), width=3)

# --- 涂鸦 F ---
layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)

stem = catmull_rom([(432, 246), (424, 400), (414, 560), (408, 700), (404, 796)])
top_bar = catmull_rom([(410, 262), (500, 254), (600, 250), (696, 246)])
mid_bar = catmull_rom([(412, 516), (490, 512), (560, 508), (628, 505)])

strokes = [(stem, 72), (top_bar, 64), (mid_bar, 60)]
for points, width in strokes:
    draw_stroke(d, points, width, 255)

# 轻微的手绘抖动叠层（纯黑，不影响颜色）
for points, width in strokes:
    draw_stroke(d, jitter(points, 2.0), width - 6, 255)

layer = layer.rotate(-3, resample=Image.BICUBIC, center=(SIZE / 2, SIZE / 2))
canvas.alpha_composite(layer)

os.makedirs("F.iconset", exist_ok=True)
sizes = [16, 32, 64, 128, 256, 512, 1024]
canvas.save("Resources/F-1024.png")
for s in sizes:
    img = canvas.resize((s, s), Image.LANCZOS)
    if s in (16, 32, 128, 256, 512):
        img.save(f"F.iconset/icon_{s}x{s}.png")
    if s >= 32:
        img.save(f"F.iconset/icon_{s // 2}x{s // 2}@2x.png")

subprocess.run(["iconutil", "-c", "icns", "F.iconset", "-o", "Resources/F.icns"], check=True)
print("wrote Resources/F.icns")
