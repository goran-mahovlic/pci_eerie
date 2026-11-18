#!/usr/bin/env bash
# Jedinični testovi (TASK-6161): eerie_skp_eb na 7 odstupanja takta i eerie_scr8 izvorno vs EERIE_SCR8_MAT+PTREE.
#   sim/run_unit.sh [skp|scr8|crc16|sve]   (skp ispituje izvorni spremnik; EB2: SKP_DEFS=-DEERIE_SKP_EB2)
set -euo pipefail
cd "$(dirname "$0")/.."
OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}   # oss-cad-suite root (measured: 2026-11-17)
export PATH=$OSS/bin:$PATH
E=../rtl; B=build/sim/unit; mkdir -p $B; R=0
if [ "${1:-sve}" = sve ] || [ "${1:-}" = skp ]; then
  iverilog -g2005 ${SKP_DEFS:-} -I$E -o $B/tb_skp_eb.vvp -s tb_skp_eb sim/tb_skp_eb.v $E/eerie_skp_eb.v
  for p in ${PPM_LIST:-0 300 -300 600 -600}; do   # spec: +-300 ppm po taktu = +-600; PPM_LIST="1000 -1000" za marginu
    o=$(cd $B && vvp -n tb_skp_eb.vvp +ppm=$p | tr "\n" " " | grep -oE "ppm=.*(PASS|FAIL)"); echo "$o"; case $o in *PASS*) ;; *) R=1;; esac
  done
fi
if [ "${1:-sve}" = sve ] || [ "${1:-}" = scr8 ]; then
  sed 's/module eerie_scr8/module scr_gold/' $E/eerie_scr8.v > $B/gold.v
  { echo '`define EERIE_SCR8_MAT'; echo '`define EERIE_SCR8_PTREE'; sed 's/module eerie_scr8/module scr_gate/' $E/eerie_scr8.v
    echo '`undef EERIE_SCR8_MAT'; echo '`undef EERIE_SCR8_PTREE'; } > $B/gate.v
  iverilog -g2005 -I$E -o $B/scr8.vvp sim/tb_scr8_eq.v $B/gold.v $B/gate.v
  o=$(cd $B && vvp -n scr8.vvp | grep -E "PASS|FAIL" | tail -1); echo "scr8: $o"; case $o in PASS*) ;; *) R=1;; esac
fi
if [ "${1:-sve}" = sve ] || [ "${1:-}" = crc16 ]; then
  iverilog -g2005 -I$E -o $B/c16.vvp sim/tb_crc16_mat.v
  o=$(vvp -n $B/c16.vvp | grep -E "PASS|FAIL"); echo "crc16: $o"; case $o in PASS*) ;; *) R=1;; esac
fi
exit $R
