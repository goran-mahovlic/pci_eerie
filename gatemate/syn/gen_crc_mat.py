#!/usr/bin/env python3
"""gen_crc_mat.py — eksplicitne XOR maske za LCRC (reflected EDB88320) napredovanje stanja za n bajtova
nula: c' = M^n · c. Izlaz: ../rtl/eerie_crcmat.vh s f_crc32_adv32 / f_crc32_adv64 (TASK-6161).
Svaki izlazni bit = ^(c & maska) → balansirano XOR stablo, umjesto lanca uvjetnih XOR-ova."""
def byte0(c):
    for _ in range(8):
        c = (c >> 1) ^ (0xEDB88320 if c & 1 else 0)
    return c
def adv(c, n):
    for _ in range(n): c = byte0(c)
    return c
def masks(n):
    cols = [adv(1 << j, n) for j in range(32)]          # stupac j = slika bita j
    return [sum(1 << j for j in range(32) if cols[j] >> i & 1) for i in range(32)]
out = ["// generirano: syn/gen_crc_mat.py — LCRC c' = M^n c (n bajtova nula), TASK-6161"]
for n in (1, 2, 3, 4, 5, 6, 7, 8):
    m = masks(n)
    out.append(f"function [31:0] f_crc32_adv{8*n};\n  input [31:0] c;\n  begin")
    for i in range(32):
        out.append(f"    f_crc32_adv{8*n}[{i}] = ^(c & 32'h{m[i]:08X});")
    out.append("  end\nendfunction")
def dat(d, nbytes):
    # crc(0, D): bajtovi u redoslijedu žice, prvi bajt = najviši (kao f_crc32_dw)
    c = 0
    for k in range(nbytes):
        b = d >> (8 * (nbytes - 1 - k)) & 0xFF
        c = byte0(c ^ b)
    return c
for nb in (1, 2, 3, 4, 8):
    cols = [dat(1 << j, nb) for j in range(8 * nb)]
    out.append(f"function [31:0] f_crc32_dat{8*nb};\n  input [{8*nb-1}:0] d;\n  begin")
    for i in range(32):
        m = sum(1 << j for j in range(8 * nb) if cols[j] >> i & 1)
        out.append(f"    f_crc32_dat{8*nb}[{i}] = ^(d & {8*nb}'h{m:0{2*nb}X});")
    out.append("  end\nendfunction")
# složeno: crc(0, nb bajtova podataka pa nz bajtova nula) = M^nz · dat(d) — jedna ravna matrica umjesto
# dvije ulančane (rx_ml stupanj B: a_g0 -> b_h0_*, kritični put 25,1 MHz na GateMateu)
for nb, nz in ((4, 4), (4, 3), (3, 4), (3, 3)):
    cols = [adv(dat(1 << j, nb), nz) for j in range(8 * nb)]
    fn = f"f_crc32_d{8*nb}z{8*nz}"
    out.append(f"function [31:0] {fn};\n  input [{8*nb-1}:0] d;\n  begin")
    for i in range(32):
        m = sum(1 << j for j in range(8 * nb) if cols[j] >> i & 1)
        out.append(f"    {fn}[{i}] = ^(d & {8*nb}'h{m:0{2*nb}X});")
    out.append("  end\nendfunction")
# DLLP CRC16 (f_crc16_byte, 0x100B, LSB prvi), početna vrijednost FFFF -> afino: out = M·d ^ k
def c16b(c, d):
    for i in range(8):
        fb = (c >> 15 & 1) ^ (d >> i & 1)
        c = ((c << 1) & 0xFFFF) ^ (0x100B if fb else 0)
    return c
def c16(d, nb):
    c = 0xFFFF
    for k in range(nb): c = c16b(c, d >> (8 * (nb - 1 - k)) & 0xFF)
    return c
def rev8(x): return int(f"{x:08b}"[::-1], 2)
def fld(c): return rev8(~c >> 8 & 0xFF) << 8 | rev8(~c & 0xFF)
for fn, nb, f in (("f_crc16_dl3", 3, lambda d: c16(d, 3)), ("f_dllp_fld4", 4, lambda d: fld(c16(d, 4)))):
    k = f(0); cols = [f(1 << j) ^ k for j in range(8 * nb)]
    out.append(f"function [15:0] {fn};   // {nb} bajta od FFFF (prvi bajt = najviši){', polje {wire 4, wire 5}' if nb == 4 else ''}\n  input [{8*nb-1}:0] d;\n  begin")
    for i in range(16):
        m = sum(1 << j for j in range(8 * nb) if cols[j] >> i & 1)
        out.append(f"    {fn}[{i}] = ^(d & {8*nb}'h{m:0{2*nb}X}) ^ 1'b{k >> i & 1};")
    out.append("  end\nendfunction")
open("../rtl/eerie_crcmat.vh", "w").write("\n".join(out) + "\n")
print("ok", [bin(x).count("1") for x in masks(8)][:8])
