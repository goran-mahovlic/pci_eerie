# TASK-6170 — openSERDES_BFM + openPCIE_BFM u simulacijskom toku eerie W8, vrh s CC_SERDES

18. 11. 2026. · Jelena · nastavak TASK-6161 · repo `ulx5m-gs-pcie`, izvoz na `goran-mahovlic/pci_eerie` grana `gatemate-w8`

## 1. Što je napravljeno

```
openPCIE_BFM A7RC root port (pcieVHost PcieVhostSerial, VProc čvor 2, 59 pravila)
   │ serijska linija 2,5 Gb/s (8b10b, scrambling)            [tb: ser_retimer samo za EP→RC kad je ppm≠0]
   ▼
eerie_ccs_phy (glue, naš)  ── JEDNA instanca ccfpga_serdes ──  sim: ccfpga_serdes.BFM.sv (openSERDES_BFM)
   │ PIPE 64 bit @31,25 MHz                                    čip: ccfpga_serdes.SYNTH.sv → CC_SERDES
   ▼
eerie_w8_ep (pci_eerie EERIE_W8 + BAR0 aplikacija) — isti RTL u simulaciji i na čipu
```

| datoteka | što |
|---|---|
| `ext/openSERDES_BFM` (submodul, BSD-3, 1f4d5d7) | `ccfpga_serdes` BFM i SYNTH |
| `ext/openPCIE_BFM` (submodul, b674c8a) | RC model + checker; **samo simulacija** (pcieVHost/VProc su GPL-3, ostaju u submodulu, ne ulaze u bit ni u CERN-OHL-P kod) |
| `rtl/gs/eerie_ccs_phy.v` | glue PIPE↔ccfpga_serdes: PCLK = PLL_CLK_O, PhyStatus, RxStatus (detekcija prijemnika, 8b10b greška), RxValid, EI, polaritet; `SRNS=0` zajednički takt (RX_CLK_I=PCLK), `SRNS=1` vlastiti takt (RX_CLK_I=RX_CLK_O + `eerie_skp_eb` EB2) |
| `rtl/gs/eerie_bufg.v` | CC_BUFG na čipu, žica u simulaciji |
| `rtl/gs/m2_pcie_top.v`, `syn/m2_pcie.sh`, `syn/m2_pcie.ccf` | M2 vrh: clk_i (POR), PERST# IO_SA_A1, CLKREQ# IO_SA_B3 = 0 |
| `sim/ser/tb_ser.sv`, `run_ser.sh`, `reg_ser.sh`, `reg_ppm.sh`, `a7rc_eerie.h`, `ser_retimer.sv` | serijski tb (Verilator 5.055, 1ns/1ps) |

Licence: openSERDES_BFM BSD-3 (spojivo s CERN-OHL-P, uključen kao submodul). openPCIE_BFM: BSD-3 za omotače/RC
model/checker, GPL-3.0-or-later za pcieVHost, VProc, mem_model — koristimo ga samo kao simulacijski alat iz
submodula, ništa iz njega nije kopirano u naš RTL.

## 2. Rezultati simulacije (59 pravila openPCIE_BFM A7RC)

