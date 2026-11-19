#!/usr/bin/env bash
# TASK-6173: jedinični testovi W16: eerie_scr16 (i scr8) prema serijskom modelu po simbolu; eerie_skp_eb16 na 0, +-300, +-600 ppm.
set -euo pipefail
cd "$(dirname "$0")/.."
OSS=${OSS:-$(cd "$(dirname "$(command -v iverilog)")/.." && pwd)}; export PATH=$OSS/bin:$PATH
E=../rtl; B=build/sim/unit; mkdir -p $B; R=0
iverilog -g2005 -DEERIE_SCR8_MAT -DEERIE_SCR8_PTREE -I$E -o $B/scr16.vvp sim/tb_scr16_eq.v $E/eerie_scr16.v $E/eerie_scr8.v
o=$(vvp -n $B/scr16.vvp | grep -E "PASS|FAIL"); echo "scr16: $o"; case $o in PASS*) ;; *) R=1;; esac
iverilog -g2005 -I$E -o $B/eb16.vvp -s tb_skp_eb16 sim/tb_skp_eb16.v $E/eerie_skp_eb16.v
for p in ${PPM_LIST:-0 300 -300 600 -600}; do
  o=$(cd $B && vvp -n eb16.vvp +ppm=$p +nw=${NW:-30000} | tr "\n" " " | grep -oE "ppm=.*(PASS|FAIL)"); echo "eb16: $o"; case $o in *PASS*) ;; *) R=1;; esac
done
exit $R
