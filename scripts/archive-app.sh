#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
: "${P12_BASE64:?Set IOS_P12_BASE64 in repository Actions secrets}"
: "${P12_PASSWORD:?Set IOS_P12_PASSWORD in repository Actions secrets}"
: "${PROFILE_BASE64:?Set IOS_PROVISION_PROFILE_BASE64 in repository Actions secrets}"

ipa_path="$RUNNER_TEMP/nanpure.ipa"
if [[ -e "$ipa_path" || -L "$ipa_path" ]]; then
  echo "The output IPA already exists; refusing to reuse a previous build." >&2
  exit 1
fi

work=$(mktemp -d "$RUNNER_TEMP/nanpure-signing.XXXXXX")
keychain="$work/build.keychain-db"
installed_profile=
search_list_changed=false
original_keychains=()
cleanup() {
  local status=$?
  local cleanup_failed=false
  if [[ "$search_list_changed" == true ]]; then
    if [[ ${#original_keychains[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || cleanup_failed=true
    else
      security list-keychains -d user -s >/dev/null 2>&1 || cleanup_failed=true
    fi
  fi
  if [[ -e "$keychain" ]]; then
    security delete-keychain "$keychain" >/dev/null 2>&1 || cleanup_failed=true
  fi
  if [[ -n "$installed_profile" ]]; then
    rm -f "$installed_profile" || cleanup_failed=true
  fi
  rm -rf "$work" || cleanup_failed=true
  if [[ "$cleanup_failed" == true ]]; then
    echo "Signing cleanup failed; the runner must not be reused." >&2
    [[ "$status" -ne 0 ]] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

security list-keychains -d user > "$work/keychains.txt"
while IFS= read -r line; do
  # security prints each path in double quotes, with optional leading spaces.
  line=${line#*\"}
  line=${line%\"*}
  [[ -z "$line" ]] || original_keychains+=("$line")
done < "$work/keychains.txt"

profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
profile_path="$profile_dir/nanpure.mobileprovision"
mkdir -p "$profile_dir"
if [[ -e "$profile_path" || -L "$profile_path" ]]; then
  echo "A provisioning profile already exists at the install path." >&2
  exit 1
fi
printf '%s' "$PROFILE_BASE64" | base64 --decode > "$work/app.mobileprovision"
installed_profile="$profile_path"
cp "$work/app.mobileprovision" "$installed_profile"

printf '%s' "$P12_BASE64" | base64 --decode > "$work/cert.p12"
keychain_password=$(uuidgen)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/cert.p12" -P "$P12_PASSWORD" -t cert -f pkcs12 \
  -T /usr/bin/codesign -T /usr/bin/security -k "$keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$keychain_password" "$keychain" >/dev/null
search_list_changed=true
if [[ ${#original_keychains[@]} -gt 0 ]]; then
  security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
else
  security list-keychains -d user -s "$keychain"
fi
rm -f "$work/cert.p12" "$work/app.mobileprovision"
unset P12_BASE64 P12_PASSWORD PROFILE_BASE64 keychain_password

xcodebuild archive \
  -project "src/ナンプレ.xcodeproj" \
  -scheme Nanpure \
  -configuration Release \
  "CURRENT_PROJECT_VERSION=$GITHUB_RUN_NUMBER" \
  -archivePath "$work/app.xcarchive" \
  -destination 'generic/platform=iOS'

cat > "$work/exportOptions.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>4QLQBKXV72</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>io.github.tsekimoto.nanpure</key>
        <string>nanpure distribution</string>
    </dict>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$work/app.xcarchive" \
  -exportPath "$work/export" \
  -exportOptionsPlist "$work/exportOptions.plist"

shopt -s nullglob
ipas=("$work"/export/*.ipa)
if [[ ${#ipas[@]} -ne 1 ]]; then
  echo "Expected exactly one exported IPA." >&2
  exit 1
fi
mv "${ipas[0]}" "$ipa_path"
