// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6173): SKP elastic buffer for a x1 lane on a 128-bit PIPE (EERIE_W16, 16 symbols
// per clock). The EERIE_SKP_EB2 structure of eerie_skp_eb for 16-symbol words:
//   W0: register the word, decode COM / SKP per symbol;
//   W1: pick at most one SKP of the word (one per SKP OS): remove the second SKP of a set when the FIFO
//       (write view) is above HI, duplicate the first SKP when it is below (LO+HI)/2; apply it as a +-1
//       symbol local shift (15, 16 or 17 symbols);
//   W2: repack through a residue (0..15 symbols), one word out when the window holds >= 16 symbols, two
//       when it holds 32 (residue 15 + an insert);
//   W3: FIFO RAM write from registers. The read side is a plain dual-clock FIFO of 16-symbol words.
// wclk: the recovered word clock / 2 (16 symbols), rclk: the PIPE clock. Capacity: one SKP per SKP OS
// (650..850 ppm), as eerie_skp_eb. Symbol 0 of a word is in [7:0].
`timescale 1ns / 1ps
module eerie_skp_eb16 #(
    parameter AW = 4,                    // FIFO depth 2**AW words
    parameter LO = 4,                    // insert below this fill (words)
    parameter HI = 10                    // remove above this fill (words)
) (
    input              wclk,
    input              wrst,
    input              w_v,              // word valid (symbol lock, not electrical idle)
    input      [127:0] w_d,
    input      [15:0]  w_k,
    input              w_err,            // decode / disparity error in this word
    input              rclk,
    input              rrst,
    output reg         r_v,
    output reg [127:0] r_d,
    output reg [15:0]  r_k,
    output reg [2:0]   r_status,         // 000 ok, 001 SKP added, 010 SKP removed, 100 error, 110 underflow
    output reg [AW:0]  r_fill
);
    integer i;
    localparam [7:0] K_COM2 = 8'hBC, K_SKP2 = 8'h1C;
    // ---------------- write side ----------------
    reg [146:0] mem [0:(1<<AW)-1];        // {err, removed, added, k[15:0], d[127:0]}
    reg [AW:0] wp = 0, wg = 0;
    reg [AW:0] rg_w1 = 0, rg_w2 = 0;
    reg [AW:0] rp = 0, rg = 0;
    function [AW:0] g2b; input [AW:0] g; integer j; begin g2b[AW] = g[AW];
        for (j = AW - 1; j >= 0; j = j - 1) g2b[j] = g2b[j+1] ^ g[j]; end endfunction
    reg [AW:0] wfill;
    // W0
    reg        s0_v, s0_e; reg [127:0] s0_d; reg [15:0] s0_k, s0_com, s0_skp;
    always @(posedge wclk) begin
        s0_v <= w_v && !wrst; s0_d <= w_d; s0_k <= w_k; s0_e <= w_err;
        for (i = 0; i < 16; i = i + 1) begin
            s0_com[i] <= w_k[i] && w_d[8*i +: 8] == K_COM2;
            s0_skp[i] <= w_k[i] && w_d[8*i +: 8] == K_SKP2;
        end
    end
    // W1: decision. State carried across words: {inside a SKP OS, SKP seen, OS already adjusted}.
    // W1p evaluates the 16-symbol scan for all 8 start states in parallel (registered), so the
    // state loop in W1s is an 8:1 select. Packed per start state: {n_state[2:0], del, ins, pos[3:0]}.
    reg        want_del, want_ins;       // registered: the fill moves by one word per clock at most
    always @(posedge wclk) begin want_del <= wfill > HI; want_ins <= wfill < (LO + HI) / 2; end
    function [8:0] sscan; input [2:0] st; input [15:0] com, skp; input wd, wi;
        integer x; reg ni, ns, na, fd, fi; reg [3:0] ps;
        begin
            {ni, ns, na} = st; fd = 1'b0; fi = 1'b0; ps = 4'd0;
            for (x = 0; x < 16; x = x + 1) begin
                if (com[x]) begin ni = 1'b1; ns = 1'b0; na = 1'b0; end
                else if (skp[x] && ni) begin
                    if (!na && ((wd && ns) || wi)) begin
                        na = 1'b1; ps = x;
                        if (wd && ns) fd = 1'b1; else fi = 1'b1;
                    end
                    ns = 1'b1;
                end else ni = 1'b0;
            end
            sscan = {ni, ns, na, fd, fi, ps};
        end
    endfunction
    reg [8:0]  p_sc [0:7]; reg p_v, p_e; reg [127:0] p_d; reg [15:0] p_k;
    integer    q;
    always @(posedge wclk) begin
        for (q = 0; q < 8; q = q + 1) p_sc[q] <= sscan(q, s0_com, s0_skp, want_del, want_ins);
        p_v <= s0_v && !wrst; p_e <= s0_e; p_d <= s0_d; p_k <= s0_k;
    end
    reg  [2:0] st;
    wire [8:0] sc = p_sc[st];
    wire       wfound = p_v && sc[5], wins = p_v && sc[4];
    wire [3:0] wpos = sc[3:0];
    // W1a: register the decision with the word; W1b: apply it
    reg        s1_v, s1_e, s1_del, s1_ins; reg [3:0] s1_pos; reg [127:0] s1_d; reg [15:0] s1_k;
    always @(posedge wclk) begin
        if (wrst) st <= 3'd0;
        else if (p_v) st <= sc[8:6];
        s1_v <= p_v && !wrst; s1_e <= p_e; s1_del <= wfound; s1_ins <= wins; s1_pos <= wpos;
        s1_d <= p_d; s1_k <= p_k;
    end
    reg [9:0]  a [0:16];                 // adjusted symbols {err, k, d}
    reg [4:0]  a_n; reg a_v, a_ins, a_del, a_e;
    reg [9:0]  sy [0:16];
    always @(*) for (i = 0; i < 17; i = i + 1) sy[i] = (i < 16) ? {s1_e, s1_k[i], s1_d[8*i +: 8]} : 10'd0;
    always @(posedge wclk) begin
        for (i = 0; i < 17; i = i + 1)
            a[i] <= (s1_del && i >= s1_pos) ? sy[i + 1 > 16 ? 16 : i + 1] :
                    (s1_ins && i > s1_pos)  ? sy[(i == 0) ? 0 : i - 1] : sy[i];
        a_n <= s1_del ? 5'd15 : s1_ins ? 5'd17 : 5'd16;
        a_v <= s1_v && !wrst; a_ins <= s1_ins; a_del <= s1_del; a_e <= s1_e;
    end
    // W2: repack
    reg [4:0]  o;                        // W2 residue symbols (0..15)
    reg [9:0]  res [0:15];
    reg [9:0]  win [0:31];
    wire [5:0] tot = {1'b0, o} + {1'b0, a_n};
    always @(*) for (i = 0; i < 32; i = i + 1) win[i] = (i < o) ? res[i & 15] : (i - o <= 16) ? a[(i - o) & 31] : 10'd0;
    reg        f_ins, f_del;             // flags of words still in the residue
    // W2 registers the words to write (0, 1 or 2); W3 writes the FIFO RAM (not gated by wrst)
    reg [1:0]  e_n; reg [146:0] e_w0, e_w1;
    always @(posedge wclk) begin
        e_n <= 2'd0;
        for (i = 0; i < 16; i = i + 1) begin
            e_w0[8*i +: 8] <= win[i][7:0]; e_w0[128 + i] <= win[i][8];
            e_w1[8*i +: 8] <= win[i + 16][7:0]; e_w1[128 + i] <= win[i + 16][8];
        end
        e_w0[146:144] <= {win[0][9] | win[15][9], f_del | a_del, f_ins | a_ins};
        e_w1[146:144] <= {win[16][9] | win[31][9], 2'b00};
        if (wrst) begin o <= 5'd0; f_ins <= 1'b0; f_del <= 1'b0; end
        else if (a_v) begin
            if (tot == 6'd32) begin
                e_n <= 2'd2; o <= 5'd0; f_ins <= 1'b0; f_del <= 1'b0;
            end else if (tot >= 6'd16) begin
                e_n <= 2'd1;
                for (i = 0; i < 16; i = i + 1) res[i] <= win[i + 16];
                o <= tot[4:0] - 5'd16; f_ins <= 1'b0; f_del <= 1'b0;
            end else begin
                for (i = 0; i < 16; i = i + 1) res[i] <= win[i];
                o <= tot[4:0]; f_ins <= f_ins | a_ins; f_del <= f_del | a_del;
            end
        end
    end
    // W3: FIFO write (a full FIFO drops the words: overflow, beyond the SKP capacity)
    wire       e_ok = (e_n == 2'd2) ? wfill < (1 << AW) - 1 : wfill != (1 << AW);
    always @(posedge wclk) begin
        if (e_n != 2'd0 && e_ok) mem[wp[AW-1:0]] <= e_w0;
        if (e_n == 2'd2 && e_ok) mem[wp[AW-1:0] + 1'b1] <= e_w1;
    end
    always @(posedge wclk) begin
        rg_w1 <= rg; rg_w2 <= rg_w1;
        wfill <= wp - g2b(rg_w2);
        if (wrst) begin wp <= 0; wg <= 0; end
        else if (e_n != 2'd0 && e_ok) begin
            wp <= wp + e_n; wg <= (wp + e_n) ^ ((wp + e_n) >> 1);
        end
    end

    // ---------------- read side: plain FIFO ----------------
    reg [AW:0] wg_r1 = 0, wg_r2 = 0;
    wire [AW:0] fill = g2b(wg_r2) - rp;
    reg        run_ok;
    wire       pop = (fill != 0) && (run_ok || fill >= (LO + HI) / 2);
    wire [146:0] fw = mem[rp[AW-1:0]];
    always @(posedge rclk) begin
        wg_r1 <= wg; wg_r2 <= wg_r1;
        r_fill <= fill;
        if (rrst) begin rp <= 0; rg <= 0; r_v <= 1'b0; run_ok <= 1'b0; r_status <= 3'b000; end
        else begin
            if (pop) begin run_ok <= 1'b1; rp <= rp + 1'b1; rg <= (rp + 1'b1) ^ ((rp + 1'b1) >> 1); end
            r_v <= pop;
            r_status <= !pop ? 3'b110 : fw[144] ? 3'b001 : fw[146] ? 3'b100 : fw[145] ? 3'b010 : 3'b000;
            r_d <= fw[127:0]; r_k <= fw[143:128];
        end
    end
endmodule
