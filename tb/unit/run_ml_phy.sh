#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-P
# multi-lane PHY loopback unit test: tb/unit/run_ml_phy.sh [W] [SKEW hex, e.g. 00010302]
set -e
HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/../../rtl" && pwd)
W=${1:-4}; SKEW=${2:-00010302}
source ${VIVADO:-/opt/Xilinx/Vivado/2023.2}/settings64.sh >/dev/null
B=$HERE/build_w${W}_$SKEW${TAG:+_$TAG}; mkdir -p $B; cd $B
xvlog --sv -i $R $R/eerie_pl_tx.v $R/eerie_pl_tx_ml.v $R/eerie_pl_rx.v $R/eerie_pl_deskew.v $R/eerie_pl_rx_ml.v \
      $HERE/ml_phy_tb.v > xvlog.log 2>&1 || { grep ERROR xvlog.log; exit 1; }
xelab --debug off ml_phy_tb -generic_top "W=$W" -generic_top "SKEW=32'h$SKEW" -s tb > xelab.log 2>&1 || { grep ERROR xelab.log; exit 1; }
xsim tb -R ${PLUSARGS} > sim.log 2>&1 || true
grep -E "ERR|ml_phy_tb W=|elastic" sim.log | head -${MAXLINES:-30}
