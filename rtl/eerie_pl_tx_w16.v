// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6173): physical layer transmit path for a x1 lane on a 128-bit PIPE
// (EERIE_W16: 16 symbols per PIPE clock; 31.25 MHz at 5.0 GT/s, 15.625 MHz at 2.5 GT/s).
// Drop-in for eerie_pl_tx_w8, plus the 5.0 GT/s EIEOS.
//
// Every PIPE word carries exactly one of:
//   TS1/TS2      {COM, link, lane, N_FTS, rate, ctrl, ID x 10} (one TS is one word)
//   EIEOS        {COM, EIE x 14, D10.2} at 5.0 GT/s before the first TS of a sequence and after every 32 TS
//   SKP          L0 / logical idle: {COM SKP SKP SKP} + 12 symbols of logical idle (as EERIE_W8_SKP1);
//                training: {COM SKP SKP SKP} x 4 (SKP ordered sets back to back)
//   EIOS         {COM IDL IDL IDL} x 4
//   packet beat  two packet FIFO entries (8 bytes each) of the same packet; a last beat of 4, 8 or 12 bytes
//                is followed by logical idle up to the end of the word (one packet per word)
//   logical idle 16 x D0.0 (scrambled)
// The packet FIFO entries are 8 bytes (the DLL is 64 bits wide), so a beat takes one or two entries.
// Pipeline: select (reg) -> eerie_scr16 (2 clocks) -> PIPE.
`timescale 1ns / 1ps
module eerie_pl_tx_w16 #(
    parameter SKP_INTERVAL = 1200      // symbol times between scheduled SKP OS (1180..1538)
) (
    input              clk,
    input              rst,
    input      [2:0]   mode,
    input      [7:0]   ts_link,
    input              ts_link_pad,
    input      [7:0]   ts_lane,
    input              ts_lane_pad,
    input      [7:0]   ts_nfts,
    input      [7:0]   ts_rate,
    input      [7:0]   ts_ctrl,
    input              scramble_en,
    input              gen2,             // operating at 5.0 GT/s: EIEOS before / every 32 TS
    input              eieos_clr,        // reset the EIEOS interval count (first TS2 in RcvrCfg)
    output reg         ts_done,
    output reg         eios_done,
    output reg         idle_pair,        // pulse: a word of logical idle was sent
    output reg         busy,
    input      [66:0]  pkt_rd_data,      // {half,last,sop,data[63:0]}, FWFT, whole packets
    input      [66:0]  pkt_rd_data2,     // the entry after it (valid with pkt_rd_has2)
    input              pkt_rd_empty,
    input              pkt_rd_has2,
    output     [1:0]   pkt_rd_n,         // entries popped this clock (0, 1, 2)
    output     [127:0] pipe_txdata,      // symbol 0 in [7:0]
    output     [15:0]  pipe_txdatak,
    output             pipe_txelecidle
);
    localparam M_EIDLE = 3'd0, M_TS1 = 3'd1, M_TS2 = 3'd2, M_DATA = 3'd3, M_EIOS = 3'd4, M_IDLE = 3'd5;
    localparam K_COM = 8'hBC, K_PAD = 8'hF7, K_SKP = 8'h1C, K_IDL = 8'h7C, K_EIE = 8'hFC;

    wire       is_ts = (mode == M_TS1 || mode == M_TS2);
    reg        in_pkt;             // between the first and the last beat of a packet
    reg [10:0] skp_cnt;
    reg [2:0]  skp_pend;
    reg [5:0]  ei_cnt;             // TS sent since the last EIEOS
    reg        prev_ts;            // a TS sequence is ongoing

    wire [63:0] pd0 = pkt_rd_data[63:0],  pd1 = pkt_rd_data2[63:0];
    wire        p0_sop = pkt_rd_data[64],  p0_last = pkt_rd_data[65],  p0_half = pkt_rd_data[66];
    wire        p1_last = pkt_rd_data2[65], p1_half = pkt_rd_data2[66];
    wire        beat_ok = mode == M_DATA || in_pkt;
    wire        take0 = !rst && !pkt_rd_empty && beat_ok && (in_pkt || skp_pend == 3'd0);
    // the second entry belongs to the same packet when the first is not its last one; the FIFO only shows
    // whole packets, so it is there (pkt_rd_has2) unless the packet is a single entry
    wire        take1 = take0 && !p0_last && pkt_rd_has2;
    assign pkt_rd_n = take1 ? 2'd2 : take0 ? 2'd1 : 2'd0;
    wire        ei_due = gen2 && (!prev_ts || ei_cnt >= 6'd32);

    // word under construction (symbol 0 first)
    reg [127:0] w; reg [15:0] wk, wscr, wcom, wskp; reg weidle;
    reg         n_ts_done, n_eios_done, n_idle, take_skp, n_eieos, n_ts;
    integer     i;
    wire [7:0]  ts_id = (mode == M_TS2) ? 8'h45 : 8'h4A;
    always @(*) begin
        w = 128'd0; wk = 16'd0; wscr = 16'd0; wcom = 16'd0; wskp = 16'd0; weidle = 1'b0;
        n_ts_done = 1'b0; n_eios_done = 1'b0; n_idle = 1'b0; take_skp = 1'b0; n_eieos = 1'b0; n_ts = 1'b0;
        if (take0) begin
            for (i = 0; i < 8; i = i + 1) w[8*i +: 8] = pd0[63-8*i -: 8];
            wk[0] = p0_sop;
            if (p0_last && p0_half) begin
                wk[3] = 1'b1; w[127:32] = 96'd0;                       // END in byte 3, then idle
            end else if (p0_last) begin
                wk[7] = 1'b1; w[127:64] = 64'd0;                       // END in byte 7, then idle
            end else if (take1) begin
                for (i = 0; i < 8; i = i + 1) w[64 + 8*i +: 8] = pd1[63-8*i -: 8];
                if (p1_last && p1_half) begin wk[11] = 1'b1; w[127:96] = 32'd0; end
                else if (p1_last) wk[15] = 1'b1;
            end
            wscr = scramble_en ? ~wk : 16'd0;
        end else if (in_pkt) begin
            // packet beat not in the FIFO (cannot happen with a whole-packet FIFO): idle
            wscr = scramble_en ? 16'hFFFF : 16'd0;
        end else if (mode == M_EIDLE) begin
            weidle = 1'b1;
        end else if (skp_pend != 3'd0 && (mode == M_DATA || mode == M_IDLE)) begin
            take_skp = 1'b1;
            w[31:0] = {K_SKP, K_SKP, K_SKP, K_COM}; wk = 16'h000F;
            wcom = 16'h0001; wskp = 16'h000E; wscr = scramble_en ? 16'hFFF0 : 16'd0;
        end else if (skp_pend != 3'd0 && mode != M_EIOS) begin
            take_skp = 1'b1;
            w = {4{K_SKP, K_SKP, K_SKP, K_COM}}; wk = 16'hFFFF;
            wcom = 16'h1111; wskp = 16'hEEEE;
        end else if (is_ts && ei_due) begin
            w = {8'h4A, {14{K_EIE}}, K_COM}; wk = 16'h7FFF; wcom = 16'h0001; n_eieos = 1'b1;
        end else if (is_ts) begin
            w = {{10{ts_id}}, ts_ctrl, ts_rate, ts_nfts, ts_lane_pad ? K_PAD : ts_lane,
                 ts_link_pad ? K_PAD : ts_link, K_COM};
            wk = {13'd0, ts_lane_pad, ts_link_pad, 1'b1};
            wcom = 16'h0001; n_ts_done = 1'b1; n_ts = 1'b1;
        end else if (mode == M_EIOS) begin
            w = {4{K_IDL, K_IDL, K_IDL, K_COM}}; wk = 16'hFFFF;
            wcom = 16'h1111; n_eios_done = 1'b1;
        end else begin
            wscr = scramble_en ? 16'hFFFF : 16'd0;                     // logical idle
            n_idle = 1'b1;
        end
    end

    reg [127:0] s_d; reg [15:0] s_k, s_scr, s_com, s_skp; reg s_eidle;
    always @(posedge clk) begin
        if (rst) begin
            in_pkt <= 1'b0; skp_cnt <= 11'd0; skp_pend <= 3'd0; ei_cnt <= 6'd0; prev_ts <= 1'b0;
            ts_done <= 1'b0; eios_done <= 1'b0; idle_pair <= 1'b0; busy <= 1'b0;
            s_eidle <= 1'b1; s_k <= 16'd0; s_scr <= 16'd0; s_com <= 16'd0; s_skp <= 16'd0;
        end else begin
            if (take0) in_pkt <= take1 ? !p1_last : !p0_last;
            ts_done <= n_ts_done; eios_done <= n_eios_done; idle_pair <= n_idle;
            busy <= (take0 && !(take1 ? p1_last : p0_last)) || (in_pkt && !take0);
            // EIEOS interval (TS since the last EIEOS); a sequence ends with anything but TS / SKP / EIEOS
            if (n_eieos || eieos_clr) ei_cnt <= 6'd0;
            else if (n_ts_done && ei_cnt != 6'h3F) ei_cnt <= ei_cnt + 1'b1;
            if (n_eieos || n_ts) prev_ts <= 1'b1;
            else if (!is_ts && !take_skp) prev_ts <= 1'b0;
            if (weidle) begin
                skp_cnt <= 11'd0; skp_pend <= 3'd0;
            end else if (skp_cnt >= SKP_INTERVAL / 16 - 1) begin
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
    eerie_scr16 #(.SW(1)) scr (
        .clk(clk), .rst(rst || s_eidle), .v(1'b1), .d(s_d), .k(s_k), .scr(s_scr), .com(s_com), .skp(s_skp),
        .side(s_eidle), .od(pipe_txdata), .ok(pipe_txdatak), .ov(ov), .oside(oe)
    );
    assign pipe_txelecidle = oe || rst;
endmodule
