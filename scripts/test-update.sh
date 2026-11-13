#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bundle_id=org.betterwispr.app.updatetest
old_version=0.0.1
new_version=0.0.2
port="${UPDATE_TEST_PORT:-8765}"
arch="$(uname -m)"
entitlements=Resources/BetterWispr.entitlements
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/\)/ {print $2; exit}' || true)}"
identity="${identity:--}"
work="$(mktemp -d "${TMPDIR:-/tmp}/betterwispr-update-test.XXXXXX")"
work="$(cd "$work" && pwd -P)"
installed="$work/install/BetterWispr.app"
app_pid=""
server_pid=""
log_pid=""

cleanup() {
    status=$?
    for pid in $app_pid $server_pid $log_pid; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    if [[ $status -ne 0 && -f "$work/sparkle.log" ]]; then
        echo '--- app and Sparkle log ---' >&2
        cat "$work/sparkle.log" >&2
    fi
    launchctl remove "$bundle_id-sparkle-updater" 2>/dev/null || true
    launchctl remove "$bundle_id-sparkle-progress" 2>/dev/null || true
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    rm -rf "$work" "$HOME/Library/Preferences/$bundle_id.plist" "$HOME/Library/Caches/$bundle_id" "$HOME/Library/HTTPStorages/$bundle_id" "$HOME/Library/HTTPStorages/$bundle_id.binarycookies"
    [[ $status -eq 0 ]] && echo 'PASS: update installed and cleaned up' || echo "FAIL ($status)" >&2
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

stamp() {
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" \
        -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $2" "$1/Contents/Info.plist"
    codesign --deep --force --options runtime --sign "$identity" --entitlements "$entitlements" "$1"
    codesign --verify --deep --strict "$1"
}

echo "Signing identity: $identity"
built="$(CODESIGN_IDENTITY="$identity" ./scripts/build-app.sh | tail -1)"
mkdir -p "$work/old" "$work/new" "$work/feed" "$work/install" "$work/home"
ditto "$built" "$work/old/BetterWispr.app"
ditto "$built" "$work/new/BetterWispr.app"
stamp "$work/old/BetterWispr.app" "$old_version"
stamp "$work/new/BetterWispr.app" "$new_version"

dmg="$work/feed/BetterWispr-$arch.dmg"
if osascript -e 'with timeout of 10 seconds' -e 'tell application "Finder" to get name of startup disk' -e 'end timeout' >/dev/null 2>&1; then
    bash scripts/create-dmg.sh "$work/new/BetterWispr.app" "$dmg"
else
    echo 'warning: this process cannot script Finder, so the DMG skips create-dmg.sh window layout (Sparkle ignores it)' >&2
    mkdir -p "$work/staging"
    ditto "$work/new/BetterWispr.app" "$work/staging/BetterWispr.app"
    ln -s /Applications "$work/staging/Applications"
    diskutil image create from "$work/staging" "$dmg" --format UDZO --volumeName BetterWispr
fi
[[ "$identity" == - ]] || codesign --sign "$identity" "$dmg"
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account betterwispr "$dmg")"
hardware_requirement=""
[[ "$arch" == arm64 ]] && hardware_requirement='<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
cat > "$work/feed/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>BetterWispr</title>
        <item>
            <title>Version $new_version ($arch)</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$new_version</sparkle:version>
            <sparkle:shortVersionString>$new_version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            $hardware_requirement
            <enclosure url="http://127.0.0.1:$port/$(basename "$dmg")" type="application/octet-stream" $signature/>
        </item>
    </channel>
</rss>
EOF

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" > "$work/http.log" 2>&1 &
server_pid=$!
for _ in {1..20}; do curl -fs "http://127.0.0.1:$port/appcast.xml" >/dev/null && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$port/appcast.xml" >/dev/null || fail "feed server did not start on port $port"

ditto "$work/old/BetterWispr.app" "$installed"
defaults delete "$bundle_id" >/dev/null 2>&1 || true
defaults write "$bundle_id" SUFeedURL "http://127.0.0.1:$port/appcast.xml"
defaults write "$bundle_id" SUEnableAutomaticChecks -bool true
defaults write "$bundle_id" SUAutomaticallyUpdate -bool true

log stream --style compact --level debug \
    --predicate "processImagePath BEGINSWITH \"$work\" AND (subsystem == \"org.sparkle-project.Sparkle\" OR category == \"Updates\")" \
    > "$work/sparkle.log" 2>&1 &
log_pid=$!
sleep 2

echo "Launching $old_version from $installed"
CFFIXED_USER_HOME="$work/home" "$installed/Contents/MacOS/BetterWispr" > "$work/app.log" 2>&1 &
app_pid=$!

for _ in {1..120}; do
    grep -q "Update ready to install on quit: version=$new_version" "$work/sparkle.log" && break
    kill -0 "$app_pid" 2>/dev/null || fail 'old app exited before the update was ready'
    grep -q 'org.sparkle-project.Sparkle:Sparkle\] Error:' "$work/sparkle.log" && fail 'Sparkle rejected the update'
    sleep 1
done
grep -q "Update ready to install on quit: version=$new_version" "$work/sparkle.log" || fail 'update was not downloaded and prepared within 120 s'
grep -q "GET /$(basename "$dmg")" "$work/http.log" || fail 'the DMG was never downloaded'
echo "Update $new_version downloaded and verified; quitting $old_version"

kill "$app_pid"
wait "$app_pid" 2>/dev/null || true
app_pid=""

for _ in {1..60}; do
    [[ "$(defaults read "$installed/Contents/Info" CFBundleVersion 2>/dev/null)" == "$new_version" ]] && break
    sleep 1
done
reported="$(defaults read "$installed/Contents/Info" CFBundleVersion 2>/dev/null || true)"
[[ "$reported" == "$new_version" ]] || fail "installed bundle reports $reported, expected $new_version"
codesign --verify --deep --strict "$installed" || fail 'updated bundle fails codesign --verify --deep --strict'
echo "Installed bundle now reports $reported and passes codesign --verify --deep --strict"
