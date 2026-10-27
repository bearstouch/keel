#!/usr/bin/env python3
"""Generate the design-token fixture (Tests/Fixtures/Design/tokens.json) from docs/design/index.md.

The page is the design contract (DS-06); `ThemeTokensTests` compares `KeelTheme` with this fixture, so a value
changed on one side only fails the tests. Run it after editing the Color tables:

    python3 -I scripts/generate-design-tokens.py           # rewrite the fixture
    python3 -I scripts/generate-design-tokens.py --check   # exit 1 when the fixture is stale

Each table row names its code tokens in backticks; "`a` / `b`" with one value gives both names that value, with as
many values as names it pairs them in order. Colors are "#RRGGBB" (uppercase) or "rgba(r,g,b,a)".
"""

import argparse
import json
import os
import re
import sys

FORMAT_VERSION = 1
ROOT = os.path.join(os.path.dirname(__file__), "..")
PAGE = os.path.join(ROOT, "docs", "design", "index.md")
OUTPUT = os.path.join(ROOT, "Tests", "Fixtures", "Design", "tokens.json")

COLOR = re.compile(r"#[0-9A-Fa-f]{6}\b|rgba\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*[0-9.]+\s*\)")
NAME = re.compile(r"`([A-Za-z][A-Za-z0-9]*)`")


def normalize(color):
    if color.startswith("#"):
        return color.upper()
    return "rgba(" + ",".join(part.strip() for part in color[5:-1].split(",")) + ")"


def sections(text):
    """Maps each `### Heading` to the data rows (lists of cells) of the tables under it."""
    result, current = {}, None
    for line in text.splitlines():
        if line.startswith("### "):
            current = line[4:].strip()
            result[current] = []
        elif current and line.startswith("|") and not re.match(r"^\|\s*-", line):
            result[current].append([cell.strip() for cell in line.strip().strip("|").split("|")])
    # The first row of every table is its header.
    return {name: [row for row in rows if row[0] not in ("Token", "Badge", "Syntax", "Label", "Pair")] for name, rows in result.items()}


def names_and_colors(name_cell, value_cell):
    names, colors = NAME.findall(name_cell), [normalize(c) for c in COLOR.findall(value_cell)]
    if not names or not colors:
        raise SystemExit(f"unreadable row: {name_cell} | {value_cell}")
    if len(colors) == 1:
        return {name: colors[0] for name in names}
    if len(colors) != len(names):
        raise SystemExit(f"{len(names)} names but {len(colors)} values: {name_cell} | {value_cell}")
    return dict(zip(names, colors))


def palette(rows):
    tokens = {}
    for row in rows:
        for name, color in names_and_colors(row[0], row[1]).items():
            if name in tokens:
                raise SystemExit(f"token {name} listed twice")
            tokens[name] = color
    return tokens


def two_themes(rows, key=lambda cell: NAME.findall(cell)[0]):
    """Rows of `name | light | dark`: each name's value in both themes."""
    result = {}
    for row in rows:
        light, dark = COLOR.findall(row[1]), COLOR.findall(row[2])
        result[key(row[0])] = {"light": normalize(light[0]), "dark": normalize(dark[0])}
    return result


def badge_side(cell):
    colors = [normalize(c) for c in COLOR.findall(cell)]
    if len(colors) == 2:
        return {"text": colors[0], "fill": colors[1]}
    # OTHER: references to palette tokens ("`muted` / `soft`").
    text, fill = NAME.findall(cell)
    return {"text": text, "fill": fill}


def build(text):
    tables = {heading.split(" (")[0]: rows for heading, rows in sections(text).items()}
    overrides = two_themes(tables["Increase Contrast"])
    contrast = {side: {name: values[side] for name, values in overrides.items()} for side in ("light", "dark")}
    badges, syntax, labels = {}, {}, {}
    for row in tables["Type badges and labels"]:
        if row[0].isupper():
            badges[row[0]] = {"light": badge_side(row[1]), "dark": badge_side(row[2])}
        elif row[0].startswith("`json"):
            syntax.update(two_themes([row]))
        else:
            labels.update(two_themes([row]))
    return {
        "version": FORMAT_VERSION,
        "generatedFrom": "docs/design/index.md",
        "light": palette(tables["Light"]),
        "dark": palette(tables["Dark"]),
        "increaseContrast": contrast,
        "console": palette(tables["Console"]),
        "badges": badges,
        "syntax": syntax,
        "labels": labels,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--page", default=PAGE)
    parser.add_argument("--output", default=OUTPUT)
    parser.add_argument("--check", action="store_true", help="fail when the fixture differs from the page")
    args = parser.parse_args()

    with open(args.page, encoding="utf-8") as handle:
        rendered = json.dumps(build(handle.read()), indent=2, sort_keys=True) + "\n"
    if args.check:
        try:
            with open(args.output, encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            current = ""
        if current != rendered:
            print(f"{args.output} is stale: run scripts/generate-design-tokens.py", file=sys.stderr)
            return 1
        return 0
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
