// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6173, EERIE_W16): dual-clock packet FIFO with two read ports: rd_data2 is the
// entry after rd_data, rd_has2 says it is readable, rd_n pops 0, 1 or 2 entries (eerie_pl_tx_w16 takes a
// 16-byte packet beat as two 8-byte entries).
//
// Block RAM friendly: the entries live in two banks (even / odd entries, one write port each, synchronous
// read), so entries f and f+1 are always read in the same clock; a 4-entry output queue (the RAM output
// falls through when it is empty) makes the read side first-word fall-through. (Two asynchronous read ports of one array became 8.6 k flip-flops on GateMate.)
// PKT_MODE=1: the read side only sees entries up to the last committed packet boundary (wr_last).
// SYNC=1 (EERIE_1CLK): wr_clk == rd_clk, the pointers cross without synchronizers.
`timescale 1ns / 1ps
module eerie_async_fifo2 #(
    parameter W        = 64,
    parameter AW       = 4,        // depth = 2**AW (AW >= 2)
    parameter PKT_MODE = 0,
    parameter SYNC     = 0
) (
    input              wr_clk,
    input              wr_rst,
    input              wr_en,
    input  [W-1:0]     wr_data,
    input              wr_last,    // PKT_MODE: this entry ends a packet
    output             wr_full,
    output [AW:0]      wr_free,    // free entries (conservative: the output queue counts as used)

    input              rd_clk,
    input              rd_rst,
    input      [1:0]   rd_n,       // entries popped (2 only with rd_has2)
    output [W-1:0]     rd_data,    // first-word fall-through
    output [W-1:0]     rd_data2,   // the next entry
    output             rd_empty,
    output             rd_has2
);
    function [AW:0] bin2gray(input [AW:0] b); bin2gray = b ^ (b >> 1); endfunction
    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    reg [W-1:0] m0 [0:(1<<(AW-1))-1];       // even entries
    reg [W-1:0] m1 [0:(1<<(AW-1))-1];       // odd entries

    // ---------------- write side ----------------
    reg  [AW:0] wptr_bin, wptr_gray, cptr_bin, cptr_gray;
    reg  [AW:0] rptr_gray_r;                 // read side: entries released (gray)
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rptr_gray_w1, rptr_gray_w2;
    reg  [AW:0] rptr_bin_w, rptr_rel;
    wire [AW:0] used_w = wptr_bin - rptr_bin_w;
    assign wr_full = used_w[AW];
    assign wr_free = (1 << AW) - used_w;
    always @(posedge wr_clk) begin
        if (wr_en && !wr_full && !wptr_bin[0]) m0[wptr_bin[AW-1:1]] <= wr_data;
        if (wr_en && !wr_full &&  wptr_bin[0]) m1[wptr_bin[AW-1:1]] <= wr_data;
    end
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wptr_bin <= 0; wptr_gray <= 0; cptr_bin <= 0; cptr_gray <= 0;
            rptr_gray_w1 <= 0; rptr_gray_w2 <= 0; rptr_bin_w <= 0;
        end else begin
            rptr_gray_w1 <= rptr_gray_r;
            rptr_gray_w2 <= rptr_gray_w1;
            rptr_bin_w   <= SYNC ? rptr_rel : gray2bin(rptr_gray_w2);
            if (wr_en && !wr_full) begin
                wptr_bin  <= wptr_bin + 1'b1;
                wptr_gray <= bin2gray(wptr_bin + 1'b1);
                if (!PKT_MODE || wr_last) begin
                    cptr_bin  <= wptr_bin + 1'b1;
                    cptr_gray <= bin2gray(wptr_bin + 1'b1);
                end
            end
        end
    end
    wire [AW:0] pub_gray = PKT_MODE ? cptr_gray : wptr_gray;
    wire [AW:0] pub_bin  = PKT_MODE ? cptr_bin : wptr_bin;

    // ---------------- read side ----------------
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wptr_gray_r1, wptr_gray_r2;
    reg  [AW:0] wptr_bin_r;
    wire [AW:0] wvis = SYNC ? pub_bin : wptr_bin_r;   // entries the read side may fetch
    reg  [AW:0] fptr;                                 // next entry to fetch from the RAM
    reg  [W-1:0] q [0:3]; reg [2:0] qn;              // output queue
    reg  [1:0]  fn;                                   // entries fetched last clock (arrive now)
    reg         f_odd;                                // ... the first of them was odd
    // the read view: the queue, then the entries arriving from the RAM this clock (no extra register)
    wire [2:0]  vn = qn + fn;
    wire [1:0]  pop = (rd_n == 2'd0 || vn == 3'd0) ? 2'd0 : (rd_n == 2'd2 && vn >= 3'd2) ? 2'd2 : 2'd1;
    wire [2:0]  qn_n = vn - pop;                      // after this clock, without the new fetch
    wire [AW:0] avail = wvis - fptr;
    wire [2:0]  room = 3'd4 - qn_n;
    wire [1:0]  nf = (avail == 0 || room == 3'd0) ? 2'd0 : (avail == 1 || room == 3'd1) ? 2'd1 : 2'd2;
    wire [AW:0] fptr1 = fptr + 1'b1;
    // bank addresses: entry fptr and fptr+1 (always one even, one odd)
    wire [AW-2:0] a0 = fptr[0] ? fptr1[AW-1:1] : fptr[AW-1:1];
    wire [AW-2:0] a1 = fptr[0] ? fptr[AW-1:1]  : fptr1[AW-1:1];
    reg  [W-1:0] r0, r1;
    always @(posedge rd_clk) begin r0 <= m0[a0]; r1 <= m1[a1]; end
    wire [W-1:0] fa = f_odd ? r1 : r0;                // the first fetched entry
    wire [W-1:0] fb = f_odd ? r0 : r1;
    integer k;
    reg [W-1:0] v [0:5];
    always @(*) begin
        for (k = 0; k < 6; k = k + 1) v[k] = (k < 4) ? q[k & 3] : {W{1'b0}};
        for (k = 0; k < 6; k = k + 1) begin
            if (fn != 2'd0 && k == qn) v[k] = fa;
            if (fn == 2'd2 && k == qn + 1) v[k] = fb;
        end
    end
    assign rd_data  = v[0];
    assign rd_data2 = v[1];
    assign rd_empty = (vn == 3'd0);
    assign rd_has2  = (vn >= 3'd2);
    reg [W-1:0] qs [0:3];
    always @(*) for (k = 0; k < 4; k = k + 1) qs[k] = v[k + pop];
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            fptr <= 0; qn <= 3'd0; fn <= 2'd0; f_odd <= 1'b0; rptr_rel <= 0; rptr_gray_r <= 0;
            wptr_gray_r1 <= 0; wptr_gray_r2 <= 0; wptr_bin_r <= 0;
        end else begin
            wptr_gray_r1 <= pub_gray;
            wptr_gray_r2 <= wptr_gray_r1;
            wptr_bin_r   <= gray2bin(wptr_gray_r2);
            for (k = 0; k < 4; k = k + 1) q[k] <= qs[k];
            qn <= qn_n;
            fn <= nf; f_odd <= fptr[0];
            fptr <= fptr + nf;
            // released entries: popped from the queue; the write side sees them one per clock (one gray bit)
            if (rptr_rel != (fptr - vn) && !SYNC) begin
                rptr_rel    <= rptr_rel + 1'b1;
                rptr_gray_r <= bin2gray(rptr_rel + 1'b1);
            end else if (SYNC) rptr_rel <= rptr_rel + pop;
        end
    end
endmodule
