// SPDX-License-Identifier: CERN-OHL-P-2.0
// Ponašajni PIPE PHY (16 bita, Gen1) za simulaciju petlje (TASK-6160).
// TX strana MAC-a ide na "žicu" (line_*), RX strana čita partnerovu žicu s kašnjenjem.
// - PhyStatus: impuls nakon promjene PowerDown-a i nakon TxDetectRx (uz RxStatus=011 ako je partner tu)
// - RxElecIdle = partnerov TxElecIdle; RxValid = !RxElecIdle
// - SHIFT=1: simbolni pomak za jedan bajt (COM pada u gornji bajt) — provjera poravnanja u MAC-u
`timescale 1ns / 1ps
module pipe_phy_model #(
    parameter SHIFT = 0,
    parameter DLY   = 4
) (
    input             pclk,
    input             rst,
    // MAC strana
    input      [15:0] txdata,
    input      [1:0]  txdatak,
    input             txelecidle,
    input      [1:0]  powerdown,
    input             txdetectrx,
    output reg [15:0] rxdata,
    output reg [1:0]  rxdatak,
    output reg        rxvalid,
    output reg        rxelecidle,
    output reg [2:0]  rxstatus,
    output reg        phystatus,
    // žica
    output     [17:0] line_out,     // {k[1:0], data[15:0]}, X kad je TX u mirovanju
    output            line_ei_out,
    input      [17:0] line_in,
    input             line_ei_in,
    input             partner_present
);
    assign line_out    = {txdatak, txdata};
    assign line_ei_out = txelecidle;

    reg [17:0] d [0:DLY-1];
    reg        e [0:DLY-1];
    reg [8:0]  last_hi;
    integer i;
    reg [1:0]  pd_q;
    reg        det_q;
    reg [3:0]  pd_cnt, det_cnt;
    always @(posedge pclk) begin
        d[0] <= line_in; e[0] <= line_ei_in;
        for (i = 1; i < DLY; i = i + 1) begin d[i] <= d[i-1]; e[i] <= e[i-1]; end
        last_hi <= {d[DLY-1][17], d[DLY-1][15:8]};
        if (SHIFT) begin
            // bajt 0 = gornji bajt prošle riječi, bajt 1 = donji bajt ove
            rxdata  <= {d[DLY-1][7:0], last_hi[7:0]};
            rxdatak <= {d[DLY-1][16], last_hi[8]};
        end else begin
            rxdata  <= d[DLY-1][15:0];
            rxdatak <= d[DLY-1][17:16];
        end
        rxelecidle <= e[DLY-1];
        rxvalid    <= !e[DLY-1];
        // PhyStatus / RxStatus
        phystatus <= 1'b0; rxstatus <= 3'b000;
        pd_q <= powerdown; det_q <= txdetectrx;
        if (rst) begin pd_cnt <= 0; det_cnt <= 0; end
        else begin
            if (powerdown != pd_q) pd_cnt <= 4'd8;
            else if (pd_cnt != 0) begin pd_cnt <= pd_cnt - 1'b1; if (pd_cnt == 1) phystatus <= 1'b1; end
            if (txdetectrx && !det_q) det_cnt <= 4'd10;
            else if (det_cnt != 0) begin
                det_cnt <= det_cnt - 1'b1;
                if (det_cnt == 1) begin phystatus <= 1'b1; rxstatus <= partner_present ? 3'b011 : 3'b000; end
            end
        end
    end
endmodule
