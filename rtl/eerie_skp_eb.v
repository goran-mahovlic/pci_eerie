// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6161): SKP elastic buffer in the fabric for a x1 lane on a 64-bit PIPE.
//
// The CC_SERDES clock correction cannot match PCIe SKP ordered sets, so with separate reference
// clocks (SRNS, up to +-600 ppm) the received words (recovered clock, wclk) are moved into the local
// PIPE clock (rclk) here:
//   * wclk: valid words go into an ordinary async FIFO (one word per write, Gray pointers);
//   * rclk: a residue buffer (up to 16 symbols) is refilled with one FIFO word when it holds fewer
//     than 8 symbols and always delivers 8 symbols per clock. When the FIFO runs low one SKP symbol is
//     inserted after the last SKP of a SKP ordered set (the set then has at most 5 SKP). Removal is on the write side
//     (one SKP of a set with >= 2 SKP when the FIFO is above HI). RxStatus reports 001 (added) / 100.
// Symbols outside SKP ordered sets are never touched. Symbol 0 of a word is in [7:0].
`timescale 1ns / 1ps
module eerie_skp_eb #(
    parameter AW = 4,                    // FIFO depth 2**AW words
    parameter LO = 4,                    // insert below this fill (words)
    parameter HI = 10                    // remove above this fill (words)
) (
    input             wclk,
    input             wrst,
    input             w_v,               // word valid (symbol lock, not electrical idle)
    input      [63:0] w_d,
    input      [7:0]  w_k,
    input             w_err,             // decode / disparity error in this word
    input             rclk,
    input             rrst,
    output reg        r_v,
    output reg [63:0] r_d,
    output reg [7:0]  r_k,
    output reg [2:0]  r_status,          // 000 ok, 001 SKP added, 010 SKP removed, 100 error, 110 underflow
    output reg [AW:0] r_fill
);
    localparam K_COM = 8'hBC, K_SKP = 8'h1C;
    integer i;
`ifdef EERIE_SKP_EB2
    `include "eerie_skp_eb2.vh"
`else

    // ---------------- write side ----------------
    // removal happens here (the read clock is slower): one SKP of a SKP OS (>= 2 SKP) is dropped, the
    // symbols are repacked into 8-symbol words through a write residue (< 8 symbols)
    reg [72:0] mem [0:(1<<AW)-1];
    reg [AW:0] wp = 0, wg = 0;
    reg [AW:0] rg_w1 = 0, rg_w2 = 0;
    reg [AW:0] rp = 0, rg = 0;            // read side (declared here for the synchronizer)
    function [AW:0] g2b; input [AW:0] g; integer j; begin g2b[AW] = g[AW];
        for (j = AW - 1; j >= 0; j = j - 1) g2b[j] = g2b[j+1] ^ g[j]; end endfunction
    wire [AW:0] wfill = wp - g2b(rg_w2);
    reg  [9:0]  wr [0:14];                // write residue {err, k, d}
    reg  [3:0]  wrn;
    reg         w_in, w_rmv; reg [2:0] w_run;
    reg  [9:0]  ws [0:7]; reg [3:0] wcnt; reg [3:0] wat; reg wfound; reg wi; reg [2:0] wru;
    reg  [9:0]  nw [0:14]; reg [4:0] nwn;
    always @(*) begin
        // first SKP (run >= 2) of a SKP OS in this word
        wfound = 1'b0; wat = 4'd8; wi = w_in; wru = w_run;
        for (i = 0; i < 8; i = i + 1) begin
            if (w_k[i] && w_d[8*i +: 8] == K_COM) begin wi = 1'b1; wru = 3'd0; end
            else if (w_k[i] && w_d[8*i +: 8] == K_SKP && wi) begin
                wru = wru + 1'b1;
                if (!wfound && wru >= 3'd2 && wfill > HI) begin wfound = 1'b1; wat = i; end
            end else wi = 1'b0;
        end
        for (i = 0; i < 8; i = i + 1)
            ws[i] = (wfound && i >= wat) ? ((i < 7) ? {w_err, w_k[i+1], w_d[8*(i+1) +: 8]} : 10'd0)
                                          : {w_err, w_k[i], w_d[8*i +: 8]};
        wcnt = wfound ? 4'd7 : 4'd8;
        for (i = 0; i < 15; i = i + 1) nw[i] = wr[i];
        for (i = 0; i < 8; i = i + 1) nw[wrn + i] = ws[i];
        nwn = wrn + wcnt;
    end
    always @(posedge wclk) begin
        rg_w1 <= rg; rg_w2 <= rg_w1;
        if (wrst) begin wp <= 0; wg <= 0; wrn <= 4'd0; w_in <= 1'b0; w_run <= 3'd0; w_rmv <= 1'b0; end
        else if (w_v) begin
            w_in <= wi; w_run <= wru; w_rmv <= wfound;
            if (nwn >= 5'd8) begin
                if (wfill != (1 << AW)) begin
                    for (i = 0; i < 8; i = i + 1) mem[wp[AW-1:0]][8*i +: 8] <= nw[i][7:0];
                    for (i = 0; i < 8; i = i + 1) mem[wp[AW-1:0]][64 + i] <= nw[i][8];
                    mem[wp[AW-1:0]][72] <= nw[0][9] | nw[7][9] | w_rmv;   // err; SKP-removed flag rides along
                    wp <= wp + 1'b1; wg <= (wp + 1'b1) ^ ((wp + 1'b1) >> 1);
                end
                for (i = 0; i < 7; i = i + 1) wr[i] <= nw[i + 8];
                wrn <= nwn - 5'd8;
            end else begin
                for (i = 0; i < 15; i = i + 1) wr[i] <= nw[i];
                wrn <= nwn;
            end
        end
    end

    // ---------------- read side ----------------
    reg [AW:0] wg_r1 = 0, wg_r2 = 0;
    wire [AW:0] fill = g2b(wg_r2) - rp;
    // residue: symbols {err, k, d}
    reg [9:0]  rs [0:15];
    reg [4:0]  rn;                       // symbols in the residue
    reg        in_skp;                   // the residue ends inside a SKP OS (for SKPs that start the next word)
    reg [2:0]  skp_run;
    reg [9:0]  n_rs [0:16];
    reg [4:0]  n_rn;
    reg        pop, ins, del, done, n_in_skp;
    reg [2:0]  n_run, run;
    reg [72:0] fw;
    reg        run_ok;                   // started: the FIFO was filled to the middle once
    reg        c_skp, c_com;
    always @(*) begin
        fw = mem[rp[AW-1:0]];
        pop = (rn < 5'd8) && (fill != 0) && (run_ok || fill >= (LO + HI) / 2);
        for (i = 0; i < 17; i = i + 1) n_rs[i] = (i < 16) ? rs[i] : 10'd0;
        n_rn = rn;
        if (pop) begin
            for (i = 0; i < 8; i = i + 1) n_rs[rn + i] = {fw[72], fw[64 + i], fw[8*i +: 8]};
            n_rn = rn + 5'd8;
        end
        // one SKP insert / remove per clock, inside a SKP OS, within the first 15 symbols
        ins = 1'b0; del = 1'b0; done = 1'b0; run = 3'd0; n_run = skp_run; n_in_skp = in_skp;
        for (i = 0; i < 15; i = i + 1) begin
            c_com = n_rs[i][8] && n_rs[i][7:0] == K_COM;
            c_skp = n_rs[i][8] && n_rs[i][7:0] == K_SKP;
            if (i < n_rn) begin
                if (c_com) begin n_in_skp = 1'b1; n_run = 3'd0; end
                else if (c_skp && n_in_skp) begin
                    n_run = n_run + 1'b1;
                    if (!done && fill < LO && n_run < 3'd5 && i + 1 < n_rn && !(n_rs[i+1][8] && n_rs[i+1][7:0] == K_SKP)) begin ins = 1'b1; done = 1'b1; end
                                    end else n_in_skp = 1'b0;
            end
        end
    end
    // apply the insert / delete at the first SKP position that qualified (found again here)
    reg [4:0] at; reg found; reg [2:0] r2; reg s2;
    always @(*) begin
        at = 5'd0; found = 1'b0; r2 = skp_run; s2 = in_skp;
        for (i = 0; i < 15; i = i + 1) if (i < n_rn && !found) begin
            if (n_rs[i][8] && n_rs[i][7:0] == K_COM) begin s2 = 1'b1; r2 = 3'd0; end
            else if (n_rs[i][8] && n_rs[i][7:0] == K_SKP && s2) begin
                r2 = r2 + 1'b1;
                if (ins && r2 < 3'd5 && i + 1 < n_rn && !(n_rs[i+1][8] && n_rs[i+1][7:0] == K_SKP)) begin at = i; found = 1'b1; end
            end else s2 = 1'b0;
        end
    end
    reg [9:0] m_rs [0:16]; reg [4:0] m_rn;
    always @(*) begin
        for (i = 0; i < 17; i = i + 1) m_rs[i] = n_rs[i];
        m_rn = n_rn;
        if (found && ins) begin
            for (i = 1; i < 17; i = i + 1) if (i > at) m_rs[i] = n_rs[i - 1];
            m_rn = n_rn + 1'b1;
        end
    end
    // SKP state after the 8 delivered symbols
    reg [2:0] o_run; reg o_in;
    always @(*) begin
        o_run = skp_run; o_in = in_skp;
        for (i = 0; i < 8; i = i + 1) begin
            if (m_rs[i][8] && m_rs[i][7:0] == K_COM) begin o_in = 1'b1; o_run = 3'd0; end
            else if (m_rs[i][8] && m_rs[i][7:0] == K_SKP && o_in) o_run = o_run + 1'b1;
            else o_in = 1'b0;
        end
    end
    always @(posedge rclk) begin
        wg_r1 <= wg; wg_r2 <= wg_r1;
        r_fill <= fill;
        if (rrst) begin
            rp <= 0; rg <= 0; rn <= 5'd0; r_v <= 1'b0; run_ok <= 1'b0; in_skp <= 1'b0; skp_run <= 3'd0; r_status <= 3'b000;
        end else begin
            if (pop) run_ok <= 1'b1;
            if (pop) begin rp <= rp + 1'b1; rg <= (rp + 1'b1) ^ ((rp + 1'b1) >> 1); end
            r_v <= (m_rn >= 5'd8);
            r_status <= (m_rn < 5'd8) ? 3'b110 : (found && ins) ? 3'b001 :
                        (m_rs[0][9] | m_rs[1][9] | m_rs[2][9] | m_rs[3][9] |
                         m_rs[4][9] | m_rs[5][9] | m_rs[6][9] | m_rs[7][9]) ? 3'b100 : 3'b000;
            for (i = 0; i < 8; i = i + 1) begin r_d[8*i +: 8] <= m_rs[i][7:0]; r_k[i] <= m_rs[i][8]; end
            if (m_rn >= 5'd8) begin
                for (i = 0; i < 16; i = i + 1) rs[i] <= (i + 8 < 17) ? m_rs[i + 8] : 10'd0;
                rn <= m_rn - 5'd8; skp_run <= o_run; in_skp <= o_in;
            end else begin
                for (i = 0; i < 16; i = i + 1) rs[i] <= m_rs[i];
                rn <= m_rn;
            end
        end
    end
`endif
endmodule
