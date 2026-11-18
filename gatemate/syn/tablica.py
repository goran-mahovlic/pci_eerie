#!/usr/bin/env python3
"""tablica.py — markdown tablica iz mjerenja/*.txt (gm_mjeri.sh): ime, opcije, CPE_LT, CPE_FF, RAM, Fmax po taktu (TASK-6161)."""
import glob, re, sys, os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
print("| pokus | top | opcije (-D) | sjeme | CPE_LT | CPE_FF | CPE_RAMIO | RAM_HALF | Fmax nakon rutiranja |")
print("|---|---|---|---|---:|---:|---:|---:|---|")
for f in sorted(glob.glob("mjerenja/*.txt")):
    t = open(f).read()
    h = re.search(r"# (\S+): top=(\S+) freq=\S+ MHz seed=(\d+) defs='([^']*)'", t)
    if not h: continue
    g = lambda k: (re.search(rf"{k}:\s+(\d+)/", t) or [None, "—"])[1]
    fm = re.findall(r"clock '([^']+)': ([\d.]+) MHz \((PASS|FAIL)", t)
    fs = "; ".join(f"{c.split('.')[-1]} {v} {r}" for c, v, r in fm) or ("nije rutirano" if "rc=" in t else "—")
    if "rc=143" in t or "NAPOMENA: rutiranje prekinuto" in t: fs += " (procjena, rutiranje prekinuto)"
    print(f"| {h[1]} | {h[2]} | {h[4].replace('EERIE_','') or '—'} | {h[3]} | {g('CPE_LT')} | {g('CPE_FF')} | {g('CPE_RAMIO')} | {g('RAM_HALF')} | {fs} |")
