#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-P-2.0
# Simulacija petlje EP<->RP (iverilog). Upotreba: sim/run_loop.sh [+shift] [+vcd]
set -euo pipefail
cd "$(dirname "$0")/.."
# OSS=<oss-cad-suite> (neobavezno; inače yosys/nextpnr/iverilog iz PATH-a)
[ -n "${OSS:-}" ] && export PATH=$OSS/bin:$PATH
mkdir -p build/sim
EER=../rtl
iverilog -g2005 -I$EER -Irtl -o build/sim/tb_loop.vvp -s tb_loop \
  sim/tb_loop.v sim/pipe_phy_model.v rtl/eerie_ram_sdp.v rtl/eerie_x1_core.v rtl/eerie_bar0_app.v rtl/eerie_x1_ep.v \
  $(sed "s|^|$EER/|" $EER/files.f)
cd build/sim && vvp -n tb_loop.vvp "$@"
