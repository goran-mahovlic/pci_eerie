#!/usr/bin/env bash
# Fmax jednog modula na GateMateu kroz omotač gen_harness.py (TASK-6161).
#   [GM_DEFS="OPC1 OPC2"] syn/gm_modul.sh <ime> <modul> <taktovi,zarezom> <freq_MHz> <popis.f> [PARAM=VR ...]
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1 MOD=$2 CLKS=$3 FREQ=$4 LIST=$5; shift 5
OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}   # oss-cad-suite root (measured: 2026-11-17)
B=build/gm/$NAME; mkdir -p "$B"
SRC="" INC=""
while read -r l; do l=${l%%#*}; l=$(echo "$l" | xargs); [ -z "$l" ] && continue; l=$(eval echo "$l")
  case $l in +incdir+*) INC="$INC -I${l#+incdir+}";; *) SRC="$SRC $l";; esac; done < "$LIST"
CHP="" GP=""; for kv in "$@"; do CHP="$CHP -chparam ${kv%%=*} ${kv#*=}"; GP="$GP --param $kv"; done
"$OSS/bin/yosys" -q -p "read_verilog -sv -DSYNTHESIS $(for d in ${GM_DEFS:-}; do echo -n " -D$d"; done) $INC $SRC; hierarchy -top $MOD $CHP; proc; write_json $B/ports.json" > "$B/ports.log" 2>&1
python3 syn/gen_harness.py "$B/ports.json" "$MOD" --clk "$CLKS" $GP > "$B/harness.v"
{ cat "$LIST"; echo "$PWD/$B/harness.v"; } > "$B/list.f"
syn/gm_mjeri.sh "$NAME" harness "$FREQ" "$B/list.f" ${GM_DEFS:-}
