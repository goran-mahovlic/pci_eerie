#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-P-2.0
# Simulacija eerie_dbg_uart: 3 retka, provjera formata i brojača (TASK-6160).
set -euo pipefail
cd "$(dirname "$0")/.."
# OSS=<oss-cad-suite> (neobavezno; inače yosys/nextpnr/iverilog iz PATH-a)
[ -n "${OSS:-}" ] && export PATH=$OSS/bin:$PATH
mkdir -p build/sim
iverilog -g2005 -o build/sim/tb_dbg_uart.vvp -s tb_dbg_uart sim/tb_dbg_uart.v rtl/eerie_dbg_uart.v
vvp -n build/sim/tb_dbg_uart.vvp | tr -d '\r' | tee build/sim/dbg_uart.txt
L=$(grep -a "^La " build/sim/dbg_uart.txt | tail -1 | sed "s/ *sim\/.*$/ /")
ok=1
[[ $L =~ ^La\ f=[0-9a-f]{2}\ l=[0-9a-f]{2}\ p=[0-9a-f]{2}\ K=[0-9a-f]{8}\ 1=[0-9a-f]{8}\ 2=[0-9a-f]{8}\ i=[0-9a-f]{8}\ v=[0-9a-f]{8}\ e=[0-9a-f]{8}\ c=[0-9a-f]{8}\ s=[0-9a-f]{16}\ $ ]] || { echo "FAIL format: '$L'"; ok=0; }
for e in 'f=d5' 'K=000003e8' '1=000003e8' '2=00000000' 'i=00000064' 'v=000003e8' 'e=00000096' 'c=00000032' 'p=02' 's=0000000000000089'; do
  [[ $L == *"$e"* ]] || { echo "FAIL $e"; ok=0; }
done
NT=$(grep -ac "^Ta [0-9a-f]\{3\} [0-9a-f]\{8\}$" build/sim/dbg_uart.txt)
[[ $NT == 1024 ]] || { echo "FAIL snimač: $NT redaka T (treba 1024)"; ok=0; }
grep -aq " 0e04a1bc$" build/sim/dbg_uart.txt || { echo "FAIL snimač: nema riječi prije okidača (0e04a1bc)"; ok=0; }
grep -aq " 1d0b5800$" build/sim/dbg_uart.txt || { echo "FAIL snimač: nema riječi poslije okidača (1d0b5800)"; ok=0; }
[[ $(grep -a "^Ta 000 " build/sim/dbg_uart.txt | cut -c8-9) == 0e ]] || { echo "FAIL snimač: najstarija riječ nije prije okidača"; ok=0; }
grep -q "DIFF=1" build/sim/dbg_uart.txt || { echo "FAIL drugi izlaz nema vlastitu oznaku"; ok=0; }
((ok)) && echo "PASS dbg_uart" || exit 1
