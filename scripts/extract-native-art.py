#!/usr/bin/env python3
"""Copies the classic page's doodle art (SVG data URLs in its CSS, and the inline logo) into design/native/*.svg,
so scripts/render-art.swift can turn them into images for the SwiftUI interface. Run it after changing that art."""
import re, urllib.parse, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
html = (root / "web/juice-tracker.html").read_text()
out = root / "design/native"
out.mkdir(parents=True, exist_ok=True)
colors = {"var(--lavender)": "#ff6ad5", "var(--new)": "#ffa04a", "var(--mist)": "#fff6fb", "var(--night)": "#0a0618", "var(--have)": "#c9f24a"}

def svg_after(selector, nth=0):
    """The nth SVG data URL in the CSS rule that starts with this selector."""
    i = html.index(selector)
    for _ in range(nth + 1):
        i = html.index('url("data:image/svg+xml,', i) + len('url("data:image/svg+xml,')
    return urllib.parse.unquote(html[i:html.index('")', i)])

art = {
    "planet": svg_after("  .scoreboard::before {"),
    "heart": svg_after("  .scoreboard::after {"),
    "flash": svg_after("  .sky-flash {"),
    "sparkles": svg_after("  .shell::before {"),
    "fly": svg_after("  .meter::after {"),
    "scribble": svg_after('  .rail-nav button[aria-current="page"] {'),
    "squiggle": svg_after("  .section-title {"),
    "check": svg_after("  .st.have::before {"),
}
for n in range(6):
    art[f"sticker{n + 1}"] = svg_after(f"  .era-card:nth-child(6n+{n + 1})::before {{")
logo = re.search(r'<a class="brand"[^>]*>\s*(<svg[\s\S]*?</svg>)', html).group(1)
for var, hex_ in colors.items():
    logo = logo.replace(var, hex_)
art["logo"] = re.sub(r'<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ', logo, count=1) if "xmlns" not in logo else logo

for name, svg in art.items():
    (out / f"{name}.svg").write_text(svg)
    print("wrote", f"design/native/{name}.svg", len(svg))
