# GateMate PCIe Gen2 — EERIE_W16 (128-bitni PIPE) i promjena brzine 2,5 → 5,0 GT/s u simulaciji

TASK-6173, 19. 11. 2026., Jelena. Goranova uputa 18. 11. 22:55: W16 je u redu jer bržu logiku na GateMateu teško
dobivamo, a **prije HW-a ide simulacija**. Fork `goran-mahovlic/pci_eerie`
grana **gatemate-w16** (na gatemate-w8). Mjerenja: `mjerenja/t6173/`.

## Sažetak

| što | stanje | dokaz |
|---|---|---|
| EERIE_W16: 16 simbola/takt, 31,25 MHz @5 GT/s (15,625 @2,5), W8 ostaje zadano | ✅ | `rtl/eerie/eerie_{scr16,pl_rx_w16,pl_tx_w16,slot_fifo,async_fifo2,skp_eb16}.v` |
| scr16 (matrice LFSR-a) | ✅ 100 000 riječi, 0 razlika prema modelu po simbolu | `mjerenja/t6173/unit16.txt` |
| EB za 16 simbola | ✅ jedinično 0/±300/±600 ppm PASS; serijski 0…±1000 ppm PASS | `unit16.txt`, `reg16_summary.txt` |
| Gen2: LINK_CAP_MAX_LINK_SPEED=2, Recovery.Speed, PIPE Rate → CC_SERDES | ✅ | `eerie_w16_core.v` (MAX_GEN), `eerie_ccs_phy16.v` |
| openSERDES_BFM podržava Rate? | ✅ da (PLL_CFG1 kroz regfile uz PLL off/on) — **nije uzvodni problem**, ljepilo je u našem PHY-u | §3 |
| Sim A7RC (Gen2) serijski → openSERDES_BFM → W16: trening 2,5, promjena na 5,0, L0 na 5,0, CfgRd/BAR0, 59 pravila | ✅ 59 pravila, 0 kršenja, RC MODEL RESULT PASS | `reg16_summary.txt` |
| svih 16 položaja COM-a | ✅ 16/16 na 2,5 **i** 16/16 na 5,0 GT/s (61 PASS pokretanje) | `com16.txt`, `shift16.txt` |
| odvojeni taktovi ±300/±600 ppm (M2 v001 vlastiti oscilator) | ✅ EB16: 0, ±300, ±600, ±1000 ppm (FAST), ±600 (ACCURATE), oba sparivanja | `reg16_summary.txt` |
| sinteza + P&R W16 na A1 @31,25 MHz | ❌ **ne rutira**: sinteza 33 231 CPE_LT (81 %); P&R seed 1 i 2 ne konvergira (preopterećene žice rastu), prekinuto 19. 11. 12:50 | `mjerenja/W16B_s1.txt`, `mjerenja/W16B_s2.txt` |
| uzvodni bug pronađen simulacijom | pci_eerie LTSSM ne prati smanjenje brzine (5→2,5) — popravak `EERIE_LTSSM_SPDDN`, EN nacrt issuea | `docs/UPSTREAM_GEN2_W16_EN.md` |

## 1. Arhitektura W16

5 GT/s s 8 simbola/takt traži PCLK 62,5 MHz — na GateMateu nedostižno (W8 jezgra je jedva 31,35/33,25 MHz).
W16 drži 31,25 MHz uz 16 simbola po taktu; na 2,5 GT/s ista širina, PCLK 15,625 MHz (fiksna širina, PCLK prati
brzinu, kao PIPE 4.x "rate-dependent PCLK").

* **Fizički sloj na punoj brzini (16 B/takt):** `eerie_scr16` (17 kandidata stanja LFSR-a kao ravne XOR matrice,
  `gen_lfsr_mat16.py`, brojanje preko popcount stabla), `eerie_pl_rx_w16` (prozor od 2 riječi za TS/EIOS/SKP/idle na bilo
  kojem položaju COM-a, maska paketa za oba početna stanja, sažimanje, red slotova 0..4 × 4 B/takt),
  `eerie_pl_tx_w16` (TS = jedna riječ, EIEOS na 5 GT/s prije prvog TS-a i svakih 32, SKP + 12 idle u L0, EIOS ×4,
  paketni otkucaj = 2 unosa FIFO-a).
