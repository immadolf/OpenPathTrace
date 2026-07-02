#!/usr/bin/env bash
set -euo pipefail

identity="${1:-}"
app_name="OpenPathTrace"
app_path=".build/${app_name}.app"
install_path="/Applications/${app_name}.app"

swift build -c release
./scripts/build-app.sh release "${app_path}"
./scripts/sign-app.sh "${app_path}" "${identity}"

pkill -x "${app_name}" 2>/dev/null || true
rm -rf "${install_path}"
ditto "${app_path}" "${install_path}"
open "${install_path}"

echo "Installed ${install_path}"
