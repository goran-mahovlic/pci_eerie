// SPDX-License-Identifier: CERN-OHL-P-2.0
// Ponašajni PIPE PHY s 64 bita (8 simbola / takt, Gen1) za simulaciju petlje (TASK-6161).
// Radi na brzom taktu fclk (125 MHz, 2 simbola po taktu na "žici", isti format kao pipe_phy_model:
// line = {k1, k0, d[15:0]}, d[7:0] prvi); MAC strana je na sclk = fclk/4 (31,25 MHz), faza ph = 0..3
// (sclk raste kad ph prelazi 1 -> 2). SHIFT = 0..7: simbolni pomak riječi (COM može pasti bilo gdje).
`timescale 1ns / 1ps
module pipe_phy_w8 #(
    parameter SHIFT = 0
) (
    input             fclk,
    input      [1:0]  ph,
    input             sclk,
    input             rst,
    // MAC strana (sclk)
    input      [63:0] txdata,
    input      [7:0]  txdatak,
    input             txelecidle,
    input      [1:0]  powerdown,
    input             txdetectrx,
    output reg [63:0] rxdata,
    output reg [7:0]  rxdatak,
    output reg        rxvalid,
    output reg        rxelecidle,
    output reg [2:0]  rxstatus,
    output reg        phystatus,
    // žica (fclk)
    output reg [17:0] line_out,
    output reg        line_ei_out,
    input      [17:0] line_in,
    input             line_ei_in,
    input             partner_present
);
    // TX: riječ uzeta kad je ph == 3 (stabilna od rastućeg brida sclk), pa 4 para simbola
    reg [63:0] tq; reg [7:0] tqk; reg tqe = 1'b1; reg [1:0] tp = 0;
    always @(posedge fclk) begin
        if (ph == 2'd3) begin tq <= txdata; tqk <= txdatak; tqe <= txelecidle || rst; tp <= 2'd0; end
        else tp <= tp + 1'b1;
        line_out    <= {tqk[2*tp + 1], tqk[2*tp], tq[16*tp +: 16]};
        line_ei_out <= tqe;
    end
    // RX: povijest simbola {ei, k, d}, najnoviji na vrhu
    reg [9:0] hist [0:23];
    integer i;
    always @(posedge fclk) begin
        for (i = 0; i < 22; i = i + 1) hist[i] <= hist[i + 2];
        hist[22] <= {line_ei_in, line_in[16], line_in[7:0]};
        hist[23] <= {line_ei_in, line_in[17], line_in[15:8]};
        if (ph == 2'd3) begin
            rxelecidle <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                rxdata[8*i +: 8] <= hist[16 - SHIFT + i][7:0];
                rxdatak[i]       <= hist[16 - SHIFT + i][8];
            end
            rxelecidle <= hist[16 - SHIFT][9] | hist[23 - SHIFT][9];
            rxvalid    <= !(hist[16 - SHIFT][9] | hist[23 - SHIFT][9]);
        end
    end
    // PhyStatus / RxStatus (sclk)
    reg [1:0] pd_q; reg det_q; reg [3:0] pd_cnt, det_cnt;
    always @(posedge sclk) begin
        phystatus <= 1'b0; rxstatus <= 3'b000;
        pd_q <= powerdown; det_q <= txdetectrx;
        if (rst) begin pd_cnt <= 0; det_cnt <= 0; end
        else begin
            if (powerdown != pd_q) pd_cnt <= 4'd4;
            else if (pd_cnt != 0) begin pd_cnt <= pd_cnt - 1'b1; if (pd_cnt == 1) phystatus <= 1'b1; end
            if (txdetectrx && !det_q) det_cnt <= 4'd5;
            else if (det_cnt != 0) begin
                det_cnt <= det_cnt - 1'b1;
                if (det_cnt == 1) begin phystatus <= 1'b1; rxstatus <= partner_present ? 3'b011 : 3'b000; end
            end
        end
    end
endmodule
