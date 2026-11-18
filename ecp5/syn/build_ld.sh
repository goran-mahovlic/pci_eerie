#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-P-2.0
# ULX4M-LD (SerDes/EXTREF pinovi su fiksni, zato --lpf-allow-unconstrained): yosys + nextpnr-ecp5 + ecppack (LFE5UM5G-85F, CABGA381) -> build/ld/top_ld_eerie.bit (TASK-6160).
set -euo pipefail
cd "$(dirname "$0")/.."
# OSS=<oss-cad-suite> (neobavezno; inače yosys/nextpnr/iverilog iz PATH-a)
[ -n "${OSS:-}" ] && export PATH=$OSS/bin:$PATH
SEED=${SEED:-1}
# Zadano (od 18.11. 18:00, pokusi E4+E6 na CM5): LD_IGNORE_LOL=1, LD_IGNORE_POL=1, LD_FORCE_INV=1; stari bit c9c9fc62 = sve 0.
# LD_IGNORE_LOL=1: pokus E4 (RSL ne čeka CDR lock); LD_IGNORE_POL=1: pokus E5 (INV_RX = LD_FORCE_INV, zadano 0); E6: LD_FORCE_INV=1; E7: LD_REQ_OFF=1 (RX EQ isključen); E8: LD_DCBIAS=1; E9: LD_REQ_LVL=0b11
mkdir -p build/ld
EER=../rtl
SRC="$(sed "s|^|$EER/|" $EER/files.f | tr '\n' ' ') rtl/eerie_ram_sdp.v rtl/eerie_x1_core.v rtl/eerie_bar0_app.v rtl/eerie_x1_ep.v rtl/eerie_ecp5_pipe.v rtl/eerie_dbg_uart.v rtl/top_ld_eerie.v"
yosys -q -l build/ld/synth.log -p "read_verilog -DSYNTHESIS -DLD_IGNORE_LOL=${LD_IGNORE_LOL:-1} -DLD_IGNORE_POL=${LD_IGNORE_POL:-1} -DLD_FORCE_INV=${LD_FORCE_INV:-1} ${LD_REQ_OFF:+-DLD_REQ_OFF} ${LD_DCBIAS:+-DLD_DCBIAS} ${LD_REQ_LVL:+-DLD_REQ_LVL=\"$LD_REQ_LVL\"} -I$EER -Irtl $SRC; synth_ecp5 -top top_ld_eerie -json build/ld/top.json"
nextpnr-ecp5 --um5g-85k --package CABGA381 --speed 8 --json build/ld/top.json --lpf syn/ld.lpf --lpf-allow-unconstrained \
  --textcfg build/ld/top.config --report build/ld/report.json --seed $SEED -l build/ld/pnr.log >/dev/null 2>&1 || { tail -30 build/ld/pnr.log; exit 1; }
ecppack --compress --idcode 0x81113043 build/ld/top.config build/ld/top_ld_eerie.bit
grep -E "Max frequency|Info: Device utilisation|TRELLIS_COMB|TRELLIS_FF|DP16KD|DCUA|EXTREFB" build/ld/pnr.log | tail -14
sha256sum build/ld/top_ld_eerie.bit
