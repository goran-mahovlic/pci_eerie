# Upstream drafts (EN), TASK-6173 — not sent; for Goran to review

## 1. regymm/pci_eerie — issue: an upstream port does not follow a speed change down to 2.5 GT/s

**Title:** LTSSM Recovery.RcvrLock: speed_change ignored unless the partner offers 5.0 GT/s (stuck in RcvrLock on a Gen2 -> Gen1 change)

In `eerie_ltssm.v`, Recovery.RcvrLock sets `directed_speed_change` only for TS1s with speed_change = 1 **and**
5.0 GT/s in the partner's rate field (`both_gen2`):

```verilog
if (ts1 && os_rate[7] && both_gen2) begin
```

When the root port takes a 5.0 GT/s link back to 2.5 GT/s (PCIe 2.1 4.2.6.4.1: it sends TS1s with speed_change = 1
and advertises 2.5 GT/s only) the endpoint never sets `directed_speed_change`; its TS1s keep speed_change = 0, so
`cnt_a` (speed_change equal to `directed_speed_change`) never counts and the endpoint stays in RcvrLock until the
24 ms timeout. The same happens for a speed_change Recovery at 2.5 GT/s with a partner that offers 2.5 GT/s only.
Recovery.RcvrCfg has the matching condition in `rr_spd` / `rr_nospd`.

Found with openPCIE_BFM's Artix-7 RC model (the random tester's `Speed()` / `Retrain()`: "the RC changes the link to
Gen1, reads outstanding" -> "Recovery for 50 us, still in RcvrLock at Gen2"). For an upstream port the spec does not
tie the response to speed_change to the advertised rates; Recovery.Speed then goes to the highest common rate.

Fix (build option `EERIE_LTSSM_SPDDN` on our branch, default unchanged): in RcvrLock
`os_rate[7] && (both_gen2 || cur_gen2 || !DSP)`, in the `rr_spd` / `rr_nospd` registers the same `|| !DSP`.
With it the tester's speed changes 5.0 -> 2.5 -> 5.0 with reads outstanding and the random Recoveries with a speed
change pass (59 rules, 0 violations, 5 of 8 seeds; the other 3 fail only DL.ACK-LAT at 2.5 GT/s, see 3.).

## 2. regymm/pci_eerie — PR text: x1 Gen2 on a 128-bit PIPE (EERIE_W16), GateMate

Branch `gatemate-w16` (on top of `gatemate-w8`). All build options; without defines the core is unchanged
(yosys equivalence of `eerie_ltssm`, `eerie_dll`, `eerie_async_fifo`, preprocessed `pci_eerie.v`:
`gatemate/syn/equiv_t6173.sh`).

* `EERIE_W16`: x1 lane on a 128-bit PIPE (16 symbols per clock, 31.25 MHz at 5.0 GT/s, 15.625 MHz at 2.5 GT/s;
  fixed width, PCLK follows the rate): `eerie_scr16`, `eerie_pl_rx_w16`, `eerie_pl_tx_w16` (EIEOS at 5.0 GT/s),
  `eerie_slot_fifo` (16 -> 8 bytes per clock in front of `eerie_pl_rx_ml`), `eerie_async_fifo2` (two reads per
  clock, block RAM), `eerie_skp_eb16`; LTSSM parameter `US_DIV2` (default 249 = upstream), Recovery.Speed times
  and EIOS count for 16 symbols; UpdateFC period per rate.
* `EERIE_1CLK`: USERCLK == PIPECLK, the PL <-> DLL FIFOs without synchronizers (shorter Ack path).
* `EERIE_LTSSM_SPDDN`: the fix of 1.
* Simulation: openPCIE_BFM A7RC root port at Gen2 on the serial line -> openSERDES_BFM `ccfpga_serdes` -> endpoint:
  training at 2.5 GT/s, Recovery.Speed, L0 at 5.0 GT/s, CfgRd, BAR0, 59 rules, 0 violations; every COM position of
  the 16-symbol word; SKP elastic buffer at +-300 / +-600 / +-1000 ppm.

## 3. Known limits (for the PR description)

* Link / transaction layers stay 64 bits wide: 8 bytes per clock = 250 MB/s at 5.0 GT/s (the PHY runs at 16).
* At 2.5 GT/s the W16 user clock is 15.625 MHz: under back-to-back TLPs an Ack can wait behind a TLP and exceed
  the Ack latency limit (openPCIE_BFM DL.ACK-LAT, by 12 .. 600 ns); the 64-bit W8 build shows the same class at Gen1
  in the tester. Light traffic and 5.0 GT/s pass.

## 4. chili-chips/openSERDES_BFM — note (no issue needed)

The PIPE Rate change of a GateMate PCIe endpoint works on the model as on DS1001: PLL off (`PLL_CFG0[0]`),
`PLL_CFG1` OUT_DIVSEL (M3 2 -> 1), PLL on, lock after `BHV_PLL_LOCK_TIME_NS`, `CLK_CORE_PLL_O` back at the new
rate. No glue was needed in the model. Hardware note for the README, if wanted: on our ULX5M boards the M3 = 1
path was measured much worse than M3 = 2 already at 2.4 Gb/s, so 5.0 Gb/s on CC_SERDES is unproven in silicon.
