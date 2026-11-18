#!/usr/bin/env python3
"""gen_lfsr_mat.py — eksplicitne XOR maske za PCIe Gen1 LFSR (x^16+x^5+x^4+x^3+1, f_lfsr_adv8 / f_lfsr_byte):
f_lfsr_m<n>(l) = ADV8^n(l), f_lfsr_b<n>(l) = scramble bajt od ADV8^n(l), n = 0..8. Izlaz: ../rtl/eerie_lfsrmat.vh
(TASK-6161, opcija EERIE_SCR8_MAT u eerie_scr8: jedna ravna matrica po kandidatu umjesto n ulančanih koraka)."""
def step(x): return ((x << 1) & 0xFFFF) ^ (0x0039 if x & 0x8000 else 0)
def adv8(x):
    for _ in range(8): x = step(x)
    return x
def byte(x):
    o = 0
    for i in range(8):
        o |= (x >> 15 & 1) << i; x = step(x)
    return o
def advn(x, n):
    for _ in range(n): x = adv8(x)
    return x
def masks(f, nout):
    cols = [f(1 << j) for j in range(16)]
    return [sum(1 << j for j in range(16) if cols[j] >> i & 1) for i in range(nout)]
out = ["// generirano: syn/gen_lfsr_mat.py — PCIe LFSR ADV8^n i scramble bajt, TASK-6161"]
for n in range(9):
    for nm, f, w in ((f"f_lfsr_m{n}", lambda x, n=n: advn(x, n), 16), (f"f_lfsr_b{n}", lambda x, n=n: byte(advn(x, n)), 8)):
        out.append(f"function [{w-1}:0] {nm};\n  input [15:0] l;\n  begin")
        for i, m in enumerate(masks(f, w)):
            out.append(f"    {nm}[{i}] = ^(l & 16'h{m:04X});")
        out.append("  end\nendfunction")
open("../rtl/eerie_lfsrmat.vh", "w").write("\n".join(out) + "\n")
print("ok")
