// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: lane-to-lane deskew for multi-lane links
//
// Input: the descrambled symbol pair of every lane (eerie_pl_rx ln_*), in arrival order.
// Every lane feeds a small FIFO with its SKP symbols removed (so lanes whose SKP ordered sets
// had symbols added or removed by the GT elastic buffer stay in step); a COM that starts a SKP
// ordered set is tagged. Symbol times are popped from all active lanes together; when some
// lanes show a COM at their head and others do not, the others are popped alone until every
// lane has its COM at the head (ordered sets are sent on all lanes at the same time). The
// aligned stream drops the COM of SKP ordered sets and carries up to two symbol times per clock.
`timescale 1ns / 1ps
module eerie_pl_deskew #(
    parameter N = 4
) (
    input              clk,
    input              rst,
    input  [N-1:0]     act,            // lanes in the link (lane 0 always)
    input  [N-1:0]     ln_v,
    input  [16*N-1:0]  ln_d,
    input  [2*N-1:0]   ln_k,
    input  [2*N-1:0]   ln_com,
    input  [2*N-1:0]   ln_skp,
    input  [N-1:0]     ln_err,

    // aligned symbol times (lane l in [8l+7:8l])
    output reg         o_va, o_vb,
    output reg [8*N-1:0] o_da, o_db,
    output reg [N-1:0]   o_ka, o_kb,
    output reg         o_erra, o_errb
);
    localparam D = 16;                 // FIFO depth per lane (symbols)
    // entry: {err, skpcom, com, k, d[7:0]}
    localparam EW = 12;

    // ---------------- stage A: one pair of lookahead to tag COMs that start a SKP OS ----------------
    reg  [N-1:0]    p_v;
    reg  [16*N-1:0] p_d;
    reg  [2*N-1:0]  p_k, p_com, p_skp;
    reg  [N-1:0]    p_err;
    always @(posedge clk) begin
        if (rst) p_v <= {N{1'b0}};
        else p_v <= ln_v;
        p_d <= ln_d; p_k <= ln_k; p_com <= ln_com; p_skp <= ln_skp; p_err <= ln_err;
    end

    // ---------------- per-lane FIFOs ----------------
    reg [EW-1:0] mem [0:N*D-1];
    reg [4:0]    wp [0:N-1];
    reg [4:0]    rp [0:N-1];
    reg [1:0]    popc [0:N-1];         // pops this cycle (computed below)

    integer l;
    reg [EW-1:0] e0, e1;
    reg          w0, w1;
    reg [4:0]    occ;
    always @(posedge clk) begin
        for (l = 0; l < N; l = l + 1) begin
            if (rst || !act[l]) begin
                wp[l] <= 5'd0; rp[l] <= 5'd0;
            end else begin
                // previous pair (p_*), SKP symbols removed; slot 1's lookahead is the current slot 0
                // (no push when nearly full: a lane that is far ahead is realigned at the next COM)
                occ = wp[l] - rp[l];                      // 5-bit modular difference
                w0 = p_v[l] && !p_skp[2*l] && occ < D - 2;
                w1 = p_v[l] && !p_skp[2*l+1] && occ < D - 2;
                e0 = {p_err[l], p_com[2*l] && p_skp[2*l+1], p_com[2*l], p_k[2*l], p_d[16*l +: 8]};
                e1 = {p_err[l], p_com[2*l+1] && ln_v[l] && ln_skp[2*l], p_com[2*l+1], p_k[2*l+1], p_d[16*l+8 +: 8]};
                if (w0 && w1) begin
                    mem[l*D + wp[l][3:0]] <= e0; mem[l*D + ((wp[l] + 5'd1) & 5'd15)] <= e1; wp[l] <= wp[l] + 5'd2;
                end else if (w0) begin
                    mem[l*D + wp[l][3:0]] <= e0; wp[l] <= wp[l] + 5'd1;
                end else if (w1) begin
                    mem[l*D + wp[l][3:0]] <= e1; wp[l] <= wp[l] + 5'd1;
                end
                rp[l] <= rp[l] + popc[l];
            end
        end
    end

    // ---------------- alignment / pop (two symbol times per clock) ----------------
    reg [EW-1:0] h0 [0:N-1];
    reg [EW-1:0] h1 [0:N-1];
    reg [4:0]    cnt [0:N-1];
    reg [N-1:0]  pa, pb;
    reg          av_a, av_b, anyc, allc, outa, outb;
    reg [EW-1:0] hb;
    reg [8*N-1:0] da, db; reg [N-1:0] ka, kb; reg ea, eb;
    always @(*) begin
        for (l = 0; l < N; l = l + 1) begin
            cnt[l] = wp[l] - rp[l];
            h0[l] = mem[l*D + rp[l][3:0]];
            h1[l] = mem[l*D + ((rp[l] + 5'd1) & 5'd15)];
        end
        // symbol time A
        av_a = 1'b1; anyc = 1'b0; allc = 1'b1;
        for (l = 0; l < N; l = l + 1) if (act[l]) begin
            if (cnt[l] == 5'd0) av_a = 1'b0;
            if (h0[l][9]) anyc = 1'b1; else allc = 1'b0;
        end
        pa = {N{1'b0}}; outa = 1'b0;
        if (av_a) begin
            for (l = 0; l < N; l = l + 1)
                pa[l] = act[l] && (!anyc || allc || !h0[l][9]);
            outa = !anyc || (allc && !h0[0][10]);
        end
        // symbol time B (heads after A's pops)
        av_b = 1'b1; anyc = 1'b0; allc = 1'b1;
        for (l = 0; l < N; l = l + 1) if (act[l]) begin
            hb = pa[l] ? h1[l] : h0[l];
            if (cnt[l] <= {4'd0, pa[l]}) av_b = 1'b0;
            if (hb[9]) anyc = 1'b1; else allc = 1'b0;
        end
        pb = {N{1'b0}}; outb = 1'b0;
        if (av_b) begin
            for (l = 0; l < N; l = l + 1) begin
                hb = pa[l] ? h1[l] : h0[l];
                pb[l] = act[l] && (!anyc || allc || !hb[9]);
            end
            hb = pa[0] ? h1[0] : h0[0];
            outb = !anyc || (allc && !hb[10]);
        end
        ea = 1'b0; eb = 1'b0;
        for (l = 0; l < N; l = l + 1) begin
            popc[l] = {1'b0, pa[l]} + {1'b0, pb[l]};
            da[8*l +: 8] = h0[l][7:0]; ka[l] = h0[l][8] && act[l];
            hb = pa[l] ? h1[l] : h0[l];
            db[8*l +: 8] = hb[7:0];    kb[l] = hb[8] && act[l];
            if (act[l] && h0[l][11]) ea = 1'b1;
            if (act[l] && hb[11]) eb = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin o_va <= 1'b0; o_vb <= 1'b0; end
        else begin o_va <= outa; o_vb <= outb; end
        o_da <= da; o_db <= db; o_ka <= ka; o_kb <= kb; o_erra <= ea; o_errb <= eb;
    end
endmodule
