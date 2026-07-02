#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?usage: sign-app.sh <app-path> [identity]}"
requested_identity="${2:-}"
local_identity="OpenPathTrace Local Code Signing"

identity_names() {
  security find-identity -p codesigning -v | sed -n 's/.*"\(.*\)".*/\1/p'
}

pick_identity() {
  if [[ -n "${requested_identity}" ]]; then
    printf '%s\n' "${requested_identity}"
    return
  fi

  for pattern in "Apple Development" "Developer ID Application" "Mac Developer"; do
    match="$(identity_names | grep -m 1 "${pattern}" || true)"
    if [[ -n "${match}" ]]; then
      printf '%s\n' "${match}"
      return
    fi
  done
}

identity="$(pick_identity)"
if [[ -z "${identity}" ]] && identity_names | grep -Fxq "${local_identity}"; then
  identity="${local_identity}"
fi

if [[ -z "${identity}" ]]; then
  cat >&2 <<EOF
No code signing identity found.
Run: make create-signing-identity
Then run: make install
EOF
  exit 1
fi

if [[ "${identity}" == "-" ]]; then
  echo "Refusing ad-hoc signing. Use a stable code signing identity." >&2
  exit 1
fi

if ! identity_names | grep -Fxq "${identity}"; then
  echo "Code signing identity not found: ${identity}" >&2
  security find-identity -p codesigning -v >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_path}/Contents/Info.plist")"
if [[ "${bundle_id}" != "dev.repairman.OpenPathTrace" ]]; then
  echo "Unexpected bundle id: ${bundle_id}" >&2
  exit 1
fi

codesign --force --deep --timestamp=none --sign "${identity}" "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"
codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n '1,80p'
