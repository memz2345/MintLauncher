#!/usr/bin/env python3
"""生成下载页分组用的方块图标（16x16 像素画 → 32x32 PNG，最近邻放大）。

正式版 grass 用现成的 HMCL 图标；这里补齐快照（命令方块）和远古版
（原石）。纯 stdlib（zlib/struct），直接产出 RGBA PNG。
"""

import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "icons"

SCALE = 2  # 16 -> 32


def png_write(path: Path, grid, palette):
    h = len(grid)
    w = len(grid[0])
    assert all(len(row) == w for row in grid), f"{path.name}: 行宽不齐"
    raw = b""
    for y in range(h):
        row = grid[y]
        line = bytearray()
        line.append(0)  # filter: none
        for x in range(w):
            for _ in range(SCALE):
                line += palette[row[x]]
        for _ in range(SCALE):
            raw += bytes(line)
    W, H = w * SCALE, h * SCALE

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)
    print(f"{path.relative_to(OUT.parent.parent)}: {W}x{H}")


def rgba(hexcolor):
    return bytes(
        [(hexcolor >> 16) & 0xFF, (hexcolor >> 8) & 0xFF, hexcolor & 0xFF, 0xFF]
    )


# ── 命令方块（快照）：灰色机身 + 深色边框 + 中央暗色面板 ──
CMD = [
    "BBBBBBBBBBBBBBBB",
    "BggmdggggggdmggB",
    "BggggggggggggggB",
    "BgdggggggggggdgB",
    "BggggccccccggggB",
    "BggggccccccggggB",
    "BggggccmmccggggB",
    "BggggcmllmcggggB",
    "BggggcmllmcggggB",
    "BggggccmmccggggB",
    "BggggccccccggggB",
    "BggggggggggggggB",
    "BgdggggggggggdgB",
    "BggmdggggggdmggB",
    "BggggggggggggggB",
    "BBBBBBBBBBBBBBBB",
]
CMD_PALETTE = {
    "B": rgba(0x333336),  # 深色边框
    "g": rgba(0x9D9DA0),  # 机身浅灰
    "d": rgba(0x77777A),  # 铆钉
    "m": rgba(0x8A8A8D),  # 面板内框
    "c": rgba(0x4F4F53),  # 中央暗面板
    "l": rgba(0xC9C9CC),  # 高光
}

# ── 原石（远古版）：不规则石块 + 深色缝隙 ──
COBBLE = [
    "tssvvuuuvvsssvvt",
    "tssvuwvuuvsssUut",
    "ssvvuwwuuvussuuu",
    "vvvuUuuvvvvUuvvv",
    "ssUvvvsssvvssvvu",
    "sssvsttsvssssvuu",
    "ussvsttsvvswwsvu",
    "uuvvsssvvuvwswvu",
    "suuvssvuuvvssvuu",
    "ssUvvsssvssvuUvu",
    "sssvssUUvsuUvvuv",
    "vvvvUUuvvsUuvvvu",
    "ussuuuvvsssvsuvv",
    "usssvvsttsvssuuu",
    "uusvssvttSvsSuuv",
    "vvvvvvvvvvvvvvvv",
]
COBBLE_PALETTE = {
    "t": rgba(0x96969B),  # 亮石
    "s": rgba(0x838388),  # 主灰
    "u": rgba(0x6C6C70),  # 中灰
    "v": rgba(0x545457),  # 深缝
    "w": rgba(0xA6A6AB),  # 高光
}

# 修正上面手写行里的笔误（大写字母 → 同色小写），保持行宽 16。
COBBLE = [row.replace("U", "u").replace("V", "v").replace("S", "s") for row in COBBLE]

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    png_write(OUT / "command_block.png", CMD, CMD_PALETTE)
    png_write(OUT / "cobblestone.png", COBBLE, COBBLE_PALETTE)
