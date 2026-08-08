#!/usr/bin/env python3
"""Generate every Violeeter export from `violeeter.json`.

# Why a generator

A palette is thirty-six hex values times one file per terminal. Copied by hand,
the copies drift — and a palette that is *almost* the same in two terminals is
worse than two different palettes, because the difference reads as a rendering
bug rather than as a choice. `violeeter.json` is the only file anyone edits.

Usage:
    python3 build.py            # write dist/
    python3 build.py --check    # verify contrast, exit non-zero on failure
"""

from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).parent
SOURCE = ROOT / "violeeter.json"
DIST = ROOT / "dist"

ORDER = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow",
    "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
]

# The two ANSI slots that are surfaces rather than text, and only in a light
# variant. `white` and `brightWhite` mean "the palest thing here"; on a pale
# background they are what you fill with, not what you write with. Holding them
# to a text ratio would mean darkening white until it stopped being white.
LIGHT_FILLS = {"white", "brightWhite"}


def rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _channel(c: int) -> float:
    v = c / 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def luminance(h: str) -> float:
    r, g, b = rgb(h)
    return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b)


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

def iterm(v: dict) -> str:
    """iTerm2 wants floats per channel, and its own key names."""
    def component(h: str, key: str) -> str:
        r, g, b = rgb(h)
        return (
            f"\t<key>{key}</key>\n\t<dict>\n"
            f"\t\t<key>Color Space</key>\n\t\t<string>sRGB</string>\n"
            f"\t\t<key>Red Component</key>\n\t\t<real>{r / 255:.6f}</real>\n"
            f"\t\t<key>Green Component</key>\n\t\t<real>{g / 255:.6f}</real>\n"
            f"\t\t<key>Blue Component</key>\n\t\t<real>{b / 255:.6f}</real>\n"
            f"\t\t<key>Alpha Component</key>\n\t\t<real>1</real>\n\t</dict>\n"
        )

    body = "".join(
        component(v["ansi"][name], f"Ansi {i} Color")
        for i, name in enumerate(ORDER)
    )
    body += component(v["background"], "Background Color")
    body += component(v["foreground"], "Foreground Color")
    body += component(v["cursor"], "Cursor Color")
    body += component(v["background"], "Cursor Text Color")
    body += component(v["selection"], "Selection Color")
    body += component(v["foreground"], "Selected Text Color")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n<dict>\n' + body + "</dict>\n</plist>\n"
    )


def alacritty(v: dict) -> str:
    a = v["ansi"]
    return f"""# {v['name']} — https://github.com/grippado/violeet
[colors.primary]
background = "{v['background']}"
foreground = "{v['foreground']}"

[colors.cursor]
cursor = "{v['cursor']}"
text = "{v['background']}"

[colors.selection]
background = "{v['selection']}"
text = "{v['foreground']}"

[colors.normal]
black = "{a['black']}"
red = "{a['red']}"
green = "{a['green']}"
yellow = "{a['yellow']}"
blue = "{a['blue']}"
magenta = "{a['magenta']}"
cyan = "{a['cyan']}"
white = "{a['white']}"

[colors.bright]
black = "{a['brightBlack']}"
red = "{a['brightRed']}"
green = "{a['brightGreen']}"
yellow = "{a['brightYellow']}"
blue = "{a['brightBlue']}"
magenta = "{a['brightMagenta']}"
cyan = "{a['brightCyan']}"
white = "{a['brightWhite']}"
"""


def kitty(v: dict) -> str:
    a = v["ansi"]
    lines = [
        f"# {v['name']} — https://github.com/grippado/violeet",
        f"background {v['background']}",
        f"foreground {v['foreground']}",
        f"cursor {v['cursor']}",
        f"cursor_text_color {v['background']}",
        f"selection_background {v['selection']}",
        f"selection_foreground {v['foreground']}",
    ]
    lines += [f"color{i} {a[name]}" for i, name in enumerate(ORDER)]
    return "\n".join(lines) + "\n"


def ghostty(v: dict) -> str:
    a = v["ansi"]
    lines = [
        f"# {v['name']} — https://github.com/grippado/violeet",
        f"background = {v['background'].lstrip('#')}",
        f"foreground = {v['foreground'].lstrip('#')}",
        f"cursor-color = {v['cursor'].lstrip('#')}",
        f"selection-background = {v['selection'].lstrip('#')}",
        f"selection-foreground = {v['foreground'].lstrip('#')}",
    ]
    lines += [f"palette = {i}={a[name]}" for i, name in enumerate(ORDER)]
    return "\n".join(lines) + "\n"


