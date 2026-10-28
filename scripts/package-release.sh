#!/usr/bin/env bash
# Builds, signs, packages and verifies a Keel release (MAC-08 – MAC-11, INT-11, KEEL-052):
#
#   scripts/package-release.sh [--no-layout]
#
# Produces in dist/: Keel.app (Universal 2, hardened runtime), Keel-<version>.dmg, the Sparkle archive
# Keel-<version>.zip, appcast.xml, SHA256SUMS.txt and release-evidence.json, which records every check in
# release/manifest.json `releaseChecks` as passed, failed or skipped (plus the latest .build/bench/evidence.json under
# `performance`). Any failed check, a failed notarization included, exits 1. A skipped check makes the build a pre-release.
#
#   KEEL_SIGN_IDENTITY     "Developer ID Application: …" (default "-": ad-hoc, not distributable)
#   KEEL_NOTARY_PROFILE    notarytool keychain profile; notarization is skipped when unset or ad-hoc
#   KEEL_NOTARY_KEYCHAIN   keychain holding that profile when it isn't the default keychain (the release workflow's)
#   KEEL_SPARKLE_KEY_FILE  Sparkle EdDSA private key file (generate_keys -x), or
#   KEEL_SPARKLE_ACCOUNT   the keychain account generate_keys stored it under; without either the update is unsigned
#
# --no-layout skips the Finder pass on the DMG (headless machines without Finder automation).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

layout=""
for argument in "$@"; do
    case "$argument" in
    --no-layout) layout=--no-layout ;;
    *) echo "package-release: unknown argument $argument" >&2; exit 64 ;;
    esac
done

identity="${KEEL_SIGN_IDENTITY:--}"
notary="${KEEL_NOTARY_PROFILE:-}"
notary_profile=(--keychain-profile "$notary")
[ -z "${KEEL_NOTARY_KEYCHAIN:-}" ] || notary_profile+=(--keychain "$KEEL_NOTARY_KEYCHAIN")
field() { /usr/bin/plutil -extract "$1" raw -o - release/manifest.json; }
version=$(field version)
minimum=$(field minimumMacOS)
bundle_id=$(field bundleIdentifier)
public_key=$(field sparkle.publicEDKey)
download_prefix=$(field sparkle.downloadURLPrefix)
# Sparkle orders updates by CFBundleVersion, which is the version itself, so only plain X.Y.Z versions are accepted.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "package-release: version $version is not X.Y.Z" >&2; exit 1; }

sparkle_bin=".build/artifacts/sparkle/Sparkle/bin"
sparkle_key=()
if [ -n "${KEEL_SPARKLE_KEY_FILE:-}" ]; then
    sparkle_key=(--ed-key-file "$KEEL_SPARKLE_KEY_FILE")
elif [ -n "${KEEL_SPARKLE_ACCOUNT:-}" ]; then
    sparkle_key=(--account "$KEEL_SPARKLE_ACCOUNT")
fi

dist="$ROOT/dist"
rm -rf "$dist"
mkdir -p "$dist"
work=$(mktemp -d "${TMPDIR:-/tmp}/keel-release.XXXXXX")
launched=""
# A launched app (the launch check) never outlives the script, even when it stops early.
trap '[ -z "$launched" ] || kill "$launched" 2>/dev/null || true; rm -rf "$work"' EXIT
checks="$work/checks.tsv"
: >"$checks"
# record ID STATUS DETAIL: one line of evidence (status passed, failed or skipped).
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ')" >>"$checks"
    echo "package-release: [$2] $1 ${3:+— $3}"
}

# --- Build: one native build per architecture, combined with lipo (Universal 2, MAC-11) ---------------------------
for arch in arm64 x86_64; do
    for product in Keel keel-askpass; do swift build --configuration release --triple "$arch-apple-macosx$minimum" --product "$product"; done
done
arm=$(swift build --configuration release --triple "arm64-apple-macosx$minimum" --show-bin-path)
intel=$(swift build --configuration release --triple "x86_64-apple-macosx$minimum" --show-bin-path)

