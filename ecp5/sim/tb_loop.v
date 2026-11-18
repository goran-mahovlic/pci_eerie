// SPDX-License-Identifier: CERN-OHL-P-2.0
// Simulacija petlje (TASK-6160): pci_eerie endpoint (eerie_x1_ep + BAR0 app) <-PIPE-> pci_eerie root port.
// Root port glumi host: čeka L0 i DL up, pa radi što i Linux pri enumeraciji + jedan pristup BAR0:
//   CfgRd0 0x00 (vendor/device), CfgWr0/CfgRd0 BAR0 (veličina), CfgWr0 BAR0, CfgWr0 Command (MEM),
//   MRd32 BAR0+0 (ID), MWr32 BAR0+0x0C, MRd32 BAR0+0x0C.
// Ishod: "PASS n/n" ili "FAIL". Plusarg +shift => PHY pomak simbola za 1 bajt.
`timescale 1ns / 1ps
module tb_loop;
    reg pclk = 0, uclk = 0, rst_n = 0;
    always #4 pclk = !pclk;                  // 125 MHz
    always @(posedge pclk) uclk <= !uclk;    // 62,5 MHz

    // ---------------- PIPE žice
    wire [17:0] ep_line, rp_line;
    wire        ep_ei, rp_ei;
    wire [15:0] ep_rxd, rp_rxd, ep_txd, rp_txd;
    wire [1:0]  ep_rxk, rp_rxk, ep_txk, rp_txk, ep_pd, rp_pd;
    wire [2:0]  ep_rxs, rp_rxs;
    wire        ep_rxv, rp_rxv, ep_rxei, rp_rxei, ep_phys, rp_phys, ep_txei, rp_txei, ep_det, rp_det;
    wire [5:0]  ep_ltssm, rp_ltssm;
    wire        ep_lnk, rp_lnk, ep_phylnk, rp_phylnk;

`ifndef LD_SHIM
    eerie_x1_ep #(.FAST_TRAIN("TRUE")) ep (
        .pclk(pclk), .uclk(uclk), .sys_rst_n(rst_n),
        .pipe_rxdata(ep_rxd), .pipe_rxdatak(ep_rxk), .pipe_rxvalid(ep_rxv), .pipe_rxelecidle(ep_rxei),
        .pipe_rxstatus(ep_rxs), .pipe_phystatus(ep_phys),
        .pipe_txdata(ep_txd), .pipe_txdatak(ep_txk), .pipe_txelecidle(ep_txei), .pipe_txcompliance(),
        .pipe_powerdown(ep_pd), .pipe_txdetectrx(ep_det), .pipe_rxpolarity(), .pipe_rate(),
        .ltssm(ep_ltssm), .phy_lnk_up(ep_phylnk), .lnk_up(ep_lnk));

