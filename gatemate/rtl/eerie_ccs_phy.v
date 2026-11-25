// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6170: PIPE x1 Gen1, 64 bits at 31.25 MHz, for pci_eerie (EERIE_W8) on the GateMate SerDes.
//
// One ccfpga_serdes instance, the same in simulation and on the chip: the file list picks
// ccfpga_serdes.BFM.sv (openSERDES_BFM, simulation) or ccfpga_serdes.SYNTH.sv (CC_SERDES).
// The SerDes does 8b10b, comma alignment (any lane: the W8 RX takes a COM in any of the 8 slots),
// electrical idle, receiver detection and polarity. This glue adds what PIPE needs on top:
//   * PCLK = the SerDes PLL clock (2.5 Gb/s / 80 = 31.25 MHz), also the SerDes TX/RX core clock;
//   * PhyStatus: high in reset, a pulse after a PowerDown change and after a receiver detection;
//   * RxStatus 011 / 000 from the receiver detection (or, with RXDET_TMO, "present" after a timeout:
//     DS1001 does not say how long the detection takes, the BFM takes 120 ns);
//   * RxStatus 100 for an 8b10b code or disparity error in the word;
//   * RxValid = byte aligned and not electrical idle.
// SRNS = 0 (default, common REFCLK, e.g. a host slot): RX_CLK_I = PCLK, the SerDes RX buffer crosses
// the phase only (no clock correction: it cannot match PCIe SKP ordered sets, openSERDES_BFM README).
// SRNS = 1 (separate reference clocks): RX_CLK_I = RX_CLK_O and the words cross into PCLK through
// eerie_skp_eb (build with EERIE_SKP_EB2), which inserts / removes SKP symbols of SKP ordered sets;
// with EERIE_SKP_EBB through eerie_skp_ebb (the same, FIFO in block RAM, TASK-6176).
`timescale 1ns / 1ps
module eerie_ccs_phy #(
    parameter       SRNS       = 0,
    parameter       RX_POL_INV = 0,      // board P/N swap on the RX pair (the LTSSM also inverts by itself)
    parameter       TX_NEG     = 1,      // TX data from a falling-edge register (SerDes ports are not timed)
    parameter       RXDET_TMO  = 1023,   // PCLKs to wait for RX_DETECT_DONE; then report "present" (0: wait forever)
    // the PLL and the analog part: 2.5 Gb/s from 100 MHz, recipe GS<->M2 2.5G "zadano CPM4" (TASK-5979)
    parameter [5:0] PLL_FCNTRL      = 6'd58,
    parameter [5:0] PLL_MAIN_DIVSEL = 6'd27,
    parameter [1:0] PLL_OUT_DIVSEL  = 2'd1,
    parameter [4:0] TX_AMP          = 5'd12,
    parameter [7:0] RX_CDR_CKP      = 8'h3E
) (
    input         rst_n,                 // async: PERST# and power-on, active low
    input         clk_ref,               // simulation only: the SerDes reference (CC_SERDES has its own pads)
    input         ser_rxp, ser_rxn,      // simulation only: the serial line
    output        ser_txp, ser_txn,
    output        pclk,
    output        phy_rdy,               // SerDes TX out of reset, synchronous to pclk
    // PIPE, MAC side (pclk)
    input  [63:0] txdata,                // symbol 0 in [7:0]
    input  [7:0]  txdatak,
    input         txelecidle,
    input         txcompliance,
    input  [1:0]  powerdown,
    input         txdetectrx,
    input         rxpolarity,
    output reg [63:0] rxdata,
    output reg [7:0]  rxdatak,
    output reg        rxvalid,
    output reg        rxelecidle,
    output reg [2:0]  rxstatus,
    output reg        phystatus,
    // debug
    output     [7:0]  dbg                // {rx_buf_err, tx_buf_err, rx_resetdone, tx_resetdone, aligned, ei, det_done, present}
`ifdef EERIE_ALIGN_L0
   ,input             align_hold         // TASK-6185 (pclk, quasi-static): 1 = comma alignment off (settled in L0)
