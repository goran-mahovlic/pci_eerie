#!/usr/bin/env bash
# TASK-6170: pci_eerie W8 EP behind ONE ccfpga_serdes (openSERDES_BFM) on the serial line, against
# openPCIE_BFM's Artix-7 RC model (59 rules). Verilator.
#   sim/ser/run_ser.sh [build|run] [+ppm=N] [+verilator+seed+N]     env: SRNS=1 (EB2 path), A7RC=1|0, NAME=obj dir
set -euo pipefail
cd "$(dirname "$0")/../.."
R=$PWD; BFM=$R/ext/openPCIE_BFM; SBFM=$R/ext/openSERDES_BFM/1.gatemate/1.model
OSS=${OSS:-$(cd "$(dirname "$(command -v verilator)")/.." && pwd)}; export PATH=$OSS/bin:$PATH   # measured: oss-cad-suite 2026-11-17
A7RC=${A7RC:-1}; SRNS=${SRNS:-0}; CDR=${CDR:-FAST}
NAME=${NAME:-ser_a${A7RC}_s${SRNS}_${CDR}}; O=$R/build/sim/$NAME; mkdir -p "$O"
VIP_DIR=$(VIP_PATCH=$BFM/1.upstream/patches/pcievhost-speed.patch VPROC_PATCH=$BFM/1.upstream/patches/vproc-coroutine.patch \
          VIP_BUILD=$R/build/vip bash $BFM/4.build/build-vip.sh)
EOPTS="EERIE_W8 EERIE_DLL_CRCPRE EERIE_ML_CRCMAT EERIE_ML_DLCPRE EERIE_ML_QREG EERIE_ML_ADUP EERIE_ML_KPRE EERIE_ML_CDUP \
       EERIE_W8_IDLEPRE EERIE_W8_PAPRE EERIE_SCR8_MAT EERIE_SCR8_PTREE EERIE_SKP_EB2 ${FIX_DEFS-EERIE_W8_SKP1 EERIE_DLL_FCSET} ${EXTRA_DEFS:-}"
DEFS="-DVPROC -DEXCLUDE_LTSSM -DVPROC_SV -DRC_GEN=2 -DA7RC_LITERAL=$A7RC -DA7RC_EP_EXPECT=\"a7rc_eerie.h\" -DSIM_SERIAL -DA7RC_NO_DMA"
INC="-I$R/sim/ser -I$BFM/3.sw/a7rc -I$VIP_DIR/include"
if [ "${1:-build}" = build ] || [ ! -x "$O/Vtb" ]; then
  g++ -c -fPIC -O2 -std=c++20 -Wno-write-strings $DEFS $INC $BFM/3.sw/a7rc/VUserMain2.cpp -o $O/VUserMain2.o
  g++ -c -fPIC -O2 -std=c++20 -Wno-write-strings $DEFS $INC $BFM/3.sw/a7rc/a7rc_check.cpp -o $O/a7rc_check.o
  gcc -c -fPIC -O2 $DEFS $INC $BFM/3.sw/ltssm/ltssm.c -o $O/ltssm.o
  rm -f $O/libuser.a; ar cr $O/libuser.a $O/VUserMain2.o $O/a7rc_check.o $O/ltssm.o
  { for d in $EOPTS; do echo "+define+$d"; done; [ "$SRNS" = 1 ] && echo "+define+SRNS"; echo "+define+CDR_MODEL=$CDR"
    echo "+incdir+$VIP_DIR/hdl/headers"; echo "+incdir+$VIP_DIR/hdl"; echo "$VIP_DIR/hdl/headers/allheaders.svh"
    echo "$VIP_DIR/hdl/f_VProc.sv"; echo "$VIP_DIR/hdl/clkmux.sv"; echo "$VIP_DIR/hdl/Serialiser.sv"; echo "$VIP_DIR/hdl/pcieVHost.sv"
    echo "$SBFM/ccfpga_serdes_pkg.sv"; echo "$SBFM/ccfpga_serdes.BFM.sv"
    echo "+incdir+$R/../rtl"; sed "s|^|$R/../rtl/|" $R/../rtl/files.f; echo "$R/../rtl/eerie_skp_eb.v"
    echo "+incdir+$R/rtl"; echo "+incdir+$R/rtl"
    for f in rtl/eerie_ram_sdp.v rtl/eerie_w8_core.v rtl/eerie_bar0_app.v rtl/eerie_w8_ep.v rtl/eerie_bufg.v rtl/eerie_ccs_phy.v; do echo "$R/$f"; done
    echo "$R/sim/ser/ser_retimer.sv"; echo "$R/sim/ser/tb_ser.sv"; } > $O/files.f
  verilator --binary -sv --timing --timescale 1ns/1ps --top-module tb -Mdir $O/obj -j 8 \
    -Wno-fatal -Wno-WIDTH -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT +define+VPROC_SV +define+VPROC_BYTE_ENABLE \
    -f $O/files.f -MAKEFLAGS "--quiet CFG_LDFLAGS_VERILATED=" -CFLAGS "-std=c++20 -Wno-attributes" \
    -LDFLAGS "-Wl,-whole-archive $O/libuser.a -Wl,-no-whole-archive -L$VIP_DIR/lib -lcosimlnx -lpcielnx -lpthread -lrt -ldl -rdynamic" \
    > $O/verilator.log 2>&1 || { tail -40 $O/verilator.log; exit 1; }
  cp $O/obj/Vtb $O/Vtb
fi
MODE=${1:-build}; [ $# -gt 0 ] && shift; [ "$MODE" = build ] && [ $# -eq 0 ] && exit 0
D=$O/run_$$; mkdir -p $D/hex; cp $BFM/5.sim-regression/hex/ContDisps.hex $D/hex/
cd $D && A7RC_SEED=${SEED:-1} timeout ${SIM_TMO:-3600} $O/Vtb "$@"
