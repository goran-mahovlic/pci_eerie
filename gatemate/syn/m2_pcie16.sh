#!/usr/bin/env bash
# TASK-6238: ULX5M-M2 v002 PCIe Gen2 endpoint bitstream: m2_pcie16_top = eerie_ccs_phy16 (ccfpga_serdes.SYNTH.sv ->
# CC_SERDES) + eerie_w16_ep (pci_eerie EERIE_W16, the options of sim/ser/run_ser16.sh). Otherwise as syn/m2_pcie.sh
# (CC_SERDES HM-only parameters by setparam, gmpack --reset). PCLK 31.25 MHz at 5.0 GT/s is the timing target.
#   [SEED=1] [SRNS=0] [MAX_GEN=2] [PNR_OPTS=--tmg-ripup] [CCF=syn/m2_pcie.ccf] [EXTRA_DEFS=M2_LED] [NOPNR=1] syn/m2_pcie16.sh <name>
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1; OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}; export PATH=$OSS/bin:$PATH
SEED=${SEED:-1}; SRNS=${SRNS:-0}; MAX_GEN=${MAX_GEN:-2}; B=build/gm/$NAME; mkdir -p $B mjerenja
D0="EERIE_W16 EERIE_1CLK EERIE_LTSSM_SPDDN EERIE_DLL_CRCPRE EERIE_ML_CRCMAT EERIE_ML_DLCPRE EERIE_ML_QREG EERIE_ML_ADUP \
      EERIE_ML_KPRE EERIE_ML_CDUP EERIE_DLL_FCSET"; DEFS="${DEFS:-$D0} ${EXTRA_DEFS:-}"
SRC="$(sed 's|^|../rtl/|' ../rtl/files.f | tr '\n' ' ') ../rtl/eerie_skp_eb16.v rtl/eerie_ram_sdp.v rtl/eerie_w16_core.v \
     rtl/eerie_bar0_app.v rtl/eerie_w16_ep.v rtl/eerie_bufg.v rtl/eerie_ccs_phy16.v rtl/m2_pcie16_top.v \
     ext/openSERDES_BFM/1.gatemate/1.model/ccfpga_serdes.SYNTH.sv"
T0=$(date +%s)
yosys -q -l $B/synth.log -p "read_verilog -sv -DSYNTHESIS $(for d in $DEFS; do echo -n " -D$d"; done) -I../rtl -Irtl $SRC; \
  chparam -set SRNS $SRNS -set MAX_GEN $MAX_GEN m2_pcie16_top; hierarchy -top m2_pcie16_top; \
  setparam -set RX_CALIB_EN 1 -set TX_CALIB_EN 1 -set RX_POWER_DOWN_N 1 -set TX_POWER_DOWN_N 1 \
           -set SERDES_TESTMODE 1 -set TX_DC_ENABLE_RXDET 63 t:CC_SERDES; synth_gatemate -top m2_pcie16_top ${SYNTH_OPTS--luttree -nomx8}; \
  tee -o $B/stat.txt stat; write_json $B/top.json"
[ "${NOPNR:-0}" = 1 ] && { grep -E "CPE|RAM|SERDES" $B/stat.txt | head; exit 0; }
if [ "${PACKONLY:-0}" = 1 ]; then nextpnr-himbaechel --device CCGM1A1 --json $B/top.json --vopt ccf=${CCF:-syn/m2_pcie.ccf} --pack-only -l $B/pack.log >/dev/null 2>&1; grep -E "^Info:[[:space:]]+(CPE_LT|CPE_FF|RAM_HALF):" $B/pack.log | sed "s/^Info:[[:space:]]*/  /" | tee mjerenja/$NAME.pack.txt; exit 0; fi
nextpnr-himbaechel --device CCGM1A1 --json $B/top.json --vopt ccf=${CCF:-syn/m2_pcie.ccf} --vopt out=$B/top.txt --seed $SEED \
  --freq 31.25 ${PNR_OPTS---tmg-ripup} --report $B/report.json -l $B/pnr.log > /dev/null 2>&1 || echo "nextpnr rc=$?" >> $B/pnr.log
[ -s $B/top.txt ] && gmpack --reset $B/top.txt $B/$NAME.bit
T1=$(date +%s)
{ echo "# $NAME: m2_pcie16_top SRNS=$SRNS MAX_GEN=$MAX_GEN seed=$SEED pnr='${PNR_OPTS---tmg-ripup}' lanac=$(basename $(readlink -f $OSS)) $(date -Iseconds) ($((T1-T0)) s)"
  grep -E "^Info:[[:space:]]+(CPE_LT|CPE_FF|RAM_HALF|SERDES|CPE_RAMIO|GLBOUT):" $B/pnr.log | head -10 | sed 's/^Info:[[:space:]]*/  /'
  grep -E "Max frequency for clock" $B/pnr.log | awk -F"clock" '{k=$2; sub(/:.*/,"",k); last[k]=$0} END{for(k in last) print "  POSTROUTE" last[k]}' | sed -E 's/(Info|ERROR|Warning): //'
  grep -E "Hold/min time violations|nextpnr rc=|ERROR: " $B/pnr.log | head -3 || true
  grep -E "iter=" $B/pnr.log | tail -1 | sed 's/^Info:[[:space:]]*/  zadnja iteracija: /'
  [ -s $B/$NAME.bit ] && echo "  bit $B/$NAME.bit $(stat -c %s $B/$NAME.bit) B sha256 $(sha256sum $B/$NAME.bit | cut -c1-16)"; } | tee mjerenja/$NAME.txt
