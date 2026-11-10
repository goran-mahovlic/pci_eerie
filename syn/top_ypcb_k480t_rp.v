// SPDX-License-Identifier: CERN-OHL-P
// YPCB K480T as a PCIe root port (pci_eerie in the Vivado 7-series root port core), e.g. into an
// M.2 SSD through a PCIe x8 female to M.2 adapter that supplies the 100 MHz reference clock
// on the edge connector. The FPGA drives PERST# (the edge connector's PERST# pin, an output
// here): low for 100 ms after configuration, then high. Controlled over JTAG (eerie_jtag_bus,
// see tools/eerie_host.tcl): ctl bit 0 forces PERST# low, ctl bit 1 holds the core in reset.
// LEDs: 0 user_lnk_up, 1 PERST# released, 2 user clock heartbeat.
`timescale 1ns / 1ps
module top_ypcb_k480t_rp #(
    parameter LANES       = 4,
    parameter ENABLE_GEN2 = 1,
    parameter UCF         = 2
) (
    output [LANES-1:0] pci_exp_txp, output [LANES-1:0] pci_exp_txn,
    input  [LANES-1:0] pci_exp_rxp, input  [LANES-1:0] pci_exp_rxn,
    input  sys_clk_p, input sys_clk_n,
    output perst_n,
    input  clk_50,
    output [2:0] led
);
    wire sys_clk;
    IBUFDS_GTE2 refclk_ibuf (.O(sys_clk), .ODIV2(), .I(sys_clk_p), .CEB(1'b0), .IB(sys_clk_n));

    wire [31:0] ctl;
    // clk_50: power-on core reset (1 ms) and PERST# (100 ms)
    reg [22:0] por = 23'd0;
    reg        core_rst_n = 1'b0, perst_q = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ctl_s0 = 2'b00, ctl_s1 = 2'b00;
    always @(posedge clk_50) begin
        ctl_s0 <= ctl[1:0]; ctl_s1 <= ctl_s0;
        if (ctl_s1[0]) por <= 23'd0;                    // forced PERST#: restart the 100 ms
        else if (por != 23'd5_000_000) por <= por + 1'b1;
        perst_q    <= (por == 23'd5_000_000) && !ctl_s1[0];
        core_rst_n <= (por >= 23'd50_000 || core_rst_n) && !ctl_s1[1];
    end
    assign perst_n = perst_q;
    reg [24:0] hb50 = 25'd0;
    always @(posedge clk_50) hb50 <= hb50 + 1'b1;

    wire user_clk, lnk_up;
    wire req, we, ack; wire [15:0] addr; wire [31:0] wdata, rdata;
    eerie_host_rp #(.LANES(LANES), .ENABLE_GEN2(ENABLE_GEN2), .UCF(UCF), .GT_DEVICE("GTX")) rp (
        .pci_exp_txp(pci_exp_txp), .pci_exp_txn(pci_exp_txn), .pci_exp_rxp(pci_exp_rxp), .pci_exp_rxn(pci_exp_rxn),
        .sys_clk(sys_clk), .sys_rst_n(core_rst_n), .user_clk(user_clk), .user_lnk_up(lnk_up),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata), .ack(ack)
    );
    reg [25:0] hbu = 26'd0;
    always @(posedge user_clk) hbu <= hbu + 1'b1;

    eerie_jtag_bus jtag (
        .clk(user_clk), .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata), .ack(ack),
        .aux({5'd0, hb50[24], hbu[25], lnk_up, core_rst_n, perst_q}), .ctl(ctl)
    );
    // LEDs (active low as in top_ypcb_k480t)
    assign led = ~{hbu[25], perst_q, lnk_up};
endmodule
