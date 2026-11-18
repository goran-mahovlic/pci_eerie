// SPDX-License-Identifier: CERN-OHL-P-2.0
// ULX4M-LD (LFE5UM5G-85F) + ULX4M-PCIe-IO: otvoreni PCIe Gen1 x1 endpoint s pci_eerie (TASK-6160).
// Lanac: yosys + nextpnr-ecp5 + Trellis, bez Diamonda i bez IP Expressa.
// DCU0 CH0 (TX W4/W5, RX Y5/Y6), EXTREF0 (Y11/Y12) = 100 MHz host REFCLK; PERST# D8; CLKREQ# A10 = Z.
// LED: 0 PERST# (1 = pušten), 1 TX PLL spreman, 2 signal na RX-u (bez LOS-a), 3 RX poravnat (LSM),
//      4 prijemnik hosta detektiran, 5 LTSSM u L0, 6 DL up, 7 živ pclk (~1,9 Hz).
`timescale 1ns / 1ps
`ifndef LD_IGNORE_LOL
`define LD_IGNORE_LOL 0
`endif
`ifndef LD_IGNORE_POL
`define LD_IGNORE_POL 0
`endif
`ifndef LD_FORCE_INV
`define LD_FORCE_INV 0
`endif
module top_ld_eerie (
    input        clk_25mhz,
    input        refclkp, refclkn,
    input        rxp, rxn,
    output       txp, txn,
    input        pcie_perst_n,
    inout        pcie_clkreq_n,
    output [7:0] led,
    output [4:0] dbg_tx            // 115200 8N1, eerie_dbg_uart; a=N3 ftdi_rxd, b=P2 GPIO14, c=G1 GPIO15, d=B15 GPIO4, e=N1 GPIO5
);
    assign pcie_clkreq_n = 1'bz;

    wire refclk;
    (* LOC = "EXTREF0" *)
    EXTREFB #(