app="$dist/Keel.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources" "$contents/Frameworks"
/usr/bin/lipo -create "$arm/Keel" "$intel/Keel" -output "$contents/MacOS/Keel"
/usr/bin/lipo -create "$arm/keel-askpass" "$intel/keel-askpass" -output "$contents/Helpers/keel-askpass"
# Resource bundles are architecture-independent; KeelCore and KeelUI look for them here (Bundle.packagedResources).
cp -R "$arm/Keel_KeelCore.bundle" "$arm/Keel_KeelUI.bundle" "$contents/Resources/"
# Sparkle's binary target is already Universal 2.
/usr/bin/ditto "$arm/Sparkle.framework" "$contents/Frameworks/Sparkle.framework"
# Keel isn't sandboxed (MAC-09), so Sparkle never uses its XPC services (SUEnableInstallerLauncherService is unset):
# leaving them out keeps unused signed code out of the bundle.
rm -rf "$contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$contents/Frameworks/Sparkle.framework/XPCServices"
# SwiftPM links with @loader_path only; the bundle keeps its frameworks one level up.
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents/MacOS/Keel"
scripts/generate-app-icon.sh --compile "$contents/Resources"
cp LICENSE "$contents/Resources/LICENSE.txt"
cp ThirdParty/Sparkle-LICENSE.txt "$contents/Resources/Sparkle-LICENSE.txt"
cp release/Info.plist "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" "$contents/Info.plist"
printf 'APPL????' >"$contents/PkgInfo"

# --- Sign inside-out: Sparkle's helpers, the framework, keel-askpass, then the app; hardened runtime, no entitlements --
# An ad-hoc signature has no Team ID, so the hardened runtime's library validation would refuse to load the embedded
# Sparkle.framework and the app couldn't launch; ad-hoc builds (never distributed) are therefore signed without it.
sign() {
    local path=$1; shift
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --timestamp=none --sign - "$@" "$path"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$@" "$path"
    fi
}
sparkle_framework="$contents/Frameworks/Sparkle.framework"
sign "$sparkle_framework/Versions/B/Autoupdate"
sign "$sparkle_framework/Versions/B/Updater.app"
sign "$sparkle_framework"
sign "$contents/Helpers/keel-askpass" --identifier "$bundle_id.askpass"
sign "$app" --identifier "$bundle_id"

# --- Product checks ------------------------------------------------------------------------------------------------
# The manifest's artifacts and Info.plist facts, and the update policy keys (UpdatePolicy.requiredInfoValues).
if detail=$(python3 -I - "$app" <<'PY' 2>&1
import json, os, plistlib, sys
app = sys.argv[1]
manifest = json.load(open("release/manifest.json"))
info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
problems = [f"missing {a}" for a in manifest["artifacts"] if not os.path.exists(os.path.join(os.path.dirname(app), a))]
expected = {"CFBundleIdentifier": manifest["bundleIdentifier"], "LSMinimumSystemVersion": manifest["minimumMacOS"], "CFBundleIconName": manifest["iconName"],
            "CFBundleShortVersionString": manifest["version"], "CFBundleVersion": manifest["version"], "SUFeedURL": manifest["sparkle"]["feedURL"],
            "SUPublicEDKey": manifest["sparkle"]["publicEDKey"], "SUEnableSystemProfiling": False, "SUAllowsAutomaticUpdates": False,
            "SUAutomaticallyUpdate": False, "SUEnableAutomaticChecks": True, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            "SUScheduledCheckInterval": 86400}
problems += [f"Info.plist {k} is {info.get(k)!r}, expected {v!r}" for k, v in expected.items() if info.get(k) != v]
if not info.get("NSLocalNetworkUsageDescription"): problems.append("Info.plist lacks NSLocalNetworkUsageDescription")
print("; ".join(problems) or "artifacts, Info.plist and update keys match the manifest")
sys.exit(1 if problems else 0)
PY
); then record manifest passed "$detail"; else record manifest failed "$detail"; fi