`endif
`ifdef EERIE_EQA_POLL
   ,input             eqa_rst            // TASK-6185 (pclk): pulse = RX reset from the EQA stage (EQA -> CDR -> PCS -> BUF)
`endif
`ifdef EERIE_DBGCNT
   ,output     [63:0] dbgc               // TASK-6185 (pclk): {pre-EB err words, realign, RX_BUF_ERR, post-EB err words, SKP add, SKP del}
`endif
`ifdef EERIE_ILA
   ,output reg [31:0] ppmw = 32'd0       // TASK-6190 (pclk): rclk - pclk clocks over the last 2^24 pclk (0.537 s); ppm = ppmw / 16.777
`endif
);
    wire clk_pll, clk_rxo, rst_pll_n;
    wire tx_rdone, rx_rdone, det_done, present, tx_buf_err, rx_buf_err, aligned, ei_raw;
`ifdef EERIE_RX_REALIGN
    reg rra_rst = 1'b0;                  // TASK-6192: alignment watchdog reset (below)
`endif
    wire [63:0] s_rxd; wire [7:0] s_rxk, s_nit, s_disp;
    wire realign;
    eerie_bufg u_bp (.I(clk_pll), .O(pclk));
    wire rclk;
    generate if (SRNS) begin : g_rxo
        eerie_bufg u_br (.I(clk_rxo), .O(rclk));
    end else begin : g_rxp
        assign rclk = pclk;
    end endgenerate
`ifdef EERIE_ALIGN_L0
    // TASK-6185: GS<->M2 ALIGN_START (ber_as.v, D2 SER-QD-17) for PCIe: the SerDes realigns on every comma it sees, so one
    // bit error that forms a false comma in L0 shifts the symbol boundary until the next true COM. Alignment is on outside
    // L0 (Detect/Polling/Recovery: TS1/TS2 COMs re-lock it) and off once the link has settled in L0 (align_hold, m2_pcie_top).
    // Re-arm as in ber_as (alignment back on when sync falls): >= 4 error words within 16 rclk (a real slip, not one false
    // comma) or RX not aligned -> alignment on for 2^10 rclk.
    wire s_e1 = |(s_nit | s_disp);
    reg [1:0] ahs = 2'b00; reg [3:0] ewin = 4'd0; reg [2:0] ecnt = 3'd0; reg [10:0] arm = 11'd0;
    always @(posedge rclk) begin
        ahs <= {ahs[0], align_hold};
        ewin <= ewin + 1'b1;
        if (ewin == 4'd0) ecnt <= {2'b00, s_e1}; else if (s_e1 && ecnt != 3'd7) ecnt <= ecnt + 1'b1;
        if ((ecnt >= 3'd4) || !aligned) arm <= 11'd1024; else if (arm != 11'd0) arm <= arm - 1'b1;
    end
    wire c_align = !ahs[1] || (arm != 11'd0);
`endif

    // ---------------- resets (pclk) ----------------
    reg [2:0] rs = 3'b000;
    always @(posedge pclk or negedge rst_n) if (!rst_n) rs <= 3'b000; else rs <= {rs[1:0], 1'b1};
    wire prst = !rs[2];
    reg [2:0] trd = 3'b000;
    always @(posedge pclk or negedge rst_n) if (!rst_n) trd <= 3'b000; else trd <= {trd[1:0], tx_rdone};
    assign phy_rdy = trd[2];
    // RX buffer error (e.g. after electrical idle): reset the buffer, 8 clocks
    reg [2:0] rbe = 3'b000; reg [3:0] rbr = 4'd0;
    always @(posedge pclk) begin
        rbe <= {rbe[1:0], rx_buf_err};
        if (prst) rbr <= 4'd0;
        else if (rbe[2] && rbr == 4'd0) rbr <= 4'd15;
        else if (rbr != 4'd0) rbr <= rbr - 1'b1;
    end
    wire rx_buf_rst = rbr[3];

    // ---------------- TX ----------------
    reg [63:0] txq = 64'd0; reg [7:0] txkq = 8'd0; reg txeiq = 1'b1, detq = 1'b0;
    generate if (TX_NEG) begin : g_txn
        always @(negedge pclk) begin txq <= txdata; txkq <= txdatak; txeiq <= txelecidle | prst; detq <= txdetectrx; end
    end else begin : g_txp
        always @(*) begin txq = txdata; txkq = txdatak; txeiq = txelecidle | prst; detq = txdetectrx; end
    end endgenerate

    ccfpga_serdes #(
        .PLL_FCNTRL(PLL_FCNTRL), .PLL_MAIN_DIVSEL(PLL_MAIN_DIVSEL), .PLL_OUT_DIVSEL(PLL_OUT_DIVSEL),
        .PLL_EN_ADPLL_CTRL(1'b1), .PLL_CONFIG_SEL(1'b1), .PLL_SET_OP_LOCK(1'b0),
        .PLL_LOCK_WINDOW(1'b1), .PLL_FAST_LOCK(1'b1), .PLL_REF_SEL(1'b1), .PLL_REF_RTERM(1'b1),
        .PLL_CI(5'h1), .PLL_CP(10'h50), .PLL_BISC_MODE(3'h5), .PLL_BISC_CP_MIN(5'h4), .PLL_BISC_CP_START(5'h4),
        .PLL_BISC_TIMER_MAX(4'hC), .PLL_BISC_CAL_SIGN(1'b1), .PLL_BISC_CAL_AUTO(1'b1), .PLL_BISC_CP_MAX(5'h1E),
        .SERDES_ENABLE(1'b1),
        .RX_DATAPATH_SEL(2'd3), .TX_DATAPATH_SEL(2'd3),
        .ALIGN_MCOMMA_VALUE(10'b1010000011), .ALIGN_PCOMMA_VALUE(10'b0101111100),
        .ALIGN_COMMA_ENABLE(10'h3FF), .ALIGN_COMMA_WORD(2'd0),
        .RX_BUF_BYPASS(0), .RX_CLKCOR_USE(1'b0),
        .RX_EI_BIAS(4'h4), .RX_EI_BW_SEL(4'h4),
        .RX_WAIT_CDR_LOCK(1'b0), .RX_RESET_TIMER_PRESC(5'h4),
        .RX_RTERM_VCMSEL(3'h3), .RX_EN_EQA(1'b1), .RX_EQA_LOCK_CFG(4'hC),
        .RX_AFE_PEAK(5'h18), .RX_AFE_GAIN(4'h0), .RX_AFE_VCMSEL(3'h3),
        .RX_CDR_CKP(RX_CDR_CKP), .RX_CDR_CKI(8'h00), .RX_CDR_LOCK_CFG(8'hD5),
        .RX_CALIB_OVR(1'b1), .RX_CALIB_VAL(4'h0), .TX_CALIB_OVR(1'b1), .TX_CALIB_VAL(4'h0),
        .TX_SEL_PRE(5'h0), .TX_SEL_POST(5'h5), .TX_AMP(TX_AMP), .TX_BRANCH_EN_PRE(5'hC),
        .TX_BRANCH_EN_MAIN(6'h3F), .TX_BRANCH_EN_POST(5'hC), .TX_DC_ENABLE(7'h2B), .TX_DC_OFFSET(5'h8)
    ) u_serdes (
        .clk_ref_i(clk_ref), .clk_reg_i(1'b0), .clk_cfg_i(1'b0),
        .clk_core_tx_i(pclk), .clk_core_rx_i(rclk), .clk_core_rx_o(clk_rxo),
        .reset_n_i(rst_n), .reset_reg_n_i(rst_n), .reset_core_tx_n_i(rst_pll_n), .reset_core_rx_n_i(rst_pll_n),
        .testmode_i(1'b0), .scan_enable_i(1'b0), .scan_in_i(7'h0), .scan_out_o(),
        .loopback_i(3'b000), .pll_reset_i(!rst_n), .clk_core_pll_o(clk_pll), .reset_core_pll_n_o(rst_pll_n),
        .refclk_sel_o(), .refclk_rterm_o(),
        .RX_SERIO_P_B(ser_rxp), .RX_SERIO_N_B(ser_rxn), .TX_SERIO_P_B(ser_txp), .TX_SERIO_N_B(ser_txn),
        .regfile_we_i(1'b0), .regfile_en_i(1'b0), .regfile_addr_i(8'h0), .regfile_mask_i(16'h0),
        .regfile_di_i(16'h0), .regfile_do_o(), .regfile_rdy_o(),
        .cfg_en_i(1'b0), .reset_cfg_i(1'b0), .cfgfile_di_i(16'h0), .cfgfile_valid_i(1'b0), .cfgfile_addr_i(8'h0),
        .tx_reset_i(!rst_n), .tx_pcs_reset_i(1'b0), .tx_pma_reset_i(1'b0),
        .tx_elec_idle_i(txeiq), .tx_detect_rx_i(detq),
        .tx_prbs_sel_i(3'b000), .tx_prbs_force_err_i(1'b0), .tx_powerdown_n_i(1'b1),
        .tx_data_i(txq), .tx_char_is_k_i(txkq), .tx_polarity_i(1'b0),
        .tx_8b10b_en_i(1'b1), .tx_8b10b_bypass_i(8'h00), .tx_char_dispmode_i(8'h00), .tx_char_dispval_i(8'h00),
        .tx_buf_err_o(tx_buf_err), .tx_resetdone_o(tx_rdone),
        .rx_detect_done_o(det_done), .rx_present_o(present), .TERM_SERIO_O(),
        .rx_reset_i(!rst_n), .rx_pma_reset_i(1'b0),
`ifdef EERIE_EQA_POLL
        .rx_eqa_reset_i(eqa_rst),
`else
        .rx_eqa_reset_i(1'b0),
`endif
`ifdef EERIE_RX_REALIGN
        .rx_cdr_reset_i(rra_rst),
        .rx_pcs_reset_i(rra_rst), .rx_buf_reset_i(rx_buf_rst | rra_rst),
`else
        .rx_cdr_reset_i(1'b0),
        .rx_pcs_reset_i(1'b0), .rx_buf_reset_i(rx_buf_rst),
`endif
        .rx_prbs_sel_i(3'b000), .rx_prbs_cnt_reset_i(1'b0), .rx_powerdown_n_i(1'b1),
        .rx_en_ei_detector_i(1'b1), .rx_comma_detect_en_i(1'b1), .rx_slide_i(1'b0),
        .rx_polarity_i(rxpolarity ^ (RX_POL_INV != 0)), .rx_8b10b_en_i(1'b1), .rx_8b10b_bypass_i(8'h00),
`ifdef EERIE_ALIGN_L0
        .rx_mcomma_align_i(c_align), .rx_pcomma_align_i(c_align),
`else
        .rx_mcomma_align_i(1'b1), .rx_pcomma_align_i(1'b1),
`endif
        .rx_prbs_err_o(), .rx_data_o(s_rxd), .rx_char_is_k_o(s_rxk), .rx_char_is_comma_o(),
        .rx_not_in_table_o(s_nit), .rx_disp_err_o(s_disp), .rx_buf_err_o(rx_buf_err),
        .rx_byte_is_aligned_o(aligned), .rx_byte_realign_o(realign), .rx_resetdone_o(rx_rdone), .rx_ei_en_o(ei_raw)
    );

    // ---------------- RX (rclk) ----------------
    reg [1:0] eis = 2'b11;
    always @(posedge rclk) eis <= {eis[0], ei_raw};
    reg [63:0] rd; reg [7:0] rk; reg rv = 1'b0, re = 1'b0;
    always @(posedge rclk) begin
        rd <= s_rxd; rk <= s_rxk; re <= |(s_nit | s_disp);
        rv <= aligned && !eis[1];
    end
    wire [63:0] pd; wire [7:0] pk; wire pv; wire [2:0] pst;
    generate if (SRNS) begin : g_eb
        wire [4:0] fill;
        reg [2:0] wr = 3'b000;
        always @(posedge rclk or negedge rst_n) if (!rst_n) wr <= 3'b000; else wr <= {wr[1:0], 1'b1};
`ifdef EERIE_SKP_EBB
        eerie_skp_ebb eb (.wclk(rclk), .wrst(!wr[2]), .w_v(rv), .w_d(rd), .w_k(rk), .w_err(re),
            .rclk(pclk), .rrst(prst), .r_v(pv), .r_d(pd), .r_k(pk), .r_status(pst), .r_fill(fill));
`else
        eerie_skp_eb eb (.wclk(rclk), .wrst(!wr[2]), .w_v(rv), .w_d(rd), .w_k(rk), .w_err(re),
            .rclk(pclk), .rrst(prst), .r_v(pv), .r_d(pd), .r_k(pk), .r_status(pst), .r_fill(fill));
`endif
    end else begin : g_cc
        assign pd = rd; assign pk = rk; assign pv = rv; assign pst = re ? 3'b100 : 3'b000;
    end endgenerate
    reg [2:0] eip = 3'b111;
    always @(posedge pclk) eip <= {eip[1:0], ei_raw};
`ifdef EERIE_RX_REALIGN
    // TASK-6192: HW ILA3B — the SerDes loses byte alignment with signal present and gets it back only when the link trains
    // again (EP deaf in L0 / Recovery for up to 2 ms). Watchdog: not aligned and not electrically idle for 32 pclk (1 us)
    // -> CDR + PCS + RX buffer reset for 16 pclk, then 128 pclk (4 us) to settle before the next one.
    (* async_reg = "true" *) reg [1:0] als = 2'b00;
    reg [5:0] rra_n = 6'd0; reg [7:0] rra_h = 8'd0;
    always @(posedge pclk) begin
        als <= {als[0], aligned};
        if (prst) begin rra_n <= 6'd0; rra_h <= 8'd0; rra_rst <= 1'b0; end
        else if (rra_h != 8'd0) begin
            rra_h <= rra_h - 1'b1; rra_rst <= (rra_h > 8'd128); rra_n <= 6'd0;
        end else if (!als[1] && !eip[2]) begin
            if (rra_n[5]) rra_h <= 8'd144; else rra_n <= rra_n + 1'b1;
        end else rra_n <= 6'd0;
    end
`endif

    // ---------------- PhyStatus / RxStatus (pclk) ----------------
    reg [1:0]  pdq = 2'b00; reg [2:0] pdc = 3'd0;
    reg        detp = 1'b0, detw = 1'b0; reg [2:0] dds = 3'b000; reg [10:0] dcnt = 11'd0;
    reg        evp = 1'b0; reg [2:0] evs = 3'b000;
    always @(posedge pclk) begin
        dds <= {dds[1:0], det_done};
        pdq <= powerdown; detp <= txdetectrx;
        evp <= 1'b0;
        if (prst || !phy_rdy) begin pdc <= 3'd0; detw <= 1'b0; dcnt <= 11'd0; end
        else begin
            if (powerdown != pdq) pdc <= 3'd4;
            else if (pdc != 3'd0) begin pdc <= pdc - 1'b1; if (pdc == 3'd1) begin evp <= 1'b1; evs <= 3'b000; end end
            if (txdetectrx && !detp) begin detw <= 1'b1; dcnt <= 11'd0; end
            else if (detw) begin
                dcnt <= dcnt + 1'b1;
                if ((dds[1] && !dds[2] && dcnt > 11'd2) || (RXDET_TMO != 0 && dcnt == RXDET_TMO[10:0])) begin
                    detw <= 1'b0; evp <= 1'b1;
                    evs <= (present || dcnt == RXDET_TMO[10:0]) ? 3'b011 : 3'b000;
                end
            end
        end
    end
    always @(posedge pclk) begin
        rxdata <= pd; rxdatak <= pk;
        rxvalid <= pv && !prst;
        rxelecidle <= eip[2] | prst;
        phystatus <= prst || !phy_rdy || evp;
        rxstatus <= evp ? evs : (pv ? pst : 3'b000);
    end
    assign dbg = {rx_buf_err, tx_buf_err, rx_rdone, tx_rdone, aligned, ei_raw, det_done, present};
`ifdef EERIE_DBGCNT
    // TASK-6185: errors at the EB input (rclk: SerDes decoder flags as captured) and at its output (pclk), all link states,
    // so "SerDes or EB" is one subtraction. rclk counters cross into pclk as Gray code (each moves by at most 1 per rclk;
    // 2-FF synchroniser per bit, Cummings SNUG 2008 sec. 5.6). 16 bit wrap (err), 8 bit wrap (realign, RX_BUF_ERR, SKP).
    function [15:0] b2g(input [15:0] b); b2g = b ^ (b >> 1); endfunction
    function [15:0] g2b(input [15:0] g); integer j; begin g2b[15] = g[15];
        for (j = 14; j >= 0; j = j - 1) g2b[j] = g2b[j+1] ^ g[j]; end endfunction
    reg [15:0] c_pre = 16'd0; reg [7:0] c_ra = 8'd0, c_rbe = 8'd0; reg rbq = 1'b0, raq = 1'b0;
    reg [15:0] g_pre = 16'd0, g_ra = 16'd0, g_rbe = 16'd0;
    always @(posedge rclk) begin
        rbq <= rx_buf_err; raq <= realign;
        if (rv && re) c_pre <= c_pre + 1'b1;
        if (realign && !raq) c_ra <= c_ra + 1'b1;
        if (rx_buf_err && !rbq) c_rbe <= c_rbe + 1'b1;
        g_pre <= b2g(c_pre); g_ra <= b2g({8'd0, c_ra}); g_rbe <= b2g({8'd0, c_rbe});
    end
    reg [15:0] s1_pre = 16'd0, s2_pre = 16'd0, s1_ra = 16'd0, s2_ra = 16'd0, s1_rbe = 16'd0, s2_rbe = 16'd0;
    reg [15:0] c_post = 16'd0; reg [7:0] c_add = 8'd0, c_del = 8'd0;
    always @(posedge pclk) begin
        s1_pre <= g_pre; s2_pre <= s1_pre; s1_ra <= g_ra; s2_ra <= s1_ra; s1_rbe <= g_rbe; s2_rbe <= s1_rbe;
        if (pv && pst == 3'b100) c_post <= c_post + 1'b1;
        if (pv && pst == 3'b001) c_add <= c_add + 1'b1;
        if (pv && pst == 3'b010) c_del <= c_del + 1'b1;
    end
    wire [15:0] b_ra = g2b(s2_ra), b_rbe = g2b(s2_rbe);
    assign dbgc = {g2b(s2_pre), b_ra[7:0], b_rbe[7:0], c_post, c_add, c_del};
`endif
`ifdef EERIE_ILA
    // TASK-6190 (uputa #904): host (recovered rclk) vs own oscillator (pclk) frequency. An 8-bit rclk counter crosses as
    // Gray code (2-FF per bit); pclk adds its step each clock and closes a window every 2^24 pclk.
    function [7:0] g8b(input [7:0] g); integer k; begin g8b[7] = g[7];
        for (k = 6; k >= 0; k = k - 1) g8b[k] = g8b[k+1] ^ g[k]; end endfunction
    reg [7:0]  pr_c = 8'd0, pr_g = 8'd0, pr_s1 = 8'd0, pr_s2 = 8'd0, pr_b = 8'd0;
    reg [31:0] pr_acc = 32'd0;
    reg [23:0] pr_w = 24'd0;
    always @(posedge rclk) begin pr_c <= pr_c + 1'b1; pr_g <= pr_c ^ (pr_c >> 1); end
    always @(posedge pclk) begin
        pr_s1 <= pr_g; pr_s2 <= pr_s1; pr_b <= g8b(pr_s2);
        pr_w <= pr_w + 1'b1;
        if (&pr_w) begin ppmw <= pr_acc + {24'd0, g8b(pr_s2) - pr_b} - 32'h0100_0000; pr_acc <= 32'd0; end
        else pr_acc <= pr_acc + {24'd0, g8b(pr_s2) - pr_b};
    end
`endif
endmodule
