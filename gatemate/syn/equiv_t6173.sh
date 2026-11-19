#!/usr/bin/env bash
# TASK-6173: the modules changed for EERIE_W16 / EERIE_1CLK are equivalent to the previous commit (W8 state, itself
# equivalent to upstream 6bfb5ef without defines, TASK-6161) when built without EERIE_W16 / EERIE_1CLK:
# with no defines and with EERIE_W8. yosys equiv_make + equiv_simple -seq 2 + equiv_induct -seq 2, all $equiv proven.
#   syn/equiv_t6173.sh [git-ref, default 1e67e34]
set -uo pipefail
cd "$(dirname "$0")/.."
REF=${1:-2e68ff9}; OSS=${OSS:-$(cd "$(dirname "$(command -v yosys)")/.." && pwd)}; export PATH=$OSS/bin:$PATH
B=build/equiv; rm -rf $B; mkdir -p $B/gold; R=0
git -C .. archive $REF rtl | tar -x -C $B/gold
for cfg in "none:" "w8:-DEERIE_W8"; do n=${cfg%%:*}; D=${cfg#*:}
  for m in eerie_ltssm eerie_dll eerie_async_fifo; do
    yosys -q -l $B/${m}_$n.log -p "
      read_verilog -sv $D -I$B/gold/rtl $B/gold/rtl/$m.v; hierarchy -top $m; proc; memory; opt_clean; rename $m gold; design -stash gold
      read_verilog -sv $D -I../rtl ../rtl/$m.v; hierarchy -top $m; proc; memory; opt_clean; rename $m gate; design -stash gate
      design -copy-from gold -as gold gold; design -copy-from gate -as gate gate
      equiv_make gold gate eq; hierarchy -top eq; equiv_simple -seq 2; equiv_induct -seq 2; equiv_status -assert" > /dev/null 2>&1
    rc=$?; st=$(grep -a "Found .* \$equiv cells\|unproven" $B/${m}_$n.log | tail -2 | tr '\n' ' ')
    echo "$m [$n]: $([ $rc = 0 ] && echo PROVEN || echo FAIL) $st"; [ $rc = 0 ] || R=1
  done
  # eerie_async_fifo as the packet FIFO (tx_fifo: W 67, AW 7, PKT_MODE 1); fork: gold = gatemate-w8
  yosys -q -l $B/fifo_pkt_$n.log -p "
    read_verilog -sv $D $B/gold/rtl/eerie_async_fifo.v; hierarchy -top eerie_async_fifo -chparam W 67 -chparam AW 7 -chparam PKT_MODE 1; proc; memory; opt_clean; rename eerie_async_fifo gold; design -stash gold
    read_verilog -sv $D ../rtl/eerie_async_fifo.v; hierarchy -top eerie_async_fifo -chparam W 67 -chparam AW 7 -chparam PKT_MODE 1; proc; memory; opt_clean; rename eerie_async_fifo gate; design -stash gate
    design -copy-from gold -as gold gold; design -copy-from gate -as gate gate
    equiv_make gold gate eq; hierarchy -top eq; equiv_simple -seq 2; equiv_induct -seq 2; equiv_status -assert" > /dev/null 2>&1
  rc=$?; echo "eerie_async_fifo W67 AW7 PKT_MODE1 [$n]: $([ $rc = 0 ] && echo PROVEN || echo FAIL) $(grep -a "Found .* \$equiv cells" $B/fifo_pkt_$n.log | tail -1)"; [ $rc = 0 ] || R=1
  # pci_eerie: the preprocessed text, the W16/1CLK additions excluded by the preprocessor
  for f in gold/rtl/eerie/pci_eerie.v; do :; done
  iverilog -E $D -I$B/gold/rtl -o $B/pe_gold_$n.v $B/gold/rtl/pci_eerie.v
  iverilog -E $D -I../rtl -o $B/pe_gate_$n.v ../rtl/pci_eerie.v
  d=$(diff <(grep -v '^\s*$' $B/pe_gold_$n.v) <(grep -v '^\s*$' $B/pe_gate_$n.v) | grep -c '^[<>]')
  echo "pci_eerie [$n]: preprocessed text, $d differing lines"; diff <(grep -v '^\s*$' $B/pe_gold_$n.v) <(grep -v '^\s*$' $B/pe_gate_$n.v) | head -12
done
exit $R
