#!/usr/bin/env bash
# Generates every Keel app icon asset from the one source, release/icon/keel-icon.svg (DS-07 – DS-10, KEEL-051).
#
#   scripts/generate-app-icon.sh                 # rewrite the committed assets under release/icon/
#   scripts/generate-app-icon.sh --check         # exit 1 when the committed assets differ from a fresh render
#   scripts/generate-app-icon.sh --compile DIR   # packaging: DIR/Assets.car and DIR/AppIcon.icns (Contents/Resources)
#
# Rendering needs rsvg-convert (`brew install librsvg`) and iconutil. --compile needs only Xcode 26 (`xcrun actool`), so
# package-release.sh and the tests can run it without librsvg.
#
# Outputs (all under release/icon/):
#   AppIcon.iconset/, AppIcon.icns   Default appearance at 16–512 pt @1x/@2x; 48 px and below use the small form (DS-08).
#   AppIcon.icon/                    Icon Composer bundle: the mark as a layer over the plate gradient, with Dark and
#                                    Tinted fills (DS-09); actool compiles it into Assets.car for macOS 26 appearances.
#   export/keel-icon-<look>[-small].svg, export/<look>/keel-icon-<px>.png
#                                    Dark, Tinted and Light (DMG, website, documents) flattened at the DS-10 sizes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="$ROOT/release/icon"
SOURCE="$ICON/keel-icon.svg"
SIZES="16 32 64 128 256 512 1024"
# The small form takes over at this size and below (DS-08).
SMALL_MAX=48
# The generated paths, relative to release/icon (the source and anything else there are left alone).
OUTPUTS="AppIcon.iconset AppIcon.icns AppIcon.icon export"

die() { echo "generate-app-icon: $*" >&2; exit 1; }

# The palette block for one look, from docs/design/icon/Icon.dc.html: bgTop bgBottom shine edgeColor edgeOpacity
# markTop markBottom shadow shadowOpacity.
palette_values() {
    case "$1" in
    default) echo "#EA4A3E #B3271E 0.22 #000000 0.08 #FFFFFF #FCE7E4 #5E120D 0.28" ;;
    dark) echo "#3A3A3C #161617 0.10 #FFFFFF 0.08 #FF7A6C #E0392C #000000 0.45" ;;
    tinted) echo "#2E2E30 #1A1A1B 0.08 #FFFFFF 0.08 #F2F2F4 #C9C9CE #000000 0.4" ;;
    light) echo "#FFFFFF #F3EDEC 0 #000000 0.10 #DC382D #B3271E #7A1A14 0.14" ;;
    *) die "unknown look $1" ;;
    esac
}

palette_css() {
    # shellcheck disable=SC2046
    set -- $(palette_values "$1")
    printf '    .bg-top { stop-color: %s } .bg-bottom { stop-color: %s }\n' "$1" "$2"
    printf '    .shine-top { stop-color: #FFFFFF; stop-opacity: %s } .shine-bottom { stop-color: #FFFFFF; stop-opacity: 0 }\n' "$3"
    printf '    .edge { stroke: %s; stroke-opacity: %s }\n' "$4" "$5"
    printf '    .mark-top { stop-color: %s } .mark-bottom { stop-color: %s }\n' "$6" "$7"
    printf '    .shadow { fill: %s; opacity: %s }\n' "$8" "$9"
}

# full: the mark above 48 px; small: the two-bar form; layer: the full mark alone (no plate, no shadow) for Icon Composer,
# which draws the plate from icon.json and adds its own shadow.
form_css() {
    case "$1" in
    full) echo '    #small { display: none }' ;;
    small) echo '    #full { display: none }' ;;
    layer) echo '    #small, #plate, #shadow { display: none }' ;;
    *) die "unknown form $1" ;;
    esac
}

# Writes the source with the palette and form blocks replaced: variant LOOK FORM OUT.
variant() {
    local palette form marker
    palette="$(palette_css "$1")"; form="$(form_css "$2")"
    # Through the environment: BSD awk refuses newlines in -v values.
    PALETTE="$palette" FORM="$form" awk '
        /\/\* palette:begin \*\// { print; print ENVIRON["PALETTE"]; skip = 1; next }
        /\/\* palette:end \*\// { skip = 0 }
        /\/\* form:begin \*\// { print; print ENVIRON["FORM"]; skip = 1; next }
        /\/\* form:end \*\// { skip = 0 }
        !skip { print }
    ' "$SOURCE" >"$3"
    # A marker that went missing would silently render the committed palette or both forms at once.
    for marker in palette:begin palette:end form:begin form:end; do grep -q "$marker" "$3" || die "$SOURCE lost its $marker marker"; done
}

# Renders LOOK at PX pixels to OUT.png, choosing the form by size.
render_png() {
    local form=full
    [ "$2" -le "$SMALL_MAX" ] && form=small
    variant "$1" "$form" "$WORK/src.svg"
    rsvg-convert -w "$2" -h "$2" "$WORK/src.svg" -o "$3"
}

# Flattens LOOK in FORM to a CSS-free SVG (CoreSVG, browsers and Icon Composer all read it the same way).
render_svg() {
    variant "$1" "$2" "$WORK/src.svg"
    rsvg-convert -f svg -w 1024 -h 1024 "$WORK/src.svg" -o "$3"
}

