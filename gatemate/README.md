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
| `EERIE_W8_SKP1` | eerie_pl_tx_w8 | in L0 one SKP OS + 4 logical idle symbols per interval (was two SKP OSs: one per 600 symbols, PL.SKP) |
| `EERIE_DLL_FCSET` | eerie_dll | the InitFC type is chosen at the start of a set, so InitFC2 sets start with P (FC.INIT-ORDER) |

With `EERIE_W8` the UpdateFC period is 750 user clocks (24 us at 31.25 MHz; 1500 were 48 us, FC.UPDATE-PERIOD).

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

## Serial line: openPCIE_BFM RC -> openSERDES_BFM -> eerie (TASK-6170)

One `ccfpga_serdes` instance in `rtl/eerie_ccs_phy.v` (PIPE glue: PCLK = PLL clock, PhyStatus, RxStatus,
receiver detection, electrical idle, polarity; `SRNS=1`: RX_CLK_I = RX_CLK_O and the SKP elastic buffer).
The file list picks `ext/openSERDES_BFM/1.gatemate/1.model/ccfpga_serdes.BFM.sv` in simulation and
`ccfpga_serdes.SYNTH.sv` (CC_SERDES) for the chip. The host is openPCIE_BFM's Artix-7 RC model on the serial
line (`PcieVhostSerial`, 59 PCIe rules). Both BFMs are git submodules (`ext/`), simulation only for openPCIE_BFM
(its pcieVHost / VProc parts are GPL-3.0-or-later; nothing of it is in the RTL or the bitstream).

```
git submodule update --init --recursive
sim/ser/run_ser.sh build && sim/ser/run_ser.sh run                  # Verilator: RC MODEL RESULT: PASS, 59 rules, 0 violations
sim/ser/run_ser.sh run +verilator+seed+7                            # the BFM picks the RX word phase from the seed
SRNS=1 sim/ser/run_ser.sh build && SRNS=1 sim/ser/run_ser.sh run +ppm=-600   # EP reference 600 ppm fast, SKP elastic buffer
A7RC=0 sim/ser/run_ser.sh build && A7RC=0 sim/ser/run_ser.sh run    # the RC model's random tester
sim/ser/reg_ser.sh; sim/ser/reg_ppm.sh                              # the regression (summary.txt under build/sim/)
```

`+ppm=N` puts the EP SerDes reference N ppm off; pcieVHost's serial receiver has no clock recovery, so the
EP -> RC line then goes through `sim/ser/ser_retimer.sv` (test bench only). Results (`mjerenja/ser/`):
12 seeds PASS (the COM in all 8 lanes of the word); EB2 at +-300, +-600, +-1000 ppm (FAST CDR) and +-600 (ACCURATE)
PASS, no receiver error in L0. What the models found and what was fixed: `REPORT_SERDES_BFM.md`.

## ULX5M-M2 top with CC_SERDES

`rtl/m2_pcie_top.v`: `eerie_ccs_phy` (SRNS = 1: the M2 runs on its own oscillator) + `eerie_w8_ep`, PERST# on
IO_SA_A1, CLKREQ# (IO_SA_B3) held low. SerDes: 2.5 Gb/s from 100 MHz, the GS<->M2 2.5G link recipe.
`SEED=1 SRNS=1 syn/m2_pcie.sh M2B_s1` (yosys + nextpnr `--tmg-ripup` + `gmpack --reset`).

## Gen2: EERIE_W16 (128-bit PIPE, 5.0 GT/s at 31.25 MHz, TASK-6173)

5.0 GT/s with 8 symbols per clock would need a 62.5 MHz PIPE clock, out of reach on GateMate. `EERIE_W16` puts the
x1 lane on a **128-bit PIPE, 16 symbols per clock**: 31.25 MHz at 5.0 GT/s, 15.625 MHz at 2.5 GT/s (fixed width,
the PIPE clock follows the rate). `EERIE_W8` stays the default GateMate build; without any define the core is
upstream pci_eerie.

