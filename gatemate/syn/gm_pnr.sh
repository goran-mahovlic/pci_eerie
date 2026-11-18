#!/usr/bin/env bash
# Samo nextpnr nad već sintetiziranim JSON-om drugog pokusa (TASK-6161): mjeri učinak opcija placera/routera
# na ISTOM netlistu.   SEED=n syn/gm_pnr.sh <ime> <izvorni_pokus> [nextpnr opcije...]
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1 SRC=$2; shift 2
OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}   # oss-cad-suite root (measured: 2026-11-17)
SEED=${SEED:-1}; B=build/gm/$NAME; mkdir -p "$B"
J=$(ls build/gm/$SRC/*.json | grep -v -e report -e ports | head -1)
T0=$(date +%s)
"$OSS/bin/nextpnr-himbaechel" --device CCGM1A1 --json "$J" --vopt allow-unconstrained --seed "$SEED" --freq 31.25 "$@" \
  --report "$B/report.json" -l "$B/pnr.log" > /dev/null 2>&1 || echo "nextpnr rc=$?" >> "$B/pnr.log"
T1=$(date +%s)
{
  echo "# $NAME: top=$(basename "$J" .json) freq=31.25 MHz seed=$SEED defs='$(sed -n "s/.*defs='\([^']*\)'.*/\1/p" mjerenja/$SRC.txt)' synth=(netlist iz $SRC) pnr='$*' lanac=$(basename "$OSS") $(date -Iseconds) (${T1}-${T0}=$((T1-T0)) s)"
  grep -E "^Info:[[:space:]]+(CPE_LT|CPE_FF|RAM_HALF|SERDES|PLL|CPE_RAMIO|GPIO):" "$B/pnr.log" | head -8 | sed 's/^Info:[[:space:]]*/  /'
  grep -E "Max frequency for clock" "$B/pnr.log" | awk -F"clock" '{k=$2; sub(/:.*/,"",k); last[k]=$0} END{for(k in last) print "  POSTROUTE" last[k]}' | sed -E 's/(Info|ERROR|Warning): //'
  grep -E "nextpnr rc=|ERROR: [^M]" "$B/pnr.log" | head -3 || true
} | tee "mjerenja/$NAME.txt"
