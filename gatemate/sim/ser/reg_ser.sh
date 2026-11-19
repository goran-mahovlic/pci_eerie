#!/usr/bin/env bash
# TASK-6170: regression of the serial-line run (sim/ser/run_ser.sh). One line per run in $OUT/summary.txt.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=${OUT:-build/sim/reg}; mkdir -p $OUT; S=$OUT/summary.txt; : > $S
one() { # name env... -- args
  local n=$1; shift; local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" SIM_TMO=1800 sim/ser/run_ser.sh run "$@" > $OUT/$n.log 2>&1
  local res=$(grep -a -m1 -o "RC MODEL RESULT: [A-Z]*" $OUT/$n.log || echo "RC MODEL RESULT: none")
  local rules=$(grep -a -m1 -o "Checker: [0-9]* rules, [0-9]* violations" $OUT/$n.log || echo "-")
  local fails=$(grep -a "^===>   [A-Z]" $OUT/$n.log | awk '$5+0>0 {printf "%s(%s) ", $2, $5}')
  local l0=$(grep -a -m1 "EP LTSSM 0x16" $OUT/$n.log | awk '{print $1/1e6 " us"}')
  echo "$n | ${res#RC MODEL RESULT: } | $rules | L0 at ${l0:-never} | $(grep -a 'tb: COM lanes' $OUT/$n.log | cut -c5-) | $(grep -a 'tb: rx_err' $OUT/$n.log | cut -c5-) | fails: ${fails:-none}" | tee -a $S
}
for c in "A7RC=1 SRNS=0 CDR=FAST" "A7RC=1 SRNS=1 CDR=FAST" "A7RC=1 SRNS=1 CDR=ACCURATE" "A7RC=0 SRNS=0 CDR=FAST"; do
  env $c sim/ser/run_ser.sh build > $OUT/build_$(echo $c | tr ' =' '__').log 2>&1 || echo "BUILD FAIL $c" | tee -a $S
done
for s in 1 2 3 4 5 6 7 8 9 10 11 12; do one cc_seed$s A7RC=1 SRNS=0 CDR=FAST -- +verilator+seed+$s; done
for p in 0 300 -300 600 -600 1000 -1000; do one eb2_ppm$p A7RC=1 SRNS=1 CDR=FAST -- +ppm=$p; done
for p in 600 -600; do one eb2acc_ppm$p A7RC=1 SRNS=1 CDR=ACCURATE -- +ppm=$p; done
for p in 300 -300; do one cc_ppm$p A7RC=1 SRNS=0 CDR=FAST -- +ppm=$p; done
for s in 1 2 3 4; do one tester_seed$s A7RC=0 SRNS=0 CDR=FAST SEED=$s -- ; done
echo "REG_DONE $(date -Iseconds)" | tee -a $S
