// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6238: ULX5M-M2 v002 in a PCIe slot (M.2 M key): pci_eerie Gen2 x1 endpoint (EERIE_W16, 128-bit PIPE)
// on CC_SERDES. The same eerie_ccs_phy16 + eerie_w16_ep as the serial-line simulation (sim/ser/tb_ser16.sv);
// the file list takes ccfpga_serdes.SYNTH.sv (CC_SERDES). Pins and resets as m2_pcie_top (TASK-6170).
//   clk_i     25 MHz (Y1): power-on reset and the SerDes register file clock (rate change 2.5 <-> 5.0 GT/s)
//   perst_n   PCIe PERST# (v002: IO_SA_A1): resets the SerDes, the PLL and the endpoint
//   clkreq_n  CLKREQ# (v002: IO_SA_B3): held low
// PCLK = SerDes word clock / 2: 15.625 MHz at 2.5 GT/s, 31.25 MHz at 5.0 GT/s. SRNS = 0 (host REFCLK).
`timescale 1ns / 1ps
module m2_pcie16_top #(
    parameter SRNS    = 0,
    parameter MAX_GEN = 2
) (
    input  clk_i,
    input  perst_n,
    output clkreq_n
`ifdef M2_LED
   ,output [7:0] led
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

    wire         pclk, phy_rdy;
    wire [127:0] rxd, txd; wire [15:0] rxk, txk; wire [7:0] dbg;
    wire         rxv, rxei, phys, txei, txc, det, pol, rate; wire [2:0] rxs; wire [1:0] pd;
    wire [5:0]   ltssm; wire lnk, phylnk;

    // endpoint reset: PHY ready, then 255 clocks with PhyStatus low
    reg [7:0] hold = 8'd0;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) hold <= 8'd0;
        else if (!phy_rdy || phys && hold != 8'hFF) hold <= 8'd0;
        else if (hold != 8'hFF) hold <= hold + 1'b1;
    wire ep_rst_n = (hold == 8'hFF);

    eerie_ccs_phy16 #(.SRNS(SRNS)) phy (
        .rst_n(rst_n), .clk_ref(1'b0), .clk_cfg(clk_i), .ser_rxp(1'b0), .ser_rxn(1'b0), .ser_txp(), .ser_txn(),
        .pclk(pclk), .phy_rdy(phy_rdy),
        .txdata(txd), .txdatak(txk), .txelecidle(txei), .txcompliance(txc), .powerdown(pd), .txdetectrx(det),
        .rxpolarity(pol), .rate(rate), .rxdata(rxd), .rxdatak(rxk), .rxvalid(rxv), .rxelecidle(rxei), .rxstatus(rxs),
        .phystatus(phys), .dbg(dbg));

    eerie_w16_ep #(.MAX_GEN(MAX_GEN), .FAST_TRAIN("FALSE"), .ADDR_XOR(4'd8)) ep (
        .pclk(pclk), .uclk(pclk), .sys_rst_n(ep_rst_n),
        .pipe_rxdata(rxd), .pipe_rxdatak(rxk), .pipe_rxvalid(rxv), .pipe_rxelecidle(rxei),
        .pipe_rxstatus(rxs), .pipe_phystatus(phys),
        .pipe_txdata(txd), .pipe_txdatak(txk), .pipe_txelecidle(txei), .pipe_txcompliance(txc),
        .pipe_powerdown(pd), .pipe_txdetectrx(det), .pipe_rxpolarity(pol), .pipe_rate(rate),
        .ltssm(ltssm), .phy_lnk_up(phylnk), .lnk_up(lnk));

`ifdef M2_LED
    //   0 PHY ready   1 RX reset done   2 comma aligned   3 PERST# released
    //   4 LTSSM in Polling/Configuration   5 LTSSM L0   6 DL up   7 5.0 GT/s (rate)
    assign led = {rate, lnk, ltssm == 6'h16, ltssm >= 6'h04 && ltssm < 6'h16, ps[2], dbg[5], dbg[3], phy_rdy};
`endif
endmodule
