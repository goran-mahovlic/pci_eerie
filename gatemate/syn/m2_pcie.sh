#!/usr/bin/env bash
# TASK-6170: ULX5M-M2 PCIe endpoint bitstream: m2_pcie_top = eerie_ccs_phy (ccfpga_serdes.SYNTH.sv -> CC_SERDES)
# + eerie_w8_ep (pci_eerie EERIE_W8, all timing options, as F1 in TASK-6161). Bitstream with gmpack --reset.
# CC_SERDES parameters that the ccfpga_serdes wrapper does not have (HM only; SYNTH leaves the Yosys defaults)
# are set on the cell with setparam, to the values of the proven GS<->M2 2.5G recipe (cc_serdes_params.vh):
# RX/TX_CALIB_EN 1, RX/TX_POWER_DOWN_N 1, SERDES_TESTMODE 1, TX_DC_ENABLE_RXDET 63 (serdes_cmp.py: 6 fields).
# SRNS=1 with the block-RAM SKP buffer: EXTRA_DEFS="M2_LED EERIE_SKP_EBB" (TASK-6176).
# TASK-6184: TOP=gs_pcie_top CCF=syn/gs_pcie.ccf (GS v005), DID 1397:4753 with EXTRA_DEFS+=EERIE_DEVID_GS.
#   [SEED=1] [SRNS=0] [PNR_OPTS=--tmg-ripup] [CCF=syn/m2_pcie.ccf] [EXTRA_DEFS=M2_LED] syn/m2_pcie.sh <name>
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1; OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}; export PATH=$OSS/bin:$PATH   # measured: oss-cad-suite 2026-11-17
SEED=${SEED:-1}; SRNS=${SRNS:-0}; TOP=${TOP:-m2_pcie_top}; B=build/gm/$NAME; mkdir -p $B mjerenja
DEFS="EERIE_W8 EERIE_DLL_CRCPRE EERIE_ML_CRCMAT EERIE_ML_DLCPRE EERIE_ML_QREG EERIE_W8_IDLEPRE EERIE_W8_PAPRE \
      EERIE_SCR8_MAT EERIE_SCR8_PTREE EERIE_ML_ADUP EERIE_ML_KPRE EERIE_ML_CDUP EERIE_SKP_EB2 EERIE_W8_SKP1 EERIE_DLL_FCSET ${EXTRA_DEFS:-}"
SRC="$(sed 's|^|../rtl/|' ../rtl/files.f | tr '\n' ' ') ../rtl/eerie_skp_eb.v ../rtl/eerie_skp_ebb.v rtl/eerie_ram_sdp.v rtl/eerie_w8_core.v \
     rtl/eerie_bar0_app.v rtl/eerie_w8_ep.v rtl/eerie_bufg.v rtl/eerie_ccs_phy.v rtl/m2_pcie_top.v rtl/gs_pcie_top.v \
     ext/openSERDES_BFM/1.gatemate/1.model/ccfpga_serdes.SYNTH.sv"
case " $DEFS " in *" EERIE_ILA "*) SRC="$SRC rtl/eerie_ila.v";; esac   # TASK-6190
T0=$(date +%s)
yosys -q -l $B/synth.log -p "read_verilog -sv -DSYNTHESIS $(for d in $DEFS; do echo -n " -D$d"; done) -I../rtl -Irtl $SRC; \
  chparam -set SRNS $SRNS $TOP; hierarchy -top $TOP; \
  setparam -set RX_CALIB_EN 1 -set TX_CALIB_EN 1 -set RX_POWER_DOWN_N 1 -set TX_POWER_DOWN_N 1 \
           -set SERDES_TESTMODE 1 -set TX_DC_ENABLE_RXDET 63 t:CC_SERDES; synth_gatemate -top $TOP ${SYNTH_OPTS--luttree -nomx8}; write_json $B/top.json"
nextpnr-himbaechel --device CCGM1A1 --json $B/top.json --vopt ccf=${CCF:-syn/m2_pcie.ccf} --vopt out=$B/top.txt --seed $SEED \
  --freq 31.25 ${PNR_OPTS---tmg-ripup} --report $B/report.json -l $B/pnr.log > /dev/null 2>&1 || echo "nextpnr rc=$?" >> $B/pnr.log
[ -s $B/top.txt ] && gmpack --reset $B/top.txt $B/$NAME.bit
T1=$(date +%s)
{ echo "# $NAME: $TOP SRNS=$SRNS seed=$SEED pnr='${PNR_OPTS---tmg-ripup}' lanac=$(basename $(readlink -f $OSS)) $(date -Iseconds) ($((T1-T0)) s)"
  grep -E "^Info:[[:space:]]+(CPE_LT|CPE_FF|RAM_HALF|SERDES|CPE_RAMIO|GPIO|IOSEL|CLKIN|GLBOUT):" $B/pnr.log | head -10 | sed 's/^Info:[[:space:]]*/  /'
  grep -E "Max frequency for clock" $B/pnr.log | awk -F"clock" '{k=$2; sub(/:.*/,"",k); last[k]=$0} END{for(k in last) print "  POSTROUTE" last[k]}' | sed -E 's/(Info|ERROR|Warning): //'
  grep -E "nextpnr rc=|ERROR: " $B/pnr.log | head -3 || true
  [ -s $B/$NAME.bit ] && echo "  bit $B/$NAME.bit $(stat -c %s $B/$NAME.bit) B sha256 $(sha256sum $B/$NAME.bit | cut -c1-16)"; } | tee mjerenja/$NAME.txt
