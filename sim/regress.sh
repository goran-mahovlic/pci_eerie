#!/bin/bash
# SPDX-License-Identifier: CERN-OHL-P
# run several pci_eerie simulations in parallel and summarize
#   sim/regress.sh "<env> <test> [plusargs]" ...      e.g.  "GEN2=1 pio_writeReadBack_test0"
#                                                      (CFG=baseline: PCIE_2_1 endpoint, RP=eerie:
#                                                      pci_eerie root port; see run.sh)
#   sim/regress.sh                                     the full regression (9 runs, about 10-30 min
#                                                      each, all in parallel; needs ~9 cores, ~5 GB)
#   sim/regress.sh rp [baseline|eerie]                 the same 9 runs plus rp_cfg_dump and rp_link_test
#                                                      with pci_eerie as the root port (RP=eerie) and the
#                                                      given endpoint core (default eerie)
#   sim/regress.sh ml                                  multi-lane: ml_width_test at x2 / x4, Gen1 / Gen2,
#                                                      pci_eerie endpoint and root port, and down-training
HERE=$(cd "$(dirname "$0")" && pwd)
PRE=""
if [ "$1" = ml ]; then
  T="SIMTIME=600000ns ml_width_test"
  set -- "CFG=eerie EP_LANES=4 $T" "CFG=eerie EP_LANES=4 GEN2=1 $T" \
         "CFG=eerie EP_LANES=2 $T" "CFG=eerie EP_LANES=2 GEN2=1 $T" \
         "RP=eerie CFG=baseline EP_LANES=4 $T" "RP=eerie CFG=baseline EP_LANES=4 GEN2=1 $T" \
         "RP=eerie CFG=eerie EP_LANES=4 $T" "RP=eerie CFG=eerie EP_LANES=4 GEN2=1 $T" \
         "CFG=eerie EP_LANES=4 RP_LANES=1 $T" "CFG=eerie EP_LANES=4 RP_LANES=2 $T" \
         "RP=eerie CFG=baseline EP_LANES=1 RP_LANES=4 $T" "RP=eerie CFG=baseline EP_LANES=2 RP_LANES=4 $T"
fi
if [ "$1" = rp ]; then PRE="RP=eerie CFG=${2:-eerie} "; set --; fi
if [ $# -eq 0 ]; then
  set -- "pio_writeReadBack_test0" \
         "GEN2=1 pio_writeReadBack_test0" \
         "APP=1 eerie_mem_test" \
         "APP=1 GEN2=1 eerie_mem_test" \
         "APP=1 SIMTIME=500000ns eerie_int_test" \
         "APP=1 SIMTIME=600000ns eerie_ur_test" \
         "SIMTIME=900000ns eerie_cfg_dump" \
         "SIMTIME=800000ns eerie_stress_test -testplusarg inject_rx_tlp=12 -testplusarg inject_tx_tlp=9" \
         "GEN2=1 SIMTIME=800000ns eerie_stress_test -testplusarg inject_rx_tlp=20 -testplusarg inject_tx_tlp=15"
  if [ -n "$PRE" ]; then
    set -- "$@" "SIMTIME=900000ns rp_cfg_dump" "SIMTIME=2000000ns rp_link_test"
    specs=(); for a in "$@"; do specs+=("$PRE$a"); done; set -- "${specs[@]}"
  fi
fi
i=0
for spec in "$@"; do
  envs=""; args=(); cfg=eerie
  for w in $spec; do
    if [[ $w =~ ^CFG= ]]; then cfg=${w#CFG=}
    elif [[ $w =~ ^[A-Z_][A-Z0-9_]*= ]]; then envs="$envs $w"; else args+=("$w"); fi
  done
  tag=${BUILD_TAG_PREFIX:-}r$i
  ( env $envs BUILD_TAG=$tag "$HERE/run.sh" $cfg "${args[@]}" > "$HERE/regress_$tag.out" 2>&1 ) &
  echo "$tag: $spec"
  i=$((i+1))
done
wait
P=${BUILD_TAG_PREFIX:-}
for ((j=0; j<i; j++)); do
  # the stock system check prints two "FAILED" lines in every run (it expects the example
  # design's device ID); a passing run has completed=1 and failure_lines=2
  r=$(grep -c "Test Completed Successfully" "$HERE/regress_${P}r$j.out")
  f=$(grep -ciE "FAILED|ERROR|TIMEOUT" "$HERE/regress_${P}r$j.out")
  echo "${P}r$j: completed=$r failure_lines=$f"
done