* **Sloj veze i transakcija ostaju 64-bitni (8 B/takt).** Odašiljanje je legalno sporije (idle između paketa);
  na prijemu `eerie_slot_fifo` (2 BRAM banke, 2 upisa/1 čitanje po taktu, 512 parova = 4 KB) prima razliku, a
  prasak TLP-ova je ograničen kreditima koje EP oglašava (PD 288 × 16 B = 4,6 KB → zaostatak ≤ pola). Ako bi se
  ikad prelio, par se odbaci → LCRC → NAK → replay (sigurno). U svim pokretanjima: 0 preljeva.
  Zašto ne 128-bitni DLL/TL ("DLL CRC unaprijed za 16 B"): W16 PHY je i ovako 81 % CPE (§4); 128-bitni DLL+TL
  ne bi stao u A1. Posljedica: propusnost 250 MB/s i na 5 GT/s (kao Gen1), ali link je Gen2.
* `eerie_async_fifo2`: paketni FIFO s dva čitanja po taktu. **Prva izvedba (dva asinkrona čitanja jednog niza)
  dala je 8 608 DFF + 5 628 MX4 i cijelu jezgru 123 % CPE** (`W16A_s*_fifo_ff.txt`); prepravljeno na dvije
  BRAM banke (parni/neparni unosi) + izlazni red od 4: 314 DFF + 2 BRAM_40K (`modul_stat.txt`, `tb_fifo2.v` PASS).
* `EERIE_1CLK`: USERCLK == PIPECLK → FIFO-i PL↔DLL bez sinkronizatora (kraći put Acka).
* LTSSM: parametar `US_DIV2` (zadano 249 = izvorno), Recovery.Speed vremena (800 ns / 6 µs) za 16 simbola/takt,
  EIOS: jedna riječ = 4 EIOS; DLL: UpdateFC period po brzini, ACK_DELAY 0 za W16.
* `eerie_skp_eb16`: EB2 struktura za 16-simbolne riječi; upisni takt = oporavljeni takt / 2.

## 2. Ljepilo CC_SERDES: `rtl/gs/eerie_ccs_phy16.v`

* PCLK = PLL_CLK_O / 2 (2,5 Gb/s: PLL 31,25 → PCLK 15,625 MHz; 5 Gb/s: 62,5 → 31,25 MHz).
* Mjenjač 2:1 u domeni PLL takta: TX 128 → 64 (simboli 0..7 pa 8..15), RX 64 → 128 (`RX_PAIR` bira par).
* **PIPE Rate → promjena brzine u radu** kroz SerDes register file (`clk_cfg`, slobodni takt — npr. 25 MHz clk_i;
  PLL takt stoji dok PLL ponovo hvata): `PLL_CFG0[0]=0` (PLL off) → `PLL_CFG1[13:12]` OUT_DIVSEL (M3 2→1; DCO
  ostaje 5 GHz) → `PLL_CFG0[0]=1` → čeka PLL lock + TX/RX reset done (256 taktova stabilno) → PhyStatus impuls.
* SRNS=1: RX mjenjač na oporavljenom taktu, `eerie_skp_eb16` u PCLK; EB se resetira tijekom promjene brzine.
* RX podatci bez dodatnog PCLK registra (ušteda 64 ns na 2,5 GT/s u putu Acka).

## 3. openSERDES_BFM i Rate

Model radi točno ono što treba: `PLL_CFG1` prima samo uz ugašen PLL (inače `$warning` i odbacuje), PLL takt
stane, nakon `BHV_PLL_LOCK_TIME_NS` (500 ns) se vrati na novoj brzini, reset sekvence se ponove. U logu:
`EP PIPE Rate = 1` → PhyStatus nakon ~14 µs (relock + 256 taktova clk_cfg + TX reset) → RcvrLock na 5 GT/s.
**Nema uzvodnog problema u openSERDES_BFM; glue je u našem PHY ljepilu.**

