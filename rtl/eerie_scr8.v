// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6161): 8-symbol (de)scrambler for a x1 lane with a 64-bit PIPE.
//
// Same LFSR as eerie_pl_rx / eerie_pl_tx (see eerie_funcs.vh): reset to FFFFh by COM, no advance
// on SKP, 8 shifts for every other symbol. Instead of chaining eight per-symbol steps, stage P
// counts for every symbol i the advancing symbols since the last COM in the word (or since the
// start of the word) and stage Q selects the LFSR state for symbol i from 16 candidates:
// ADV^n(FFFFh) (constants) or ADV^n(lfsr) (flat XOR of the state). The feedback loop is one
// candidate mux deep.
//
// Symbol 0 is d[7:0] (first on the wire). Latency 2 clocks; the side bus is delayed with the data.
`timescale 1ns / 1ps
module eerie_scr8 #(
    parameter SW = 1                     // side bus width
) (
    input             clk,
    input             rst,               // LFSR to FFFFh
    input             v,                 // word valid (LFSR advances only on valid words)
    input      [63:0] d,
    input      [7:0]  k,
    input      [7:0]  scr,               // per symbol: apply the scramble byte
    input      [7:0]  com,               // per symbol: COM (resets the LFSR)
    input      [7:0]  skp,               // per symbol: SKP (no advance)
    input      [SW-1:0] side,
    output reg [63:0] od,
    output reg [7:0]  ok,
    output reg        ov,
    output reg [SW-1:0] oside
);
    `include "eerie_funcs.vh"
`ifdef EERIE_SCR8_MAT
    `include "eerie_lfsrmat.vh"
`endif

    function [15:0] advn; input [15:0] l; input integer n;
        integer j; begin advn = l; for (j = 0; j < n; j = j + 1) advn = f_lfsr_adv8(advn); end
    endfunction

    // ---------------- stage P: per-symbol counts ----------------
    reg  [7:0]  pc;                // symbol i: a COM precedes it in this word
    reg  [3:0]  pn [0:8];          // advancing symbols before i (since the last COM); [8] = end of word
    reg         p_c8;
    integer     i;
    reg         c; reg [3:0] n;
`ifdef EERIE_SCR8_PTREE
    // TASK-6161 (GateMate): pn[i] = advancing symbols j < i with no COM in j..i-1, as a balanced
    // popcount per i instead of one running counter through the word
    function [3:0] popc8; input [7:0] x;
        popc8 = ({3'd0, x[0]} + {3'd0, x[1]}) + ({3'd0, x[2]} + {3'd0, x[3]})
              + (({3'd0, x[4]} + {3'd0, x[5]}) + ({3'd0, x[6]} + {3'd0, x[7]}));
    endfunction
    reg [7:0] pm; integer jj;
    always @(*) begin
        for (i = 0; i <= 8; i = i + 1) begin
            pm = 8'd0; c = 1'b0;
            for (jj = 7; jj >= 0; jj = jj - 1) if (jj < i) begin
                if (com[jj]) c = 1'b1;
                if (!c && !skp[jj]) pm[jj] = 1'b1;   // c: COM at jj or after it (before i)
            end
            pn[i] = popc8(pm);
            if (i < 8) pc[i] = c;
            else p_c8 = c;
        end
    end
`else
    always @(*) begin
        c = 1'b0; n = 4'd0;
        for (i = 0; i < 8; i = i + 1) begin
            pc[i] = c; pn[i] = n;
            if (com[i]) begin c = 1'b1; n = 4'd0; end
            else if (!skp[i]) n = n + 1'b1;
        end
        pn[8] = n; p_c8 = c;
    end
`endif
    reg [63:0] q_d; reg [7:0] q_k, q_scr, q_c; reg q_v; reg [SW-1:0] q_side;
    reg [3:0]  q_n [0:8]; reg q_c8;
    always @(posedge clk) begin
        q_d <= d; q_k <= k; q_scr <= scr; q_c <= pc; q_v <= v && !rst; q_side <= side;
        for (i = 0; i <= 8; i = i + 1) q_n[i] <= pn[i];
        q_c8 <= p_c8;
    end

    // ---------------- stage Q: candidate select ----------------
    reg  [15:0] lfsr;
    reg  [15:0] ca [0:8];          // ADV^n(lfsr)
    reg  [7:0]  cb [0:7];          // scramble byte of ADV^n(lfsr)
    reg  [7:0]  kb [0:7];          // scramble byte of ADV^n(FFFFh)
    reg  [15:0] kf [0:8];
    always @(*) begin
`ifdef EERIE_SCR8_MAT
        // TASK-6161 (GateMate): one flat XOR matrix per candidate (syn/gen_lfsr_mat.py)
        ca[0] = f_lfsr_m0(lfsr); ca[1] = f_lfsr_m1(lfsr); ca[2] = f_lfsr_m2(lfsr); ca[3] = f_lfsr_m3(lfsr);
        ca[4] = f_lfsr_m4(lfsr); ca[5] = f_lfsr_m5(lfsr); ca[6] = f_lfsr_m6(lfsr); ca[7] = f_lfsr_m7(lfsr);
        ca[8] = f_lfsr_m8(lfsr);
        cb[0] = f_lfsr_b0(lfsr); cb[1] = f_lfsr_b1(lfsr); cb[2] = f_lfsr_b2(lfsr); cb[3] = f_lfsr_b3(lfsr);
        cb[4] = f_lfsr_b4(lfsr); cb[5] = f_lfsr_b5(lfsr); cb[6] = f_lfsr_b6(lfsr); cb[7] = f_lfsr_b7(lfsr);
        for (i = 0; i <= 8; i = i + 1) kf[i] = advn(16'hFFFF, i);
        for (i = 0; i < 8; i = i + 1) kb[i] = f_lfsr_byte(kf[i]);
`else
        for (i = 0; i <= 8; i = i + 1) begin ca[i] = advn(lfsr, i); kf[i] = advn(16'hFFFF, i); end
        for (i = 0; i < 8; i = i + 1) begin cb[i] = f_lfsr_byte(ca[i]); kb[i] = f_lfsr_byte(kf[i]); end
`endif
    end
    reg [7:0] sb [0:7];
    always @(*) for (i = 0; i < 8; i = i + 1) sb[i] = q_c[i] ? kb[q_n[i][2:0]] : cb[q_n[i][2:0]];
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hFFFF;
        else if (q_v) lfsr <= q_c8 ? kf[q_n[8]] : ca[q_n[8]];
        for (i = 0; i < 8; i = i + 1) od[8*i +: 8] <= q_scr[i] ? (q_d[8*i +: 8] ^ sb[i]) : q_d[8*i +: 8];
        ok <= q_k; ov <= q_v && !rst; oside <= q_side;
    end
endmodule
