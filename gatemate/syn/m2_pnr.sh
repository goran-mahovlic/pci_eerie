#!/usr/bin/env bash
# TASK-6170 (uputa #877): nextpnr only, on the netlist of an earlier syn/m2_pcie.sh build (same JSON), another nextpnr.
#   NP=<nextpnr-himbaechel> GMPACK=<gmpack> [SEED=1] [PNR_OPTS=--tmg-ripup] syn/m2_pnr.sh <name> <netlist build name>
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1 SRCB=build/gm/$2; B=build/gm/$NAME; mkdir -p $B mjerenja; SEED=${SEED:-1}
NP=${NP:?NP=nextpnr-himbaechel}; GMPACK=${GMPACK:-$(dirname $NP)/gmpack}
T0=$(date +%s)
$NP --device CCGM1A1 --json $SRCB/top.json --vopt ccf=syn/m2_pcie.ccf --vopt out=$B/top.txt --seed $SEED \
  --freq 31.25 ${PNR_OPTS---tmg-ripup} --report $B/report.json -l $B/pnr.log > /dev/null 2>&1 || echo "nextpnr rc=$?" >> $B/pnr.log
[ -s $B/top.txt ] && $GMPACK --reset $B/top.txt $B/$NAME.bit
T1=$(date +%s)
{ echo "# $NAME: netlist $SRCB/top.json ($(sha256sum $SRCB/top.json | cut -c1-12)) seed=$SEED pnr='${PNR_OPTS---tmg-ripup}' nextpnr=$($NP --version 2>&1 | head -1) $(date -Iseconds) ($((T1-T0)) s)"
  grep -E "^Info:[[:space:]]+(CPE_LT|CPE_FF|RAM_HALF|SERDES):" $B/pnr.log | head -4 | sed 's/^Info:[[:space:]]*/  /'
  grep -E "Max frequency for clock" $B/pnr.log | awk -F"clock" '{k=$2; sub(/:.*/,"",k); last[k]=$0} END{for(k in last) print "  POSTROUTE" last[k]}' | sed -E 's/(Info|ERROR|Warning): //'
  grep -E "Hold/min time violations|nextpnr rc=|ERROR: " $B/pnr.log | head -3 || true
  grep -E "iter=" $B/pnr.log | tail -1 | sed 's/^Info:[[:space:]]*/  zadnja iteracija: /'
  [ -s $B/$NAME.bit ] && echo "  bit $B/$NAME.bit $(stat -c %s $B/$NAME.bit) B sha256 $(sha256sum $B/$NAME.bit | cut -c1-16)"; } | tee mjerenja/$NAME.txt
