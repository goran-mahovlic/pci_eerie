// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6238, EERIE_W16 + EERIE_1CLK): the DLL -> eerie_pl_tx_w16 packet FIFO as pairs.
// The DLL writes one 8-byte entry {half,last,sop,data} per clock; two entries of the same packet are one
// RAM word (a packet with an odd entry count ends with a single). eerie_pl_tx_w16 always takes a whole
// pair (take1 = !last && has2), so the read side is a plain first-word fall-through FIFO of pairs instead
// of the 2-port 4-entry queue of eerie_async_fifo2. PKT_MODE: only pairs up to the last committed packet
// end are visible. Single clock (wr_clk == rd_clk).
`timescale 1ns / 1ps
module eerie_pair_fifo #(
    parameter W  = 67,
    parameter AW = 7               // entries = 2**AW (pairs: 2**(AW-1))
) (
    input              clk,
    input              wr_rst,
    input              wr_en,
    input  [W-1:0]     wr_data,
    input              wr_last,
    output             wr_full,
    output [AW:0]      wr_free,

    input              rd_rst,
    input      [1:0]   rd_n,       // 1 or 2: the head pair leaves
    output [W-1:0]     rd_data,
    output [W-1:0]     rd_data2,
    output             rd_empty,
    output             rd_has2
);
    localparam PW = 2 * W + 1, PA = AW - 1;
    (* ram_style = "block" *) reg [PW-1:0] mem [0:(1<<PA)-1];
    reg  [W-1:0]  hd; reg hv;                  // first entry of a pair, waiting for the second
    reg  [PA:0]   wp, cp, rp;                  // write, committed, read (RAM) pointers (pairs)
    wire [PA:0]   used = wp - rp;
    assign wr_full = used[PA];
    wire [PA:0]   freep = (1 << PA) - used;  // free pairs
    assign wr_free = {freep, 1'b0} - {{AW{1'b0}}, hv};   // free entries (the held entry counts as used)
    wire          wr = wr_en && !wr_full;
    wire          wpair = wr && (hv || wr_last);
    wire [PW-1:0] wword = hv ? {1'b1, wr_data, hd} : {1'b0, {W{1'b0}}, wr_data};
    always @(posedge clk) if (wpair) mem[wp[PA-1:0]] <= wword;
    always @(posedge clk) begin
        if (wr_rst) begin wp <= 0; cp <= 0; hv <= 1'b0; end
        else if (wr) begin
            if (wpair) begin
                wp <= wp + 1'b1; hv <= 1'b0;
                if (wr_last) cp <= wp + 1'b1;
            end else begin
                hd <= wr_data; hv <= 1'b1;
            end
        end
    end

    // read side: RAM (synchronous read) -> 2-pair output queue, one pair per clock
    reg  [PW-1:0] rq, q0, q1; reg infl; reg [1:0] qn;
    wire          pop = rd_n != 2'd0 && qn != 2'd0;
    wire [1:0]    keep = qn - {1'b0, pop};
    wire          issue = (rp != cp) && ({1'b0, keep} + {2'b0, infl}) <= 3'd1;
    always @(posedge clk) if (issue) rq <= mem[rp[PA-1:0]];
    assign rd_data  = q0[W-1:0];
    assign rd_data2 = q0[2*W-1:W];
    assign rd_empty = qn == 2'd0;
    assign rd_has2  = qn != 2'd0 && q0[PW-1];
    always @(posedge clk) begin
        if (rd_rst) begin rp <= 0; infl <= 1'b0; qn <= 2'd0; end
        else begin
            if (issue) rp <= rp + 1'b1;
            infl <= issue;
            qn <= keep + {1'b0, infl};
            if (pop) q0 <= q1;
            if (infl) begin
                if (keep == 2'd0) q0 <= rq;
                else q1 <= rq;
            end
        end
    end
endmodule
