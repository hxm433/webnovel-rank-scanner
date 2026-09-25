#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
网文扫榜工具 —— 程序图标生成器（唯一真源）

跑一次会重出全套图标：

    python tool/make_icon.py

产物：
    assets/icon/app.png        512×512 主图（README / 网页用）
    assets/icon/app-{16..256}.png   各尺寸 PNG（网页 / 文档用）
    assets/icon/app.ico        Windows 图标（16/24/32/48/64/128/256，exe 用）

设计说明（与 lib/ui/theme.dart 的配色对齐）：
  · 底板：圆角方块（Win11 / macOS 风），对角渐变 取自主题主色
        深色主题 accent = rgb(88,196,250)   浅色主题 accent = rgb(11,127,212)
  · 图形：三根递增柱（榜单） + 一条带箭头的折线（趋势），
        4 倍超采样后 LANCZOS 降采样，16px 下柱子与箭头仍然分得开。
"""

import os
import math

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

# ---------------------------------------------------------------- 参数
SS = 4                 # 超采样倍数
S = 512                # 目标尺寸
N = S * SS             # 实际绘制尺寸

RADIUS = 116           # 圆角（512 坐标系）
BAR_W = 66             # 柱宽
BAR_GAP = 34           # 柱间距
BASELINE = 396         # 柱子底线 y
BAR_H = (112, 178, 250)  # 三根柱子高度
BAR_ALPHA = (0.46, 0.58, 0.72)  # 柱子透明度（压在折线后面，16px 下也要看得见）

LINE_PTS = [(140, 334), (216, 256), (272, 294), (380, 166)]  # 趋势折线
LINE_W = 34           # 折线线宽
HEAD_LEN = 72         # 箭头两翼长度
HEAD_DEG = 40         # 箭头张角（半角）

C_TL = np.array([92, 200, 250], dtype=np.float64)    # 左上：主题亮色
C_BR = np.array([10, 92, 176], dtype=np.float64)     # 右下：主题深色

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "icon")
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
PNG_SIZES = [16, 32, 48, 64, 128, 256, 512]


# ---------------------------------------------------------------- 背景
def make_background():
    """对角渐变 + 左上柔光 + 右下暗角，再切成圆角方块。"""
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)

    t = (xx / (N - 1) + yy / (N - 1)) / 2.0
    t = t * t * (3 - 2 * t)                       # smoothstep，避免生硬
    grad = C_TL[None, None, :] * (1 - t)[..., None] + C_BR[None, None, :] * t[..., None]

    # 左上柔光（玻璃感高光）
    d1 = np.sqrt((xx - 0.26 * N) ** 2 + (yy - 0.18 * N) ** 2) / (0.78 * N)
    grad += (np.clip(1 - d1, 0, 1) ** 2 * 0.22)[..., None] * 255.0

    # 右下暗角（把视线压回中心）
    d2 = np.sqrt((xx - 1.04 * N) ** 2 + (yy - 1.06 * N) ** 2) / (1.05 * N)
    grad -= (np.clip(1 - d2, 0, 1) ** 2 * 0.20)[..., None] * np.array([0.0, 26.0, 60.0])

    rgb = np.clip(grad, 0, 255).astype(np.uint8)

    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, N - 1, N - 1], radius=RADIUS * SS, fill=255
    )

    base = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    base.paste(Image.fromarray(rgb, "RGB"), (0, 0), mask)

    # 顶部 1px 内描边，亮一点，让边缘"立"起来
    edge = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.rounded_rectangle([2, 2, N - 3, N - 3], radius=(RADIUS - 1) * SS,
                         outline=(255, 255, 255, 46), width=2)
    base = Image.alpha_composite(base, edge)
    return base


# ---------------------------------------------------------------- 图形
def make_glyph():
    """三根递增柱 + 带箭头的趋势折线，画在透明层上。"""
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    total = BAR_W * 3 + BAR_GAP * 2
    x0 = (S - total) / 2.0
    for i, (h, a) in enumerate(zip(BAR_H, BAR_ALPHA)):
        left = (x0 + i * (BAR_W + BAR_GAP)) * SS
        top = (BASELINE - h) * SS
        right = (left + BAR_W * SS)
        bottom = BASELINE * SS
        d.rounded_rectangle([left, top, right, bottom],
                            radius=(BAR_W / 2.0) * SS,
                            fill=(255, 255, 255, int(255 * a)))

    pts = [(x * SS, y * SS) for x, y in LINE_PTS]
    d.line(pts, fill=(255, 255, 255, 255), width=LINE_W * SS, joint="curve")
    # 圆头端点（Pillow 的 line 默认是平头）
    r = (LINE_W / 2.0) * SS
    for (cx, cy) in (pts[0], pts[-1]):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 255))

    # 箭头：沿最后一段方向，两翼各偏 ±HEAD_DEG
    (x1, y1), (x2, y2) = LINE_PTS[-2], LINE_PTS[-1]
    ang = math.atan2(y2 - y1, x2 - x1)
    for sign in (+1, -1):
        a = ang + math.pi + sign * math.radians(HEAD_DEG)
        ex = (x2 + HEAD_LEN * math.cos(a)) * SS
        ey = (y2 + HEAD_LEN * math.sin(a)) * SS
        d.line([(x2 * SS, y2 * SS), (ex, ey)],
               fill=(255, 255, 255, 255), width=LINE_W * SS)
        d.ellipse([ex - r, ey - r, ex + r, ey + r], fill=(255, 255, 255, 255))
    return layer


def build():
    base = make_background()
    glyph = make_glyph()

    # 投影：图形 alpha 模糊后整体下移，再裁进底板轮廓（免得溢出圆角）
    blurred = glyph.getchannel("A").filter(ImageFilter.GaussianBlur(24 * SS))
    shifted = Image.new("L", (N, N), 0)
    shifted.paste(blurred, (0, 14 * SS))
    shifted = ImageChops.multiply(shifted, base.getchannel("A"))

    shadow = Image.new("RGBA", (N, N), (3, 24, 44, 255))
    shadow.putalpha(shifted.point(lambda v: int(v * 0.42)))

    composed = Image.alpha_composite(base, shadow)
    composed = Image.alpha_composite(composed, glyph)
    return composed


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    master = build()

    big = master.resize((S, S), Image.LANCZOS)
    big.save(os.path.join(OUT_DIR, "app.png"))

    for n in PNG_SIZES:
        if n == S:
            continue
        big.resize((n, n), Image.LANCZOS).save(os.path.join(OUT_DIR, "app-%d.png" % n))

    big.save(os.path.join(OUT_DIR, "app.ico"), sizes=ICO_SIZES)

    print("OK ->", OUT_DIR)
    for f in sorted(os.listdir(OUT_DIR)):
        print("   ", f, os.path.getsize(os.path.join(OUT_DIR, f)), "bytes")


if __name__ == "__main__":
    main()
