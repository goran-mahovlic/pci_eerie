#!/usr/bin/env bash
# TASK-6170: EP reference clock off nominal, EB2 (SRNS=1) and common-clock path (SRNS=0), EP->RC through ser_retimer.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=${OUT:-build/sim/reg_ppm}; mkdir -p $OUT; S=$OUT/summary.txt; : > $S
NAME=rt_s1 SRNS=1 sim/ser/run_ser.sh build > $OUT/b1.log 2>&1
NAME=rt_s0 SRNS=0 sim/ser/run_ser.sh build > $OUT/b0.log 2>&1
NAME=rt_acc SRNS=1 CDR=ACCURATE sim/ser/run_ser.sh build > $OUT/b2.log 2>&1
one() { local n=$1 nm=$2 srns=$3; shift 3
  NAME=$nm SRNS=$srns SIM_TMO=1800 sim/ser/run_ser.sh run "$@" > $OUT/$n.log 2>&1
  local res=$(grep -a -m1 -o "RC MODEL RESULT: [A-Z]*" $OUT/$n.log || echo "RC MODEL RESULT: none")
  local rules=$(grep -a -m1 -o "Checker: [0-9]* rules, [0-9]* violations" $OUT/$n.log || echo "-")
  local fails=$(grep -a "^===>   [A-Z]" $OUT/$n.log | awk '$5+0>0 {printf "%s(%s) ", $2, $5}')
  local first=$(grep -a -m1 "CHECK\|Error ---" $OUT/$n.log | cut -c1-120)
  echo "$n | ${res#RC MODEL RESULT: } | $rules | $(grep -a 'tb: rx_err' $OUT/$n.log | cut -c5-) | $(grep -a 'tb: EP LTSSM 0x.. lnk' $OUT/$n.log | cut -c5-) | fails: ${fails:-none} | first: ${first:-none}" | tee -a $S
}
for p in 300 -300 600 -600 1000 -1000; do one eb2_ppm$p rt_s1 1 +ppm=$p; done
for p in 600 -600; do one eb2acc_ppm$p rt_acc 1 +ppm=$p; done
for p in 300 -300; do one cc_ppm$p rt_s0 0 +ppm=$p; done
echo "PPM_DONE $(date -Iseconds)" | tee -a $S
