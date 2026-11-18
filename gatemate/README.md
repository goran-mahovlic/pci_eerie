# pci_eerie on GateMate (CCGM1A1): x1 Gen1 with a 64-bit PIPE

Branch `gatemate-w8`. Goal: a PCIe Gen1 x1 endpoint on the Cologne Chip GateMate CCGM1A1
(board ULX5M-GS) using the hard `CC_SERDES` for the analog part, 8b10b, comma alignment, receiver
detection, electrical idle and polarity, and pci_eerie for everything above the PIPE.

**Everything here is a build option. Without any `EERIE_*` define the core is exactly upstream
pci_eerie** (proven with yosys `equiv_make`/`equiv_induct` against 6bfb5ef for the modified modules,
see "Default behaviour" below).

## Why a 64-bit PIPE

On GateMate the stock x1 path (16-bit PIPE at 125 MHz) reaches about 27 MHz after routing
(logic fits: ~69 % CPE). The limit is the per-clock logic depth of the 2-symbol path, not the
SerDes. `EERIE_W8` moves the x1 lane to 8 symbols per clock (64-bit PIPE at 31.25 MHz):

| file | what |
|---|---|
| `rtl/eerie_scr8.v` | 8-symbol (de)scrambler: per-symbol LFSR state chosen from 9 candidates, no 8-step chain |
| `rtl/eerie_pl_rx_w8.v` | x1 RX for 8 symbols/clock: ordered sets (TS1/TS2/EIOS/SKP/idle), packet slot stream |
| `rtl/eerie_pl_tx_w8.v` | x1 TX for 8 symbols/clock: ordered sets, SKP scheduling, packets |
| `rtl/eerie_pl_rx_ml.v` | reused (N=4 framing: 2 DWs per clock) for TLP/DLLP framing and LCRC/CRC16 |
| `rtl/pci_eerie.v`, `rtl/eerie_ltssm.v` | `EERIE_W8` wiring; LTSSM idle count for 8 idle symbols, `US_DIV1` = 30 at 31.25 MHz |
| `rtl/eerie_skp_eb.v` (+ `eerie_skp_eb2.vh`) | SKP elastic buffer in the fabric (the `CC_SERDES` clock correction cannot match PCIe SKP ordered sets) |

## Timing options (one change per experiment, all measured)

| option | module | change |
|---|---|---|
| `EERIE_DLL_CRCPRE` | eerie_dll | TX LCRC: data part precomputed from the RAM output, the feedback is one XOR level |
| `EERIE_ML_CRCMAT` | eerie_pl_rx_ml | LCRC / DLLP CRC16 as flat XOR matrices (`eerie_crcmat.vh`, `gen_crc_mat.py`) |
| `EERIE_ML_DLCPRE` | eerie_pl_rx_ml | DLLP CRC16 and check in stage B |
| `EERIE_ML_QREG` | eerie_pl_rx_ml | output queue written one clock later, together with the LCRC residue, not gated by reset |
| `EERIE_ML_ADUP` | eerie_pl_rx_ml | separate copy of the stage A data for the CRC matrices (fan-out) |
| `EERIE_ML_KPRE` | eerie_pl_rx_ml | K symbol decode before stage A |
| `EERIE_ML_CDUP` | eerie_pl_rx_ml | LCRC selects of stage C as their own registers |
| `EERIE_W8_IDLEPRE` | eerie_pl_rx_w8 | idle run detection with prefix ANDs instead of adder chains |
| `EERIE_W8_PAPRE` | eerie_pl_rx_w8 | in-packet scan for both start states and byte ranks precomputed (2 stages) |
| `EERIE_SCR8_MAT` | eerie_scr8 | LFSR candidates as flat matrices (`eerie_lfsrmat.vh`, `gen_lfsr_mat.py`) |
| `EERIE_SCR8_PTREE` | eerie_scr8 | per-symbol advance counts as balanced popcounts |
| `EERIE_SKP_EB2` | eerie_skp_eb | insert and remove SKP on the write side, read side is a plain FIFO |

Measured numbers (yosys + nextpnr-himbaechel, oss-cad-suite 2026-11-17, CCGM1A1, seed 1/2):
`gatemate/mjerenja/*.txt`, table: `python3 gatemate/syn/tablica.py`. Summary in the section
"Status" below.

## Simulation (iverilog, no Vivado needed)

```
cd gatemate
OPTS="-DEERIE_DLL_CRCPRE -DEERIE_ML_CRCMAT -DEERIE_ML_DLCPRE -DEERIE_ML_QREG -DEERIE_ML_ADUP \
      -DEERIE_ML_KPRE -DEERIE_ML_CDUP -DEERIE_W8_IDLEPRE -DEERIE_W8_PAPRE -DEERIE_SCR8_MAT -DEERIE_SCR8_PTREE"
for s in 0 1 2 3 4 5 6 7; do sim/run_w8.sh $OPTS -- +shift=$s; done   # PASS 6/6 each
sim/run_unit.sh scr8; sim/run_unit.sh crc16
SKP_DEFS=-DEERIE_SKP_EB2 sim/run_unit.sh skp            # 0, +-300, +-600 ppm: PASS
SKP_DEFS=-DEERIE_SKP_EB2 PPM_LIST="1000 -1000" sim/run_unit.sh skp   # beyond spec: FAIL (capacity)
```

