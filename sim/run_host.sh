#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-P
# Root port hardware test design in xsim (tb/host_tb.v): syn/eerie_host_rp.v (Vivado root port core
# with pci_eerie) driven through its register bus against a multi-lane endpoint.
# usage: sim/run_host.sh [ep_config]     ep_config: eerie (default) or baseline (PCIE_2_1 endpoint)
#   env: RP_LANES (4), EP_LANES (2), GEN2 (1), PCIE_EX as sim/run.sh
set -e
EPCFG=${1:-eerie}
HERE=$(cd "$(dirname "$0")" && pwd)
EERIE=$(cd "$HERE/.." && pwd)
PCIE_EX=$(cd "${PCIE_EX:-$EERIE/../pcie_7x_0_ex/imports}" 2>/dev/null && pwd) || true
[ -e "$PCIE_EX/pcie_2_1_rport_7x.v" ] || { echo "root port example imports not found: set PCIE_EX" >&2; exit 1; }
VIVADO=${VIVADO:-/opt/Xilinx/Vivado/2023.2}
source $VIVADO/settings64.sh >/dev/null
RL=${RP_LANES:-4}; EL=${EP_LANES:-2}; G2=${GEN2:-1}
B=$HERE/build_host_${EPCFG}_rp${RL}_ep${EL}_g$G2${OXC_BRAM:+_oxc}${BUILD_TAG:+_$BUILD_TAG}; mkdir -p $B; cd $B
sed 's/^\(\s*\)PCIE_2_1 #(  \/\/ Verilog-2001/\1pci_eerie #(/' "$PCIE_EX/pcie_2_1_rport_7x.v" > pcie_2_1_rport_7x_eerie.v
[ "$(grep -c '^\s*pci_eerie #(' pcie_2_1_rport_7x_eerie.v)" = 1 ] || { echo "root port PCIE_2_1 instance not found" >&2; exit 1; }
sed -E 's/\brp_([A-Za-z0-9_]+)\b/ep_\1/g; s/\bpcie_2_1_rport_7x\b/pcie_2_1_ep_7x/g' "$PCIE_EX/pcie_2_1_rport_7x.v" > pcie_2_1_ep_7x.v
[ "$EPCFG" = eerie ] && sed -i 's/^\(\s*\)PCIE_2_1 #(  \/\/ Verilog-2001/\1pci_eerie #(/' pcie_2_1_ep_7x.v
# OXC_BRAM=1: endpoint core with syn/oxc_pcie_bram_7x.v (the openXC7 BRAM substitute) instead of its own
EXTRA=""
if [ "${OXC_BRAM:-0}" = 1 ]; then
  sed -i 's/^module ep_pcie_bram_7x$/module ep_pcie_bram_7x_vivado/' pcie_2_1_ep_7x.v; EXTRA=$EERIE/syn/oxc_pcie_bram_7x.v
fi
{
  echo "verilog xil_defaultlib --include \"$EERIE/rtl\" --include \"$EERIE/tb\" \\"
  for f in $(cat $EERIE/rtl/files.f); do echo "\"$EERIE/rtl/$f\" \\"; done
  for f in $B/pcie_2_1_rport_7x_eerie.v $B/pcie_2_1_ep_7x.v $EERIE/tb/eerie_tb_ep_ml.v $EERIE/tb/eerie_tb_app.v \
           $EERIE/syn/eerie_host_app.v $EERIE/syn/eerie_host_rp.v $EXTRA; do echo "\"$f\" \\"; done
  echo "\"$EERIE/tb/host_tb.v\""
  echo "verilog xil_defaultlib \"$VIVADO/data/verilog/src/glbl.v\""
  echo "nosort"
} > files.prj
xvlog --incr --relax -d RP_LANES=$RL -d EP_LANES=$EL -d GEN2=$G2 -d TIMEOUT_NS=${TIMEOUT_NS:-3000000} -prj files.prj > xvlog.log 2>&1 \
  || { grep -E "ERROR" xvlog.log | head -40; exit 1; }
xelab --incr --debug typical --relax --mt 8 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -L xpm \
  --snapshot host_tb xil_defaultlib.host_tb xil_defaultlib.glbl -log xelab.log > /dev/null 2>&1 \
  || { grep -E "ERROR" xelab.log | head -40; exit 1; }
echo "run all; quit" > run.tcl
xsim host_tb -tclbatch run.tcl -log sim.log > /dev/null 2>&1 || true
grep -E "HOST:" sim.log