machos=("MacOS/Keel" "Helpers/keel-askpass" "Frameworks/Sparkle.framework/Versions/B/Sparkle" "Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater")
missing=""
for binary in "${machos[@]}"; do
    archs=$(/usr/bin/lipo -archs "$contents/$binary" 2>/dev/null || true)
    for arch in arm64 x86_64; do [[ " $archs " == *" $arch "* ]] || missing+="$binary lacks $arch; "; done
done
if [ -z "$missing" ]; then record architectures passed "arm64 x86_64 in ${#machos[@]} binaries ($(/usr/bin/lipo -info "$contents/MacOS/Keel" | sed 's/.*: //'))"
else record architectures failed "$missing"; fi

# LC_BUILD_VERSION of every slice of Keel's own binaries.
wrong=""
for binary in MacOS/Keel Helpers/keel-askpass; do
    for arch in arm64 x86_64; do
        minos=$(/usr/bin/vtool -arch "$arch" -show-build "$contents/$binary" 2>/dev/null | awk '/minos/ {print $2; exit}')
        [ "$minos" = "$minimum" ] || wrong+="$binary $arch minos ${minos:-missing}; "
    done
done
if [ -z "$wrong" ]; then record minimumOS passed "minos $minimum for both slices of Keel and keel-askpass"; else record minimumOS failed "$wrong"; fi

if out=$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" 2>&1); then record signature passed "codesign --verify --deep --strict"
else record signature failed "$out"; fi