`tb_w8`: root port = **unmodified** pci_eerie 6bfb5ef (16-bit PIPE at 125 MHz, all modules renamed
`rp_*` by `sim/mk_rp.sh`, taken from this repository's git history) against the endpoint with
`EERIE_W8` (64-bit PIPE at 31.25 MHz) through a PIPE model; `+shift=N` rotates the endpoint's
receive symbols by N (0..7) to cover every comma position. Checks: L0 (LTSSM 0x16), DL up,
CfgRd vendor/device ID, BAR0 sizing, CfgWr, MRd/MWr on BAR0 (BAR0 application from
`gatemate/rtl/eerie_bar0_app.v`), and **no receiver error in L0** (a broken DLLP check is otherwise
hidden: the link recovers and the transactions still pass).

## Build / measure

```
cd gatemate
ALL="EERIE_W8 EERIE_DLL_CRCPRE EERIE_ML_CRCMAT EERIE_ML_DLCPRE EERIE_ML_QREG EERIE_W8_IDLEPRE EERIE_W8_PAPRE \
     EERIE_SCR8_MAT EERIE_SCR8_PTREE EERIE_ML_ADUP EERIE_ML_KPRE EERIE_ML_CDUP"
PNR_OPTS=--tmg-ripup GM_DEFS="$ALL" syn/gm_modul.sh F1 gs_w8_ep_1clk clk 31.25 syn/gs_w8_ep.f
syn/kriticni.sh F1          # critical path after routing
syn/gm_pnr.sh P1 F1 --tmg-ripup   # nextpnr only, on the netlist of F1 (placer/router experiments)
```

`gs_w8_ep_1clk` is the endpoint with one clock (PIPE = user clock = 31.25 MHz) and every port
through a shift-register harness (`gen_harness.py`), so all paths are register to register.

## Status (honest)

- Simulation: L0 + CfgRd + BAR0 PASS for all 8 symbol offsets with all options.
- Timing, full endpoint (core + BAR0 app + 2 MIM RAMs), all options above, `--tmg-ripup`:
  **31.35 MHz (seed 1) and 33.25 MHz (seed 2), PASS at 31.25 MHz**; 20 662 CPE_LT (51 %), 7 383 CPE_FF,
  19/64 RAM_HALF. Without `--tmg-ripup` the same netlist gives 26-29 MHz: the design is routing
  bound (30-35 ns of a 32 ns path is routing on high fan-out nets), so the margin is thin.

  | block (alone, harness) | before | after |
  |---|---|---|
  | full endpoint | 19.2 MHz (`EERIE_W8` only) | 31.35 / 33.25 MHz PASS |
  | eerie_dll | 23.8 | 36.1 PASS |
  | eerie_pl_rx_w8 | 20.8 | 40.2 PASS |
  | eerie_pl_tx_w8 | 30.5 | 37.8 PASS |
  | eerie_pl_rx_ml (N=4) | 22.9 | 27.9 (alone; not the limit inside the endpoint any more) |
  | eerie_skp_eb (wclk / rclk) | 11.7 / 3.5, 9 037 CPE_LT | 37.1 / 52.8 PASS, 5 391 CPE_LT (`EERIE_SKP_EB2`) |

  For comparison, the stock x1 path (16-bit PIPE at 125 MHz) reaches 27.6 MHz on GateMate, and
  openCologne-PCIE (chili-chips) measured with the same flow: PHY+MAC 21-23 MHz FAIL, its DLL alone
  68 362 CPE_LT (166 % of the device).
- Hardware: **not tested on a board yet.** No `CC_SERDES` top level is in this branch yet; the
  analog setup (2.5 Gb/s, 8b10b, comma alignment) follows the ULX5M-GS <-> M2 SerDes link tests.
- SKP elastic buffer: one SKP per SKP ordered set, i.e. 650..850 ppm capacity (SKP interval
  1180..1538 symbols) - enough for +-600 ppm (two +-300 ppm reference clocks), fails at +-1000 ppm.

## Default behaviour

With no defines the modified modules are equivalent to 6bfb5ef (yosys `equiv_make` +
`equiv_simple -seq 2` + `equiv_induct -seq 2`, all `$equiv` cells proven): `eerie_pl_rx_ml` (N=2
and N=4), `eerie_ltssm`, `eerie_dll`; `pci_eerie.v` preprocesses to the same text. `rtl/files.f`
lists three new files (`eerie_scr8.v`, `eerie_pl_tx_w8.v`, `eerie_pl_rx_w8.v`); they are not
instantiated without `EERIE_W8`.

License: CERN-OHL-P-2.0, same as pci_eerie.
