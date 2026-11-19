#!/usr/bin/env bash
# TASK-6173: regression of the W16 / Gen2 serial-line run (sim/ser/run_ser16.sh), runs in parallel (P=8).
# One line per run in $OUT/summary.txt; com16.txt: the PIPE symbol of the first TS COM at 2.5 and 5.0 GT/s.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=${OUT:-build/sim/reg16}; mkdir -p $OUT; S=$OUT/summary.txt; : > $S; P=${P:-8}
B="cc0:SRNS=0 PAIR=0|cc1:SRNS=0 PAIR=1|eb:SRNS=1 PAIR=0|eb1:SRNS=1 PAIR=1|ebacc:SRNS=1 CDR=ACCURATE|tester:A7RC=0|g1:EPGEN=1"
# (TASK-6173 fix: split the list on '|' only, then the env words on blanks; the first version passed
#  "SRNS=1 PAIR=0" as ONE value, so every SRNS=1 / PAIR=1 / ACCURATE build was SRNS=0)
[ -n "${ONLY_SUMMARY:-}" ] || { IFS='|' read -ra BL <<< "$B"; for b in "${BL[@]}"; do n=${b%%:*}; read -ra E <<< "${b#*:}"
  env "${E[@]}" NAME=r16_$n sim/ser/run_ser16.sh build > $OUT/build_$n.log 2>&1 || echo "BUILD FAIL $n" | tee -a $S
  grep -q "SRNS\|RX_PAIR1\|EP_GEN1\|CDR_MODEL" build/sim/r16_$n/files.f && echo "build $n: $(grep -o '+define+\(SRNS\|RX_PAIR1\|EP_GEN1\|CDR_MODEL=[A-Z]*\)' build/sim/r16_$n/files.f | tr '\n' ' ')" >> $OUT/builds.txt; done; }
one() { # name build-name env... -- args
  local n=$1 bn=$2; shift 2; local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  [ -n "${ONLY_SUMMARY:-}" ] || env "${envs[@]}" NAME=r16_$bn SIM_TMO=1800 sim/ser/run_ser16.sh run "$@" > $OUT/$n.log 2>&1
  local S=$OUT/summary.txt
  local res=$(grep -a -m1 -o "RC MODEL RESULT: [A-Z]*" $OUT/$n.log || echo "RC MODEL RESULT: none")
  local rules=$(grep -a -m1 -o "Checker: [0-9]* rules, [0-9]* violations" $OUT/$n.log || echo "-")
  local fails=$(grep -a "^===>   [A-Z]" $OUT/$n.log | awk '$5+0>0 {printf "%s(%s) ", $2, $5}')
  local spd=$(grep -a -m1 -o "link speed = 0x[0-9a-f]*" $OUT/$n.log || echo "link speed = ?")
  echo "$n | ${res#RC MODEL RESULT: } | $rules | ${spd} | $(grep -a 'tb: TS COM' $OUT/$n.log | cut -c5-) | $(grep -a 'tb: rx_err' $OUT/$n.log | cut -c5-) | $(grep -a 'tb: EP LTSSM 0x.. lnk' $OUT/$n.log | cut -c5-) | fails: ${fails:-none}" >> $S
}
export -f one; export OUT ONLY_SUMMARY
{
  for s in $(seq 1 16); do echo "cc0_seed$s cc0 SRNS=0 PAIR=0 -- +verilator+seed+$s"; echo "cc1_seed$s cc1 SRNS=0 PAIR=1 -- +verilator+seed+$s"; done
  for p in 0 300 -300 600 -600 1000 -1000; do echo "eb_ppm$p eb SRNS=1 -- +ppm=$p"; done
  for p in 600 -600; do echo "eb1_ppm$p eb1 SRNS=1 PAIR=1 -- +ppm=$p"; echo "ebacc_ppm$p ebacc SRNS=1 CDR=ACCURATE -- +ppm=$p"; done
  for p in 300 -300; do echo "cc0_ppm$p cc0 SRNS=0 -- +ppm=$p"; done
  echo "g1_ep_gen1 g1 EPGEN=1 --"
  for s in 1 2; do echo "tester_seed$s tester A7RC=0 SEED=$s --"; done
} | xargs -P $P -L 1 bash -c 'one "$@"' _
sort -V $S -o $S
python3 - "$S" > $OUT/com16.txt <<'PY'
import sys, re
g1, g2 = set(), set()
for l in open(sys.argv[1]):
    m = re.search(r"TS COM symbol 2.5 GT/s (-?\d+), 5.0 GT/s (-?\d+)", l)
    if m and "| PASS |" in l and int(m.group(1)) >= 0 and int(m.group(2)) >= 0:
        g1.add(int(m.group(1))); g2.add(int(m.group(2)))
print("PASS runs, first-TS COM PIPE symbol at 2.5 GT/s:", sorted(g1), f"({len(g1)}/16)")
print("PASS runs, first-TS COM PIPE symbol at 5.0 GT/s:", sorted(g2), f"({len(g2)}/16)")
print("union:", sorted(g1 | g2), f"({len(g1 | g2)}/16)")
PY
cat $OUT/com16.txt | tee -a $S
echo "REG16_DONE $(date -Iseconds)" | tee -a $S
