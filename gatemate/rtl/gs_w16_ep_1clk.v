// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6173: eerie_w16_ep (128-bitni PIPE, Gen2) s jednim taktom (PIPE = user = 31,25 MHz @5 GT/s), za mjerenje na GateMateu.
`timescale 1ns / 1ps
module gs_w16_ep_1clk (
    input         clk,
    input         sys_rst_n,
    input  [127:0] pipe_rxdata,
    input  [15:0] pipe_rxdatak,
    input         pipe_rxvalid,
    input         pipe_rxelecidle,
    input  [2:0]  pipe_rxstatus,
    input         pipe_phystatus,
    output [127:0] pipe_txdata,
    output [15:0] pipe_txdatak,
    output        pipe_txelecidle,
    output [1:0]  pipe_powerdown,
    output        pipe_txdetectrx,
    output        pipe_rxpolarity,
    output [5:0]  ltssm,
    output        pipe_rate,
    output        lnk_up
);
    eerie_w16_ep ep (
        .pclk(clk), .uclk(clk), .sys_rst_n(sys_rst_n),
        .pipe_rxdata(pipe_rxdata), .pipe_rxdatak(pipe_rxdatak), .pipe_rxvalid(pipe_rxvalid),
        .pipe_rxelecidle(pipe_rxelecidle), .pipe_rxstatus(pipe_rxstatus), .pipe_phystatus(pipe_phystatus),
        .pipe_txdata(pipe_txdata), .pipe_txdatak(pipe_txdatak), .pipe_txelecidle(pipe_txelecidle),
        .pipe_txcompliance(), .pipe_powerdown(pipe_powerdown), .pipe_txdetectrx(pipe_txdetectrx),
        .pipe_rxpolarity(pipe_rxpolarity), .pipe_rate(pipe_rate), .ltssm(ltssm), .phy_lnk_up(), .lnk_up(lnk_up)
    );
endmodule
