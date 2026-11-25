#!/usr/bin/env bash
# TASK-6176: serial-line regression of SRNS=1 with eerie_skp_ebb (EERIE_SKP_EBB, FIFO in block RAM):
# A7RC (openPCIE_BFM) -> openSERDES_BFM ccfpga_serdes -> eerie_ccs_phy -> eerie W8, EP reference clock off by +ppm.
# Runs in parallel (JOBS), one line per run in $OUT/summary.txt (same columns as reg_ser.sh).
set -uo pipefail
cd "$(dirname "$0")/../.."
export OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}; export PATH=$OSS/bin:$PATH
T=${T:-}
OUT=${OUT:-build/sim/reg_ebb}; mkdir -p $OUT; S=$OUT/summary.txt; : > $S
NAME=ebb_fast$T SRNS=1 EXTRA_DEFS=EERIE_SKP_EBB sim/ser/run_ser.sh build > $OUT/build_fast.log 2>&1 || { echo "BUILD FAIL fast" | tee -a $S; exit 1; }
NAME=ebb_acc$T SRNS=1 CDR=ACCURATE EXTRA_DEFS=EERIE_SKP_EBB sim/ser/run_ser.sh build > $OUT/build_acc.log 2>&1 || { echo "BUILD FAIL acc" | tee -a $S; exit 1; }
NAME=cc_fast$T SRNS=0 sim/ser/run_ser.sh build > $OUT/build_cc.log 2>&1 || { echo "BUILD FAIL cc" | tee -a $S; exit 1; }
one() { # name obj srns ebb -- args
  local n=$1 nm=$2 srns=$3 ebb=$4; shift 5
  env NAME=$nm SRNS=$srns ${ebb:+EXTRA_DEFS=EERIE_SKP_EBB} SIM_TMO=3600 sim/ser/run_ser.sh run "$@" > $OUT/$n.log 2>&1
  local res=$(grep -a -m1 -o "RC MODEL RESULT: [A-Z]*" $OUT/$n.log || echo "RC MODEL RESULT: none")
  local rules=$(grep -a -m1 -o "Checker: [0-9]* rules, [0-9]* violations" $OUT/$n.log || echo "-")
  local fails=$(grep -a "^===>   [A-Z]" $OUT/$n.log | awk '$5+0>0 {printf "%s(%s) ", $2, $5}')
  local l0=$(grep -a -m1 "EP LTSSM 0x16" $OUT/$n.log | awk '{print $1/1e6 " us"}')
  echo "$n | ${res#RC MODEL RESULT: } | $rules | L0 at ${l0:-never} | $(grep -a 'tb: COM lanes' $OUT/$n.log | cut -c5-) | $(grep -a 'tb: rx_err' $OUT/$n.log | cut -c5-) | fails: ${fails:-none}" | tee -a $S
}
J=${JOBS:-6}   # T: suffix of the Verilator obj dirs (verilator does not relink when only libuser.a changed: use a new T then)
{ for p in 0 300 -300 600 -600 1000 -1000; do echo "ebb_ppm$p ebb_fast$T 1 1 -- +ppm=$p"; done
  for p in 600 -600; do echo "ebbacc_ppm$p ebb_acc$T 1 1 -- +ppm=$p"; done
  for s in 2 3 4; do echo "ebb_seed$s ebb_fast$T 1 1 -- +verilator+seed+$s +ppm=300"; done
  echo "cc_ppm0 cc_fast$T 0 '' -- +ppm=0"; } > $OUT/jobs.txt
export -f one; export OUT S
xargs -P $J -L1 bash -c 'one "$@"' _ < $OUT/jobs.txt
echo "REG_DONE $(date -Iseconds)" | tee -a $S
