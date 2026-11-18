// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6161: eerie_w8_ep s jednim taktom (PIPE = user = 31,25 MHz), za mjerenje na GateMateu.
`timescale 1ns / 1ps
module gs_w8_ep_1clk (
    input         clk,
    input         sys_rst_n,
    input  [63:0] pipe_rxdata,
    input  [7:0]  pipe_rxdatak,
    input         pipe_rxvalid,
    input         pipe_rxelecidle,
    input  [2:0]  pipe_rxstatus,
    input         pipe_phystatus,
    output [63:0] pipe_txdata,
    output [7:0]  pipe_txdatak,
    output        pipe_txelecidle,
    output [1:0]  pipe_powerdown,
    output        pipe_txdetectrx,
    output        pipe_rxpolarity,
    output [5:0]  ltssm,
    output        lnk_up
);
    eerie_w8_ep ep (
        .pclk(clk), .uclk(clk), .sys_rst_n(sys_rst_n),
        .pipe_rxdata(pipe_rxdata), .pipe_rxdatak(pipe_rxdatak), .pipe_rxvalid(pipe_rxvalid),
        .pipe_rxelecidle(pipe_rxelecidle), .pipe_rxstatus(pipe_rxstatus), .pipe_phystatus(pipe_phystatus),
        .pipe_txdata(pipe_txdata), .pipe_txdatak(pipe_txdatak), .pipe_txelecidle(pipe_txelecidle),
        .pipe_txcompliance(), .pipe_powerdown(pipe_powerdown), .pipe_txdetectrx(pipe_txdetectrx),
        .pipe_rxpolarity(pipe_rxpolarity), .pipe_rate(), .ltssm(ltssm), .phy_lnk_up(), .lnk_up(lnk_up)
    );
endmodule
