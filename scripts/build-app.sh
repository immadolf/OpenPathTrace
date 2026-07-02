#!/usr/bin/env bash
set -euo pipefail

configuration="${1:?usage: build-app.sh <debug|release> <app-path>}"
app_path="${2:?usage: build-app.sh <debug|release> <app-path>}"
app_name="OpenPathTrace"
binary_dir=".build/${configuration}"

rm -rf "${app_path}"
mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
cp "${binary_dir}/${app_name}" "${app_path}/Contents/MacOS/${app_name}"
cp "Resources/Info.plist" "${app_path}/Contents/Info.plist"