| file | what |
|---|---|
| `rtl/eerie_scr16.v` (+ `eerie_lfsrmat16.vh`, `gen_lfsr_mat16.py`) | 16-symbol (de)scrambler: per-symbol LFSR state from 17 flat-matrix candidates, popcount tree |
| `rtl/eerie_pl_rx_w16.v` | x1 RX for 16 symbols: ordered sets in a 2-word window (TS / EIOS / SKP / idle at any COM position), packet mask for both start states, compaction, slot queue (0..4 slots of 4 bytes per clock) |
| `rtl/eerie_pl_tx_w16.v` | x1 TX for 16 symbols: one TS per word, EIEOS at 5.0 GT/s, SKP (+ 12 idle in L0), EIOS x4, packet beats of two FIFO entries |
| `rtl/eerie_slot_fifo.v` | slot FIFO (2 RAM banks, 2 pair writes / 1 read per clock) in front of `eerie_pl_rx_ml` (N=4, 8 bytes per clock) |
| `rtl/eerie_async_fifo2.v` | packet FIFO with a second read port (a 16-byte beat = two 8-byte entries) |
| `rtl/eerie_skp_eb16.v` | the EERIE_SKP_EB2 elastic buffer for 16-symbol words (separate reference clocks) |
| `rtl/pci_eerie.v`, `eerie_ltssm.v`, `eerie_dll.v` | `EERIE_W16` wiring; LTSSM `US_DIV2`, Recovery.Speed times and EIOS count for 16 symbols; UpdateFC period per rate |
| option `EERIE_1CLK` | USERCLK == PIPECLK: the PL <-> DLL FIFOs without synchronizers (shorter Ack path) |
| `rtl/eerie_w16_core.v`, `eerie_w16_ep.v`, `gs_w16_ep_1clk.v` | endpoint, `LINK_CAP_MAX_LINK_SPEED = 2` (parameter `MAX_GEN`) |
| `rtl/eerie_ccs_phy16.v` | CC_SERDES PIPE glue: PCLK = PLL clock / 2, 2:1 gearbox, **PIPE Rate through the SerDes register file** (PLL off, `PLL_CFG1` OUT_DIVSEL M3 2 -> 1, PLL on, lock, PhyStatus), EB16 for SRNS |

Design choice: the PHY layer runs at the full 16 bytes per clock; the link and transaction layers stay 64 bits wide
(8 bytes per clock, 250 MB/s). Transmit is legal at any lower rate (idle between packets); on receive the slot
FIFO takes up the difference, bounded by the credits the endpoint advertises (a 4 KB FIFO for 4.6 KB of posted
data credits). A 128-bit DLL / TL would not fit the A1 next to the PHY (W8 is already 51 %); see the report.

openSERDES_BFM models the rate change exactly as needed: `PLL_CFG1` is taken only with the PLL off, the PLL clock
stops while it relocks (500 ns) and comes back at the new rate, so no glue was needed in the BFM.

```
sim/ser/run_ser16.sh build && sim/ser/run_ser16.sh run          # A7RC (Gen2): 2.5 -> Recovery.Speed -> 5.0, L0, CfgRd, BAR0
SRNS=1 sim/ser/run_ser16.sh build && SRNS=1 sim/ser/run_ser16.sh run +ppm=-600   # EB16, EP reference 600 ppm fast
PAIR=1 ... / EPGEN=1 ... / A7RC=0 ...                           # other gearbox pairing / Gen1-only EP / RC tester
sim/ser/reg_ser16.sh                                            # regression, build/sim/reg16/summary.txt + com16.txt
iverilog ... sim/tb_scr16_eq.v ; sim/tb_skp_eb16.v              # scr16 vs a per-symbol model, EB16 at +-300/600 ppm
syn/equiv_t6173.sh                                              # default and EERIE_W8 builds unchanged (yosys equiv)
SEED=1 syn/w16_pnr.sh W16A_s1                                   # CCGM1A1 at 31.25 MHz
```

Results: `REPORT_GEN2_W16_HR.md` (report, Croatian), `UPSTREAM_GEN2_W16.md` (issue / PR drafts, limits), `mjerenja/t6173/`.

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
- Hardware: **not tested on a board yet.** The `CC_SERDES` top level for the ULX5M-M2 is `rtl/m2_pcie_top.v`
  (TASK-6170); the analog setup (2.5 Gb/s) follows the ULX5M-GS <-> M2 SerDes link tests.
- SKP elastic buffer: one SKP per SKP ordered set, i.e. 650..850 ppm capacity (SKP interval
  1180..1538 symbols) - enough for +-600 ppm (two +-300 ppm reference clocks), fails at +-1000 ppm in the unit
  test. On the serial line against the RC model +-1000 ppm passes (that host sends SKP more often than the
  slowest allowed interval), so +-1000 is not a guarantee.

## Default behaviour

With no defines the modified modules are equivalent to 6bfb5ef (yosys `equiv_make` +
`equiv_simple -seq 2` + `equiv_induct -seq 2`, all `$equiv` cells proven): `eerie_pl_rx_ml` (N=2
and N=4), `eerie_ltssm`, `eerie_dll`; `pci_eerie.v` preprocesses to the same text. `rtl/files.f`
lists three new files (`eerie_scr8.v`, `eerie_pl_tx_w8.v`, `eerie_pl_rx_w8.v`); they are not
instantiated without `EERIE_W8`.

License: CERN-OHL-P-2.0, same as pci_eerie.
