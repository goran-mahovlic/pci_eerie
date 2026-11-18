// SPDX-License-Identifier: CERN-OHL-P-2.0
// Prijenosni RAM za pci_eerie MIM portove (TX red/replay i RX međuspremnik), TASK-6160.
// Jedan upisni i jedan čitački port na istom taktu, čitanje kasni 2 takta
// (TL_*_RAM_RDATA_LATENCY = 2, kao pcie_7x pcie_four_brams). yosys ga mapira u
// DP16KD (ECP5) ili CC_BRAM_20K/40K (GateMate).
`timescale 1ns / 1ps
module eerie_ram_sdp #(
    parameter AW = 10,
    parameter DW = 68
) (
    input               clk,
    input               we,
    input  [AW-1:0]     waddr,
    input  [DW-1:0]     wdata,
    input               re,
    input  [AW-1:0]     raddr,
    output reg [DW-1:0] rdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [DW-1:0] q1;
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) q1 <= mem[raddr];
        rdata <= q1;
    end
endmodule