def windows_terminal(v: dict) -> str:
    a = v["ansi"]
    scheme = {
        "name": v["name"],
        "background": v["background"],
        "foreground": v["foreground"],
        "cursorColor": v["cursor"],
        "selectionBackground": v["selection"],
        "black": a["black"], "red": a["red"], "green": a["green"],
        "yellow": a["yellow"], "blue": a["blue"], "purple": a["magenta"],
        "cyan": a["cyan"], "white": a["white"],
        "brightBlack": a["brightBlack"], "brightRed": a["brightRed"],
        "brightGreen": a["brightGreen"], "brightYellow": a["brightYellow"],
        "brightBlue": a["brightBlue"], "brightPurple": a["brightMagenta"],
        "brightCyan": a["brightCyan"], "brightWhite": a["brightWhite"],
    }
    return json.dumps(scheme, indent=2) + "\n"


def css(data: dict) -> str:
    """Both variants as custom properties, dark by default and light by query.

    This is what the project page renders itself with, so the page cannot drift
    from the palette it is advertising.
    """
    def block(v: dict, indent: str = "  ") -> str:
        a = v["ansi"]
        rows = [
            f"{indent}--violeeter-bg: {v['background']};",
            f"{indent}--violeeter-fg: {v['foreground']};",
            f"{indent}--violeeter-cursor: {v['cursor']};",
            f"{indent}--violeeter-selection: {v['selection']};",
        ]
        rows += [f"{indent}--violeeter-{name.lower()}: {a[name]};" for name in ORDER]
        return "\n".join(rows)

    dark, light = data["variants"]["dark"], data["variants"]["light"]
    return f"""/* Violeeter {data['version']} — https://github.com/grippado/violeet
   Generated by theme/build.py. Do not edit. */
:root {{
{block(light)}
}}

@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
{block(dark, "    ")}
  }}
}}

:root[data-theme="dark"] {{
{block(dark)}
}}
"""


EXPORTS = {
    "itermcolors": iterm,
    "toml": alacritty,
    "conf": kitty,
    "ghostty": ghostty,
    "json": windows_terminal,
}


def check(data: dict) -> int:
    """Every colour used as text must clear WCAG AA against its background."""
    failures = 0
    for key, v in data["variants"].items():
        bg = v["background"]
        fills = LIGHT_FILLS if v["appearance"] == "light" else {"black"}
        worst, worst_name = 99.0, ""
        print(f"\n{v['name']}  (background {bg})")
        for name in ["foreground", "cursor"] + ORDER:
            colour = v[name] if name in v else v["ansi"][name]
            ratio = contrast(colour, bg)
            if name in fills:
                print(f"  {name:14} {colour}  {ratio:5.2f}  surface")
                continue
            ok = ratio >= 4.5
            if ratio < worst:
                worst, worst_name = ratio, name
            if not ok:
                failures += 1
            print(f"  {name:14} {colour}  {ratio:5.2f}  {'ok' if ok else 'FAIL — under AA 4.5'}")
        print(f"  worst text contrast: {worst:.2f} ({worst_name})")
    return failures


def main() -> int:
    data = json.loads(SOURCE.read_text())

    if "--check" in sys.argv:
        failures = check(data)
        print(f"\n{'PASS' if failures == 0 else f'{failures} FAILURES'}")
        return 1 if failures else 0

    DIST.mkdir(exist_ok=True)
    for key, v in data["variants"].items():
        for ext, render in EXPORTS.items():
            (DIST / f"violeeter-{key}.{ext}").write_text(render(v))
    stylesheet = css(data)
    (DIST / "violeeter.css").write_text(stylesheet)
    written = sorted(p.name for p in DIST.iterdir())
    print(f"wrote {len(written)} files to {DIST}/")
    for name in written:
        print(f"  {name}")

    # The project page is served from `docs/`, which cannot reach up into
    # `theme/`. Writing the stylesheet there too is what stops the page that
    # advertises this palette from being painted in a stale copy of it.
    page = ROOT.parent / "docs"
    if page.is_dir():
        (page / "violeeter.css").write_text(stylesheet)
        # The palette itself, so the page can draw its swatches from the source
        # rather than from its own stylesheet. Reading them back out of CSS
        # meant asking the browser to recompute `:root` mid-script, which it
        # does not reliably do — the two variants came out identical.
        (page / "violeeter.json").write_text(SOURCE.read_text())
        print(f"wrote {page}/violeeter.css and violeeter.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
