#!/bin/bash
set -euo pipefail
unit='__UNIT__'
rc=0
state=$(systemctl show "$unit" --property=LoadState --value) || rc=$?
if [ "$state" = "not-found" ]; then
  echo "Owned server unit is already gone (or was never started)."
elif [ "$rc" -ne 0 ]; then
  echo "Cannot inspect owned unit $unit (exit $rc)." >&2
  exit "$rc"
else
  systemctl stop "$unit"
  echo "Stopped owned server unit $unit."
fi
