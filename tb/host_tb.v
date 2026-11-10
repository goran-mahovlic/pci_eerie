// SPDX-License-Identifier: CERN-OHL-P
// Root port hardware test design (syn/eerie_host_rp.v: Vivado root port core with pci_eerie, plus
// eerie_host_app) against a multi-lane endpoint (eerie_tb_ep_ml, PCIE_2_1 or pci_eerie inside),
// driven through the register bus as tools/eerie_host.tcl does over JTAG:
// link up, RP config space, CfgRd0/CfgWr0 enumeration of the endpoint, MWr32 + MRd32 to BAR0.
`timescale 1ns / 1ps
`ifndef RP_LANES
`define RP_LANES 4
`endif
`ifndef EP_LANES
`define EP_LANES 2
`endif
`ifndef GEN2
`define GEN2 1
`endif
module host_tb;
    localparam RL = `RP_LANES, EL = `EP_LANES;
    reg refclk = 1'b0;
    always #5 refclk = !refclk;
    reg rst_n = 1'b0;
    wire [RL-1:0] rp_txp, rp_txn, rp_rxp, rp_rxn;
    wire [EL-1:0] ep_txp, ep_txn, ep_rxp, ep_rxn;
    genvar g;
    generate
        for (g = 0; g < EL; g = g + 1) begin : e
            if (g < RL) begin assign ep_rxp[g] = rp_txp[g]; assign ep_rxn[g] = rp_txn[g]; end
            else begin assign ep_rxp[g] = 1'b0; assign ep_rxn[g] = 1'b0; end
        end
        for (g = 0; g < RL; g = g + 1) begin : r
            if (g < EL) begin assign rp_rxp[g] = ep_txp[g]; assign rp_rxn[g] = ep_txn[g]; end
            else begin assign rp_rxp[g] = 1'b0; assign rp_rxn[g] = 1'b0; end
        end
    endgenerate

    localparam BW = RL * (`GEN2 ? 2 : 1);
    wire uclk, lnk_up, ack; wire [31:0] rdata;
    reg req = 1'b0, we = 1'b0; reg [15:0] addr = 16'd0; reg [31:0] wdata = 32'd0;
    eerie_host_rp #(.LANES(RL), .ENABLE_GEN2(`GEN2), .UCF(BW <= 1 ? 1 : 2), .FAST_TRAIN("TRUE")) RP (
        .pci_exp_txp(rp_txp), .pci_exp_txn(rp_txn), .pci_exp_rxp(rp_rxp), .pci_exp_rxn(rp_rxn),
        .sys_clk(refclk), .sys_rst_n(rst_n), .user_clk(uclk), .user_lnk_up(lnk_up),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata), .ack(ack)
    );
    eerie_tb_ep_ml #(.LANES(EL), .ENABLE_GEN2(`GEN2)) EP (
        .pci_exp_txp(ep_txp), .pci_exp_txn(ep_txn), .pci_exp_rxp(ep_rxp), .pci_exp_rxn(ep_rxn),
        .sys_clk_p(refclk), .sys_clk_n(!refclk), .sys_rst_n(rst_n)
    );

    task wr(input [15:0] a, input [31:0] d);
        begin
            @(posedge uclk); req <= 1'b1; we <= 1'b1; addr <= a; wdata <= d;
            @(posedge uclk); req <= 1'b0;
            @(posedge ack);
        end
    endtask
    task rd(input [15:0] a, output [31:0] d);
        begin
            @(posedge uclk); req <= 1'b1; we <= 1'b0; addr <= a;
            @(posedge uclk); req <= 1'b0;
            @(posedge uclk); while (!ack) @(posedge uclk);
            d = rdata;
        end
    endtask
    // configuration payload DWs are in PCIe byte order (byte 0 in bits 31:24)
    function [31:0] sw; input [31:0] d; sw = {d[7:0], d[15:8], d[23:16], d[31:24]}; endfunction
    integer errors = 0, i, n;
    reg [31:0] v, st;
    // send a TLP of 3 or 4 DWs and wait for it to leave
    task send(input integer len, input [31:0] d0, input [31:0] d1, input [31:0] d2, input [31:0] d3);
        begin
            wr(16'h0000, d0); wr(16'h0001, d1); wr(16'h0002, d2); wr(16'h0003, d3);
            wr(16'h0100, len);
            v = 1; while (v[0]) rd(16'h0100, v);
        end
    endtask
    // wait for a completion; return its first data DW (DW3)
    task cpl(output [31:0] status_dw1, output [31:0] data);
        begin
            n = 0; v = 0;
            while (v[31:24] == 0 && n < 2000) begin rd(16'h0200, v); n = n + 1; end
            if (v[31:24] == 0) begin $display("[%0t] HOST: no completion", $time); errors = errors + 1; end
            rd(16'h1000, status_dw1);   // DW0
            rd(16'h1001, v);            // DW1: completer id, status, byte count
            status_dw1 = v;
            rd(16'h1003, data);         // DW3
            wr(16'h0200, 0);
        end
    endtask
    task cfgrd(input [7:0] reg_dw, output [31:0] d);
        reg [31:0] s;
        begin
            send(3, 32'h0400_0001, 32'h0000_010F, {8'h01, 5'd0, 3'd0, 4'd0, reg_dw[5:0], 2'b00}, 0);
            cpl(s, d); d = sw(d);
            if (s[15:13] != 3'b000) begin $display("[%0t] HOST: CfgRd %h status %b", $time, reg_dw, s[15:13]); errors = errors + 1; end
        end
    endtask
    task cfgwr(input [7:0] reg_dw, input [31:0] d);
        reg [31:0] s, x;
        begin
            send(4, 32'h4400_0001, 32'h0000_020F, {8'h01, 5'd0, 3'd0, 4'd0, reg_dw[5:0], 2'b00}, sw(d));
            cpl(s, x);
            if (s[15:13] != 3'b000) begin $display("[%0t] HOST: CfgWr %h status %b", $time, reg_dw, s[15:13]); errors = errors + 1; end
        end
    endtask
    task mgmt_rd(input [9:0] dw, output [31:0] d);
        begin
            wr(16'h0400, dw); wr(16'h0402, 32'hF1);
            v = 1; while (v[0]) rd(16'h0402, v);
            if (v[1]) begin $display("[%0t] HOST: cfg_mgmt timeout", $time); errors = errors + 1; end
            rd(16'h0403, d);
        end
    endtask
    task mgmt_wr(input [9:0] dw, input [31:0] d);
        begin
            wr(16'h0400, dw); wr(16'h0401, d); wr(16'h0402, 32'hF2);
            v = 1; while (v[0]) rd(16'h0402, v);
        end
    endtask

    initial begin
        #1000 rst_n = 1'b1;
        wait (lnk_up === 1'b1);
        $display("[%0t] HOST: user_lnk_up", $time);
        // wait for the autonomous speed change and width
        n = 0; st = 0;
        while (n < 4000 && !(st[8] == `GEN2 && st[7:2] == 6'h16)) begin rd(16'h0300, st); n = n + 1; end
        repeat (200) @(posedge uclk);
        rd(16'h0300, st);
        $display("[%0t] HOST: status %h: LTSSM %h, %s, x%0d (initial x%0d)", $time, st, st[7:2],
                 st[8] ? "5.0 GT/s" : "2.5 GT/s", 1 << st[10:9], st[13:11] == 0 ? 0 : 1 << (st[13:11] - 1));
        if ((1 << st[10:9]) != (EL < RL ? EL : RL) || st[8] != `GEN2) begin
            $display("[%0t] HOST: unexpected link", $time); errors = errors + 1;
        end
        // RP config space: vendor/device, class, command <- memory + bus master, bus numbers 0/1/1
        mgmt_rd(10'h000, v); $display("[%0t] HOST: RP ID %h", $time, v);
        mgmt_rd(10'h002, v); $display("[%0t] HOST: RP class/rev %h", $time, v);
        mgmt_wr(10'h001, 32'h0000_0006);
        mgmt_wr(10'h006, 32'h0001_0100);
        mgmt_rd(10'h006, v); $display("[%0t] HOST: RP bus numbers %h", $time, v);
        if (v[23:0] != 24'h01_0100) errors = errors + 1;
        // enumerate the endpoint
        cfgrd(0, v); $display("[%0t] HOST: EP ID %h", $time, v);
        if (v != 32'h9999_10EE) errors = errors + 1;
        cfgrd(2, v); $display("[%0t] HOST: EP class/rev %h", $time, v);
        cfgwr(4, 32'hFFFF_FFFF); cfgrd(4, v); $display("[%0t] HOST: EP BAR0 mask %h", $time, v);
        if (v != 32'hFFFF_F000) errors = errors + 1;
        cfgwr(4, 32'h1000_0000);
        cfgwr(1, 32'h0000_0006);
        cfgrd(1, v); $display("[%0t] HOST: EP command/status %h", $time, v);
        // memory write + read back
        send(4, 32'h4000_0001, 32'h0000_030F, 32'h1000_0010, 32'hCAFE_0123);
        send(3, 32'h0000_0001, 32'h0000_040F, 32'h1000_0010, 0);
        cpl(st, v); $display("[%0t] HOST: MRd 0x10000010 = %h (cpl status %b)", $time, v, st[15:13]);
        if (v != 32'hCAFE_0123) errors = errors + 1;
        // a 4 DW burst
        wr(16'h0000, 32'h4000_0004); wr(16'h0001, 32'h0000_050F); wr(16'h0002, 32'h1000_0020);
        for (i = 0; i < 4; i = i + 1) wr(16'h0003 + i, 32'h1111_0000 * (i + 1) + i);
        wr(16'h0100, 7); v = 1; while (v[0]) rd(16'h0100, v);
        send(3, 32'h0000_0004, 32'h0000_060F, 32'h1000_0020, 0);
        n = 0; v = 0; while (v[31:24] == 0 && n < 2000) begin rd(16'h0200, v); n = n + 1; end
        for (i = 0; i < 4; i = i + 1) begin
            rd(16'h1003 + i, st);
            if (st != 32'h1111_0000 * (i + 1) + i) begin
                $display("[%0t] HOST: burst DW%0d %h", $time, i, st); errors = errors + 1;
            end
        end
        if (errors == 0) $display("[%0t] HOST: TEST PASSED", $time);
        else $display("[%0t] HOST: TEST FAILED, %0d errors", $time, errors);
        $finish;
    end
    initial begin #(`TIMEOUT_NS * 1.0); $display("[%0t] HOST: TIMEOUT", $time); $finish; end
endmodule