# "#RRGGBB" → Icon Composer's "srgb:r,g,b,1.00000".
srgb() {
    local hex="${1#\#}"
    awk -v r=$((16#${hex:0:2})) -v g=$((16#${hex:2:2})) -v b=$((16#${hex:4:2})) 'BEGIN { printf "srgb:%.5f,%.5f,%.5f,1.00000", r / 255, g / 255, b / 255 }'
}

gradient() { set -- $(palette_values "$1"); printf '[ "%s", "%s" ]' "$(srgb "$1")" "$(srgb "$2")"; }
mark_gradient() { set -- $(palette_values "$1"); printf '[ "%s", "%s" ]' "$(srgb "$6")" "$(srgb "$7")"; }

# The Icon Composer bundle. The layer is the 1024 source with the plate hidden; the plate's 824 squircle becomes the
# whole icon shape, so the layer is scaled 1024 / 824 to keep the mark's proportions to the plate.
write_icon_composer() {
    local out="$1"
    mkdir -p "$out/Assets"
    render_svg default layer "$out/Assets/mark.svg"
    cat >"$out/icon.json" <<EOF
{
  "fill-specializations" : [
    { "value" : { "linear-gradient" : $(gradient default) } },
    { "appearance" : "dark", "value" : { "linear-gradient" : $(gradient dark) } },
    { "appearance" : "tinted", "value" : { "linear-gradient" : $(gradient tinted) } }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "mark.svg",
          "name" : "mark",
          "position" : { "scale" : 1.24272, "translation-in-points" : [ 0, 0 ] },
          "fill-specializations" : [
            { "appearance" : "dark", "value" : { "linear-gradient" : $(mark_gradient dark) } },
            { "appearance" : "tinted", "value" : { "linear-gradient" : $(mark_gradient tinted) } }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.28 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
EOF
}

# Every committed asset, written into OUT (a fresh folder).
generate() {
    local out="$1" pt scale px name look
    command -v rsvg-convert >/dev/null || die "rsvg-convert not found (brew install librsvg)"
    mkdir -p "$out/AppIcon.iconset" "$out/export"
    for pt in 16 32 128 256 512; do
        for scale in 1 2; do
            px=$((pt * scale)); name="icon_${pt}x${pt}"
            [ "$scale" -eq 2 ] && name="${name}@2x"
            render_png default "$px" "$out/AppIcon.iconset/$name.png"
        done
    done
    iconutil -c icns "$out/AppIcon.iconset" -o "$out/AppIcon.icns"
    write_icon_composer "$out/AppIcon.icon"
    for look in default dark tinted light; do
        render_svg "$look" full "$out/export/keel-icon-$look.svg"
        render_svg "$look" small "$out/export/keel-icon-$look-small.svg"
    done
    # The Default look's PNGs are the iconset; the others are only exported.
    for look in dark tinted light; do
        mkdir -p "$out/export/$look"
        for px in $SIZES; do render_png "$look" "$px" "$out/export/$look/keel-icon-$px.png"; done
    done
}

compile() {
    local out="$1"
    [ -d "$ICON/AppIcon.icon" ] && [ -f "$ICON/AppIcon.icns" ] || die "run scripts/generate-app-icon.sh first"
    mkdir -p "$out"
    xcrun actool "$ICON/AppIcon.icon" --compile "$out" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --output-partial-info-plist "$WORK/partial.plist" --output-format human-readable-text >"$WORK/actool.log" 2>&1 \
        || { cat "$WORK/actool.log" >&2; die "actool failed"; }
    grep -q "error:" "$WORK/actool.log" && { cat "$WORK/actool.log" >&2; die "actool reported errors"; }
    [ -f "$out/Assets.car" ] || die "actool wrote no Assets.car"
    # The bundle's Info.plist names the icon AppIcon (CFBundleIconName for Assets.car, CFBundleIconFile for the .icns).
    [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$WORK/partial.plist")" = AppIcon ] || die "actool did not name the icon AppIcon"
    # actool flattens the .icon into an .icns with the full mark at every size; the committed one has the small form
    # at 48 px and below (DS-08), for macOS 14–15 and anything that reads CFBundleIconFile.
    cp "$ICON/AppIcon.icns" "$out/AppIcon.icns"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "${1:-}" in
"")
    generate "$WORK/out"
    for path in $OUTPUTS; do rm -rf "${ICON:?}/$path"; cp -R "$WORK/out/$path" "$ICON/$path"; done
    echo "generate-app-icon: wrote $OUTPUTS to release/icon" ;;
--check)
    generate "$WORK/out"
    status=0
    for path in $OUTPUTS; do diff -r "$WORK/out/$path" "$ICON/$path" >/dev/null 2>&1 || { echo "generate-app-icon: release/icon/$path is stale" >&2; status=1; }; done
    exit "$status" ;;
--compile)
    [ -n "${2:-}" ] || die "--compile needs an output folder"
    compile "$2" ;;
*) die "unknown argument $1 (use --check or --compile DIR)" ;;
esac
