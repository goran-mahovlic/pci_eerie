#!/usr/bin/env python3
"""gen_lfsr_mat16.py — dopuna gen_lfsr_mat.py za eerie_scr16 (TASK-6173, EERIE_W16): f_lfsr_m<n> za n = 9..16 i
f_lfsr_b<n> za n = 9..15 (n = 0..8 su u eerie_lfsrmat.vh). Izlaz: rtl/eerie/eerie_lfsrmat16.vh"""
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
out = ["// generirano: syn/gen_lfsr_mat16.py — PCIe LFSR ADV8^n (n = 9..16) i scramble bajt (n = 9..15), TASK-6173"]
for n in range(9, 17):
    fl = [(f"f_lfsr_m{n}", lambda x, n=n: advn(x, n), 16)]
    if n < 16: fl.append((f"f_lfsr_b{n}", lambda x, n=n: byte(advn(x, n)), 8))
    for nm, f, w in fl:
        out.append(f"function [{w-1}:0] {nm};\n  input [15:0] l;\n  begin")
        for i, m in enumerate(masks(f, w)):
            out.append(f"    {nm}[{i}] = ^(l & 16'h{m:04X});")
        out.append("  end\nendfunction")
open("rtl/eerie/eerie_lfsrmat16.vh", "w").write("\n".join(out) + "\n")
print("ok")
