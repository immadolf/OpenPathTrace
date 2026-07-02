#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-/Applications/OpenPathTrace.app}"
tcc_db="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"

codesign --verify --deep --strict --verbose=2 "${app_path}"
codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n '1,100p'

if [[ -r "${tcc_db}" ]]; then
  sqlite3 "${tcc_db}" <<'SQL' || true
.headers on
.mode column
SELECT service, client, auth_value, auth_reason, auth_version, last_modified
FROM access
WHERE service = 'kTCCServiceAccessibility'
  AND (client = 'dev.repairman.OpenPathTrace' OR client LIKE '%OpenPathTrace%');
SQL
else
  echo "TCC database is not readable: ${tcc_db}"
fi

/usr/bin/log show --last 10m --predicate 'process == "OpenPathTrace" OR process == "tccd"' --style compact
