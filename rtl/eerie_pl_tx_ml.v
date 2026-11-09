// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: multi-lane transmit striper (x2 / x4 links, 2 symbols per lane per PIPE clock)
//
// Takes the framed packets from the DLL's packet FIFO (STP/SDP ... END, 64-bit words, every
// packet starting in a new word) and stripes them across the lanes in symbol order: in each
// symbol time lane l carries packet byte (symbol time * width + l). Packets start at a PIPE
// clock boundary (lane 0, first symbol time), which keeps STP/SDP on lane 0 as required.
// Between packets it sends logical idle and schedules SKP ordered sets (COM SKP SKP SKP on
// every lane at the same time). The per-lane eerie_pl_tx instances scramble the symbols.
`timescale 1ns / 1ps
module eerie_pl_tx_ml #(
    parameter N = 4,                   // lanes
    parameter SKP_INTERVAL = 1200      // symbol times between scheduled SKP OS
) (
    input              clk,
    input              rst,
    input              en,             // link is x2 or x4 and in data / logical idle mode
    input              w4,             // 1: x4, 0: x2
    input              run,            // LTSSM in data or logical idle mode (SKP OS may be sent)
    input              data_mode,      // packets may be sent (L0); otherwise logical idle only

    input      [66:0]  pkt_rd_data,    // {half, last, sop, data[63:0]}, byte 0 in [63:56]
    input              pkt_rd_empty,
    output             pkt_rd_en,

    output reg [8*N-1:0] s0, s1,       // per lane symbol pair (lane l in [8l+7:8l])
    output reg [N-1:0]   k0, k1,
    output reg           idle,         // the pair just driven is logical idle
    output reg           busy          // the pair just driven belongs to a packet or SKP OS
);
    localparam K_COM = 8'hBC, K_SKP = 8'h1C;

    reg        in_pkt, hwd, skp2;
    reg [10:0] skp_cnt;
    reg [2:0]  skp_pend;
    wire [63:0] pd = pkt_rd_data[63:0];
    wire        p_sop = pkt_rd_data[64], p_last = pkt_rd_data[65], p_half = pkt_rd_data[66];
    function [7:0] byte_of; input [63:0] d; input [2:0] i; byte_of = d[63 - 8*i -: 8]; endfunction

    // next-cycle decisions
    reg          n_pop, n_in, n_hwd, n_skp2, n_idle, take_skp;
    reg [8*N-1:0] n_s0, n_s1;
    reg [N-1:0]   n_k0, n_k1;
    integer l;
    always @(*) begin
        n_pop = 1'b0; n_in = in_pkt; n_hwd = hwd; n_skp2 = 1'b0; n_idle = 1'b0; take_skp = 1'b0;
        n_s0 = {8*N{1'b0}}; n_s1 = {8*N{1'b0}}; n_k0 = {N{1'b0}}; n_k1 = {N{1'b0}};
        if (skp2) begin
            for (l = 0; l < N; l = l + 1) begin
                n_s0[8*l +: 8] = K_SKP; n_s1[8*l +: 8] = K_SKP; n_k0[l] = 1'b1; n_k1[l] = 1'b1;
            end
        end else if (!in_pkt && run && skp_pend != 0) begin
            take_skp = 1'b1; n_skp2 = 1'b1;
            for (l = 0; l < N; l = l + 1) begin
                n_s0[8*l +: 8] = K_COM; n_s1[8*l +: 8] = K_SKP; n_k0[l] = 1'b1; n_k1[l] = 1'b1;
            end
        end else if ((in_pkt || data_mode) && !pkt_rd_empty) begin
            if (w4) begin
                for (l = 0; l < 4 && l < N; l = l + 1) begin
                    n_s0[8*l +: 8] = byte_of(pd, l);
                    n_s1[8*l +: 8] = p_half ? 8'h00 : byte_of(pd, 4 + l);
                end
                n_k0[0] = p_sop;
                if (N >= 4) begin
                    n_k0[3] = p_last && p_half;
                    n_k1[3] = p_last && !p_half;
                end
                n_pop = 1'b1; n_in = !p_last;
            end else begin
                // x2: half a word per clock
                n_s0[7:0]  = byte_of(pd, hwd ? 4 : 0); n_s0[15:8] = byte_of(pd, hwd ? 5 : 1);
                n_s1[7:0]  = byte_of(pd, hwd ? 6 : 2); n_s1[15:8] = byte_of(pd, hwd ? 7 : 3);
                n_k0[0] = p_sop && !hwd;
                n_k1[1] = p_last && (p_half || hwd);
                if (p_half || hwd) begin n_pop = 1'b1; n_hwd = 1'b0; n_in = !p_last; end
                else begin n_hwd = 1'b1; n_in = 1'b1; end
            end
        end else begin
            n_idle = 1'b1;          // logical idle: data 00 on every lane
        end
    end
    assign pkt_rd_en = en && n_pop && !rst;

    always @(posedge clk) begin
        if (rst || !en) begin
            in_pkt <= 1'b0; hwd <= 1'b0; skp2 <= 1'b0; busy <= 1'b0; idle <= 1'b0;
            s0 <= {8*N{1'b0}}; s1 <= {8*N{1'b0}}; k0 <= {N{1'b0}}; k1 <= {N{1'b0}};
            skp_cnt <= 11'd0; skp_pend <= 3'd0;
        end else begin
            in_pkt <= n_in; hwd <= n_hwd; skp2 <= n_skp2;
            s0 <= n_s0; s1 <= n_s1; k0 <= n_k0; k1 <= n_k1; idle <= n_idle;
            busy <= !n_idle;
            if (skp_cnt >= SKP_INTERVAL / 2 - 1) begin
                skp_cnt <= 11'd0;
                if (!take_skp && skp_pend != 3'd7) skp_pend <= skp_pend + 1'b1;
            end else begin
                skp_cnt <= skp_cnt + 1'b1;
                if (take_skp) skp_pend <= skp_pend - 1'b1;
            end
        end
    end
endmodule
