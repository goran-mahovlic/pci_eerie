#!/usr/bin/env bash
# Root port za simulaciju: IZVORNI pci_eerie 6bfb5ef (16 bita @125 MHz, iz gita ovog repoa) + x1 omotač,
# svi moduli preimenovani s prefiksom rp_ (da u istoj simulaciji živi uz EP s opcijama EERIE_*).
set -euo pipefail
cd "$(dirname "$0")/.."
O=build/sim/rp; rm -rf "$O"; mkdir -p "$O/orig"; : > "$O/files.lst"
(cd .. && git archive 6bfb5ef7b1cc840a302440619b3acd93443967b8 rtl) | tar -x -C "$O/orig"
ORIG=$O/orig/rtl
FILES="$(sed "s|^|$ORIG/|" "$ORIG/files.f") rtl/eerie_ram_sdp.v rtl/eerie_x1_core.v"
MODS=$(grep -hoE "^\s*module\s+[A-Za-z0-9_]+" $FILES | awk '{print $2}' | sort -u)
SED=""; for m in $MODS; do SED="$SED s/\\b$m\\b/rp_$m/g;"; done
for f in $FILES; do sed -E "$SED" "$f" > "$O/rp_$(basename "$f")"; echo "$O/rp_$(basename "$f")" >> "$O/files.lst"; done
cp "$ORIG"/*.vh rtl/eerie_ties.vh "$O/"
cat "$O/files.lst"
