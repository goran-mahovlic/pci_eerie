// SPDX-License-Identifier: CERN-OHL-P-2.0
// Endpoint x1 Gen1, PIPE 64 bita (TASK-6161): eerie_w8_core + BAR0 aplikacija (TASK-6160). Neovisno o FPGA-u; PHY omotač je izvan.
`timescale 1ns / 1ps
module eerie_w8_ep #(
    parameter FAST_TRAIN = "FALSE",
    parameter [3:0] ADDR_XOR = 4'd0      // BAR0 application layout (eerie_bar0_app)
) (
    input         pclk,
    input         uclk,
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
    output        pipe_txcompliance,
    output [1:0]  pipe_powerdown,
    output        pipe_txdetectrx,
    output        pipe_rxpolarity,
    output        pipe_rate,
    output [5:0]  ltssm,
    output        phy_lnk_up,
    output        lnk_up
`ifdef EERIE_DBGCNT
   ,input  [63:0] phy_dbgc               // TASK-6185: eerie_ccs_phy EB input/output counters (pclk = uclk)
`endif
`ifdef EERIE_ILA3B
   ,input  [7:0]  phy_dbg                // TASK-6192: eerie_ccs_phy dbg {rx_buf_err, tx_buf_err, rx_rdone, tx_rdone, aligned, ei, det_done, present} (async)
`endif
`ifdef EERIE_ILA
   ,input  [31:0] phy_ppm                // TASK-6190: eerie_ccs_phy rclk - pclk per window
   ,output        uart_tx
   ,input         uart_rx
`endif
);
    wire [63:0] rd, td;
    wire        rrem, rsof, reof, rsrc, rdst, trem, tsof, teof, tsrc, tdst, urst;
    wire [7:0]  bar;
    wire [15:0] cid;
`ifdef EERIE_DBGCNT
    wire [7:0]  dl_ev;
`endif
`ifdef EERIE_ILA
    wire [51:0] ila_p;
`endif

    eerie_w8_core #(.RP(0), .FAST_TRAIN(FAST_TRAIN)) core (
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
`ifdef EERIE_DBGCNT
       ,.dl_ev(dl_ev)
`endif
`ifdef EERIE_ILA
       ,.ila_p(ila_p)
`endif
    );

`ifdef EERIE_ILA3B
    // TASK-6192: word record flags = SerDes state instead of RxStatus[2] / rxelecidle: [1] byte NOT aligned,
    // [2] RX or TX buffer error; 2-FF synchronisers (level flags, Cummings SNUG 2008 sec. 5.6)
    (* async_reg = "true" *) reg [2:1] dbg_m = 2'b00, dbg_s = 2'b00;
    always @(posedge uclk) begin dbg_m <= {phy_dbg[7] | phy_dbg[6], !phy_dbg[3]}; dbg_s <= dbg_m; end
`endif
    eerie_bar0_app #(.ADDR_XOR(ADDR_XOR)) app (
        .clk(uclk), .rst(urst),
        .trn_rd(rd), .trn_rrem(rrem), .trn_rsof(rsof), .trn_reof(reof), .trn_rsrc_rdy(rsrc), .trn_rbar_hit(bar),
        .trn_rdst_rdy(rdst), .trn_td(td), .trn_trem(trem), .trn_tsof(tsof), .trn_teof(teof), .trn_tsrc_rdy(tsrc),
        .trn_tdst_rdy(tdst), .completer_id(cid), .ltssm(ltssm), .lnk_up(lnk_up)
`ifdef EERIE_DBGCNT
       ,.dl_ev(dl_ev), .rxstatus(pipe_rxstatus), .rxvalid(pipe_rxvalid), .phy_dbgc(phy_dbgc)
`endif
`ifdef EERIE_ILA
       ,.ila_p(ila_p), .phy_ppm(phy_ppm), .uart_tx(uart_tx), .uart_rx(uart_rx)
`endif
`ifdef EERIE_ILA3B
       ,.ila_w({pipe_txelecidle, pipe_txdatak, pipe_txdata, dbg_s[2], dbg_s[1], pipe_rxvalid, pipe_rxdatak, pipe_rxdata})
`elsif EERIE_ILA3
       ,.ila_w({pipe_txelecidle, pipe_txdatak, pipe_txdata, pipe_rxstatus[2], pipe_rxelecidle, pipe_rxvalid, pipe_rxdatak, pipe_rxdata})
`endif
    );
endmodule
