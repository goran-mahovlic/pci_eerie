// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6173): 16-symbol (de)scrambler for a x1 lane with a 128-bit PIPE
// (EERIE_W16: 5.0 GT/s at 31.25 MHz, 2.5 GT/s at 15.625 MHz).
//
// eerie_scr8 for 16 symbols: reset to FFFFh by COM, no advance on SKP, 8 shifts for every other symbol.
// Stage P counts for every symbol i the advancing symbols since the last COM in the word (balanced
// popcounts, as EERIE_SCR8_PTREE), stage Q selects the LFSR state of symbol i from the candidates
// ADV^n(FFFFh) (constants) or ADV^n(lfsr) (flat XOR matrices, eerie_lfsrmat.vh + eerie_lfsrmat16.vh).
// The feedback loop is one 17:1 candidate mux deep.
//
// Symbol 0 is d[7:0] (first on the wire). Latency 2 clocks; the side bus is delayed with the data.
`timescale 1ns / 1ps
module eerie_scr16 #(
    parameter SW = 1                     // side bus width
) (
    input              clk,
    input              rst,              // LFSR to FFFFh
    input              v,                // word valid (LFSR advances only on valid words)
    input      [127:0] d,
    input      [15:0]  k,
    input      [15:0]  scr,              // per symbol: apply the scramble byte
    input      [15:0]  com,              // per symbol: COM (resets the LFSR)
    input      [15:0]  skp,              // per symbol: SKP (no advance)
    input      [SW-1:0] side,
    output reg [127:0] od,
    output reg [15:0]  ok,
    output reg         ov,
    output reg [SW-1:0] oside
);
    `include "eerie_funcs.vh"
    `include "eerie_lfsrmat.vh"
    `include "eerie_lfsrmat16.vh"

    function [15:0] advn; input [15:0] l; input integer n;
        integer j; begin advn = l; for (j = 0; j < n; j = j + 1) advn = f_lfsr_adv8(advn); end
    endfunction
    function [4:0] popc16; input [15:0] x; integer b; reg [4:0] s;
        begin s = 5'd0; for (b = 0; b < 16; b = b + 1) s = s + {4'd0, x[b]}; popc16 = s; end
    endfunction

    // ---------------- stage P: per-symbol counts ----------------
    reg  [15:0] pc;                // symbol i: a COM precedes it in this word
    reg  [4:0]  pn [0:16];         // advancing symbols before i (since the last COM); [16] = end of word
    reg         p_c16;
    integer     i, jj;
    reg         c; reg [15:0] pm;
    always @(*) begin
        for (i = 0; i <= 16; i = i + 1) begin
            pm = 16'd0; c = 1'b0;
            for (jj = 15; jj >= 0; jj = jj - 1) if (jj < i) begin
                if (com[jj]) c = 1'b1;
                if (!c && !skp[jj]) pm[jj] = 1'b1;   // c: COM at jj or after it (before i)
            end
            pn[i] = popc16(pm);
            if (i < 16) pc[i] = c;
            else p_c16 = c;
        end
    end
    reg [127:0] q_d; reg [15:0] q_k, q_scr, q_c; reg q_v; reg [SW-1:0] q_side;
    reg [4:0]   q_n [0:16]; reg q_c16;
    always @(posedge clk) begin
        q_d <= d; q_k <= k; q_scr <= scr; q_c <= pc; q_v <= v && !rst; q_side <= side;
        for (i = 0; i <= 16; i = i + 1) q_n[i] <= pn[i];
        q_c16 <= p_c16;
    end

    // ---------------- stage Q: candidate select ----------------
    reg  [15:0] lfsr;
    reg  [15:0] ca [0:16];         // ADV^n(lfsr)
    reg  [7:0]  cb [0:15];         // scramble byte of ADV^n(lfsr)
    reg  [7:0]  kb [0:15];         // scramble byte of ADV^n(FFFFh)
    reg  [15:0] kf [0:16];
    always @(*) begin
        ca[0]  = f_lfsr_m0(lfsr);  ca[1]  = f_lfsr_m1(lfsr);  ca[2]  = f_lfsr_m2(lfsr);  ca[3]  = f_lfsr_m3(lfsr);
        ca[4]  = f_lfsr_m4(lfsr);  ca[5]  = f_lfsr_m5(lfsr);  ca[6]  = f_lfsr_m6(lfsr);  ca[7]  = f_lfsr_m7(lfsr);
        ca[8]  = f_lfsr_m8(lfsr);  ca[9]  = f_lfsr_m9(lfsr);  ca[10] = f_lfsr_m10(lfsr); ca[11] = f_lfsr_m11(lfsr);
        ca[12] = f_lfsr_m12(lfsr); ca[13] = f_lfsr_m13(lfsr); ca[14] = f_lfsr_m14(lfsr); ca[15] = f_lfsr_m15(lfsr);
        ca[16] = f_lfsr_m16(lfsr);
        cb[0]  = f_lfsr_b0(lfsr);  cb[1]  = f_lfsr_b1(lfsr);  cb[2]  = f_lfsr_b2(lfsr);  cb[3]  = f_lfsr_b3(lfsr);
        cb[4]  = f_lfsr_b4(lfsr);  cb[5]  = f_lfsr_b5(lfsr);  cb[6]  = f_lfsr_b6(lfsr);  cb[7]  = f_lfsr_b7(lfsr);
        cb[8]  = f_lfsr_b8(lfsr);  cb[9]  = f_lfsr_b9(lfsr);  cb[10] = f_lfsr_b10(lfsr); cb[11] = f_lfsr_b11(lfsr);
        cb[12] = f_lfsr_b12(lfsr); cb[13] = f_lfsr_b13(lfsr); cb[14] = f_lfsr_b14(lfsr); cb[15] = f_lfsr_b15(lfsr);
        for (i = 0; i <= 16; i = i + 1) kf[i] = advn(16'hFFFF, i);
        for (i = 0; i < 16; i = i + 1) kb[i] = f_lfsr_byte(kf[i]);
    end
    reg [7:0] sb [0:15];
`ifdef EERIE_SCR16_LITE
    // TASK-6238: no SKP before the first COM of a word (the TX words; RX: a word that starts inside a SKP OS
    // has its symbol 0 SKP marked as COM by the caller, the LFSR is FFFFh there): a symbol before the first
    // COM uses ADV^i(lfsr), no candidate mux on the lfsr path
    always @(*) for (i = 0; i < 16; i = i + 1) sb[i] = q_c[i] ? kb[q_n[i][3:0]] : cb[i];
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hFFFF;
        else if (q_v) lfsr <= q_c16 ? kf[q_n[16]] : ca[16];
`else
    always @(*) for (i = 0; i < 16; i = i + 1) sb[i] = q_c[i] ? kb[q_n[i][3:0]] : cb[q_n[i][3:0]];
    always @(posedge clk) begin
        if (rst) lfsr <= 16'hFFFF;
        else if (q_v) lfsr <= q_c16 ? kf[q_n[16]] : ca[q_n[16]];
`endif
        for (i = 0; i < 16; i = i + 1) od[8*i +: 8] <= q_scr[i] ? (q_d[8*i +: 8] ^ sb[i]) : q_d[8*i +: 8];
        ok <= q_k; ov <= q_v && !rst; oside <= q_side;
    end
endmodule
