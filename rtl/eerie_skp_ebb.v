// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6176, EERIE_SKP_EBB): SKP elastic buffer of eerie_skp_eb (EERIE_SKP_EB2) with the
// FIFO in block RAM.
//
// EB2 writes 0, 1 or 2 words per clock (2 when a 7-symbol residue meets a SKP insert) into a flip-flop FIFO
// with an asynchronous read: ~1.2 k flip-flops plus the read multiplexer, and two write ports, so it cannot
// go into CC_BRAM. Here the write side (W0..W2, SKP decision and repack) behaves as EB2 (the W2 window is a
// 3-stage shift of the adjusted symbols ORed with the zero-padded residue); then
//   W3: the words are paired (a pending half of 0 or 1 word): at most ONE pair (2 words, 150 bits) is
//       written per clock into a dual-clock FIFO in block RAM (one write port on wclk, one read port on rclk);
//   R:  the read side reads one pair every other clock (registered RAM output) and delivers one word per clock.
// Fill thresholds are in words (write view: 2 * pairs in the FIFO + pending half + pair being written).
// Capacity as EB2: one SKP per SKP ordered set (650..850 ppm). Symbol 0 of a word is in [7:0].
`timescale 1ns / 1ps
module eerie_skp_ebb #(
    parameter AW    = 4,                 // FIFO depth 2**AW pairs (2**(AW+1) words)
    parameter LO    = 10,                // insert below this fill (words, write view)
    parameter HI    = 20,                // remove above this fill (words, write view)
    parameter START = 7                  // read side starts at this fill (pairs, read view)
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
    output reg [AW:0] r_fill             // pairs (read view)
);
    integer i;
    localparam [7:0] K_COM2 = 8'hBC, K_SKP2 = 8'h1C;
    function [AW:0] g2b; input [AW:0] g; integer j; begin g2b[AW] = g[AW];
        for (j = AW - 1; j >= 0; j = j - 1) g2b[j] = g2b[j+1] ^ g[j]; end endfunction
    reg [AW:0] wp = 0, wg = 0;           // write pointer (pairs)
    reg [AW:0] rg_w1 = 0, rg_w2 = 0;
    reg [AW:0] rp = 0, rg = 0;           // read pointer (pairs)
    reg [AW+1:0] wfill = 0;              // words, write view

    // ---------------- write side W0..W2: EB2 (eerie_skp_eb2.vh) ----------------
    // W0
    reg        s0_v, s0_e; reg [63:0] s0_d; reg [7:0] s0_k, s0_com, s0_skp;
    always @(posedge wclk) begin
        s0_v <= w_v && !wrst; s0_d <= w_d; s0_k <= w_k; s0_e <= w_err;
        for (i = 0; i < 8; i = i + 1) begin
            s0_com[i] <= w_k[i] && w_d[8*i +: 8] == K_COM2;
            s0_skp[i] <= w_k[i] && w_d[8*i +: 8] == K_SKP2;
        end
    end
    // W1: at most one SKP of a SKP OS: remove the second when above HI, duplicate the first when below LO
    reg        want_del, want_ins;
    always @(posedge wclk) begin want_del <= wfill > HI; want_ins <= wfill < LO; end
    function [7:0] sscan; input [2:0] st; input [7:0] com, skp; input wd, wi;
        integer x; reg ni, ns, na, fd, fi; reg [2:0] ps;
        begin
            {ni, ns, na} = st; fd = 1'b0; fi = 1'b0; ps = 3'd0;
            for (x = 0; x < 8; x = x + 1) begin
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
    reg [7:0]  p_sc [0:7]; reg p_v, p_e; reg [63:0] p_d; reg [7:0] p_k;
    integer    q;
    always @(posedge wclk) begin
        for (q = 0; q < 8; q = q + 1) p_sc[q] <= sscan(q, s0_com, s0_skp, want_del, want_ins);
        p_v <= s0_v && !wrst; p_e <= s0_e; p_d <= s0_d; p_k <= s0_k;
    end
    reg  [2:0] st;
    wire [7:0] sc = p_sc[st];
    wire       wfound = p_v && sc[4], wins = p_v && sc[3];
    wire [2:0] wpos = sc[2:0];
    reg        s1_v, s1_e, s1_del, s1_ins; reg [2:0] s1_pos; reg [63:0] s1_d; reg [7:0] s1_k;
    always @(posedge wclk) begin
        if (wrst) st <= 3'd0;
        else if (p_v) st <= sc[7:5];
        s1_v <= p_v && !wrst; s1_e <= p_e; s1_del <= wfound; s1_ins <= wins; s1_pos <= wpos;
        s1_d <= p_d; s1_k <= p_k;
    end
    reg [9:0]  a [0:8];                  // adjusted symbols {err, k, d}
    reg [3:0]  a_n; reg a_v, a_ins, a_del, a_e;
    reg [9:0]  sy [0:8];
    always @(*) for (i = 0; i < 9; i = i + 1) sy[i] = (i < 8) ? {s1_e, s1_k[i], s1_d[8*i +: 8]} : 10'd0;
    always @(posedge wclk) begin
        for (i = 0; i < 9; i = i + 1)
            a[i] <= (s1_del && i >= s1_pos) ? sy[i + 1 > 8 ? 8 : i + 1] :
                    (s1_ins && i > s1_pos)  ? sy[(i == 0) ? 0 : i - 1] : sy[i];
        a_n <= s1_del ? 4'd7 : s1_ins ? 4'd9 : 4'd8;
        a_v <= s1_v && !wrst; a_ins <= s1_ins; a_del <= s1_del; a_e <= s1_e;
    end
    // W2: repack, 0, 1 or 2 words {err, removed, added, k[7:0], d[63:0]}
    // window = residue ++ adjusted symbols. The residue is kept zero above its o symbols and a[] is zero above
    // a_n, so the window is residue | (a << o symbols): a 3-stage shift instead of a 9:1 select per symbol.
    reg [3:0]  o;
    reg [79:0] resv;                     // residue, symbol i in [10*i +: 10]
    reg [9:0]  win [0:15];
    wire [4:0] tot = {1'b0, o} + {1'b0, a_n};
    wire [159:0] av0 = {70'd0, a[8], a[7], a[6], a[5], a[4], a[3], a[2], a[1], a[0]};
    wire [159:0] av1 = o[0] ? {av0[149:0], 10'd0} : av0;
    wire [159:0] av2 = o[1] ? {av1[139:0], 20'd0} : av1;
    wire [159:0] av3 = o[2] ? {av2[119:0], 40'd0} : av2;
    wire [159:0] winv = av3 | {80'd0, resv};
    always @(*) for (i = 0; i < 16; i = i + 1) win[i] = winv[10*i +: 10];
    reg        f_ins, f_del;
    reg [1:0]  e_n; reg [74:0] e_w0, e_w1;
    always @(posedge wclk) begin
        e_n <= 2'd0;
        for (i = 0; i < 8; i = i + 1) begin
            e_w0[8*i +: 8] <= win[i][7:0]; e_w0[64 + i] <= win[i][8];
            e_w1[8*i +: 8] <= win[i + 8][7:0]; e_w1[64 + i] <= win[i + 8][8];
        end
        e_w0[74:72] <= {win[0][9] | win[7][9], f_del | a_del, f_ins | a_ins};
        e_w1[74:72] <= {win[8][9] | win[15][9], 2'b00};
        if (wrst) begin o <= 4'd0; resv <= 80'd0; f_ins <= 1'b0; f_del <= 1'b0; end
        else if (a_v) begin
            if (tot == 5'd16) begin
                e_n <= 2'd2; o <= 4'd0; resv <= 80'd0; f_ins <= 1'b0; f_del <= 1'b0;
            end else if (tot >= 5'd8) begin
                e_n <= 2'd1;
                resv <= winv[159:80];
                o <= tot[3:0] - 4'd8; f_ins <= 1'b0; f_del <= 1'b0;
            end else begin
                resv <= winv[79:0];
                o <= tot[3:0]; f_ins <= f_ins | a_ins; f_del <= f_del | a_del;
            end
        end
    end

    // ---------------- W3: pairing, one RAM write per clock ----------------
    // hv/ph: a word waiting for its pair partner. With 0..2 new words, hv + e_n <= 3: one pair out at most.
    reg         hv = 1'b0; reg [74:0] ph;
    reg         pw_v = 1'b0; reg [149:0] pw_d;  // pair to write {second, first}
    always @(posedge wclk) begin
        pw_v <= 1'b0;
        if (wrst) hv <= 1'b0;
        else case ({hv, e_n})
            3'b0_01: begin hv <= 1'b1; ph <= e_w0; end
            3'b0_10: begin pw_v <= 1'b1; pw_d <= {e_w1, e_w0}; end
            3'b1_01: begin pw_v <= 1'b1; pw_d <= {e_w0, ph}; hv <= 1'b0; end
            3'b1_10: begin pw_v <= 1'b1; pw_d <= {e_w0, ph}; ph <= e_w1; end
            default: ;
        endcase
    end
    (* ram_style = "block" *) reg [149:0] mem [0:(1<<AW)-1];
    wire [AW:0] wused = wp - g2b(rg_w2);
    wire        wfull = wused[AW];
    always @(posedge wclk)               // a full FIFO drops the pair: overflow, beyond the SKP capacity
        if (pw_v && !wfull) mem[wp[AW-1:0]] <= pw_d;
    always @(posedge wclk) begin
        rg_w1 <= rg; rg_w2 <= rg_w1;
        wfill <= {wused, 1'b0} + hv + {pw_v, 1'b0};
        if (wrst) begin wp <= 0; wg <= 0; end
        else if (pw_v && !wfull) begin wp <= wp + 1'b1; wg <= (wp + 1'b1) ^ ((wp + 1'b1) >> 1); end
    end

    // ---------------- read side: one pair per two clocks, one word per clock ----------------
    reg [AW:0]  wg_r1 = 0, wg_r2 = 0;
    wire [AW:0] fill = g2b(wg_r2) - rp;
    reg         run_ok = 1'b0;           // started (the FIFO was filled to START once)
    reg         rq_ok = 1'b0;            // the RAM output register holds an unread pair
    reg         h = 1'b0;                // the half delivered next
    reg [149:0] rq;
    // fetch when the RAM output is free or its second half goes out now
    wire        need = !rq_ok || h;
    wire        fetch = need && fill != 0 && (run_ok || fill >= START);
    always @(posedge rclk) if (fetch) rq <= mem[rp[AW-1:0]];
    wire [74:0] fw = h ? rq[149:75] : rq[74:0];
    always @(posedge rclk) begin
        wg_r1 <= wg; wg_r2 <= wg_r1;
        r_fill <= fill;
        if (rrst) begin
            rp <= 0; rg <= 0; run_ok <= 1'b0; rq_ok <= 1'b0; h <= 1'b0; r_v <= 1'b0; r_status <= 3'b000;
        end else begin
            if (fetch) begin run_ok <= 1'b1; rp <= rp + 1'b1; rg <= (rp + 1'b1) ^ ((rp + 1'b1) >> 1); end
            if (rq_ok) h <= !h;
            if (fetch) rq_ok <= 1'b1; else if (rq_ok && h) rq_ok <= 1'b0;
            if (fetch) h <= 1'b0;
            r_v <= rq_ok;
            r_status <= !rq_ok ? 3'b110 : fw[72] ? 3'b001 : fw[74] ? 3'b100 : fw[73] ? 3'b010 : 3'b000;
            r_d <= fw[63:0]; r_k <= fw[71:64];
        end
    end
endmodule
