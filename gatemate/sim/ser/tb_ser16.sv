// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6173: pci_eerie EERIE_W16 endpoint (128-bit PIPE, Gen2) on the serial line, Verilator; from tb_ser.sv
// (TASK-6170: pci_eerie EERIE_W8 endpoint on the serial line).
//   host  = openPCIE_BFM's Artix-7 RC model (pcieVHost PcieVhostSerial, VProc node 2, VUserMain2.cpp, 59 rules)
//   PHY   = eerie_ccs_phy16: ONE ccfpga_serdes instance, here openSERDES_BFM ccfpga_serdes.BFM.sv (CDR_MODEL=FAST);
//           the PIPE Rate goes to the SerDes PLL through its register file (2.5 -> 5.0 GT/s)
//   EP    = eerie_w16_ep (pci_eerie with EERIE_W16 + BAR0 application), the same as on the chip
// Plusargs: +pair=1  the other RX gearbox pairing (with the SerDes word phase from +verilator+seed+N: all 16
//           COM positions); +gen1  the EP advertises 2.5 GT/s only
// Plusargs: +ppm=N  the EP reference clock N ppm off (positive: slower), the host stays nominal
// The module must be "tb" with a task Fatal (pcieVHost calls tb.Fatal).
module tb;
  localparam HALF_SER_PS   = 100;     // 5 GHz: the host divides it to 2.5 GHz at Gen1
  localparam HALF_PCIE2_PS = 1000;    // 500 MHz: the host divides it to 250 MHz at Gen1
  localparam RUN_US        = 4000;

  logic rst_n = 1'b0;
  logic serclk = 1'b0, pcieclk2 = 1'b0, refclk = 1'b0, cfgclk = 1'b0;
  initial forever #(20ns) cfgclk = ~cfgclk;          // 25 MHz, the board's clk_i (SerDes register file)
  logic ser_dn, ser_up, ser_up_n;

  initial forever #(HALF_SER_PS * 1ps) serclk = ~serclk;
  initial forever #(HALF_PCIE2_PS * 1ps) pcieclk2 = ~pcieclk2;

  // EP reference clock, 100 MHz +- ppm, on an absolute time grid (edges rounded, no drift)
  real    ppm = 0.0, half_ps;
  integer ippm = 0;
  real    t_next = 0.0, t_now = 0.0;
  integer dly = 0;
  initial begin
    if ($value$plusargs("ppm=%d", ippm)) ppm = ippm;
    half_ps = 5000.0 * (1.0 + ppm * 1.0e-6);
    $display("tb: EP refclk %0d ppm, half period %f ps", ippm, half_ps);
    forever begin
      t_next = t_next + half_ps;              // ps, exact
      dly    = $rtoi(t_next - t_now + 0.5);   // rounded to the 1 ps grid
      t_now  = t_now + dly;
      #(dly * 1ps) refclk = ~refclk;
    end
  end

  initial begin
    #(25ns) rst_n <= 1'b1;
    #(RUN_US * 1us);
    $display("tb: TIME LIMIT %0d us: no RC MODEL RESULT", RUN_US);
    $fatal(1, "time limit");
  end

  // the host's electrical idle is a constant 0 on ser_dn; the GateMate RX takes idle from P = N
  // (as openCologne-PCIE 5.sim/tb.sv): N follows P once the line stayed constant for 12 serclk periods
  bit ser_dn_q; int ser_dn_same; logic ser_dn_idle;
  always_ff @(posedge serclk or negedge rst_n)
    if (!rst_n) begin ser_dn_q <= 1'b0; ser_dn_same <= 12; end
    else begin
      ser_dn_q    <= ser_dn;
      ser_dn_same <= (ser_dn != ser_dn_q) ? 0 : ((ser_dn_same < 12) ? ser_dn_same + 1 : 12);
    end
  assign ser_dn_idle = (ser_dn_same == 12) && (ser_dn == ser_dn_q);

  // ---------------- EP: PHY glue + eerie W16 ----------------
  wire        pclk, phy_rdy;
  wire [127:0] rxd, rxd_p, txd; wire [15:0] rxk, rxk_p, txk; wire [7:0] dbg; wire rxv_p;
  wire        rxv, rxei, phys, txei, txc, det, pol, rate; wire [2:0] rxs; wire [1:0] pd;
  wire [5:0]  ltssm; wire lnk, phylnk;

  // EP reset: PHY ready (once), then 255 clocks with PhyStatus low (as gs_hyb_top)
  reg [7:0] hold = 8'd0;
  always @(posedge pclk or negedge rst_n)
    if (!rst_n) hold <= 8'd0;
    else if (hold != 8'hFF && (!phy_rdy || phys)) hold <= 8'd0;
    else if (hold != 8'hFF) hold <= hold + 1'b1;
  wire ep_rst_n = (hold == 8'hFF);

  eerie_ccs_phy16 #(.SRNS(`ifdef SRNS 1 `else 0 `endif), .RX_PAIR(`ifdef RX_PAIR1 1 `else 0 `endif)) phy (
    .rst_n(rst_n), .clk_ref(refclk), .clk_cfg(cfgclk),
    .ser_rxp(ser_dn), .ser_rxn(ser_dn_idle ? ser_dn : ~ser_dn), .ser_txp(ser_up), .ser_txn(ser_up_n),
    .pclk(pclk), .phy_rdy(phy_rdy),
    .txdata(txd), .txdatak(txk), .txelecidle(txei), .txcompliance(txc), .powerdown(pd), .txdetectrx(det),
    .rxpolarity(pol), .rate(rate), .rxdata(rxd_p), .rxdatak(rxk_p), .rxvalid(rxv_p), .rxelecidle(rxei), .rxstatus(rxs),
    .phystatus(phys), .dbg(dbg));

  // +shift=N (0..15): the received symbol stream moved by N PIPE symbols on its way to the EP (simulation only,
  // as tb_w8's +shift): every COM position at both rates with one SerDes word phase
  int shn = 0; initial void'($value$plusargs("shift=%d", shn));
  reg [127:0] prd = 0; reg [15:0] prk = 0; reg prv = 0;
  always @(posedge pclk) begin prd <= rxd_p; prk <= rxk_p; prv <= rxv_p; end
  wire [255:0] wd2 = {rxd_p, prd}; wire [31:0] wk2 = {rxk_p, prk};
  assign rxd = (shn == 0) ? rxd_p : wd2[8*(16-shn) +: 128];
  assign rxk = (shn == 0) ? rxk_p : wk2[(16-shn) +: 16];
  assign rxv = (shn == 0) ? rxv_p : (rxv_p && prv);

  eerie_w16_ep #(.FAST_TRAIN("FALSE"), .ADDR_XOR(4'd8), .MAX_GEN(`ifdef EP_GEN1 1 `else 2 `endif)) ep (
    .pclk(pclk), .uclk(pclk), .sys_rst_n(ep_rst_n),
    .pipe_rxdata(rxd), .pipe_rxdatak(rxk), .pipe_rxvalid(rxv), .pipe_rxelecidle(rxei),
    .pipe_rxstatus(rxs), .pipe_phystatus(phys),
    .pipe_txdata(txd), .pipe_txdatak(txk), .pipe_txelecidle(txei), .pipe_txcompliance(txc),
    .pipe_powerdown(pd), .pipe_txdetectrx(det), .pipe_rxpolarity(pol), .pipe_rate(rate),
    .ltssm(ltssm), .phy_lnk_up(phylnk), .lnk_up(lnk));

  // EP -> RC: straight, or through the retimer when the EP clock is off nominal (+ppm, or +retime)
  wire ser_up_rc, ser_up_rt; int rt_ins, rt_del; bit retime = 1'b0;
  real ui_ep_ps;
  int  rt_ppm = 0;
  initial begin
    void'($value$plusargs("ppm=%d", rt_ppm));           // read here: the order of initial blocks is not defined
    retime = (rt_ppm != 0) || $test$plusargs("retime");
  end
  always @(*) ui_ep_ps = (rate ? 200.0 : 400.0) * (1.0 + rt_ppm * 1.0e-6);
  ser_retimer u_rt (.serclk(serclk), .din(ser_up), .ui_in_ps(ui_ep_ps), .gen2(rate), .dout(ser_up_rt), .n_ins(rt_ins), .n_del(rt_del));
  assign ser_up_rc = retime ? ser_up_rt : ser_up;

  // ---------------- host ----------------
  PcieVhostSerial #(.LinkWidth(1), .NodeNum(2), .EndPoint(0), .Gen2Clk(1)) u_rc (
    .Clk(pcieclk2), .SerClk(serclk), .notReset(rst_n), .ClkOut(), .SerClkOut(),
    .LinkIn0(ser_up_rc), .LinkIn1(1'b0), .LinkIn2(1'b0), .LinkIn3(1'b0), .LinkIn4(1'b0), .LinkIn5(1'b0),
    .LinkIn6(1'b0), .LinkIn7(1'b0), .LinkIn8(1'b0), .LinkIn9(1'b0), .LinkIn10(1'b0), .LinkIn11(1'b0),
    .LinkIn12(1'b0), .LinkIn13(1'b0), .LinkIn14(1'b0), .LinkIn15(1'b0),
    .LinkOut0(ser_dn), .LinkOut1(), .LinkOut2(), .LinkOut3(), .LinkOut4(), .LinkOut5(), .LinkOut6(),
    .LinkOut7(), .LinkOut8(), .LinkOut9(), .LinkOut10(), .LinkOut11(), .LinkOut12(), .LinkOut13(),
    .LinkOut14(), .LinkOut15());

  task Fatal;
    $fatal(1, "pcieVHost fatal: the RC model's FAIL, or a bad VProc access");
  endtask

  // ---------------- monitors ----------------
  reg [5:0] ltq = 6'h3F;
  always @(posedge pclk) if (ltssm != ltq) begin ltq <= ltssm; $display("%t tb: EP LTSSM 0x%02h", $time, ltssm); end
  always @(lnk) $display("%t tb: EP DL up = %b", $time, lnk);
  always @(phy_rdy) $display("%t tb: PHY ready = %b (dbg %08b)", $time, phy_rdy, dbg);
  // COM lanes seen by the EP (16 PIPE symbols), receiver errors in L0, RxStatus, rate changes, time at 5 GT/s
  int com_lane [16]; int rxerr_l0 = 0, rxerr_all = 0, st_add = 0, st_rmv = 0, st_err = 0, st_und = 0;
  int bufrst = 0, n_rate = 0, ovf = 0; realtime t_gen2 = 0, t_l0g2 = 0;
  always @(posedge pclk) begin
    if (rxv) for (int i = 0; i < 16; i++) if (rxk[i] && rxd[8*i +: 8] == 8'hBC) com_lane[i]++;
    if (ep.core.eerie.rx_err) begin rxerr_all++; if (phylnk && ltssm == 6'h16) rxerr_l0++; end
    if (ep.core.eerie.w16_ovf) ovf++;
    if (rxv) case (rxs) 3'b001: st_add++; 3'b010: st_rmv++; 3'b100: st_err++; 3'b110: st_und++; default: ; endcase
  end
  // the PIPE symbol of the COM of the first TS1/TS2 (COM, then data or PAD) at each rate: the alignment of
  // the 16-symbol word to the line, from the SerDes word phase and the gearbox pairing
  int ts_lane [2] = '{-1, -1}; bit c15 = 0;
  always @(posedge pclk) if (ep_rst_n) begin
    if (rxv && c15 && (!rxk[0] || rxd[7:0] == 8'hF7) && ts_lane[rate] < 0) begin
      ts_lane[rate] = 15; $display("%t tb: first TS at %s GT/s: COM in PIPE symbol 15", $time, rate ? "5.0" : "2.5");
    end
    if (rxv) for (int i = 14; i >= 0; i--)
      if (rxk[i] && rxd[8*i +: 8] == 8'hBC && (!rxk[i+1] || rxd[8*(i+1) +: 8] == 8'hF7) && ts_lane[rate] < 0) begin
        ts_lane[rate] = i; $display("%t tb: first TS at %s GT/s: COM in PIPE symbol %0d", $time, rate ? "5.0" : "2.5", i);
      end
    c15 = rxv && rxk[15] && rxd[127:120] == 8'hBC;
  end
  always @(rate) begin
    n_rate++; $display("%t tb: EP PIPE Rate = %0d (%s GT/s)", $time, rate, rate ? "5.0" : "2.5");
    if (rate) t_gen2 = $realtime;
  end
  always @(posedge pclk) if (rate && ltssm == 6'h16 && t_l0g2 == 0) begin
    t_l0g2 = $realtime; $display("%t tb: EP in L0 at 5.0 GT/s", $time);
  end
  always @(posedge phys) if (ep_rst_n) $display("%t tb: PhyStatus pulse (rate %0d, LTSSM 0x%02h)", $time, rate, ltssm);
  always @(posedge dbg[7]) bufrst++;
  // +dbgrl: every 2 us in Recovery: TX mode / electrical idle, TS received, rate (debug)
  int n_tsv = 0; always @(posedge pclk) if (ep.core.eerie.l_tsv[0]) n_tsv++;
  initial forever begin #(2us); if ($test$plusargs("dbgrl") && ltssm >= 6'h1c && ltssm <= 6'h20)
    $display("%t dbg: LTSSM 0x%02h tx_mode %0d txei %b rate %0d ts_rx %0d os_rate %02h rxv %b rxei %b sub %0d cnt_a %0d dsc %b",
      $time, ltssm, ep.core.eerie.tx_mode, txei, rate, n_tsv, ep.core.eerie.l_rate[7:0], rxv, rxei,
      ep.core.eerie.ltssm.sub, ep.core.eerie.ltssm.cnt_a, ep.core.eerie.ltssm.directed_speed_change); end
`ifdef SRNS
  // EB16: fill (read view) every 10 us, write-side inserts / removes
  int eb_ins = 0, eb_del = 0;
  always @(posedge phy.g_eb.wclk16) begin if (phy.g_eb.eb.s1_ins) eb_ins++; if (phy.g_eb.eb.s1_del) eb_del++; end
  initial forever begin #(10us); if ($test$plusargs("ebmon"))
    $display("%t tb: EB16 fill %0d wfill %0d ins %0d del %0d rate %0d LTSSM 0x%02h", $time, phy.g_eb.eb.r_fill,
             phy.g_eb.eb.wfill, eb_ins, eb_del, rate, ltssm); end
`endif
  final begin
    $write("tb: COM lanes");
    for (int i = 0; i < 16; i++) $write(" %0d", com_lane[i]);
    $write("\n");
    $display("tb: rx_err L0 %0d, all %0d; RxStatus SKP+ %0d SKP- %0d err %0d under %0d; RX buffer errors %0d; slot FIFO overflows %0d; ppm %0d",
             rxerr_l0, rxerr_all, st_add, st_rmv, st_err, st_und, bufrst, ovf, ippm);
    $display("tb: TS COM symbol 2.5 GT/s %0d, 5.0 GT/s %0d", ts_lane[0], ts_lane[1]);
    $display("tb: EP LTSSM 0x%02h lnk_up %b rate %0d; rate changes %0d; L0 at 5.0 GT/s from %0t; retimer %0d (EP->RC SKP +%0d -%0d)",
             ltssm, lnk, rate, n_rate, t_l0g2, retime, rt_ins, rt_del);
  end
endmodule
