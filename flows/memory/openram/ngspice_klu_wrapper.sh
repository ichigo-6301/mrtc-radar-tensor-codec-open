#!/usr/bin/env bash
set -euo pipefail

: "${RDTC_NGSPICE_REAL:?Set RDTC_NGSPICE_REAL to the reviewed ngspice binary}"

if [[ $# -eq 0 ]]; then
  exec "$RDTC_NGSPICE_REAL"
fi

stimulus="${!#}"
if [[ -f "$stimulus" ]]; then
  spice_init="$(dirname "$stimulus")/.spiceinit"
  touch "$spice_init"
  if ! grep -qx 'option klu' "$spice_init"; then
    printf '%s\n' 'option klu' >> "$spice_init"
  fi
fi

log_file=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-o" ]]; then
    log_file="$argument"
    break
  fi
  previous="$argument"
done

set +e
"$RDTC_NGSPICE_REAL" "$@"
status=$?
set -e

if [[ -n "${RDTC_NGSPICE_ARCHIVE_DIR:-}" && -n "$log_file" && -f "$log_file" ]]; then
  mkdir -p "$RDTC_NGSPICE_ARCHIVE_DIR"
  period="unknown"
  if [[ -f "$stimulus" ]]; then
    period=$(sed -n 's/.*period of \([0-9.][0-9.]*\)n.*/\1/p' "$stimulus" | head -n 1)
    period=${period:-unknown}
  fi
  run_id=$(date -u +%Y%m%dT%H%M%S%N)
  prefix="$RDTC_NGSPICE_ARCHIVE_DIR/${run_id}_period_${period}ns"
  cp "$log_file" "${prefix}.lis"
  if [[ -f "$stimulus" ]]; then
    cp "$stimulus" "${prefix}_stim.sp"
    measure_file="$(dirname "$stimulus")/delay_meas.sp"
    if [[ -f "$measure_file" ]]; then
      cp "$measure_file" "${prefix}_meas.sp"
    fi
  fi
fi

exit "$status"