## 4. Sinteza + P&R (CCGM1A1, oss-cad-suite-20261117, `-luttree -nomx8`, `--tmg-ripup`)

| varijanta | CPE_LT | CPE_FF | RAM_HALF | Fmax nakon rutiranja |
|---|---|---|---|---|
| W8 F1 (TASK-6161, referenca) | 20 662 (50 %) | 7 383 | 19 | 31,35 / 33,25 MHz PASS |
| W16A (prva FIFO2 izvedba, FF) | 50 630 (**123 %**) | 17 854 | 21 | ne stane |
| W16B (FIFO2 u BRAM, konačni RTL) | 33 231 (81 %) | — | — | **ne rutira** — s1: min 13 392 preopterećenih žica (iter 22), iter 54 → 27 223; s2: min 27 070 (iter 16), iter 39 → 42 496; raste, prekinuto 19. 11. 12:50 |

**Zaključak P&R (19. 11. 12:50):** W16 na CCGM1A1 ne rutira na 31,25 MHz — kod 81 % CPE-a rutiranje ne konvergira
(oba seeda nakon minimuma oko iter 16–22 preopterećenje raste). Za Gen2 na HW treba **manji W16** (npr. uži
pl_rx_w16 / slot_fifo, DLL/TL dijeljeni s W8 bez dupliciranja) **ili CCGM1A2**. Novo rutiranje W16 bez naloga se ne
pokreće. Goran 19. 11.: **Gen1 je za sada dovoljan** (framebuffer s Pija) — W8 ostaje put za HW; Gen2 W16 ostaje
dokazan samo u simulaciji (§5).

Po modulima (yosys synth_gatemate, sam modul): pl_rx_w16 2 641 DFF / 1 184 MX4 (W8: 1 455 / 338), pl_tx_w16
532 / 113 (W8: 284 / 44), slot_fifo 423 DFF + 2 BRAM_40K, fifo2 314 DFF + 2 BRAM_40K (`modul_stat.txt`).

## 5. Simulacija — rezultati (konačni RTL)

Tok: `sim/ser/run_ser16.sh` — openPCIE_BFM A7RC (RC_GEN=2, `PcieVhostSerial`) → serijska linija →
openSERDES_BFM `ccfpga_serdes` (CDR FAST/ACCURATE) → `eerie_ccs_phy16` → `eerie_w16_ep`. Regresija `reg_ser16.sh`:

* **32/32 sjemena (2 sparivanja) PASS**: trening 2,5 → Recovery.Speed (TS2 s speed_change) → L0 na 5,0 GT/s
  (`link speed = 0x2`), Vendor/Device 0xE0E11204, BAR0 4 KB, firmware 0xFACE, **59 pravila, 0 kršenja**, rx_err u L0 = 0.
* **COM položaji:** 16/16 na 2,5 i 16/16 na 5,0 GT/s (sjemena + usmjereni `+shift=0..15`, svih 16 PASS).
* **EB16 (SRNS=1), EP referenca pomaknuta:** 0, +300, −300, +600, −600, +1000, −1000 ppm (FAST), ±600 (ACCURATE),
  ±600 s drugim sparivanjem — svi PASS, 59/0, rx_err u L0 = 0; npr. +600 ppm 68 uklonjenih SKP, −600 ppm 32 umetnuta.
* EP samo-Gen1 (`EPGEN=1`, 15,625 MHz): PASS, 59/0.
* SRNS=0 (zajednički takt) uz −300 ppm: FAIL (DL.NAK) — **očekivano**, bez EB-a odvojeni taktovi nisu podržani
  (M2 v001 s vlastitim oscilatorom mora koristiti SRNS=1).
