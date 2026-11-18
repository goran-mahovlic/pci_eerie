#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-P-2.0
# Simulacija petlje: LD (ECP5 shim + model DCU FF sučelja + pci_eerie EP) <-> pci_eerie RP. Upotreba: sim/run_ld_loop.sh [+shift] [+vcd]
set -euo pipefail
cd "$(dirname "$0")/.."
# OSS=<oss-cad-suite> (neobavezno; inače yosys/nextpnr/iverilog iz PATH-a)
[ -n "${OSS:-}" ] && export PATH=$OSS/bin:$PATH
mkdir -p build/sim
EER=../rtl
# top_ld_eerie.v: u simulaciju ide samo ld_eerie_core (DCUA/EXTREFB/CLKDIVF nisu modelirani)
sed -n '/^module ld_eerie_core/,$p' rtl/top_ld_eerie.v > build/sim/ld_eerie_core.v
iverilog -g2005 -DLD_SHIM -I$EER -Irtl -o build/sim/tb_ld_loop.vvp -s tb_loop \
  sim/tb_loop.v sim/pipe_phy_model.v sim/dcua_ff_model.v build/sim/ld_eerie_core.v rtl/eerie_ecp5_pipe.v rtl/eerie_dbg_uart.v \
  rtl/eerie_ram_sdp.v rtl/eerie_x1_core.v rtl/eerie_bar0_app.v rtl/eerie_x1_ep.v $(sed "s|^|$EER/|" $EER/files.f)
cd build/sim && vvp -n tb_ld_loop.vvp "$@"
