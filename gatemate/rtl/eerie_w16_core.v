// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6173: kao eerie_w8_core, ali PIPE x1 od 128 bita (16 simbola/takt; pci_eerie s EERIE_W16), Gen2:
// 5,0 GT/s na 31,25 MHz, 2,5 GT/s na 15,625 MHz (fiksna širina, PIPE takt prati brzinu; pipe_rate van).
// MAX_GEN = 1: samo 2,5 GT/s (oglašava Gen1).
// TASK-6161: kao eerie_x1_core, ali PIPE x1 od 64 bita (8 simbola/takt, 31,25 MHz; pci_eerie s EERIE_W8).
// pci_eerie x1 Gen1 bez Xilinx omotača (TASK-6160): jezgra + dva MIM RAM-a, PIPE x1 i 64-bitni TRN van.
// Ne koristi pcie_7x (pcie_block, AXI mostovi i GT omotač su Xilinx datoteke) — samo rtl/ iz pci_eerie.
// RP=0: endpoint (tip 0); RP=1: root port (samo za simulaciju petlje).
`timescale 1ns / 1ps
module eerie_w16_core #(
    parameter        MAX_GEN    = 2,
    parameter        RP         = 0,
    parameter        FAST_TRAIN = "FALSE",
    parameter [31:0] BAR0       = 32'hFFFFF000,      // 4 KB, 32-bit, memorijski, bez prefetcha
    parameter [23:0] CLASS_CODE = 24'hFF0000
) (
    input             pclk,          // PIPE takt: 15,625 MHz (2,5 GT/s) / 31,25 MHz (5,0 GT/s), 128 bita
    input             uclk,          // user takt (64-bitni TRN; = pclk)
    input             sys_rst_n,
    // PIPE x1
    input     [127:0] pipe_rxdata,     // simbol 0 u [7:0]
    input      [15:0] pipe_rxdatak,
    input             pipe_rxvalid,
    input             pipe_rxelecidle,
    input      [2:0]  pipe_rxstatus,
    input             pipe_phystatus,
    output    [127:0] pipe_txdata,
    output     [15:0] pipe_txdatak,
    output            pipe_txelecidle,
    output            pipe_txcompliance,
    output     [1:0]  pipe_powerdown,
    output            pipe_txdetectrx,
    output            pipe_rxpolarity,
    output            pipe_rate,
    // TRN (64 bita, user takt)
    output     [63:0] trn_rd,
    output            trn_rrem,
    output            trn_rsof,
    output            trn_reof,
    output            trn_rsrc_rdy,
    output     [7:0]  trn_rbar_hit,
    input             trn_rdst_rdy,
    input      [63:0] trn_td,
    input             trn_trem,
    input             trn_tsof,
    input             trn_teof,
    input             trn_tsrc_rdy,
    output            trn_tdst_rdy,
    output            trn_lnk_up,
    output     [15:0] completer_id,  // {bus, dev, 3'b000} iz CfgWr0
    output            user_rst,
    // root port: odredište konfiguracijskih zahtjeva
    input      [7:0]  ds_bus,
    // stanje
    output     [5:0]  ltssm,
    output            phy_lnk_up
);
    localparam RXAW = 10;   // VC0_RX_RAM_LIMIT = 0x3FF

    wire        rx_we, rx_re, tx_we, tx_re;
    wire [12:0] rx_wa, rx_ra, tx_wa, tx_ra;
    wire [67:0] rx_wd, rx_rd;
    wire [68:0] tx_wd, tx_rd;
    wire [3:0]  tdst;
    wire [1:0]  rrem2;
    wire [127:0] rd128;
    wire [15:0] msg_data;
    wire        msg_rcvd, usr_rstn, phy_lnk_up_n;

    eerie_ram_sdp #(.AW(RXAW), .DW(68)) ram_rx (.clk(uclk), .we(rx_we), .waddr(rx_wa[RXAW-1:0]), .wdata(rx_wd),
        .re(rx_re), .raddr(rx_ra[RXAW-1:0]), .rdata(rx_rd));
    eerie_ram_sdp #(.AW(RXAW), .DW(69)) ram_tx (.clk(uclk), .we(tx_we), .waddr(tx_wa[RXAW-1:0]), .wdata(tx_wd),
        .re(tx_re), .raddr(tx_ra[RXAW-1:0]), .rdata(tx_rd));

    // bus/dev se hvataju iz CFGMSGDATA dok nema poruke (kao pcie_7x pcie_block)
    reg [15:0] cid;
    always @(posedge uclk) if (!usr_rstn) cid <= 16'd0; else if (!msg_rcvd) cid <= msg_data[15:0];
    assign completer_id = cid;
    assign user_rst = !usr_rstn;
    assign phy_lnk_up = !phy_lnk_up_n;
    assign trn_tdst_rdy = tdst[0];
    assign trn_rd = rd128[63:0];
    assign trn_rrem = rrem2[0];

    pci_eerie #(
        .PCIE_CAP_DEVICE_PORT_TYPE(RP ? 4'h4 : 4'h0),
        .HEADER_TYPE(RP ? 8'h01 : 8'h00),
        .UPSTREAM_FACING(RP ? "FALSE" : "TRUE"),
        .LINK_CAP_MAX_LINK_WIDTH(6'h01),
        .LINK_CAP_MAX_LINK_SPEED(MAX_GEN >= 2 ? 4'h2 : 4'h1),
        .LINK_CTRL2_TARGET_LINK_SPEED(MAX_GEN >= 2 ? 4'h2 : 4'h1),
        .BAR0(RP ? 32'h0 : BAR0), .BAR1(32'h0), .BAR2(32'h0), .BAR3(32'h0), .BAR4(32'h0), .BAR5(32'h0),
        .EXPANSION_ROM(32'h0),
        .CLASS_CODE(RP ? 24'h060400 : CLASS_CODE),
        .MSI_CAP_ON("FALSE"),
        .MSIX_CAP_ON("FALSE"),
        .PL_FAST_TRAIN(FAST_TRAIN),
        .VC0_RX_RAM_LIMIT(13'h03FF),
        .TL_RX_RAM_RDATA_LATENCY(2),
        .TL_TX_RAM_RDATA_LATENCY(2),
        .USER_CLK_FREQ(1)
    ) eerie (
`include "eerie_ties_w16.vh"
        .PIPECLK(pclk), .USERCLK(uclk), .USERCLK2(uclk),
        .SYSRSTN(sys_rst_n), .PLRSTN(1'b1),
        .PIPERX0DATA(pipe_rxdata[15:0]), .PIPERX0CHARISK(pipe_rxdatak[1:0]),
        .PIPERX1DATA(pipe_rxdata[31:16]), .PIPERX1CHARISK(pipe_rxdatak[3:2]),
        .PIPERX2DATA(pipe_rxdata[47:32]), .PIPERX2CHARISK(pipe_rxdatak[5:4]),
        .PIPERX3DATA(pipe_rxdata[63:48]), .PIPERX3CHARISK(pipe_rxdatak[7:6]),
        .PIPERX4DATA(pipe_rxdata[79:64]), .PIPERX4CHARISK(pipe_rxdatak[9:8]),
        .PIPERX5DATA(pipe_rxdata[95:80]), .PIPERX5CHARISK(pipe_rxdatak[11:10]),
        .PIPERX6DATA(pipe_rxdata[111:96]), .PIPERX6CHARISK(pipe_rxdatak[13:12]),
        .PIPERX7DATA(pipe_rxdata[127:112]), .PIPERX7CHARISK(pipe_rxdatak[15:14]), .PIPERX0VALID(pipe_rxvalid),
        .PIPERX0ELECIDLE(pipe_rxelecidle), .PIPERX0STATUS(pipe_rxstatus), .PIPERX0PHYSTATUS(pipe_phystatus),
        .PIPERX0CHANISALIGNED(pipe_rxvalid),
        .PIPETX0DATA(pipe_txdata[15:0]), .PIPETX0CHARISK(pipe_txdatak[1:0]),
        .PIPETX1DATA(pipe_txdata[31:16]), .PIPETX1CHARISK(pipe_txdatak[3:2]),
        .PIPETX2DATA(pipe_txdata[47:32]), .PIPETX2CHARISK(pipe_txdatak[5:4]),
        .PIPETX3DATA(pipe_txdata[63:48]), .PIPETX3CHARISK(pipe_txdatak[7:6]),
        .PIPETX4DATA(pipe_txdata[79:64]), .PIPETX4CHARISK(pipe_txdatak[9:8]),
        .PIPETX5DATA(pipe_txdata[95:80]), .PIPETX5CHARISK(pipe_txdatak[11:10]),
        .PIPETX6DATA(pipe_txdata[111:96]), .PIPETX6CHARISK(pipe_txdatak[13:12]),
        .PIPETX7DATA(pipe_txdata[127:112]), .PIPETX7CHARISK(pipe_txdatak[15:14]), .PIPETX0ELECIDLE(pipe_txelecidle),
        .PIPETX0COMPLIANCE(pipe_txcompliance), .PIPETX0POWERDOWN(pipe_powerdown),
        .PIPETXRCVRDET(pipe_txdetectrx), .PIPERX0POLARITY(pipe_rxpolarity), .PIPETXRATE(pipe_rate),
        .MIMRXWEN(rx_we), .MIMRXWADDR(rx_wa), .MIMRXWDATA(rx_wd), .MIMRXREN(rx_re), .MIMRXRADDR(rx_ra), .MIMRXRDATA(rx_rd),
        .MIMTXWEN(tx_we), .MIMTXWADDR(tx_wa), .MIMTXWDATA(tx_wd), .MIMTXREN(tx_re), .MIMTXRADDR(tx_ra), .MIMTXRDATA(tx_rd),
        .TRNRD(rd128), .TRNRREM(rrem2), .TRNRSOF(trn_rsof), .TRNREOF(trn_reof), .TRNRSRCRDY(trn_rsrc_rdy),
        .TRNRBARHIT(trn_rbar_hit), .TRNRDSTRDY(trn_rdst_rdy),
        .TRNTD({64'd0, trn_td}), .TRNTREM({1'b0, trn_trem}), .TRNTSOF(trn_tsof), .TRNTEOF(trn_teof),
        .TRNTSRCRDY(trn_tsrc_rdy), .TRNTDSTRDY(tdst), .TRNTCFGGNT(1'b1), .TRNTSRCDSC(1'b0), .TRNTSTR(1'b0),
        .TRNTERRFWD(1'b0), .TRNRNPOK(1'b1), .TRNRNPREQ(1'b1), .TRNRFCPRET(1'b1),
        .TRNLNKUP(trn_lnk_up), .USERRSTN(usr_rstn),
        .CFGMSGDATA(msg_data), .CFGMSGRECEIVED(msg_rcvd),
        .CFGDSBUSNUMBER(ds_bus), .CFGDSDEVICENUMBER(5'd0), .CFGDSFUNCTIONNUMBER(3'd0),
        .CFGVENDID(16'h1204), .CFGDEVID(RP ? 16'hE0E0 : 16'hE0E1), .CFGREVID(8'h01),
        .CFGSUBSYSVENDID(16'h1204), .CFGSUBSYSID(16'h0001),
        .PLLTSSMSTATE(ltssm), .PLPHYLNKUPN(phy_lnk_up_n)
    );
endmodule
