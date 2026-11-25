// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6170: pci_eerie EERIE_W8 endpoint on the serial line, Verilator.
//   host  = openPCIE_BFM's Artix-7 RC model (pcieVHost PcieVhostSerial, VProc node 2, VUserMain2.cpp, 59 rules)
//   PHY   = eerie_ccs_phy: ONE ccfpga_serdes instance, here openSERDES_BFM ccfpga_serdes.BFM.sv (CDR_MODEL=FAST)
//   EP    = eerie_w8_ep (pci_eerie with EERIE_W8 + BAR0 application), the same as on the chip
// Plusargs: +ppm=N  the EP reference clock N ppm off (positive: slower), the host stays nominal
// The module must be "tb" with a task Fatal (pcieVHost calls tb.Fatal).
module tb;
  localparam HALF_SER_PS   = 100;     // 5 GHz: the host divides it to 2.5 GHz at Gen1
  localparam HALF_PCIE2_PS = 1000;    // 500 MHz: the host divides it to 250 MHz at Gen1
  localparam RUN_US        = 4000;

  logic rst_n = 1'b0;
  logic serclk = 1'b0, pcieclk2 = 1'b0, refclk = 1'b0;
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

  integer run_us = RUN_US;    // TASK-6192: +run_us=N (Recovery.Idle 2 ms timeouts need more than 4 ms)
  initial begin
    void'($value$plusargs("run_us=%d", run_us));
    #(25ns) rst_n <= 1'b1;
    #(run_us * 1us);
    $display("tb: TIME LIMIT %0d us: no RC MODEL RESULT", run_us);
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

  // ---------------- EP: PHY glue + eerie W8 ----------------
  wire        pclk, phy_rdy;
  wire [63:0] rxd, txd; wire [7:0] rxk, txk, dbg;
  wire        rxv, rxei, phys, txei, txc, det, pol; wire [2:0] rxs; wire [1:0] pd;
  wire [5:0]  ltssm; wire lnk, phylnk;

  // EP reset: PHY ready, then 255 clocks with PhyStatus low (as gs_hyb_top)
  reg [7:0] hold = 8'd0;
  always @(posedge pclk or negedge rst_n)
    if (!rst_n) hold <= 8'd0;
    else if (!phy_rdy || phys && hold != 8'hFF) hold <= 8'd0;
    else if (hold != 8'hFF) hold <= hold + 1'b1;
  wire ep_rst_n = (hold == 8'hFF);

  eerie_ccs_phy #(.SRNS(`ifdef SRNS 1 `else 0 `endif)) phy (
    .rst_n(rst_n), .clk_ref(refclk),
    .ser_rxp(ser_dn), .ser_rxn(ser_dn_idle ? ser_dn : ~ser_dn), .ser_txp(ser_up), .ser_txn(ser_up_n),
    .pclk(pclk), .phy_rdy(phy_rdy),
    .txdata(txd), .txdatak(txk), .txelecidle(txei), .txcompliance(txc), .powerdown(pd), .txdetectrx(det),
    .rxpolarity(pol), .rxdata(rxd), .rxdatak(rxk), .rxvalid(rxv), .rxelecidle(rxei), .rxstatus(rxs),
    .phystatus(phys), .dbg(dbg));

  eerie_w8_ep #(.FAST_TRAIN("FALSE"), .ADDR_XOR(4'd8)) ep (
    .pclk(pclk), .uclk(pclk), .sys_rst_n(ep_rst_n),
    .pipe_rxdata(rxd), .pipe_rxdatak(rxk), .pipe_rxvalid(rxv), .pipe_rxelecidle(rxei),
    .pipe_rxstatus(rxs), .pipe_phystatus(phys),
    .pipe_txdata(txd), .pipe_txdatak(txk), .pipe_txelecidle(txei), .pipe_txcompliance(txc),
    .pipe_powerdown(pd), .pipe_txdetectrx(det), .pipe_rxpolarity(pol), .pipe_rate(),
    .ltssm(ltssm), .phy_lnk_up(phylnk), .lnk_up(lnk));

  // EP -> RC: straight, or through the retimer when the EP clock is off nominal (+ppm, or +retime)
  wire ser_up_rc, ser_up_rt; int rt_ins, rt_del; bit retime = 1'b0;
  real ui_ep_ps;
  int  rt_ppm = 0;
  initial begin
    void'($value$plusargs("ppm=%d", rt_ppm));           // read here: the order of initial blocks is not defined
    ui_ep_ps = 400.0 * (1.0 + rt_ppm * 1.0e-6); retime = (rt_ppm != 0) || $test$plusargs("retime");
  end
  ser_retimer u_rt (.serclk(serclk), .din(ser_up), .ui_in_ps(ui_ep_ps), .gen2(1'b0), .dout(ser_up_rt), .n_ins(rt_ins), .n_del(rt_del));
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
  // COM lanes seen by the EP (the SerDes aligns on any lane), receiver errors in L0, RxStatus
  int com_lane [8]; int rxerr_l0 = 0, rxerr_all = 0, st_add = 0, st_rmv = 0, st_err = 0, st_und = 0;
  int bufrst = 0;
  always @(posedge pclk) begin
    if (rxv) for (int i = 0; i < 8; i++) if (rxk[i] && rxd[8*i +: 8] == 8'hBC) com_lane[i]++;
    if (ep.core.eerie.rx_err) begin rxerr_all++; if (phylnk && ltssm == 6'h16) rxerr_l0++; end
    if (rxv) case (rxs) 3'b001: st_add++; 3'b010: st_rmv++; 3'b100: st_err++; 3'b110: st_und++; default: ; endcase
  end
  always @(posedge dbg[7]) bufrst++;
  final begin
    $display("tb: COM lanes %0d %0d %0d %0d %0d %0d %0d %0d", com_lane[0], com_lane[1], com_lane[2], com_lane[3],
             com_lane[4], com_lane[5], com_lane[6], com_lane[7]);
    $display("tb: rx_err L0 %0d, all %0d; RxStatus SKP+ %0d SKP- %0d err %0d under %0d; RX buffer errors %0d; ppm %0d",
             rxerr_l0, rxerr_all, st_add, st_rmv, st_err, st_und, bufrst, ippm);
    $display("tb: EP LTSSM 0x%02h lnk_up %b; retimer %0d (EP->RC SKP +%0d -%0d)", ltssm, lnk, retime, rt_ins, rt_del);
  end
endmodule
