#!/usr/bin/env python3
"""gen_harness.py — omotač za mjerenje Fmax jednog modula na GateMateu bez stotina IO-a (TASK-6161).

Svi ulazi modula (osim taktova) dolaze iz posmičnog registra punjenog s jednog pina, svi izlazi
se registriraju i XOR-sažmu u jedan izlazni pin. Tako su svi putovi u modulu reg→reg, a broj
GPIO-a ostaje 3 + broj taktova.

  gen_harness.py <ports.json> <modul> --clk clk[,uclk] [--param N=4 ...] > harness.v

<ports.json> je `write_json` iz yosysa nakon `hierarchy -top <modul>`.
"""
import argparse
import json
import sys

ap = argparse.ArgumentParser()
ap.add_argument("ports_json")
ap.add_argument("module")
ap.add_argument("--clk", required=True, help="imena taktnih portova, zarezom")
ap.add_argument("--param", action="append", default=[], help="IME=VRIJEDNOST za instancu")
a = ap.parse_args()

mods = json.load(open(a.ports_json))["modules"]
name = next(k for k in mods if k == a.module or k.startswith("$paramod") and a.module in k)
ports = mods[name]["ports"]
clks = [c for c in a.clk.split(",") if c]
missing = [c for c in clks if c not in ports]
if missing:
    sys.exit(f"nema taktnog porta {missing} u {a.module}")

ins = [(p, len(v["bits"])) for p, v in ports.items() if v["direction"] == "input" and p not in clks]
outs = [(p, len(v["bits"])) for p, v in ports.items() if v["direction"] == "output"]
nin = sum(w for _, w in ins) or 1
c0 = clks[0]

o = []
o.append(f"// generirano: gen_harness.py {a.module} --clk {a.clk}")
o.append("module harness (")
o += [f"    input wire {c}," for c in clks]
o.append("    input wire h_si, output reg h_so);")
o.append(f"    reg [{nin - 1}:0] h_sr = 0;")
o.append(f"    always @(posedge {c0}) h_sr <= {{h_sr[{max(nin - 2, 0)}:0], h_si}};" if nin > 1
         else f"    always @(posedge {c0}) h_sr <= h_si;")
for p, w in outs:
    o.append(f"    wire [{w - 1}:0] o_{p};")
params = ", ".join(f".{kv.split('=', 1)[0]}({kv.split('=', 1)[1]})" for kv in a.param)
o.append(f"    {a.module} {('#(' + params + ') ') if params else ''}dut (")
conn = [f"        .{c}({c})" for c in clks]
off = 0
for p, w in ins:
    conn.append(f"        .{p}(h_sr[{off + w - 1}:{off}])")
    off += w
conn += [f"        .{p}(o_{p})" for p, _ in outs]
o.append(",\n".join(conn))
o.append("    );")
# izlazi: registar po taktu (svi na c0 — putevi iz drugih domena izlaze kao cross-domain u nextpnr-u)
cat = ", ".join(f"o_{p}" for p, _ in outs) or "1'b0"
nout = max(sum(w for _, w in outs), 1)
ng = (nout + 15) // 16
o.append(f"    reg [{nout - 1}:0] h_oq; reg [{ng - 1}:0] h_x; integer h_i;")
o.append(f"    always @(posedge {c0}) begin h_oq <= {{{cat}}};")
o.append(f"        for (h_i = 0; h_i < {ng}; h_i = h_i + 1) h_x[h_i] <= ^((h_oq >> (16 * h_i)) & 16'hFFFF);")
o.append("        h_so <= ^h_x; end")
o.append("endmodule")
print("\n".join(o))