`endif
    // ---------------- root port (TRN izložen)
    wire [63:0] r_rd; reg [63:0] r_td = 0;
    wire        r_rrem, r_rsof, r_reof, r_rsrc, r_tdst;
    reg         r_trem = 1, r_tsof = 0, r_teof = 0, r_tsrc = 0;
    eerie_x1_core #(.RP(1), .FAST_TRAIN("TRUE")) rp (
        .pclk(pclk), .uclk(uclk), .sys_rst_n(rst_n),
        .pipe_rxdata(rp_rxd), .pipe_rxdatak(rp_rxk), .pipe_rxvalid(rp_rxv), .pipe_rxelecidle(rp_rxei),
        .pipe_rxstatus(rp_rxs), .pipe_phystatus(rp_phys),
        .pipe_txdata(rp_txd), .pipe_txdatak(rp_txk), .pipe_txelecidle(rp_txei), .pipe_txcompliance(),
        .pipe_powerdown(rp_pd), .pipe_txdetectrx(rp_det), .pipe_rxpolarity(), .pipe_rate(),
        .trn_rd(r_rd), .trn_rrem(r_rrem), .trn_rsof(r_rsof), .trn_reof(r_reof), .trn_rsrc_rdy(r_rsrc),
        .trn_rbar_hit(), .trn_rdst_rdy(1'b1),
        .trn_td(r_td), .trn_trem(r_trem), .trn_tsof(r_tsof), .trn_teof(r_teof), .trn_tsrc_rdy(r_tsrc),
        .trn_tdst_rdy(r_tdst), .trn_lnk_up(rp_lnk), .completer_id(), .user_rst(), .ds_bus(8'd1),
        .ltssm(rp_ltssm), .phy_lnk_up(rp_phylnk));

`ifndef LD_SHIM
    wire [15:0] ep_rxd0, ep_rxd1; wire [1:0] ep_rxk0, ep_rxk1;
    reg shift_ep = 0;
    initial shift_ep = $test$plusargs("shift");
    // dva modela: EP-ov s pomakom (ako +shift), RP-ov bez
    pipe_phy_model #(.SHIFT(0)) phy_ep0 (.pclk(pclk), .rst(!rst_n), .txdata(ep_txd), .txdatak(ep_txk),
        .txelecidle(ep_txei), .powerdown(ep_pd), .txdetectrx(ep_det),
        .rxdata(ep_rxd0), .rxdatak(ep_rxk0), .rxvalid(ep_rxv), .rxelecidle(ep_rxei), .rxstatus(ep_rxs),
        .phystatus(ep_phys), .line_out(ep_line), .line_ei_out(ep_ei), .line_in(rp_line), .line_ei_in(rp_ei),
        .partner_present(1'b1));
    pipe_phy_model #(.SHIFT(1)) phy_ep1 (.pclk(pclk), .rst(!rst_n), .txdata(ep_txd), .txdatak(ep_txk),
        .txelecidle(ep_txei), .powerdown(ep_pd), .txdetectrx(ep_det),
        .rxdata(ep_rxd1), .rxdatak(ep_rxk1), .rxvalid(), .rxelecidle(), .rxstatus(),
        .phystatus(), .line_out(), .line_ei_out(), .line_in(rp_line), .line_ei_in(rp_ei),
        .partner_present(1'b1));
    assign ep_rxd = shift_ep ? ep_rxd1 : ep_rxd0;
    assign ep_rxk = shift_ep ? ep_rxk1 : ep_rxk0;
`else
    // EP = ld_eerie_core (ECP5 shim + pci_eerie + BAR0 app) nad modelom DCU FF sučelja
    reg clk_free = 0; always #20 clk_free = !clk_free;   // 25 MHz
    wire [23:0] dcu_rx_d, dcu_tx_d;
    wire d_plol, d_rlol, d_rlos, d_lsm, d_done, d_con, d_trst, d_rrst, d_lrx, d_ltx, d_det, d_ct, d_inv;
    wire [7:0] ld_led;
    ld_eerie_core #(.FAST_TRAIN("TRUE"), .TRST_W(3), .PLL_W(6), .LOS_W(5), .LOL_W(5), .DET_US(10)) ep (
        .clk_free(clk_free), .pclk(pclk), .uclk(uclk), .perst_n(rst_n),
        .dcu_rx_d(dcu_rx_d), .dcu_tx_d(dcu_tx_d), .dcu_plol(d_plol), .dcu_rlol(d_rlol), .dcu_rlos(d_rlos),
        .dcu_lsm(d_lsm), .dcu_pcie_done(d_done), .dcu_pcie_con(d_con), .dcu_trst(d_trst), .dcu_rrst(d_rrst),
        .dcu_lane_rx_rst(d_lrx), .dcu_lane_tx_rst(d_ltx), .dcu_pcie_det_en(d_det), .dcu_pcie_ct(d_ct),
        .dcu_sb_inv_rx(d_inv), .led(ld_led), .ltssm(ep_ltssm), .lnk_up(ep_lnk));
    reg shift_ep = 0;
    initial shift_ep = $test$plusargs("shift");
    wire [23:0] rx_d0, rx_d1; wire [17:0] l0, l1; wire ei0, ei1;
    wire plol0, rlol0, rlos0, lsm0, done0;
    dcua_ff_model #(.SHIFT(0)) dcu0 (.pclk(pclk), .clk_free(clk_free), .tx_d(dcu_tx_d), .rx_d(rx_d0),
        .plol(d_plol), .rlol(d_rlol), .rlos(d_rlos), .lsm(d_lsm), .pcie_done(d_done), .pcie_con(d_con),
        .trst(d_trst), .rrst(d_rrst), .lane_rx_rst(d_lrx), .pcie_det_en(d_det), .pcie_ct(d_ct),
        .line_out(ep_line), .line_ei_out(ep_ei), .line_in(rp_line), .line_ei_in(rp_ei), .partner_present(1'b1));
    dcua_ff_model #(.SHIFT(1)) dcu1 (.pclk(pclk), .clk_free(clk_free), .tx_d(dcu_tx_d), .rx_d(rx_d1),
        .plol(), .rlol(), .rlos(), .lsm(), .pcie_done(), .pcie_con(),
        .trst(d_trst), .rrst(d_rrst), .lane_rx_rst(d_lrx), .pcie_det_en(d_det), .pcie_ct(d_ct),
        .line_out(), .line_ei_out(), .line_in(rp_line), .line_ei_in(rp_ei), .partner_present(1'b1));
    assign dcu_rx_d = shift_ep ? rx_d1 : rx_d0;
    always @(posedge d_det) $display("%t EP detekcija prijemnika (DCU DET_EN)", $time);
    always @(posedge ld_led[4]) $display("%t EP LED4: prijemnik hosta detektiran", $time);
`endif
    pipe_phy_model #(.SHIFT(0)) phy_rp (.pclk(pclk), .rst(!rst_n), .txdata(rp_txd), .txdatak(rp_txk),
        .txelecidle(rp_txei), .powerdown(rp_pd), .txdetectrx(rp_det),
        .rxdata(rp_rxd), .rxdatak(rp_rxk), .rxvalid(rp_rxv), .rxelecidle(rp_rxei), .rxstatus(rp_rxs),
        .phystatus(rp_phys), .line_out(rp_line), .line_ei_out(rp_ei), .line_in(ep_line), .line_ei_in(ep_ei),
        .partner_present(1'b1));

    // ---------------- LTSSM trag (EP)
    reg [5:0] ltq = 6'h3F;
    always @(posedge pclk) if (ep_ltssm != ltq) begin
        ltq <= ep_ltssm; $display("%t EP LTSSM 0x%02h", $time, ep_ltssm);
    end
    always @(posedge ep_lnk) $display("%t EP DL up (trn_lnk_up)", $time);

    // ---------------- RP TRN RX: hvata zadnji CplD
    reg [31:0] c_dw [0:3]; reg [1:0] c_beat = 0; reg c_got = 0;
    always @(posedge uclk) if (r_rsrc) begin
        if (r_rsof) begin c_dw[0] <= r_rd[63:32]; c_dw[1] <= r_rd[31:0]; c_beat <= 1; end
        else if (c_beat == 1) begin c_dw[2] <= r_rd[63:32]; c_dw[3] <= r_rd[31:0]; c_beat <= 2; end
        if (r_reof) c_got <= 1'b1;
    end

    task send(input [31:0] d0, input [31:0] d1, input [31:0] d2, input [31:0] d3, input with_d3);
        begin
            @(posedge uclk); while (!r_tdst) @(posedge uclk);
            r_td <= {d0, d1}; r_tsof <= 1; r_teof <= 0; r_trem <= 1; r_tsrc <= 1;
            @(posedge uclk); while (!r_tdst) @(posedge uclk);
            r_td <= {d2, d3}; r_tsof <= 0; r_teof <= 1; r_trem <= with_d3;
            @(posedge uclk); while (!r_tdst) @(posedge uclk);
            r_tsrc <= 0; r_teof <= 0;
        end
    endtask

    integer pass = 0, total = 0, t;
    reg [7:0] tag = 0;
    reg [31:0] got;
    task wait_cpl(output [31:0] data);
        begin
            t = 0;
            while (!c_got && t < 20000) begin @(posedge uclk); t = t + 1; end
            if (!c_got) begin $display("%t TIMEOUT čekajući CplD", $time); data = 32'hDEADDEAD; end
            else begin
                data = c_dw[3];
                $display("%t   CplD dw0=%08h dw1=%08h dw2=%08h data=%08h", $time, c_dw[0], c_dw[1], c_dw[2], c_dw[3]);
            end
            @(posedge uclk); c_got <= 0;
        end
    endtask
    task check(input [31:0] g, input [31:0] e, input [8*32-1:0] what);
        begin
            total = total + 1;
            if (g === e) begin pass = pass + 1; $display("  OK   %0s = %08h", what, g); end
            else $display("  FAIL %0s = %08h (očekivano %08h)", what, g, e);
        end
    endtask
    // Cfg: bus 1, dev 0, fn 0
    task cfgrd(input [9:0] dw, output [31:0] data);
        begin tag = tag + 1; c_got <= 0;
            send({8'h04, 8'h00, 6'd0, 10'd1}, {16'h0000, tag, 8'h0F}, {8'd1, 5'd0, 3'd0, 4'd0, dw[9:6], dw[5:0], 2'b00}, 32'd0, 1'b0);
            wait_cpl(data);
        end
    endtask
    task cfgwr(input [9:0] dw, input [31:0] v);
        begin tag = tag + 1; c_got <= 0;
            send({8'h44, 8'h00, 6'd0, 10'd1}, {16'h0000, tag, 8'h0F}, {8'd1, 5'd0, 3'd0, 4'd0, dw[9:6], dw[5:0], 2'b00}, v, 1'b1);
            wait_cpl(got);   // CfgWr dobiva Cpl bez podataka
        end
    endtask
    task mrd(input [31:0] a, output [31:0] data);
        begin tag = tag + 1; c_got <= 0;
            send({8'h00, 8'h00, 6'd0, 10'd1}, {16'h0000, tag, 8'h0F}, a, 32'd0, 1'b0);
            wait_cpl(data);
        end
    endtask
    task mwr(input [31:0] a, input [31:0] v);
        begin send({8'h40, 8'h00, 6'd0, 10'd1}, {16'h0000, 8'h00, 8'h0F}, a, v, 1'b1); end
    endtask
    function [31:0] bs(input [31:0] v); bs = {v[7:0], v[15:8], v[23:16], v[31:24]}; endfunction

    initial begin
        if ($test$plusargs("vcd")) begin $dumpfile("tb_loop.vcd"); $dumpvars(0, tb_loop); end
        repeat (20) @(posedge pclk); rst_n = 1;
        t = 0;
        while (!(ep_lnk && rp_lnk) && t < 400000) begin @(posedge uclk); t = t + 1; end
        if (!(ep_lnk && rp_lnk)) begin $display("FAIL: nema DL up (EP LTSSM 0x%02h, RP 0x%02h)", ep_ltssm, rp_ltssm); $finish; end
        repeat (200) @(posedge uclk);
        cfgrd(10'd0, got);  check(got, bs(32'hE0E11204), "CfgRd0 0x00 ID");
        cfgwr(10'd4, 32'hFFFFFFFF);
        cfgrd(10'd4, got);  check(got, bs(32'hFFFFF000), "BAR0 velicina");
        cfgwr(10'd4, bs(32'hC0000000));
        cfgwr(10'd1, bs(32'h00000006));
        mrd(32'hC0000000, got); check(bs(got), 32'h4C440E1E, "BAR0+0 ID (bajt-red CPU-a)");
        mwr(32'hC000000C, 32'hCAFEF00D);
        mrd(32'hC000000C, got); check(got, 32'hCAFEF00D, "BAR0+0x0C scratch");
        mrd(32'hC0000008, got); check(bs(got) & 32'h0000_0001, 32'h1, "BAR0+8 lnk_up");
        $display("%0s %0d/%0d (EP LTSSM 0x%02h)", (pass == total) ? "PASS" : "FAIL", pass, total, ep_ltssm);
        $finish;
    end
endmodule
