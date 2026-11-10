// SPDX-License-Identifier: CERN-OHL-P
// openXC7 builds of the Vivado 7-series core (syn/Makefile.openxc7 BOARD=ac7100b_x4): replacement for
// the core's pcie_bram_7x (yosys cannot elaborate the BRAM_TDP_MACRO copy in the core), same
// parameters and ports, one RAMB36E1 in TDP mode (port A writes, port B reads) as pcie_7x's
// pcie_brams.v does. The Makefile renames the core's own module out of the way.
// Widths 4, 9, 18, 36 (the 72-bit SDP variant is only used for x8 Gen2).
`timescale 1ns / 1ps
module ep_pcie_bram_7x #(
    parameter [3:0] LINK_CAP_MAX_LINK_SPEED = 4'h1,
    parameter [5:0] LINK_CAP_MAX_LINK_WIDTH = 6'h08,
    parameter IMPL_TARGET = "HARD",
    parameter DOB_REG = 0,
    parameter WIDTH = 0
) (
    input                user_clk_i,
    input                reset_i,
    input                wen_i,
    input  [12:0]        waddr_i,
    input  [WIDTH - 1:0] wdata_i,
    input                ren_i,
    input                rce_i,
    input  [12:0]        raddr_i,
    output [WIDTH - 1:0] rdata_o
);
    localparam AW  = (WIDTH == 4) ? 13 : (WIDTH == 9) ? 12 : (WIDTH == 18) ? 11 : 10;  // address bits
    localparam DW  = (WIDTH == 4) ? 4 : (WIDTH == 9) ? 8 : (WIDTH == 18) ? 16 : 32;    // data bits
    localparam PW  = WIDTH - DW;                                                        // parity bits
    localparam LO  = 15 - AW;                                                           // tied-off low address bits

    wire [31:0] di = {{(32 - DW){1'b0}}, wdata_i[DW - 1:0]};
    wire [3:0]  dip;
    wire [31:0] dob;
    wire [3:0]  dopb;
    generate
        if (PW > 0) begin : g_p
            assign dip = {{(4 - PW){1'b0}}, wdata_i[WIDTH - 1:DW]};
            assign rdata_o = {dopb[PW - 1:0], dob[DW - 1:0]};
        end else begin : g_np
            assign dip = 4'h0;
            assign rdata_o = dob[DW - 1:0];
        end
    endgenerate

    RAMB36E1 #(
        .DOA_REG(0), .DOB_REG(DOB_REG), .EN_ECC_READ("FALSE"), .EN_ECC_WRITE("FALSE"), .RAM_MODE("TDP"),
        .READ_WIDTH_A(WIDTH), .READ_WIDTH_B(WIDTH), .WRITE_WIDTH_A(WIDTH), .WRITE_WIDTH_B(WIDTH),
        .SIM_DEVICE("7SERIES"), .SRVAL_A(0), .SRVAL_B(0),
        .WRITE_MODE_A("NO_CHANGE"), .WRITE_MODE_B("WRITE_FIRST")
    ) ram (
        .ADDRARDADDR({1'b1, waddr_i[AW - 1:0], {LO{1'b1}}}),
        .ADDRBWRADDR({1'b1, raddr_i[AW - 1:0], {LO{1'b1}}}),
        .CLKARDCLK(user_clk_i), .CLKBWRCLK(user_clk_i),
        .DIADI(di), .DIBDI(32'd0), .DIPADIP(dip), .DIPBDIP(4'h0),
        .DOADO(), .DOBDO(dob), .DOPADOP(), .DOPBDOP(dopb),
        .ENARDEN(wen_i), .ENBWREN(ren_i),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
        .REGCEAREGCE(1'b0), .REGCEB(rce_i),
        .RSTRAMARSTRAM(reset_i), .RSTRAMB(reset_i), .RSTREGARSTREG(1'b0), .RSTREGB(reset_i),
        .WEA(4'hF), .WEBWE(8'h00)
    );
endmodule