| pokus | rezultat | dokaz |
|---|---|---|
| prije popravaka (eerie W8 iz TASK-6161) | **FAIL**: PL.SKP 1, FC.INIT-ORDER 1, FC.UPDATE-PERIOD 7, TL.ORDER 1 | `mjerenja/ser/prije_popravaka_r1.log` |
| poslije popravaka, zajednički takt | **PASS, 59 pravila, 0 kršenja**, L0 za 86,8 µs, DL up 88,5 µs | `poslije_popravaka_r2.log` |
| 12 seedova (`+verilator+seed+N`, BFM bira fazu riječi) | **12/12 PASS 59/0**; COM pao u svih 8 traka (seed 7: 0/4, 1: 1/5, 8: 2/6, 3: 3/7) | `reg_seed_tester.txt` |
| EB2 (SRNS=1), EP refclk +300 / −300 ppm | **PASS 59/0**, rx_err u L0 = 0; EB2 uklonio 25 SKP (+300) | `reg_ppm_retimer.txt` |
| EB2, ±600 ppm | **PASS 59/0**, rx_err L0 0; −53 / +32 SKP | isto |
| EB2, ±1000 ppm | **PASS 59/0**, rx_err L0 0; −60 / +48 SKP | isto |
| EB2, ±600 ppm, `CDR_MODEL=ACCURATE` | **PASS 59/0**, rx_err L0 0 | isto |
| zajednički takt (SRNS=0) uz ±300 ppm | +300 PASS; **−300: 1 RX buffer greška, rx_err u L0 = 1** (RC oporavio) | isto — SRNS=0 nije za M2 s vlastitim taktom (uputa #876) |
| stara iverilog `tb_w8` s novim opcijama, 8 pomaka | **8/8 PASS 6/6** | `tb_w8_8pomaka.txt` |
| tester (A7RC=0, slučajni legalni podražaji), seed 1–4 | link L0 i fizički sloj čisti; prekršaji samo TL/config i 1× Ack latencija (tablica 3, br. 11–14) | `tester_seed1.log` |
| zadano ponašanje (bez definicija) `eerie_dll` vs 6bfb5ef | yosys equiv: **1311/1311 `$equiv` dokazano** | `mjerenja/eq_dll_6170.log` |

±1000 ppm prolazi u sustavu iako jedinični test EB2 (TASK-6161, 60 000 riječi) pada: A7RC šalje SKP OS-ove u
L0 češće od najsporijeg dopuštenog razmaka, a run traje ~400 µs. Zaliha ±1000 nije dokazana za host koji SKP
šalje na 1538 simbola — spec traži ±600, to je pokriveno s rezervom.

## 3. Problemi koje su BFM-ovi otkrili (simptom → uzrok → popravak → čija strana)

| # | simptom | uzrok | popravak | strana |
|---|---|---|---|---|
| 1 | PL.SKP: EP šalje 132 SKP OS u 78 903 simbola L0 (1 na 597) | `eerie_pl_tx_w8` šalje 2 SKP OS-a po terminu (poravnanje na riječ od 8 simbola) | `EERIE_W8_SKP1`: u L0 jedan SKP OS + 4 simbola logičkog idlea → 1 na 1195 | eerie — naša W8 opcija (TASK-6161), nije uzvodni kod |
| 2 | FC.UPDATE-PERIOD: UpdateFC svakih 48 µs (granica 30 µs + 50 %) | `UPDFC_PERIOD=1500` user taktova pretpostavlja 62,5 MHz; W8 radi na 31,25 MHz | uz `EERIE_W8` 750 taktova = 24 µs | eerie — W8 opcija |
| 3 | FC.INIT-ORDER: „InitFC2 type 2 after InitFC1” | kružni brojač InitFC tipova ne kreće ispočetka pri FC_INIT1→FC_INIT2, set InitFC2 počinje s NP/Cpl | `EERIE_DLL_FCSET`: tip (1/2) se bira na početku seta | **eerie uzvodno** (isti kod u regymm/pci_eerie 6bfb5ef) |
| 4 | TL.ORDER: čitanje 0x80000000 vratilo 0x1E (ID) nakon zapisa | BAR0 test aplikacija ima RO registre na 0x00–0x08, A7RC piše u prva 32 B | parametar `ADDR_XOR=8` (RO na 0x20–0x28); M2 vrh i tb ga koriste | naša test aplikacija |
| 5 | uz ppm≠0 RC svakih ~3300 simbola gubi poravnanje („no SKP for 3329 Symbol Times”, „polarity inverted”), zatim FRAMING i Fatal | `PcieVhostSerial`/Serialiser uzorkuje vlastitim taktom, nema CDR: 1 bit klizi svakih 1/ppm UI | `sim/ser/ser_retimer.sv` (samo tb, EP→RC): bitovi iz razmaka rubova, poravnanje na K28.5, dodaje/briše K28.0 | **openPCIE_BFM** (uzvodni pcieVHost) |
| 6 | host EI = stalna 0 na jednoj žici; GateMate RX (i BFM) idle prepoznaje po P = N | `PcieVhostSerial` ima samo jednu izlaznu žicu | tb: N prati P nakon 12 serclk bez promjene (kao openCologne-PCIE `5.sim/tb.sv`) | openPCIE_BFM (sučelje) — prijedlog |
| 7 | `reset_core_pll_n_o`: u BFM-u = PLL zaključan, u SYNTH-u konstanta 1 | CC_SERDES nema izlaz zaključanosti PLL-a | glue ga koristi samo za `reset_core_*_n_i` (kao phy_top); EP čeka `tx_resetdone_o` (postoji na oba) | openSERDES_BFM — prijedlog za dokumentaciju |
| 8 | RX buffer clock correction ne može PCIe SKP (BFM: niz od 4 simbola poravnat u riječi, dva zaredom) | DS1001 / BFM model | `RX_CLKCOR_USE=0`; zajednički takt: RX_CLK_I = PCLK; vlastiti takt: RX_CLK_I = RX_CLK_O + EB2 | dizajnska odluka, u skladu s BFM README |
| 9 | 1 greška 8b10b/disparity po runu, uvijek prije L0 | prijelaz iz EI / zaključavanje CDR-a i poravnanja | RxStatus 100 u to vrijeme; u L0 0 grešaka u svim runovima | očekivano |
| 10 | detekcija prijemnika: DS1001 ne kaže koliko traje (BFM 120 ns) | — | glue: čeka RX_DETECT_DONE, nakon 1023 PCLK prijavi „prisutan” | glue; na čipu još neprovjereno |
| 11 | tester: Cfg na funkciju 1 single-function uređaja vraća SC (CFG.FN, TL.UR, TL.CPL-ID — isti zahtjev) | eerie ne provjerava broj funkcije | nije popravljeno | **eerie uzvodno** |
| 12 | tester: MRdLk završen s UR bez CplLk (TL.CPL-STATUS) | eerie TL vraća Cpl umjesto CplLk | nije popravljeno | **eerie uzvodno** |
| 13 | tester seed 1: TLP Ackan nakon 3288 ns (granica 2588 ns, Gen1) | ACK_DELAY + DLL cjevovod u taktovima na 31,25 MHz (pola 16-bitnog puta) | nije popravljeno (1 slučaj u 4 seeda, pod opterećenjem) | eerie — W8 opcija |
| 14 | tester: TL.ORDER, TL.CPL-ALL (10×) | BAR0 aplikacija: samo 1 DW, ignorira BE, višedwordna čitanja ne dobiju Cpl | nije popravljeno (testna aplikacija) | naša test aplikacija |
| 15 | CC_SERDES blok prvog bita (M2A) razlikuje se od 2,5G recepta u 8 polja (`serdes_cmp.py`, sirovi CMD_SERDES blok) | 6 su HM-only parametri koje `ccfpga_serdes` nema, pa SYNTH ostavlja Yosys zadano: `RX_CALIB_EN` 0 (recept 1), `TX_CALIB_EN` 0 (1), `RX_POWER_DOWN_N` 0 (1), `TX_POWER_DOWN_N` 0 (1), `SERDES_TESTMODE` 0 (1), **`TX_DC_ENABLE_RXDET` 0 (63) — TX driver za detekciju prijemnika ugašen**; `PLL_BISC_CP_MAX` 18 (30) jer ga glue nije postavio | `setparam` na CC_SERDES ćeliju u `syn/m2_pcie.sh` (RTL isti); `PLL_BISC_CP_MAX(5'h1E)` u glueu; `RX_ALIGN_COMMA_WORD` 0 namjerno (W8 RX prima COM u bilo kojoj traci) | openSERDES_BFM SYNTH (prijedlog) + naš build |

Sučelje ccfpga_serdes ↔ eerie PIPE: **nijedan problem nije bio u samom openSERDES_BFM-u** — glue je radio iz prve
(L0 u prvom runu); BFM je otkrio da W8 RX zaista prima COM u svakoj od 8 traka (nasumična faza riječi) i da
SerDes RX buffer bez korekcije ne podnosi odvojene taktove (#8, SRNS=0 −300 ppm).

## 4. Usporedba sa starim tokom (PIPE model iz TASK-6161)

| | stari `tb_w8` (iverilog) | novi `tb_ser` (Verilator) |
|---|---|---|
| partner | izvorni pci_eerie RP na PIPE-u | A7RC RC (kalibriran prema Xilinx PCIE_2_1), 59 pravila |
| PHY | idealni PIPE model, pomak simbola zadajemo | openSERDES_BFM: serijalizacija, CDR (FAST/ACCURATE), 8b10b, poravnanje na zarez, EI, detekcija |
| ppm | samo jedinični test EB2 | cijeli link, EP refclk ±300…±1000 ppm |
| našao | rupu u provjeri rx_err (TASK-6161) | probleme 1–3 (rok/raspored DLL-a i PL-a) koje stari tok nije mogao vidjeti |

## 5. HW vrh (M2)

`m2_pcie_top`: `eerie_ccs_phy` + `eerie_w8_ep` (sve opcije iz F1 + `EERIE_SKP_EB2 EERIE_W8_SKP1 EERIE_DLL_FCSET`),
ccfpga_serdes.SYNTH.sv → CC_SERDES s 2,5G receptom „zadano CPM4” (TASK-5979: PLL 100 MHz × 25 / 2, CI 1,
BISC CP 4, TX_AMP 12, TX_SEL_PRE 0, TX_SEL_POST 5, CALIB 0, CDR CKP 0x3E, EQA uključen). Bitovi i Fmax: §6.
HW test ide kroz TASK-6167 (sonda m2 je njegova).

## 6. P&R i bitovi (CCGM1A1, yosys + nextpnr-himbaechel, `--freq 31.25`)

| build | SRNS | lanac | CPE_LT | ishod | dokaz |
|---|---|---|---|---|---|
| M2A_s2 | 0 | 20261117, `--tmg-ripup` | 21 088 (51 %) | PCLK **31,68 MHz PASS**; 1 hold prekršaj −0,02 ns (RAM DOB → FF, razlika takta 3,4 ns); CC_SERDES 8 polja ≠ recept | `mjerenja/M2A_s2.txt` |
| **M2F_s2** | 0 | isto | 21 088 (51 %) | isti smještaj kao M2A_s2 (31,68 MHz PASS, isti hold −0,02 ns); CC_SERDES = recept osim `RX_ALIGN_COMMA_WORD` (namjerno) | `mjerenja/M2F_s2.txt` |
| M2C_s1–s3 | 1 (EB2) | 20261117, `--tmg-ripup` | 26 142 (63 %) | rutiranje ne konvergira (9–18k preklapanja nakon 30–46 iteracija), prekinuto | `mjerenja/M2C_s*.txt` |
| M2D_s1/s2 | 1 | + `--router router2` | 26 142 | isto (~9–16k), prekinuto | `mjerenja/M2D_s2.txt` |
| M2E_s1 | 1 | bez `--tmg-ripup` | 26 142 | isto (~11k nakon 38 iter.), prekinuto | — |
| N18C_s1–3 | 1 | 20261118 | — | ugašeno: TASK-6175 izmjerio da je 20261118 za GateMate P&R bit-identičan 20261117 (uputa #879) | — |
| C22F_s2 | 0 | nextpnr c22d0709, isti netlist kao M2F_s2 | 21 088 | **bajtno isti bit kao M2F_s2** (sha256 2238dcd0…), isti hold −0,02 ns | `mjerenja/C22F_s2.txt` |
| C22C_s1/s2 | 1 | nextpnr c22d0709, netlist M2C | 26 142 | ne konvergira (~9,5k / 16k nakon 25–33 iter.) | — |

EB2 (`eerie_skp_eb`, EERIE_SKP_EB2) dodaje ~5 050 CPE_LT (51 → 63 %) i dva upisa po taktu u FIFO s asinkronim
čitanjem, pa ne ide u BRAM; uz W8 jezgru koja je već ograničena rutiranjem (TASK-6161) dizajn se ne može razvesti.
Sljedeći korak za SRNS=1: EB s jednim upisom/taktom i FIFO u CC_BRAM (manje CPE), ili niži broj opcija
dupliciranja (ADUP/CDUP) uz EB.

**Isporučeno na Pi** (`pi@192.168.10.14:/home/pi/FPGA/`): `m2_pcie_eerie_w8_srns0_s2.bit` (= M2F_s2, sha256
2238dcd0cbe14647…, 892 638 B, gmpack --reset, CFGRST provjeren) + `README_m2_pcie_eerie_w8.md`. To je SRNS=0 bit:
za prvi HW test (Detect/Polling/LTSSM/lspci); s vlastitim oscilatorom M2 očekuju se povremena RX buffer klizanja.
**SRNS=1 (EB2) bit nije napravljen** — ne prolazi rutiranje ni s jednim od 3 lanca/routera.