# The CodeDirectory flags list "runtime" for hardened-runtime signatures (ad-hoc too).
plain=""
for code in "$app" "$contents/Helpers/keel-askpass" "$sparkle_framework" "$sparkle_framework/Versions/B/Autoupdate" "$sparkle_framework/Versions/B/Updater.app"; do
    # Captured first: under pipefail, grep -q closing the pipe early would fail the pipeline on codesign's SIGPIPE.
    display=$(/usr/bin/codesign --display --verbose=4 "$code" 2>&1 || true)
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$display" || plain+="${code#"$dist/"}; "
done
if [ "$identity" = "-" ]; then record hardenedRuntime skipped "ad-hoc builds are signed without it (library validation needs a Team ID)"
elif [ -z "$plain" ]; then record hardenedRuntime passed "app, keel-askpass and Sparkle's helpers"
else record hardenedRuntime failed "no hardened runtime: $plain"; fi

# The signed app must start: dyld refusing a framework (library validation, a missing rpath) or a missing resource bundle
# passes codesign --verify but kills the process at once. --fixture uses a throwaway state folder and has no updater.
"$contents/MacOS/Keel" --fixture >"$work/launch.log" 2>&1 &
launched=$!
sleep 5
if kill -0 "$launched" 2>/dev/null; then
    kill "$launched" 2>/dev/null || true; wait "$launched" 2>/dev/null || true
    record launch passed "running after 5 s with --fixture"
else
    wait "$launched" 2>/dev/null || true
    record launch failed "exited at launch: $(head -c 400 "$work/launch.log")"
fi
launched=""

# MAC-09: no entitlements at all (no JIT, no unsigned memory, no library validation exceptions).
entitled=""
for code in "$app" "$contents/Helpers/keel-askpass"; do
    [ -z "$(/usr/bin/codesign --display --entitlements - --xml "$code" 2>/dev/null)" ] || entitled+="${code#"$dist/"}; "
done
if [ -z "$entitled" ]; then record entitlements passed "none"; else record entitlements failed "entitlements present: $entitled"; fi

if [ "$identity" = "-" ]; then
    record developerID skipped "ad-hoc signature (KEEL_SIGN_IDENTITY unset)"
elif grep -q '^Authority=Developer ID Application:' <<<"$(/usr/bin/codesign --display --verbose=2 "$app" 2>&1 || true)"; then
    record developerID passed "$identity"
else
    record developerID failed "$identity is not a Developer ID Application identity"
fi

# --- Notarize: the app (so the Sparkle archive carries a stapled app), then the DMG --------------------------------
# notarize FILE: submits and waits; succeeds only on "Accepted", printing the log otherwise.
notarize() {
    local result status id
    result=$(/usr/bin/xcrun notarytool submit "$1" "${notary_profile[@]}" --wait --output-format json 2>"$work/notary.err") || true
    status=$(printf '%s' "$result" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("status", ""))
except Exception: print("")')
    [ "$status" = Accepted ] && return 0
    id=$(printf '%s' "$result" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("id", ""))
except Exception: print("")')
    cat "$work/notary.err" >&2
    [ -n "$id" ] && /usr/bin/xcrun notarytool log "$id" "${notary_profile[@]}" >&2 || true
    echo "${status:-submission failed}"
    return 1
}

notarizing=false
[ -n "$notary" ] && [ "$identity" != "-" ] && notarizing=true
notary_detail=""
notary_failed=false
if [ "$notarizing" = true ]; then
    /usr/bin/ditto -c -k --keepParent "$app" "$work/notarize.zip"
    if outcome=$(notarize "$work/notarize.zip"); then /usr/bin/xcrun stapler staple "$app" >/dev/null || notary_failed=true
    else notary_failed=true; notary_detail="app: $outcome"; fi
fi

# --- Sparkle archive, DMG ------------------------------------------------------------------------------------------
archive="Keel-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$archive"
dmg="Keel-$version.dmg"
scripts/make-dmg.sh "$app" "$dist/$dmg" "Keel $version" $layout
[ "$identity" = "-" ] || /usr/bin/codesign --force --timestamp --sign "$identity" "$dist/$dmg"
if [ "$notarizing" = true ] && [ "$notary_failed" = false ]; then
    if outcome=$(notarize "$dist/$dmg"); then /usr/bin/xcrun stapler staple "$dist/$dmg" >/dev/null || notary_failed=true
    else notary_failed=true; notary_detail="dmg: $outcome"; fi
fi

if [ "$notarizing" = false ]; then
    record notarization skipped "$([ "$identity" = "-" ] && echo "ad-hoc build" || echo "KEEL_NOTARY_PROFILE unset")"
    record stapling skipped "not notarized"
elif [ "$notary_failed" = true ]; then
    record notarization failed "${notary_detail:-stapling failed}"
    record stapling failed "not notarized"
else
    record notarization passed "app and DMG accepted"
    if /usr/bin/xcrun stapler validate "$app" >/dev/null && /usr/bin/xcrun stapler validate "$dist/$dmg" >/dev/null; then record stapling passed "app and DMG"
    else record stapling failed "stapler validate"; fi
fi

# Gatekeeper rejects ad-hoc and unnotarized builds by design, so only a notarized build can pass or fail here.
gatekeeper=$( { /usr/sbin/spctl --assess --type execute --verbose=2 "$app" 2>&1; /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dist/$dmg" 2>&1; } || true)
if [ "$notarizing" = false ] || [ "$notary_failed" = true ]; then
    record gatekeeper skipped "not notarized; spctl: $gatekeeper"
elif /usr/sbin/spctl --assess --type execute "$app" 2>/dev/null && /usr/sbin/spctl --assess --type open --context context:primary-signature "$dist/$dmg" 2>/dev/null; then
    record gatekeeper passed "$gatekeeper"
else
    record gatekeeper failed "$gatekeeper"
fi

# --- EdDSA: the archive's signature must verify against the key the app carries, and a tampered copy must not ------
signature=""
if [ ${#sparkle_key[@]} -eq 0 ]; then
    record updateSignature skipped "no EdDSA key (KEEL_SPARKLE_KEY_FILE / KEEL_SPARKLE_ACCOUNT)"
elif ! signature=$("$sparkle_bin/sign_update" "${sparkle_key[@]}" -p "$dist/$archive"); then
    record updateSignature failed "sign_update could not sign $archive"; signature=""
else
    cp "$dist/$archive" "$work/tampered.zip"
    # Flip the last byte: the archive is otherwise intact, so only the signature check can catch it.
    python3 -I -c 'import sys
with open(sys.argv[1], "r+b") as f:
    f.seek(-1, 2); b = f.read(1); f.seek(-1, 2); f.write(bytes([b[0] ^ 0xFF]))' "$work/tampered.zip"
    if ! swift scripts/verify-update-signature.swift "$public_key" "$dist/$archive" "$signature"; then
        record updateSignature failed "the signature doesn't verify against the manifest's public key"
    elif swift scripts/verify-update-signature.swift "$public_key" "$work/tampered.zip" "$signature"; then
        record updateSignature failed "a tampered archive verified"
    else
        record updateSignature passed "verifies against SUPublicEDKey; a tampered archive is rejected"
    fi
fi

# --- Appcast: one item for this version, then signed in place (SURequireSignedFeed) --------------------------------
python3 -I - "$dist/appcast.xml" "$version" "$minimum" "$download_prefix$archive" "$(stat -f %z "$dist/$archive")" "$signature" <<'PY'
import email.utils, sys
from xml.sax.saxutils import quoteattr, escape
out, version, minimum, url, length, signature = sys.argv[1:]
signature_attr = f" sparkle:edSignature={quoteattr(signature)}" if signature else ""
with open(out, "w", encoding="utf-8") as handle:
    handle.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Keel</title>
    <item>
      <title>Keel {escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>
      <enclosure url={quoteattr(url)} length={quoteattr(length)} type="application/octet-stream"{signature_attr}/>
    </item>
  </channel>
</rss>
""")
PY
if [ -z "$signature" ]; then
    record feedSignature skipped "no EdDSA key; appcast.xml is unsigned"
elif "$sparkle_bin/sign_update" "${sparkle_key[@]}" --disable-signing-warning "$dist/appcast.xml" >/dev/null \
    && "$sparkle_bin/sign_update" "${sparkle_key[@]}" --verify "$dist/appcast.xml" >/dev/null 2>&1; then
    record feedSignature passed "appcast.xml signed and verified"
else
    record feedSignature failed "appcast.xml could not be signed or verified"
fi

# --- Checksums -----------------------------------------------------------------------------------------------------
(cd "$dist" && /usr/bin/shasum -a 256 "$dmg" "$archive" appcast.xml >SHA256SUMS.txt)
if (cd "$dist" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null); then record checksums passed "SHA256SUMS.txt"; else record checksums failed "shasum -c"; fi

# --- Performance evidence (KEEL-047): the latest bench-browser.py run ------------------------------------------------
bench=".build/bench/evidence.json"
if [ ! -f "$bench" ]; then
    record performance skipped "no $bench (run scripts/bench-browser.py)"
else
    # Only a complete run of this commit counts: a stale, dirty or partial (--skip-*) "pass" can't make a release.
    result=$(python3 -I -c 'import json,sys
e = json.load(open(sys.argv[1])); git = e.get("git", {})
partial = not {"1m", "10m"} <= set(e.get("sizes") or []) or any("skipped in this run" in p.get("check", "") for p in e.get("pending", []))
fresh = git.get("commit") == sys.argv[2] and not git.get("dirty")
print(e.get("result", ""), "complete" if not partial else "partial", "current" if fresh else "stale", git.get("commit", "")[:12], e.get("generated", ""))' "$bench" "$(git rev-parse HEAD 2>/dev/null || true)")
    case "$result" in
    "pass complete current "*) record performance passed "bench-browser.py $result" ;;
    pass*) record performance skipped "bench-browser.py $result (rerun on a clean checkout of this commit: 1M and 10M keys, nothing skipped)" ;;
    *) record performance failed "bench-browser.py $result" ;;
    esac
fi

# Exits 1 on any failed check or incomplete evidence (AC4); `set -e` would stop before the summary line.
status=0
python3 -I scripts/release-evidence.py write --checks "$checks" --sums "$dist/SHA256SUMS.txt" --out "$dist/release-evidence.json" --bench "$bench" --identity "$identity" || status=$?
echo "package-release: $(python3 -I -c 'import json; e=json.load(open("dist/release-evidence.json")); print(e["channel"])') evidence in dist/release-evidence.json"
exit "$status"
