# pci_eerie on Lattice ECP5 (DCU) — ULX4M-LD port

This directory adds a Lattice ECP5-5G SerDes (DCUA) PIPE shim and a board top for the
[ULX4M-LD](https://github.com/intergalaktik/ulx4m-ld) module (LFE5UM5G-85F) on the ULX4M-PCIe-IO card, built with a fully
open toolchain (yosys + nextpnr-ecp5 + Project Trellis). **Nothing under `../rtl` is changed**: pci_eerie runs as-is,
everything ECP5-specific lives here, so the default behaviour of pci_eerie is untouched.

Target: PCIe Gen1 x1 (2.5 GT/s) endpoint, no MSI, BAR0 4 KB, ID `1204:e0e1` (Lattice VID, lab use only).

## What is added

| file | what |
|---|---|
| `rtl/eerie_ecp5_pipe.v` | PIPE x1 (16 bit @ 125 MHz) over one DCUA channel in PCIe mode: receiver detection (`FFC_PCIE_DET_EN/CT`), PhyStatus, RxValid/RxElecIdle, TX electrical idle per byte, reset sequencing (TRST → PLL lock → RRST → LANE_RX_RST). DCU provides 8b10b, comma alignment and CTC. Options (default = plain behaviour): `IGNORE_LOL`, `IGNORE_POL`, `FORCE_INV` |
| `rtl/top_ld_eerie.v` | EXTREFB + DCUA (DCU0 CH0) + CLKDIVF; `ld_eerie_core` = shim + pci_eerie + BAR0 app + LEDs + debug UART |
| `rtl/dcua_gen1_params.vh`, `rtl/extref_params.vh` | DCUA/EXTREFB parameters, taken from a Lattice Diamond PCIe bitstream (decoded with Trellis) with the rate set to 2.5G and CTC in the DCU; `LD_REQ_OFF`, `LD_REQ_LVL`, `LD_DCBIAS` defines for experiments |
| `rtl/eerie_x1_core.v`, `eerie_x1_ep.v`, `eerie_bar0_app.v`, `eerie_ram_sdp.v`, `eerie_ties.vh` | pci_eerie x1 Gen1 with external PIPE/TRN, portable 2-cycle SDP RAM for the MIM ports, a tiny TRN BAR0 app (0x00 = `0x4C440E1E`, 0x04 counter, 0x08 status, 0x0C–0x3C RW) |
| `rtl/eerie_dbg_uart.v` | read-only observer: RSL flags, LTSSM, counters of K28.5 / TS1 / TS2 / inverted TS1 / decode errors / CTC events, polarity toggles, mask of visited LTSSM states, and a 1024-word capture of the raw DCU RX bus around the first entry to Polling.Configuration; 115200 8N2 |
| `sim/run_loop.sh` | EP ↔ RP (both pci_eerie) through a behavioural PIPE PHY |
| `sim/run_ld_loop.sh` | same, but the EP goes through the ECP5 shim and a model of the DCU fabric interface (`sim/dcua_ff_model.v`) |
| `sim/run_dbg_uart.sh` | testbench for the observer (counters, capture, line format) |
| `syn/build_ld.sh`, `syn/ld.lpf` | ULX4M-LD bitstream → `build/ld/top_ld_eerie.bit` |
| `tools/analiza_snimke.py` | decodes the capture lines (`T? aaa LLdddddd`) into symbols |
| `tools/enc8b10b_pomak.py` | 8b10b-encodes a TS2 stream and decodes it shifted by 1..9 bits (used to identify bit slips) |

Comments in the HDL are in Croatian (the lab language); identifiers and this README are English.

## Simulate and build

```
export OSS=/path/to/oss-cad-suite        # optional, otherwise tools from PATH
sim/run_loop.sh            # PASS 5/5 (EP LTSSM 0x16 = L0, DL up, enumeration, BAR0)
sim/run_loop.sh +shift     # PASS 5/5 (COM in the upper byte)
sim/run_ld_loop.sh         # PASS 5/5 through the ECP5 shim + DCU model
sim/run_ld_loop.sh +shift  # PASS 5/5
sim/run_dbg_uart.sh        # PASS dbg_uart
syn/build_ld.sh            # pclk 146 MHz (PASS @125), user 72 MHz (PASS @62.5); 8.2k LUT4, 5.0k FF, 12 DP16KD on 85F
```
`build_ld.sh` defaults to `LD_IGNORE_LOL=1 LD_IGNORE_POL=1 LD_FORCE_INV=1` (what the ULX4M-LD board needs, see below);
set them to 0 for the plain shim.

## State on the board (honest, 18 Nov 2026)

Host: Raspberry Pi CM5 (BCM2712), card behind M.2 → ULX4M-PCIe-IO → ULX4M-LD, LTSSM trace enabled in the host driver.
**The card does not enumerate yet (no `lspci`).** Experiments, one change each:

1. Plain shim (and the Lattice Diamond PCIe IP on the same board): host stops in **Polling.Configuration** — the FPGA never
   receives the host's TS1. The observer shows PLL lock, signal present and receiver detected, but **CDR lock never
   asserts**, so LANE_RX_RST is never released. RLOL does not clear while the lane is held in reset, so a reset sequencer
   that waits for CDR lock before releasing LANE_RX_RST deadlocks. → `IGNORE_LOL=1`: host reaches **Configuration.Link**.
2. pci_eerie flips `RxPolarity` on every inverted TS it sees; through the DCU the inversion lands many symbols later, so it
   oscillates (24 flips in one training). On this board the RX pair is inverted (the M.2 path swaps P/N). →
   `IGNORE_POL=1 FORCE_INV=1`: the endpoint walks Polling → Configuration.Linkwidth → Lanenum → **Configuration.Complete**.
3. Remaining fault: the capture shows TS ordered sets shifted by exactly one bit (reproduced by `tools/enc8b10b_pomak.py`),
   with roughly 10 % of symbols in error. The endpoint therefore does not collect 8 consecutive TS2 in Configuration.Complete,
   and the host times out in Configuration. Disabling the RX equaliser, raising it, and REFCLK DC bias made no difference.
   The next step is to measure the signal on the channel and to tune the CDR settings; pci_eerie itself is not suspected.

Licence: CERN-OHL-P-2.0, same as pci_eerie.
