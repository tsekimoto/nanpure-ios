#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID in repository Actions secrets}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID in repository Actions secrets}"
: "${ASC_API_KEY_P8:?Set ASC_API_KEY_P8 in repository Actions secrets}"
if [[ ! "$ASC_KEY_ID" =~ ^[A-Z0-9]+$ ]]; then
  echo "Invalid App Store Connect key ID." >&2
  exit 1
fi
ipa_path="$RUNNER_TEMP/nanpure.ipa"
if [[ ! -f "$ipa_path" ]]; then
  echo "The exported IPA is missing." >&2
  exit 1
fi

key_dir="$HOME/.appstoreconnect/private_keys"
key_file="$key_dir/AuthKey_${ASC_KEY_ID}.p8"
mkdir -p "$key_dir"
if [[ -e "$key_file" || -L "$key_file" ]]; then
  echo "An API key with the same ID already exists." >&2
  exit 1
fi
cleanup() {
  local status=$?
  if ! rm -f "$key_file"; then
    echo "API key cleanup failed; the runner must not be reused." >&2
    [[ "$status" -ne 0 ]] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$ASC_API_KEY_P8" > "$key_file"
unset ASC_API_KEY_P8
xcrun altool --upload-app \
  -f "$ipa_path" \
  -t ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
