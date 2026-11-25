// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6173, EERIE_W16): slot FIFO between eerie_pl_rx_w16 (0..4 slots of 4 bytes per
// clock) and eerie_pl_rx_ml (2 slots per clock). Entries are slot pairs {a, b}; up to two pairs are written
// per clock (two RAM banks, even / odd entries), one is read per clock.
//
// The link layer above is 64 bits wide (8 bytes per clock): the FIFO holds the part of a packet burst that
// arrives faster. A burst of TLPs is bounded by the credits the endpoint advertises (the TLPs stay in the
// FIFO / RX buffer until the TL releases their credits), so a FIFO of half the advertised bytes does not
// overflow; DLLPs are short and spaced. If it ever does (o_ovf), the pair is dropped: the LCRC check fails
// and the TLP is Naked and replayed.
`timescale 1ns / 1ps
module eerie_slot_fifo #(
    parameter AW = 9                  // 2**AW pairs (8 bytes each)
) (
    input              clk,
    input              rst,
    input      [3:0]   i_v,           // slots 0..3, a prefix
    input      [127:0] i_d,
    input      [15:0]  i_k,
    input      [3:0]   i_e,
    output reg         o_va, o_vb,
    output reg [31:0]  o_da, o_db,
    output reg [3:0]   o_ka, o_kb,
    output reg         o_ea, o_eb,
    output reg         o_ovf
);
    localparam EW = 2 * (1 + 32 + 4 + 1);
    function [EW-1:0] pair; input va; input [31:0] da; input [3:0] ka; input ea; input vb; input [31:0] db;
        input [3:0] kb; input eb;
        pair = {vb, eb, kb, db, va, ea, ka, da};
    endfunction
    wire [EW-1:0] p0 = pair(i_v[0], i_d[31:0],  i_k[3:0],  i_e[0], i_v[1], i_d[63:32],  i_k[7:4],   i_e[1]);
    wire [EW-1:0] p1 = pair(i_v[2], i_d[95:64], i_k[11:8], i_e[2], i_v[3], i_d[127:96], i_k[15:12], i_e[3]);
    wire [1:0] n_wr = i_v[2] ? 2'd2 : i_v[0] ? 2'd1 : 2'd0;

    reg [EW-1:0] m0 [0:(1<<(AW-1))-1];
    reg [EW-1:0] m1 [0:(1<<(AW-1))-1];
    reg [AW:0]   wp, rp;
    wire [AW:0]  used = wp - rp;
    wire         room = used <= (1 << AW) - 2;
    // entry wp -> bank wp[0]; entry wp+1 -> the other bank
    wire [AW:0]  wp1 = wp + 1'b1;
    wire         we0 = room && (n_wr == 2'd2 || (n_wr == 2'd1 && !wp[0]));
    wire         we1 = room && (n_wr == 2'd2 || (n_wr == 2'd1 && wp[0]));
    wire [AW-2:0] wa0 = wp[0] ? wp1[AW-1:1] : wp[AW-1:1];
    wire [AW-2:0] wa1 = wp[0] ? wp[AW-1:1] : wp1[AW-1:1];
    wire [EW-1:0] wd0 = wp[0] ? p1 : p0;
    wire [EW-1:0] wd1 = wp[0] ? p0 : p1;
    always @(posedge clk) begin
        if (we0) m0[wa0] <= wd0;
        if (we1) m1[wa1] <= wd1;
    end
    // read: one pair per clock while not empty (registered RAM read, then the output register)
    reg          rv, rsel; reg [EW-1:0] q0, q1;
    wire         rd = !rst && (wp != rp);
    always @(posedge clk) begin
        q0 <= m0[rp[AW-1:1]]; q1 <= m1[rp[AW-1:1]];
        if (rst) begin
            wp <= 0; rp <= 0; rv <= 1'b0; o_va <= 1'b0; o_vb <= 1'b0; o_ovf <= 1'b0;
        end else begin
            if (n_wr != 2'd0) begin
                if (room) wp <= wp + n_wr;
            end
            o_ovf <= (n_wr != 2'd0) && !room;
            if (rd) rp <= rp + 1'b1;
            rv <= rd; rsel <= rp[0];
            {o_vb, o_eb, o_kb, o_db, o_va, o_ea, o_ka, o_da} <= rv ? (rsel ? q1 : q0) : {EW{1'b0}};
        end
    end
endmodule
