// SPDX-License-Identifier: CERN-OHL-P-2.0
// Endpoint x1 Gen2, PIPE 128 bita (TASK-6173): eerie_w16_core + BAR0 aplikacija (TASK-6160). Neovisno o FPGA-u; PHY omotač je izvan.
`timescale 1ns / 1ps
module eerie_w16_ep #(
    parameter MAX_GEN = 2,
    parameter FAST_TRAIN = "FALSE",
    parameter [3:0] ADDR_XOR = 4'd0      // BAR0 application layout (eerie_bar0_app)
) (
    input         pclk,
    input         uclk,
    input         sys_rst_n,
    input [127:0] pipe_rxdata,
    input  [15:0] pipe_rxdatak,
    input         pipe_rxvalid,
    input         pipe_rxelecidle,
    input  [2:0]  pipe_rxstatus,
    input         pipe_phystatus,
    output [127:0] pipe_txdata,
    output [15:0] pipe_txdatak,
    output        pipe_txelecidle,
    output        pipe_txcompliance,
    output [1:0]  pipe_powerdown,
    output        pipe_txdetectrx,
    output        pipe_rxpolarity,
    output        pipe_rate,
    output [5:0]  ltssm,
    output        phy_lnk_up,
    output        lnk_up
);
    wire [63:0] rd, td;
    wire        rrem, rsof, reof, rsrc, rdst, trem, tsof, teof, tsrc, tdst, urst;
    wire [7:0]  bar;
    wire [15:0] cid;

    eerie_w16_core #(.RP(0), .FAST_TRAIN(FAST_TRAIN), .MAX_GEN(MAX_GEN)) core (
        .pclk(pclk), .uclk(uclk), .sys_rst_n(sys_rst_n),
        .pipe_rxdata(pipe_rxdata), .pipe_rxdatak(pipe_rxdatak), .pipe_rxvalid(pipe_rxvalid),
        .pipe_rxelecidle(pipe_rxelecidle), .pipe_rxstatus(pipe_rxstatus), .pipe_phystatus(pipe_phystatus),
        .pipe_txdata(pipe_txdata), .pipe_txdatak(pipe_txdatak), .pipe_txelecidle(pipe_txelecidle),
        .pipe_txcompliance(pipe_txcompliance), .pipe_powerdown(pipe_powerdown), .pipe_txdetectrx(pipe_txdetectrx),
        .pipe_rxpolarity(pipe_rxpolarity), .pipe_rate(pipe_rate),
        .trn_rd(rd), .trn_rrem(rrem), .trn_rsof(rsof), .trn_reof(reof), .trn_rsrc_rdy(rsrc), .trn_rbar_hit(bar),
        .trn_rdst_rdy(rdst), .trn_td(td), .trn_trem(trem), .trn_tsof(tsof), .trn_teof(teof), .trn_tsrc_rdy(tsrc),
        .trn_tdst_rdy(tdst), .trn_lnk_up(lnk_up), .completer_id(cid), .user_rst(urst), .ds_bus(8'd0),
        .ltssm(ltssm), .phy_lnk_up(phy_lnk_up)
    );

    eerie_bar0_app #(.ADDR_XOR(ADDR_XOR)) app (
        .clk(uclk), .rst(urst),
        .trn_rd(rd), .trn_rrem(rrem), .trn_rsof(rsof), .trn_reof(reof), .trn_rsrc_rdy(rsrc), .trn_rbar_hit(bar),
        .trn_rdst_rdy(rdst), .trn_td(td), .trn_trem(trem), .trn_tsof(tsof), .trn_teof(teof), .trn_tsrc_rdy(tsrc),
        .trn_tdst_rdy(tdst), .completer_id(cid), .ltssm(ltssm), .lnk_up(lnk_up)
    );
endmodule
