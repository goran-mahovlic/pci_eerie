// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6170: ULX5M-M2 in a PCIe slot (M.2 M key): pci_eerie Gen1 x1 endpoint (EERIE_W8) on CC_SERDES.
// The same eerie_ccs_phy + eerie_w8_ep as the serial-line simulation (sim/ser/tb_ser.sv); here the file
// list takes ccfpga_serdes.SYNTH.sv (CC_SERDES) instead of ccfpga_serdes.BFM.sv.
//   clk_i     25 MHz (Y1): power-on reset only
//   perst_n   PCIe PERST# (M.2 pin 50, IO_SA_A1): resets the SerDes, the PLL and the endpoint
//   clkreq_n  CLKREQ# (M.2 pin 52, IO_SA_B3): held low, the host gates REFCLK with it (uputa #544)
// REFCLK: the M2 has no X2, the SerDes reference is the host's PCIe REFCLK (common clock): SRNS = 0.
`timescale 1ns / 1ps
module m2_pcie_top #(
    parameter SRNS = 0
) (
    input  clk_i,
    input  perst_n,
    output clkreq_n
`ifdef M2_LED
   ,output [7:0] led
`endif
`ifdef EERIE_ILA
   ,output uart_tx                       // TASK-6190: ILA dump / status (probe if01)
   ,input  uart_rx
`endif
);
    assign clkreq_n = 1'b0;

    // power-on (~2.6 ms on 25 MHz) and PERST#, synchronised; async assert into the PHY
    reg [15:0] por = 16'd0;
    reg [2:0]  ps = 3'b000;
    always @(posedge clk_i) begin
        if (!(&por)) por <= por + 1'b1;
        ps <= {ps[1:0], perst_n};
    end
    wire rst_n = (&por) && ps[2];

    wire        pclk, phy_rdy;
    wire [63:0] rxd, txd; wire [7:0] rxk, txk, dbg;
    wire        rxv, rxei, phys, txei, txc, det, pol; wire [2:0] rxs; wire [1:0] pd;
    wire [5:0]  ltssm; wire lnk, phylnk;

    // endpoint reset: PHY ready, then 255 clocks with PhyStatus low
    reg [7:0] hold = 8'd0;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) hold <= 8'd0;
        else if (!phy_rdy || phys && hold != 8'hFF) hold <= 8'd0;
        else if (hold != 8'hFF) hold <= hold + 1'b1;
    wire ep_rst_n = (hold == 8'hFF);
`ifdef EERIE_ALIGN_L0
    // TASK-6185: comma alignment off after 2^12 PCLK (131 us) in L0 without a break, back on as soon as L0 is left
    reg [12:0] l0c = 13'd0;
    always @(posedge pclk) l0c <= (ltssm != 6'h16) ? 13'd0 : (l0c[12] ? l0c : l0c + 1'b1);
    wire ahold = l0c[12];
`endif
`ifdef EERIE_EQA_POLL
    // TASK-6185: GS<->M2 readapt (SER-CAL-04/06; SRST restarts both RX on a live signal) for PCIe: the EP comes out of
    // power-on / configuration while the host TX is still idle, so the adaptive EQA settles (and locks, LOCK_CFG 0xC) on
    // no signal. Once per Polling.Active visit, after 2^8 PCLK (8 us) with the RX out of electrical idle, a 16 PCLK pulse
    // restarts the RX from the EQA stage on the host's TS1 (Polling.Active lasts >= 1024 TS1 = 65 us anyway).
    reg [8:0] pac = 9'd0; reg [4:0] eqp = 5'd0; reg eqd = 1'b0;
    always @(posedge pclk) begin
        if (ltssm != 6'h04) begin pac <= 9'd0; eqd <= 1'b0; end
        else if (!eqd) begin
            pac <= rxei ? 9'd0 : pac + 1'b1;
            if (pac[8]) begin eqd <= 1'b1; eqp <= 5'd16; end
        end
        if (eqp != 5'd0) eqp <= eqp - 1'b1;
    end
    wire eqa_rst = (eqp != 5'd0);
`endif
`ifdef EERIE_DBGCNT
    wire [63:0] dbgc;
`endif
`ifdef EERIE_ILA
    wire [31:0] ppmw;
`endif

    eerie_ccs_phy #(.SRNS(SRNS)) phy (
        .rst_n(rst_n), .clk_ref(1'b0), .ser_rxp(1'b0), .ser_rxn(1'b0), .ser_txp(), .ser_txn(),
        .pclk(pclk), .phy_rdy(phy_rdy),
        .txdata(txd), .txdatak(txk), .txelecidle(txei), .txcompliance(txc), .powerdown(pd), .txdetectrx(det),
        .rxpolarity(pol), .rxdata(rxd), .rxdatak(rxk), .rxvalid(rxv), .rxelecidle(rxei), .rxstatus(rxs),
        .phystatus(phys), .dbg(dbg)
`ifdef EERIE_ALIGN_L0
       ,.align_hold(ahold)
`endif
`ifdef EERIE_EQA_POLL
       ,.eqa_rst(eqa_rst)
`endif
`ifdef EERIE_DBGCNT
       ,.dbgc(dbgc)
`endif
`ifdef EERIE_ILA
       ,.ppmw(ppmw)
`endif
        );

    eerie_w8_ep #(.FAST_TRAIN("FALSE"), .ADDR_XOR(4'd8)) ep (
        .pclk(pclk), .uclk(pclk), .sys_rst_n(ep_rst_n),
        .pipe_rxdata(rxd), .pipe_rxdatak(rxk), .pipe_rxvalid(rxv), .pipe_rxelecidle(rxei),
        .pipe_rxstatus(rxs), .pipe_phystatus(phys),
        .pipe_txdata(txd), .pipe_txdatak(txk), .pipe_txelecidle(txei), .pipe_txcompliance(txc),
        .pipe_powerdown(pd), .pipe_txdetectrx(det), .pipe_rxpolarity(pol), .pipe_rate(),
        .ltssm(ltssm), .phy_lnk_up(phylnk), .lnk_up(lnk)
`ifdef EERIE_DBGCNT
       ,.phy_dbgc(dbgc)
`endif
`ifdef EERIE_ILA
       ,.phy_ppm(ppmw), .uart_tx(uart_tx), .uart_rx(uart_rx)
`endif
`ifdef EERIE_ILA3B
       ,.phy_dbg(dbg)                    // TASK-6192: SerDes flags into the ILA3 word records
`endif
        );

`ifdef M2_LED
    // TASK-6172: v001 LEDs (active high) for bring-up on camera j1
    //   0 PHY ready (PLL, TX reset done)   1 RX reset done (CDR)   2 comma aligned   3 PERST# released
    //   4 LTSSM in Polling/Configuration   5 LTSSM L0              6 DL up           7 PCLK heartbeat ~1 Hz
    reg [24:0] hb = 25'd0;
    always @(posedge pclk) hb <= hb + 1'b1;
    assign led = {hb[24], lnk, ltssm == 6'h16, ltssm >= 6'h04 && ltssm < 6'h16, ps[2], dbg[5], dbg[3], phy_rdy};
`endif
endmodule