* Tester A7RC=0 (nasumični): iste greške kao W8 na Gen1 (TL.ORDER/CPL-ALL/funkcija 1/MRdLk u BAR0 aplikaciji i TL-u,
  postojeće), ne stiže do Speed(). Zato sim-only `SPEED_ONLY=1` (Speed() + Retrain() odmah nakon firmwarea):
  **pronađen uzvodni bug LTSSM-a** — EP nije pratio RC-ov pad 5,0 → 2,5 GT/s (ostajao u RcvrLock). Popravak
  `EERIE_LTSSM_SPDDN`. S njim: 5→2,5→5 s otvorenim čitanjima i nasumični Recovery s promjenom brzine rade;
  **5/8 sjemena PASS**, preostala 3 padaju samo na DL.ACK-LAT na 2,5 GT/s pod uzastopnim TLP-ovima (Ack čeka iza
  TLP-a koji 64-bitni DLL šalje na 15,625 MHz; 2600–3124 ns prema granici 2588 ns). W8 na Gen1 ima isti razred
  (3288 ns u testeru, TASK-6170).
* Jedinični: scr16 100 000/0, EB16 5 ppm točaka PASS, FIFO2 (SYNC=1 i dva takta) PASS.
* Zadano (bez opcija) i W8: yosys ekvivalencija eerie_ltssm / eerie_dll / eerie_async_fifo (×2 parametrizacije)
  PROVEN prema 1e67e34, pci_eerie predprocesiran razlikuje se samo u `SYNC(0)` / `ACK_DLY=2` (`equiv_default_w8.txt`);
  W8 serijski 59/0 PASS, W8 EB2 −600 ppm PASS (`w8_regresija_*.log`).

## 6. Rizici za HW (iskreno)

1. **5 Gb/s na CC_SERDES nije dokazan u siliciju.** Put M3 = 1 (OUTDIV 1) je na ULX5M već na 2,4 Gb/s mjeren ~×3·10⁴
   lošiji od M3 = 2 (TASK-5995); 3G smo dobili samo preko OD2/DCO 3000. 5G traži DCO 2500 s M3 = 1. Simulacija
   dokazuje logiku, ne analognu stranu. Prvi HW korak: BER na 5G (M3=1) između GS i M2 prije bilo kakvog PCIe Gen2.
2. PCLK iz djelitelja (FF → BUFG) staje tijekom relocka; prijelaz PCLK ↔ PLL takt u mjenjaču nextpnr ne analizira
   kao povezane taktove — u P&R mjeren je samo `gs_w16_ep_1clk` (jedan takt), ne cijeli M2 vrh s ljepilom.
3. Ack latencija na 2,5 GT/s pod opterećenjem (§5) — prekršaj specifikacije, funkcionalno nije gubitak (RC replay
   timer je ~3× granica).
4. Propusnost 250 MB/s (DLL/TL 64 bita).

## 7. Datoteke

RTL: `rtl/eerie/eerie_scr16.v`, `eerie_lfsrmat16.vh`, `eerie_pl_rx_w16.v`, `eerie_pl_tx_w16.v`, `eerie_slot_fifo.v`,
`eerie_async_fifo2.v`, `eerie_skp_eb16.v`, izmjene `pci_eerie.v`, `eerie_ltssm.v`, `eerie_dll.v`, `eerie_async_fifo.v`
(sve pod opcijama); `rtl/gs/eerie_w16_core.v`, `eerie_w16_ep.v`, `gs_w16_ep_1clk.v`, `eerie_ties_w16.vh`, `eerie_ccs_phy16.v`.
Sim: `sim/ser/{run_ser16.sh,reg_ser16.sh,tb_ser16.sv}`, `ser_retimer.sv` (5 GT/s), `sim/{tb_scr16_eq,tb_skp_eb16,tb_fifo2}.v`,
`sim/run_unit16.sh`. Syn: `syn/{w16_pnr.sh,equiv_t6173.sh,gen_lfsr_mat16.py,gs_w16_ep.f}`, `export_fork.sh`.
EN nacrti: `docs/UPSTREAM_GEN2_W16_EN.md` (issue LTSSM, PR tekst, ograničenja, napomena openSERDES_BFM).
