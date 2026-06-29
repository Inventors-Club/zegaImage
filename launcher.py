#!/usr/bin/env python3
"""Zega launcher — a small pygame menu for the 320x240 SPI panel.

Reads ~/launcher.toml, groups entries by category, lets the user navigate
with the D-pad and launch the selected entry with the A button. Each entry's
`command` is exec'd via subprocess.run; pygame releases the display first
so the child (RetroArch, a pygame game, a shell command) can take over the
KMS connector, and re-claims it when the child exits.

Boot autolaunch: zega-launcher.service runs this on tty1 with
SDL_VIDEODRIVER=kmsdrm. Input arrives from the kernel gpio-keys overlay
(buttons.sh), which SDL reads through evdev. Required groups for the
runtime user: video, input, audio, render.
"""

import os
import sys
import time
import tomllib
import subprocess
from pathlib import Path

os.environ.setdefault("SDL_VIDEODRIVER", "kmsdrm")
import pygame  # noqa: E402

CONFIG = Path.home() / "launcher.toml"
WIDTH, HEIGHT = 320, 240
FPS = 30

# Palette.
BG = (12, 12, 18)
HEADER_BG = (24, 28, 40)
FG = (240, 240, 240)
DIM = (140, 140, 150)
ACCENT = (255, 130, 50)
HIGHLIGHT_BG = (52, 60, 84)
SEPARATOR_FG = (110, 115, 130)

# Layout.
HEADER_H = 20
FOOTER_H = 14
ROW_H = 16
PADDING = 6


def load_entries():
    if not CONFIG.exists():
        return [{
            "label": f"No {CONFIG.name} found",
            "category": "error",
            "command": ["true"],
        }]
    try:
        with CONFIG.open("rb") as f:
            return tomllib.load(f).get("entries", [])
    except Exception as e:
        return [{
            "label": f"toml error: {e}",
            "category": "error",
            "command": ["true"],
        }]


def build_rows(entries):
    """Sort entries by category, intersperse with header separators.

    Returns a list of (kind, payload) tuples where kind is "header" or
    "entry". Headers are non-selectable; entries are the dicts from TOML.
    """
    by_cat: dict[str, list[dict]] = {}
    order: list[str] = []
    for e in entries:
        cat = e.get("category") or ""
        if cat not in by_cat:
            order.append(cat)
            by_cat[cat] = []
        by_cat[cat].append(e)

    rows: list[tuple[str, object]] = []
    for cat in order:
        if cat:
            rows.append(("header", cat))
        for e in by_cat[cat]:
            rows.append(("entry", e))
    return rows


def first_selectable(rows, start, direction):
    """Walk from start in direction until landing on an entry row."""
    n = len(rows)
    if n == 0:
        return 0
    i = start % n
    for _ in range(n):
        if rows[i][0] == "entry":
            return i
        i = (i + direction) % n
    return start


def next_selectable(rows, current, direction):
    n = len(rows)
    if n == 0:
        return 0
    i = current
    for _ in range(n):
        i = (i + direction) % n
        if rows[i][0] == "entry":
            return i
    return current


def render(screen, fonts, rows, selected, scroll):
    screen.fill(BG)

    # Header bar.
    pygame.draw.rect(screen, HEADER_BG, (0, 0, WIDTH, HEADER_H))
    title = fonts["title"].render("ZEGA", True, ACCENT)
    screen.blit(title, (PADDING, 3))
    clk = fonts["title"].render(time.strftime("%H:%M"), True, FG)
    screen.blit(clk, (WIDTH - clk.get_width() - PADDING, 3))

    # List area.
    list_y = HEADER_H + 3
    list_h = HEIGHT - HEADER_H - FOOTER_H - 6
    visible = list_h // ROW_H

    start = scroll
    end = min(start + visible, len(rows))

    y = list_y
    for i in range(start, end):
        kind, payload = rows[i]
        if i == selected:
            pygame.draw.rect(
                screen, HIGHLIGHT_BG,
                (PADDING - 4, y - 1, WIDTH - 2 * (PADDING - 4), ROW_H),
            )
        if kind == "header":
            text = f"── {payload} ──"
            label = fonts["small"].render(text, True, SEPARATOR_FG)
            screen.blit(label, (PADDING + 2, y + 1))
        else:
            entry = payload
            label = fonts["body"].render(entry["label"], True, FG)
            screen.blit(label, (PADDING + 2, y))
            cat = entry.get("category", "")
            if cat:
                cat_label = fonts["small"].render(f"[{cat}]", True, DIM)
                screen.blit(
                    cat_label,
                    (WIDTH - cat_label.get_width() - PADDING, y + 2),
                )
        y += ROW_H

    # Footer hint.
    pygame.draw.rect(screen, HEADER_BG, (0, HEIGHT - FOOTER_H, WIDTH, FOOTER_H))
    hint = fonts["small"].render(
        "UP/DN  A=launch  B=back  SEL=menu", True, DIM,
    )
    screen.blit(hint, (PADDING, HEIGHT - FOOTER_H + 2))


def launch(entry):
    """Release the display, exec the child, re-init on return."""
    print(f"[launcher] running: {entry['label']}", flush=True)
    pygame.display.quit()
    pygame.quit()
    try:
        subprocess.run(entry["command"], check=False)
    except FileNotFoundError as e:
        print(f"[launcher] command not found: {e}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[launcher] launch error: {e}", flush=True)
    pygame.init()
    pygame.mouse.set_visible(False)
    return pygame.display.set_mode((WIDTH, HEIGHT))


def main():
    pygame.init()
    pygame.mouse.set_visible(False)
    screen = pygame.display.set_mode((WIDTH, HEIGHT))
    pygame.display.set_caption("zega launcher")

    fonts = {
        "title": pygame.font.SysFont("monospace", 12, bold=True),
        "body":  pygame.font.SysFont("monospace", 12),
        "small": pygame.font.SysFont("monospace", 10),
    }

    rows = build_rows(load_entries())
    selected = first_selectable(rows, 0, 1)
    scroll = 0

    clock = pygame.time.Clock()
    running = True
    while running:
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                running = False
            elif ev.type == pygame.KEYDOWN:
                if ev.key == pygame.K_UP:
                    selected = next_selectable(rows, selected, -1)
                elif ev.key == pygame.K_DOWN:
                    selected = next_selectable(rows, selected, 1)
                elif ev.key == pygame.K_x:                          # A button
                    if rows and rows[selected][0] == "entry":
                        screen = launch(rows[selected][1])
                        rows = build_rows(load_entries())
                        selected = first_selectable(rows, selected, 1)
                        scroll = 0
                elif ev.key == pygame.K_z:                          # B button
                    pass
                elif ev.key == pygame.K_ESCAPE:
                    running = False

        # Keep the selected row in view.
        list_h = HEIGHT - HEADER_H - FOOTER_H - 6
        visible = list_h // ROW_H
        if selected < scroll:
            scroll = selected
        elif selected >= scroll + visible:
            scroll = selected - visible + 1

        render(screen, fonts, rows, selected, scroll)
        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit(0)


if __name__ == "__main__":
    main()
