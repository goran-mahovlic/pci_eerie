# TASK-6239 — M2 v002 PCIe EP: zašto utihne pod prometom (24.11.2026., Jelena)
CM5 .21 **pciex1_gen=1 u svim pokusima** (od 19:35 CET; prije bilo gen=2 iz TASK-6238, kopija config.txt.t6239_prije_gen2). Link 2,5 GT/s x1, lspci 1397:4d32.

## Uzrok
CC_SERDES M2 bita je bajtno isti kao GS GSY_s2 (0/186 B). Razlika je **RTL**: M2 bitovi (c998b28) nemaju GS popravke TASK-6192/6195
(EERIE_RIDLE_RETRY, EERIE_RXLOCK_REC, EERIE_RPLY_ON, EERIE_1CLK/ACK0). S GS GTA receptom na m2_pcie_top (M2G) link drži.

## Bitovi (Pi /home/pi/FPGA/m2_t6236/, lanac 20261117, --tmg-ripup, SRNS=0, ccf m2v002_pcie_led.ccf, gmpack --reset)
| bit | RTL | ep.app.clk | sha256 |
|---|---|---|---|
| M2X_17_s4 (ref) | c998b28 bez GS popravaka | 31,63 | 7272928f… |
| M2Y_s2/s3/s4 | + DBGCNT 1CLK ACK0 RPLY_ON RIDLE_RETRY | 33,58 / 33,01 / 32,89 | 3d5c6b33 / b76bab6a / 37fede59 |
| M2G_s2/s3/s4 | M2Y + RXLOCK_REC (= GS GTA) | 33,10 / **34,65** / 32,39 | 98de0d0a / **cd9d92dc** / a9b062a1 |
Svih 6: 0x ERROR: u pnr.log, ~10 min po seedu.

## HW (gen1)
| bit | BAR0 300 kr. / 10 ms | 1:1 MWr+MRd | niz 16 | niz 64 |
|---|---|---|---|---|
| M2X_17_s4 | utihne 20/20 (1–247 kr.) | - | - | - |
| M2Y_s3 | 5/5 OK | pad 57 s | pad 4,6 s | pad 0,4 s |
| M2G_s2 | 5/5 OK | 60 s OK (500 k) | 30 s OK | pad 0,3 s |
| **M2G_s3** | 5/5 OK | **197,6 s OK (1,7 M)** | 30 s OK (+niz 2, 8) | pad 0,3 s |
Pad = host AER CE Rollover+ Timeout+, EP izgubi config (COMMAND 0, BAR0 0), CfgRd ID radi.

## Registri (serdes_cmp, JTAG health)
| registar | v001 recept (GS↔M2 2,5G) | GS PCIe GSY_s2 | v002 pročitano (L0) | JTAG pokus | BAR0 / brojači |
|---|---|---|---|---|---|
| RX_ALIGN_COMMA_WORD | 3 | 0 | 0 (bit) | 3: nije upisiv JTAG-om | - |
| TX_AMP | 31 | 12 | 12 | 6 / 31 | M2X: 32,5,62,55 / 8,2,1 (osnova 1–247); M2G 31: ne enumerira |
| TX_SEL_POST | 5 | 5 | 5 | 0 | M2X: 31,8,26 |
| RX_CDR_CKP | 62 | 62 | 62 | 126 | M2X: 17–247; M2G NAK 41 (osnova 18–35) |
| RX_CDR_CKI | 0 | 0 | 0 | 1 | M2X: 2–130; M2G NAK 27 |
| RX_AFE_PEAK | 24 | 24 | 24 | 8 / 16×3 / 31 | M2G NAK 26 / 16,35,36 / 31 |
| RX_EN_EQA | 1 | 1 | 1 | 0 | M2G NAK 35 |
| PLL_LOCKED / CAP_FT | 1 / 511 | = | 1 / 533 | - | - |
| RX/TX CALIB_DONE / CAL | 1/0 | = | 1/0 | - | - |
| RX_EQA_LOCKED / TAPW | 1/0 | = | 1/0 | - | - |
| RX_RTERM_VCMSEL / PLL_REF_RTERM | 3 / 1 | = | 3 / 1 | - | - |
| RX_CDR_LOCKED | 1 | - | 0/1 (lutrija uzorka) | - | - |
49 polja izvan cc_serdes_params.vh su statusna/brojači/debug (serdes_GSY_vs_M2X17s4.md).
EP brojači M2G_s2 (DBGCNT): bad DLLP i L0 izlazi ≥255 već u mirovanju, 8b10b greške u L0 0–3 → gubitak poravnanja, ne analog.

## Novi pinovi v002 (kicad_netlist.py U4, m2v1 vs ulx5m-m2 fa861c2)
| signal | v001 | v002 | u ccf | napon banke v002 |
|---|---|---|---|---|
| PERST# | IO_NB_B0 | IO_SA_A1 | da (ulaz, sinkr.) | 3,3 V (+3V3_SA) |
| CLKREQ# | IO_NB_A0 | IO_SA_B3 | da (izlaz 0) | 3,3 V |
| DEVSLP | IO_NA_B7 | IO_SA_A2 | ne (nekorišten) | 3,3 V |
| PEWAKE# | IO_NB_B2 | IO_SA_A3 | ne | 3,3 V |
| PEDET | IO_NB_B4 | IO_SA_B0 | ne | 3,3 V |
| LED1# (M.2) | IO_NA_A7 | IO_SA_B1 | ne | 3,3 V |
| SUSCLK | IO_NB_A2 | IO_SA_B2 | ne | 3,3 V |
| LED0..7 | IO_SB_A0..B3 | IO_EB_A7,B6,A6,B5,A5,B4,A4,B3 | da (M2G/M2Y) | VCC_EB |
| SDRAM | W banke | N/W banke | ne | SDRAM_VCC |
| SER_RTERM | R109→GND | isto | - | - |
| SER_CK | X2 preko C129/C130 + C136/C137 | X2 izravno + C136/C137, R108 | - | X2 nije zalemljen |

## Preporuka
1. Za M2 v002 koristiti **M2G_s3.bit** (cd9d92dc) — recept: mjerenja/t6185/izgradnja.sh + POST_APPLY post_m2.sh, defs
   "EERIE_DBGCNT EERIE_1CLK EERIE_ACK0 EERIE_RPLY_ON EERIE_RIDLE_RETRY EERIE_RXLOCK_REC", SRNS=0, ccf m2v002_pcie_led.ccf.
2. SerDes parametre ne mijenjati (JTAG pokusi bez učinka). U flash kad se riješi SW1 (TASK-6236).
3. Otvoreno: posted niz 64 (SER-PCIE-09); TASK-6238 Gen2 graditi s istim popravcima.
