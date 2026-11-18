// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6161): physical layer transmit path for a x1 Gen1 lane on a 64-bit PIPE
// (8 symbols per PIPE clock, 31.25 MHz). Drop-in for eerie_pl_tx (lane 0, x1, no Gen2/EIEOS).
//
// Every PIPE word carries exactly one of:
//   TS1/TS2     2 words: {COM, link, lane, N_FTS, rate, ctrl, ID, ID}, {ID x 8}
//   SKP         {COM SKP SKP SKP} x 2 (two SKP ordered sets back to back, allowed by the spec when
//               SKP OSs are accumulated; keeps every object aligned to the word)
//   EIOS        {COM IDL IDL IDL} x 2
//   packet beat 8 bytes from the DLL (STP/SDP in byte 0 of the first beat, END in byte 7 of a full
//               last beat or byte 3 of a half last beat; a half beat is followed by 4 idle bytes)
//   logical idle 8 x D0.0 (scrambled)
// SKP ordered sets are only scheduled between packets and between TS.
// Pipeline: select (reg) -> eerie_scr8 (2 clocks) -> PIPE.
`timescale 1ns / 1ps
module eerie_pl_tx_w8 #(
    parameter SKP_INTERVAL = 1200      // symbol times between scheduled SKP OS (1180..1538)
) (
    input             clk,
    input             rst,
    input      [2:0]  mode,
    input      [7:0]  ts_link,
    input             ts_link_pad,
    input      [7:0]  ts_lane,
    input             ts_lane_pad,
    input      [7:0]  ts_nfts,
    input      [7:0]  ts_rate,
    input      [7:0]  ts_ctrl,
    input             scramble_en,
    output reg        ts_done,
    output reg        eios_done,
    output reg        idle_pair,       // pulse: a word of logical idle was sent
    output reg        busy,
    input      [66:0] pkt_rd_data,     // {half,last,sop,data[63:0]}, FWFT, whole packets
    input             pkt_rd_empty,
    output            pkt_rd_en,
    output     [63:0] pipe_txdata,     // symbol 0 in [7:0]
    output     [7:0]  pipe_txdatak,
    output            pipe_txelecidle
);
    localparam M_EIDLE = 3'd0, M_TS1 = 3'd1, M_TS2 = 3'd2, M_DATA = 3'd3, M_EIOS = 3'd4, M_IDLE = 3'd5;
    localparam K_COM = 8'hBC, K_PAD = 8'hF7, K_SKP = 8'h1C, K_IDL = 8'h7C;

    wire       is_ts = (mode == M_TS1 || mode == M_TS2);
    reg        ts2nd;              // second word of a TS is due
    reg        cur_ts2;
    reg        in_pkt;             // between the first and the last beat of a packet
    reg [10:0] skp_cnt;
    reg [2:0]  skp_pend;

    wire [63:0] pd = pkt_rd_data[63:0];
    wire        p_sop = pkt_rd_data[64], p_last = pkt_rd_data[65], p_half = pkt_rd_data[66];
    wire        beat_ok = mode == M_DATA || in_pkt;
    wire        take_beat = !rst && !ts2nd && !pkt_rd_empty && beat_ok && (in_pkt || skp_pend == 3'd0);
    assign pkt_rd_en = take_beat;

    // word under construction (symbol 0 first)
    reg [63:0] w; reg [7:0] wk, wscr, wcom, wskp; reg weidle;
    reg        n_ts_done, n_eios_done, n_idle, take_skp, start_ts;
    integer    i;
    function [63:0] bytes8; input [7:0] b0, b1, b2, b3, b4, b5, b6, b7;
        bytes8 = {b7, b6, b5, b4, b3, b2, b1, b0};
    endfunction
    wire [7:0] ts_id = (ts2nd ? cur_ts2 : (mode == M_TS2)) ? 8'h45 : 8'h4A;
    always @(*) begin
        w = 64'd0; wk = 8'd0; wscr = 8'd0; wcom = 8'd0; wskp = 8'd0; weidle = 1'b0;
        n_ts_done = 1'b0; n_eios_done = 1'b0; n_idle = 1'b0; take_skp = 1'b0; start_ts = 1'b0;
        if (ts2nd) begin
            w = {8{ts_id}}; n_ts_done = 1'b1;                        // raw, not scrambled
        end else if (take_beat) begin
            for (i = 0; i < 8; i = i + 1) w[8*i +: 8] = pd[63-8*i -: 8];
            wk[0] = p_sop;
            if (p_last && p_half) begin
                wk[3] = 1'b1; w[63:32] = 32'd0;                        // END in byte 3, then idle
            end else if (p_last) wk[7] = 1'b1;
            wscr = scramble_en ? ~wk : 8'd0;
        end else if (in_pkt) begin
            // packet beat not yet in the FIFO (cannot happen with a whole-packet FIFO): idle
            wscr = scramble_en ? 8'hFF : 8'd0;
        end else if (mode == M_EIDLE) begin
            weidle = 1'b1;
        end else if (skp_pend != 3'd0 && mode != M_EIOS) begin
            take_skp = 1'b1;
            w = bytes8(K_COM, K_SKP, K_SKP, K_SKP, K_COM, K_SKP, K_SKP, K_SKP); wk = 8'hFF;
            wcom = 8'h11; wskp = 8'hEE;
        end else if (is_ts) begin
            w = bytes8(K_COM, ts_link_pad ? K_PAD : ts_link, ts_lane_pad ? K_PAD : ts_lane,
                       ts_nfts, ts_rate, ts_ctrl, ts_id, ts_id);
            wk = {6'd0, ts_lane_pad, ts_link_pad} << 1 | 8'd1;
            wcom = 8'h01; start_ts = 1'b1;
        end else if (mode == M_EIOS) begin
            w = bytes8(K_COM, K_IDL, K_IDL, K_IDL, K_COM, K_IDL, K_IDL, K_IDL); wk = 8'hFF;
            wcom = 8'h11; n_eios_done = 1'b1;
        end else begin
            wscr = scramble_en ? 8'hFF : 8'd0;                        // logical idle
            n_idle = 1'b1;
        end
    end

    reg [63:0] s_d; reg [7:0] s_k, s_scr, s_com, s_skp; reg s_eidle;
    always @(posedge clk) begin
        if (rst) begin
            ts2nd <= 1'b0; cur_ts2 <= 1'b0; in_pkt <= 1'b0; skp_cnt <= 11'd0; skp_pend <= 3'd0;
            ts_done <= 1'b0; eios_done <= 1'b0; idle_pair <= 1'b0; busy <= 1'b0;
            s_eidle <= 1'b1; s_k <= 8'd0; s_scr <= 8'd0; s_com <= 8'd0; s_skp <= 8'd0;
        end else begin
            ts2nd <= start_ts;
            if (!ts2nd) cur_ts2 <= (mode == M_TS2);
            if (take_beat) in_pkt <= !p_last;
            ts_done <= n_ts_done; eios_done <= n_eios_done; idle_pair <= n_idle;
            busy <= start_ts || (take_beat && !p_last) || (in_pkt && !take_beat);
            if (weidle) begin
                skp_cnt <= 11'd0; skp_pend <= 3'd0;
            end else if (skp_cnt >= SKP_INTERVAL / 8 - 1) begin
                skp_cnt <= 11'd0;
                if (!take_skp && skp_pend != 3'd7) skp_pend <= skp_pend + 1'b1;
            end else begin
                skp_cnt <= skp_cnt + 1'b1;
                if (take_skp) skp_pend <= skp_pend - 1'b1;
            end
            s_d <= w; s_k <= wk; s_scr <= wscr; s_com <= wcom; s_skp <= wskp; s_eidle <= weidle;
        end
    end

    wire ov; wire oe;
    eerie_scr8 #(.SW(1)) scr (
        .clk(clk), .rst(rst || s_eidle), .v(1'b1), .d(s_d), .k(s_k), .scr(s_scr), .com(s_com), .skp(s_skp),
        .side(s_eidle), .od(pipe_txdata), .ok(pipe_txdatak), .ov(ov), .oside(oe)
    );
    assign pipe_txelecidle = oe || rst;
endmodule
