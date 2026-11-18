#!/usr/bin/env bash
# Simulacija petlje RP(original, 16b@125) <-> EP(pci_eerie EERIE_W8, 64b@31,25) (TASK-6161).
#   sim/run_w8.sh [-DOPCIJA ...] [-- +shift=N +vcd]
set -euo pipefail
cd "$(dirname "$0")/.."
OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}   # oss-cad-suite root (measured: 2026-11-17)
export PATH=$OSS/bin:$PATH
DEFS=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do DEFS+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
mkdir -p build/sim; flock build/sim/rp.lock sim/mk_rp.sh > /dev/null
E=../rtl
iverilog -g2005 -DEERIE_W8 "${DEFS[@]}" -I$E -Irtl -Ibuild/sim/rp -o build/sim/tb_w8_$$.vvp -s tb_w8 ${DBG:+-s dbg_w8 sim/dbg_w8.v} \
  sim/tb_w8.v sim/pipe_phy_w8.v sim/pipe_phy_model.v rtl/eerie_ram_sdp.v rtl/eerie_w8_core.v \
  rtl/eerie_bar0_app.v rtl/eerie_w8_ep.v $(sed "s|^|$E/|" $E/files.f) $(cat build/sim/rp/files.lst)
cd build/sim && timeout ${SIM_TMO:-600} vvp -n tb_w8_$$.vvp "$@"
