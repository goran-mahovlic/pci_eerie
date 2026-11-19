#!/usr/bin/env bash
# TASK-6173: EERIE_W16 endpoint (gs_w16_ep_1clk: PIPE = user clock, every port through the gen_harness.py shift
# registers) on CCGM1A1 at 31.25 MHz (5.0 GT/s), the same flow as the W8 F1 measurement (synth_gatemate
# -luttree -nomx8, nextpnr-himbaechel --tmg-ripup). Results: mjerenja/<NAME>.txt
#   SEED=1 syn/w16_pnr.sh W16A_s1
set -euo pipefail
cd "$(dirname "$0")/.."
ALL="EERIE_W16 EERIE_1CLK EERIE_LTSSM_SPDDN EERIE_DLL_CRCPRE EERIE_ML_CRCMAT EERIE_ML_DLCPRE EERIE_ML_QREG EERIE_ML_ADUP EERIE_ML_KPRE \
     EERIE_ML_CDUP EERIE_DLL_FCSET ${EXTRA_DEFS:-}"
PNR_OPTS=${PNR_OPTS---tmg-ripup} GM_DEFS="$ALL" syn/gm_modul.sh "$1" gs_w16_ep_1clk clk 31.25 syn/gs_w16_ep.f