`include "extref_params.vh"
    ) u_ext (.REFCLKP(refclkp), .REFCLKN(refclkn), .REFCLKO(refclk));

    wire        pclk, uclk;
    wire [23:0] rx_d, tx_d;
    wire        plol, rlol, rlos, lsm, done, con;
    wire        trst, rrst, lrx_rst, ltx_rst, det_en, ct, inv;

    (* LOC = "DCU0" *)
    DCUA #(
`include "dcua_gen1_params.vh"
    ) u_dcu (
        .CH0_HDINP(rxp), .CH0_HDINN(rxn), .CH0_HDOUTP(txp), .CH0_HDOUTN(txn),
        .D_REFCLKI(refclk), .CH0_RX_REFCLK(refclk),
        .D_FFC_MACROPDB(1'b1), .D_FFC_MACRO_RST(1'b0), .D_FFC_DUAL_RST(1'b0), .D_FFC_TRST(trst),
        .D_FFS_PLOL(plol),
        .CH0_FFC_RXPWDNB(1'b1), .CH0_FFC_TXPWDNB(1'b1),
        .CH0_FFC_RRST(rrst), .CH0_FFC_LANE_RX_RST(lrx_rst), .CH0_FFC_LANE_TX_RST(ltx_rst),
        .CH0_FF_TX_PCLK(pclk), .CH0_FF_TXI_CLK(pclk), .CH0_FF_RXI_CLK(pclk), .CH0_FF_EBRD_CLK(pclk),
        .CH0_FFC_SIGNAL_DETECT(1'b1), .CH0_FFC_ENABLE_CGALIGN(1'b0), .CH0_FFC_EI_EN(1'b0),
        .CH0_FFC_SB_INV_RX(inv), .CH0_FFC_FB_LOOPBACK(1'b0), .CH0_FFC_SB_PFIFO_LP(1'b0), .CH0_FFC_PFIFO_CLR(1'b0),
        .CH0_FFC_RATE_MODE_RX(1'b0), .CH0_FFC_RATE_MODE_TX(1'b0), .CH0_FFC_DIV11_MODE_RX(1'b0), .CH0_FFC_DIV11_MODE_TX(1'b0),
        .CH0_FFC_LDR_CORE2TX_EN(1'b0), .CH0_FFC_CDR_EN_BITSLIP(1'b0),
        .CH0_FFC_PCIE_DET_EN(det_en), .CH0_FFC_PCIE_CT(ct),
        .CH0_FFS_PCIE_DONE(done), .CH0_FFS_PCIE_CON(con),
        .CH0_FFS_RLOS(rlos), .CH0_FFS_RLOL(rlol), .CH0_FFS_LS_SYNC_STATUS(lsm),
        .CH0_FF_TX_D_0(tx_d[0]), .CH0_FF_TX_D_1(tx_d[1]), .CH0_FF_TX_D_2(tx_d[2]), .CH0_FF_TX_D_3(tx_d[3]),
        .CH0_FF_TX_D_4(tx_d[4]), .CH0_FF_TX_D_5(tx_d[5]), .CH0_FF_TX_D_6(tx_d[6]), .CH0_FF_TX_D_7(tx_d[7]),
        .CH0_FF_TX_D_8(tx_d[8]), .CH0_FF_TX_D_9(tx_d[9]), .CH0_FF_TX_D_10(tx_d[10]), .CH0_FF_TX_D_11(tx_d[11]),
        .CH0_FF_TX_D_12(tx_d[12]), .CH0_FF_TX_D_13(tx_d[13]), .CH0_FF_TX_D_14(tx_d[14]), .CH0_FF_TX_D_15(tx_d[15]),
        .CH0_FF_TX_D_16(tx_d[16]), .CH0_FF_TX_D_17(tx_d[17]), .CH0_FF_TX_D_18(tx_d[18]), .CH0_FF_TX_D_19(tx_d[19]),
        .CH0_FF_TX_D_20(tx_d[20]), .CH0_FF_TX_D_21(tx_d[21]), .CH0_FF_TX_D_22(tx_d[22]), .CH0_FF_TX_D_23(tx_d[23]),
        .CH0_FF_RX_D_0(rx_d[0]), .CH0_FF_RX_D_1(rx_d[1]), .CH0_FF_RX_D_2(rx_d[2]), .CH0_FF_RX_D_3(rx_d[3]),
        .CH0_FF_RX_D_4(rx_d[4]), .CH0_FF_RX_D_5(rx_d[5]), .CH0_FF_RX_D_6(rx_d[6]), .CH0_FF_RX_D_7(rx_d[7]),
        .CH0_FF_RX_D_8(rx_d[8]), .CH0_FF_RX_D_9(rx_d[9]), .CH0_FF_RX_D_10(rx_d[10]), .CH0_FF_RX_D_11(rx_d[11]),
        .CH0_FF_RX_D_12(rx_d[12]), .CH0_FF_RX_D_13(rx_d[13]), .CH0_FF_RX_D_14(rx_d[14]), .CH0_FF_RX_D_15(rx_d[15]),
        .CH0_FF_RX_D_16(rx_d[16]), .CH0_FF_RX_D_17(rx_d[17]), .CH0_FF_RX_D_18(rx_d[18]), .CH0_FF_RX_D_19(rx_d[19]),
        .CH0_FF_RX_D_20(rx_d[20]), .CH0_FF_RX_D_21(rx_d[21]), .CH0_FF_RX_D_22(rx_d[22]), .CH0_FF_RX_D_23(rx_d[23])
    );

    // user takt 62,5 MHz = pclk / 2
    CLKDIVF #(.DIV("2.0")) u_div (.CLKI(pclk), .RST(1'b0), .ALIGNWD(1'b0), .CDIVX(uclk));

    ld_eerie_core #(.IGNORE_LOL(`LD_IGNORE_LOL), .IGNORE_POL(`LD_IGNORE_POL), .FORCE_INV(`LD_FORCE_INV)) core (
        .clk_free(clk_25mhz), .pclk(pclk), .uclk(uclk), .perst_n(pcie_perst_n),
        .dcu_rx_d(rx_d), .dcu_tx_d(tx_d), .dcu_plol(plol), .dcu_rlol(rlol), .dcu_rlos(rlos), .dcu_lsm(lsm),
        .dcu_pcie_done(done), .dcu_pcie_con(con), .dcu_trst(trst), .dcu_rrst(rrst), .dcu_lane_rx_rst(lrx_rst),
        .dcu_lane_tx_rst(ltx_rst), .dcu_pcie_det_en(det_en), .dcu_pcie_ct(ct), .dcu_sb_inv_rx(inv),
        .led(led), .dbg_tx(dbg_tx)
    );
endmodule

// Sve iznad DCU-a (shim + pci_eerie + BAR0 app + LED-ice) — isti modul ide u simulaciju s modelom DCU-a.
module ld_eerie_core #(
    parameter FAST_TRAIN = "FALSE",
    parameter TRST_W = 6, PLL_W = 17, LOS_W = 12, LOL_W = 12, DET_US = 125, IGNORE_LOL = 0, IGNORE_POL = 0, FORCE_INV = 0
) (
    input         clk_free, pclk, uclk, perst_n,
    input  [23:0] dcu_rx_d,
    output [23:0] dcu_tx_d,
    input         dcu_plol, dcu_rlol, dcu_rlos, dcu_lsm, dcu_pcie_done, dcu_pcie_con,
    output        dcu_trst, dcu_rrst, dcu_lane_rx_rst, dcu_lane_tx_rst, dcu_pcie_det_en, dcu_pcie_ct, dcu_sb_inv_rx,
    output [7:0]  led,
    output [5:0]  ltssm,
    output        lnk_up,
    output [4:0]  dbg_tx
);
    wire [15:0] rxd, txd;
    wire [1:0]  rxk, txk, pd;
    wire [2:0]  rxs;
    wire        rxv, rxei, phys, txei, txc, det, pol, rate, txr, rxr, con, phy_up;

    eerie_ecp5_pipe #(.TRST_W(TRST_W), .PLL_W(PLL_W), .LOS_W(LOS_W), .LOL_W(LOL_W), .DET_US(DET_US), .IGNORE_LOL(IGNORE_LOL), .IGNORE_POL(IGNORE_POL), .FORCE_INV(FORCE_INV)) phy (
        .clk_free(clk_free), .pclk(pclk),
        .dcu_rx_d(dcu_rx_d), .dcu_tx_d(dcu_tx_d), .dcu_plol(dcu_plol), .dcu_rlol(dcu_rlol), .dcu_rlos(dcu_rlos),
        .dcu_lsm(dcu_lsm), .dcu_pcie_done(dcu_pcie_done), .dcu_pcie_con(dcu_pcie_con),
        .dcu_trst(dcu_trst), .dcu_rrst(dcu_rrst), .dcu_lane_rx_rst(dcu_lane_rx_rst), .dcu_lane_tx_rst(dcu_lane_tx_rst),
        .dcu_pcie_det_en(dcu_pcie_det_en), .dcu_pcie_ct(dcu_pcie_ct), .dcu_sb_inv_rx(dcu_sb_inv_rx),
        .rxdata(rxd), .rxdatak(rxk), .rxvalid(rxv), .rxelecidle(rxei), .rxstatus(rxs), .phystatus(phys),
        .txdata(txd), .txdatak(txk), .txelecidle(txei), .txcompliance(txc), .powerdown(pd), .txdetectrx(det),
        .rxpolarity(pol), .tx_ready(txr), .rx_ready(rxr), .det_con(con));

    // MAC u resetu dok je PERST# aktivan ili TX PLL nije spreman
    reg [2:0] perst_s;
    always @(posedge pclk) perst_s <= {perst_s[1:0], perst_n};
    wire sys_rst_n = perst_s[2] && txr;

    eerie_x1_ep #(.FAST_TRAIN(FAST_TRAIN)) ep (
        .pclk(pclk), .uclk(uclk), .sys_rst_n(sys_rst_n),
        .pipe_rxdata(rxd), .pipe_rxdatak(rxk), .pipe_rxvalid(rxv), .pipe_rxelecidle(rxei),
        .pipe_rxstatus(rxs), .pipe_phystatus(phys),
        .pipe_txdata(txd), .pipe_txdatak(txk), .pipe_txelecidle(txei), .pipe_txcompliance(txc),
        .pipe_powerdown(pd), .pipe_txdetectrx(det), .pipe_rxpolarity(pol), .pipe_rate(rate),
        .ltssm(ltssm), .phy_lnk_up(phy_up), .lnk_up(lnk_up));

    reg [25:0] hb;
    always @(posedge pclk) hb <= hb + 1'b1;
    assign led = {hb[25], lnk_up, ltssm == 6'h16, con, rxv, !rxei, txr, perst_s[2]};

    // promatrač RX puta (samo čita): RSL zastavice, LTSSM, brojači K28.5/TS1/TS2/grešaka na UART
    eerie_dbg_uart #(.NTX(5)) dbg (
        .clk_free(clk_free), .pclk(pclk),
        .flags({con, rxr, dcu_lsm, !dcu_rlol, !dcu_rlos, txr, perst_s[2]}),
        .ltssm(ltssm), .lnk_up(lnk_up), .dcu_rx_d(dcu_rx_d), .rxvalid(rxv), .rxpolarity(pol), .tx(dbg_tx));
endmodule
