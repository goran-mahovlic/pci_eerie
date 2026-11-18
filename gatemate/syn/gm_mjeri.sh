#!/usr/bin/env bash
# GateMate CCGM1A1: synth_gatemate + nextpnr-himbaechel za jednu varijantu (TASK-6161).
# Isti lanac za sve varijante (oss-cad-suite-20261117), bez IO ograničenja; mjeri CPE_LT/CPE_FF/RAM_HALF
# i Fmax po taktu NAKON rutiranja (zadnji redak "Max frequency" po taktu u logu nextpnr-a).
#
#   syn/gm_mjeri.sh <ime> <top> <freq_MHz> <popis.f> [yosys -D...]
#
# <popis.f>: jedna datoteka po retku (putanje relativne prema korijenu repoa ili apsolutne), "+incdir+X" za include.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1 TOP=$2 FREQ=$3 LIST=$4; shift 4
OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}   # oss-cad-suite root (measured: 2026-11-17)
export PATH=$OSS/bin:$PATH
SEED=${SEED:-1}
B=build/gm/$NAME
mkdir -p "$B" mjerenja
SRC="" INC=""
while read -r l; do
  l=${l%%#*}; l=$(echo "$l" | xargs); [ -z "$l" ] && continue
  l=$(eval echo "$l")
  case $l in +incdir+*) INC="$INC -I${l#+incdir+}";; *) SRC="$SRC $l";; esac
done < "$LIST"
DEFS=""; for d in "$@"; do DEFS="$DEFS -D$d"; done
T0=$(date +%s)
yosys -q -l "$B/synth.log" -p "read_verilog -sv -DSYNTHESIS $DEFS $INC $SRC; synth_gatemate -top $TOP ${SYNTH_OPTS--luttree -nomx8}; write_json $B/$TOP.json"
nextpnr-himbaechel --device CCGM1A1 --json "$B/$TOP.json" --vopt allow-unconstrained --seed "$SEED" \
  --freq "$FREQ" ${PNR_OPTS:-} --report "$B/report.json" -l "$B/pnr.log" > /dev/null 2>&1 || echo "nextpnr rc=$?" >> "$B/pnr.log"
T1=$(date +%s)
{
  echo "# $NAME: top=$TOP freq=$FREQ MHz seed=$SEED defs='$*' synth='${SYNTH_OPTS--luttree -nomx8}' pnr='${PNR_OPTS:-}' lanac=$(basename "$OSS") $(date -Iseconds) (${T1}-${T0}=$((T1-T0)) s)"
  grep -E "^Info:[[:space:]]+(CPE_LT|CPE_FF|RAM_HALF|SERDES|PLL|CPE_RAMIO|GPIO):" "$B/pnr.log" | head -8 | sed 's/^Info:[[:space:]]*/  /'
  # nakon rutiranja: zadnja pojava po taktu
  grep -E "Max frequency for clock" "$B/pnr.log" | awk -F"clock" '{k=$2; sub(/:.*/,"",k); last[k]=$0} END{for(k in last) print "  POSTROUTE" last[k]}' \
    | sed -E 's/(Info|ERROR|Warning): //'
  grep -E "nextpnr rc=|ERROR: [^M]" "$B/pnr.log" | head -3 || true
} | tee "mjerenja/$NAME.txt"
