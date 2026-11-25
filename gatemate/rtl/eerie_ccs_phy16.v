// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6173: PIPE x1 Gen1/Gen2, 128 bits (16 symbols per PCLK), for pci_eerie (EERIE_W16) on the GateMate SerDes.
//
// One ccfpga_serdes instance (64-bit datapath), the same in simulation and on the chip: the file list picks
// ccfpga_serdes.BFM.sv (openSERDES_BFM) or ccfpga_serdes.SYNTH.sv (CC_SERDES). On top of eerie_ccs_phy:
//   * PCLK = SerDes PLL clock / 2: 2.5 Gb/s -> PLL 31.25 MHz, PCLK 15.625 MHz; 5.0 Gb/s -> 62.5 / 31.25 MHz
//     (fixed PIPE width, the PCLK follows the rate);
//   * a 2:1 gearbox in the PLL clock domain: TX 128 -> 64 bits (symbols 0..7 first), RX 64 -> 128 bits;
//     RX_PAIR picks which of two received words is the first half (with the SerDes word alignment, which
//     takes the comma in any of its 8 lanes, the COM can land in any of the 16 PIPE symbols);
//   * PIPE Rate: a change runs through the SerDes register file (clk_cfg, a free-running clock: the PLL
//     clock stops while it relocks): PLL_CFG0[0] = 0 (PLL off), PLL_CFG1[13:12] = OUT_DIVSEL (M3 = 2 for
//     2.5 Gb/s, M3 = 1 for 5.0 Gb/s, the PLL itself stays at 5 GHz), PLL_CFG0[0] = 1, then the PLL lock
//     and the TX reset sequence; PhyStatus pulses once the PHY is ready at the new rate (PIPE 4.2.1.3);
//   * PhyStatus / RxStatus / receiver detection / electrical idle as eerie_ccs_phy.
// SRNS = 0 (common REFCLK): RX_CLK_I = the PLL clock, the RX gearbox runs on it.
// SRNS = 1 (separate reference clocks): RX_CLK_I = RX_CLK_O; the RX gearbox runs on the recovered clock and
// the 128-bit words cross into PCLK through eerie_skp_eb16 (inserts / removes SKP of SKP ordered sets).
`timescale 1ns / 1ps
module eerie_ccs_phy16 #(
    parameter       SRNS       = 0,
    parameter       RX_POL_INV = 0,      // board P/N swap on the RX pair (the LTSSM also inverts by itself)
    parameter       RX_PAIR    = 0,      // 0/1: which received 64-bit word starts a 128-bit PIPE word
    parameter       RXDET_TMO  = 1023,   // PCLKs to wait for RX_DETECT_DONE; then report "present" (0: wait forever)
    // the PLL and the analog part: 5 GHz from 100 MHz, M3 = 2 (2.5 Gb/s) at reset; recipe GS<->M2 "zadano CPM4"
    parameter [5:0] PLL_FCNTRL      = 6'd58,
    parameter [5:0] PLL_MAIN_DIVSEL = 6'd27,
    parameter [4:0] TX_AMP          = 5'd12,
    parameter [7:0] RX_CDR_CKP      = 8'h3E
) (
    input          rst_n,                // async: PERST# and power-on, active low
    input          clk_ref,              // simulation only: the SerDes reference (CC_SERDES has its own pads)
    input          clk_cfg,              // free-running register file clock (e.g. the board's 25 MHz)
    input          ser_rxp, ser_rxn,     // simulation only: the serial line
    output         ser_txp, ser_txn,
    output         pclk,
    output         phy_rdy,              // first time the SerDes TX came out of reset (sticky), pclk
    // PIPE, MAC side (pclk)
    input  [127:0] txdata,               // symbol 0 in [7:0]
    input  [15:0]  txdatak,
    input          txelecidle,
    input          txcompliance,
    input  [1:0]   powerdown,
    input          txdetectrx,
    input          rxpolarity,
    input          rate,                 // 0: 2.5 GT/s, 1: 5.0 GT/s
    output     [127:0] rxdata,           // straight from the gearbox / EB registers (no extra PCLK stage)
    output     [15:0]  rxdatak,
    output             rxvalid,
    output reg         rxelecidle,
    output     [2:0]   rxstatus,
    output reg         phystatus,
    // debug
    output     [7:0]   dbg               // {rx_buf_err, tx_buf_err, rx_resetdone, tx_resetdone, aligned, ei, det_done, present}
);
    wire clk_pll, clk_rxo, rst_pll_n;
    wire tx_rdone, rx_rdone, det_done, present, tx_buf_err, rx_buf_err, aligned, ei_raw;
    wire [63:0] s_rxd; wire [7:0] s_rxk, s_nit, s_disp;
    wire [15:0] rf_do; wire rf_rdy;
    wire        rx_wd_rst;                // TASK-6241 EERIE_PHY_RXWD
    reg         rf_en = 1'b0; reg [7:0] rf_addr = 8'h0; reg [15:0] rf_mask = 16'h0, rf_di = 16'h0;

    // ---------------- clocks ----------------
    // PCLK = PLL clock / 2; ph = 1 in the first PLL clock of a PCLK period
    reg ph = 1'b0;
    always @(posedge clk_pll) ph <= ~ph;
    eerie_bufg u_bp (.I(ph), .O(pclk));
    wire rclk;
    generate if (SRNS) begin : g_rxo
        eerie_bufg u_br (.I(clk_rxo), .O(rclk));
    end else begin : g_rxp
        assign rclk = clk_pll;
    end endgenerate

    // ---------------- resets (pclk) ----------------
    reg [2:0] rs = 3'b000;
    always @(posedge pclk or negedge rst_n) if (!rst_n) rs <= 3'b000; else rs <= {rs[1:0], 1'b1};
    wire prst = !rs[2];
    reg [2:0] trd = 3'b000; reg rdy1 = 1'b0;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin trd <= 3'b000; rdy1 <= 1'b0; end
        else begin trd <= {trd[1:0], tx_rdone}; if (trd[2]) rdy1 <= 1'b1; end
    assign phy_rdy = rdy1;
    // RX buffer error (e.g. after electrical idle): reset the buffer, 8 clocks
    reg [2:0] rbe = 3'b000; reg [3:0] rbr = 4'd0;
    always @(posedge pclk) begin
        rbe <= {rbe[1:0], rx_buf_err};
        if (prst) rbr <= 4'd0;
        else if (rbe[2] && rbr == 4'd0) rbr <= 4'd15;
        else if (rbr != 4'd0) rbr <= rbr - 1'b1;
    end
    wire rx_buf_rst = rbr[3];

    // ---------------- rate change: pclk side ----------------
    // rq_t toggles to ask for cur_rate -> rate; ak_t comes back from the clk_cfg sequencer
    reg        cur_rate = 1'b0, rbusy = 1'b0, rq_t = 1'b0, rq_rate = 1'b0, rdone = 1'b0;
    reg [2:0]  ak_s = 3'b000;
    wire       ak_t;
    always @(posedge pclk) begin
        ak_s <= {ak_s[1:0], ak_t};
        rdone <= 1'b0;
        if (prst) begin cur_rate <= 1'b0; rbusy <= 1'b0; rq_t <= ak_s[2]; end
        else if (!rbusy && rate != cur_rate && rdy1) begin rbusy <= 1'b1; rq_rate <= rate; rq_t <= ~rq_t; end
        else if (rbusy && ak_s[2] == rq_t && trd[2]) begin rbusy <= 1'b0; cur_rate <= rq_rate; rdone <= 1'b1; end
    end
    // ---------------- rate change: clk_cfg sequencer ----------------
    reg [2:0]  q_rq = 3'b000, q_lk = 3'b000; reg q_rate = 1'b0, akr = 1'b0;
    reg [3:0]  cs = 4'd0; reg [9:0] cw = 10'd0;
    assign ak_t = akr;
    always @(posedge clk_cfg or negedge rst_n) begin
        if (!rst_n) begin
            q_rq <= 3'b000; q_lk <= 3'b000; cs <= 4'd0; akr <= 1'b0; rf_en <= 1'b0; cw <= 10'd0;
        end else begin
            q_rq <= {q_rq[1:0], rq_t}; q_lk <= {q_lk[1:0], rst_pll_n && tx_rdone && rx_rdone};
            case (cs)
            4'd0: if (q_rq[2] != akr) begin q_rate <= rq_rate; cs <= 4'd1; end
            // PLL off: PLL_CFG0[0] = 0
            4'd1: begin rf_addr <= 8'h50; rf_mask <= 16'h0001; rf_di <= 16'h0000; rf_en <= 1'b1; cs <= 4'd2; end
            4'd2: begin rf_en <= 1'b0; if (rf_rdy) cs <= 4'd3; end
            // OUT_DIVSEL: 01 (M3 = 2, 2.5 Gb/s) or 00 (M3 = 1, 5.0 Gb/s)
            4'd3: begin rf_addr <= 8'h51; rf_mask <= 16'h3000; rf_di <= q_rate ? 16'h0000 : 16'h1000; rf_en <= 1'b1; cs <= 4'd4; end
            4'd4: begin rf_en <= 1'b0; if (rf_rdy) cs <= 4'd5; end
            // PLL on
            4'd5: begin rf_addr <= 8'h50; rf_mask <= 16'h0001; rf_di <= 16'h0001; rf_en <= 1'b1; cs <= 4'd6; end
            4'd6: begin rf_en <= 1'b0; if (rf_rdy) begin cs <= 4'd7; cw <= 10'd0; end end
            // the lock (PLL + TX / RX reset sequences) back and steady for 256 clocks
            4'd7: begin cw <= cw + 1'b1; if (cw == 10'd63) cs <= 4'd8; end
            4'd8: if (q_lk[2]) begin cw <= 10'd0; cs <= 4'd9; end
            4'd9: begin cw <= cw + 1'b1; if (!q_lk[2]) cs <= 4'd8; else if (cw == 10'd255) begin akr <= ~akr; cs <= 4'd0; end end
            default: cs <= 4'd0;
            endcase
        end
    end

    // ---------------- TX gearbox (PLL clock): symbols 0..7, then 8..15 ----------------
    reg [63:0] txh = 64'd0; reg [7:0] txkh = 8'd0;
    reg [63:0] txg = 64'd0; reg [7:0] txkg = 8'd0; reg txeig = 1'b1, detg = 1'b0;
    always @(posedge clk_pll) begin
        if (ph) begin   // the middle of a PCLK period: the 128-bit word is stable
            txg <= txdata[63:0]; txkg <= txdatak[7:0]; txh <= txdata[127:64]; txkh <= txdatak[15:8];
            txeig <= txelecidle | prst; detg <= txdetectrx;
        end else begin
            txg <= txh; txkg <= txkh;
        end
    end
    // TX data to the SerDes from a falling-edge register (SerDes ports are not timed)
    reg [63:0] txq = 64'd0; reg [7:0] txkq = 8'd0; reg txeiq = 1'b1, detq = 1'b0;
    always @(negedge clk_pll) begin txq <= txg; txkq <= txkg; txeiq <= txeig; detq <= detg; end

    ccfpga_serdes #(
        .PLL_FCNTRL(PLL_FCNTRL), .PLL_MAIN_DIVSEL(PLL_MAIN_DIVSEL), .PLL_OUT_DIVSEL(2'd1),
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
        .RX_RTERM_VCMSEL(3'h3),
`ifdef EERIE_PHY_NOEQA
        .RX_EN_EQA(1'b0),   // TASK-6241: fixed RX equalizer (AFE peak / gain as set), no adaptation at 5 GT/s
`else
        .RX_EN_EQA(1'b1),
`endif
        .RX_EQA_LOCK_CFG(4'hC),
        .RX_AFE_PEAK(5'h18), .RX_AFE_GAIN(4'h0), .RX_AFE_VCMSEL(3'h3),
        .RX_CDR_CKP(RX_CDR_CKP), .RX_CDR_CKI(8'h00), .RX_CDR_LOCK_CFG(8'hD5),
        .RX_CALIB_OVR(1'b1), .RX_CALIB_VAL(4'h0), .TX_CALIB_OVR(1'b1), .TX_CALIB_VAL(4'h0),
        .TX_SEL_PRE(5'h0), .TX_SEL_POST(5'h5), .TX_AMP(TX_AMP), .TX_BRANCH_EN_PRE(5'hC),
        .TX_BRANCH_EN_MAIN(6'h3F), .TX_BRANCH_EN_POST(5'hC), .TX_DC_ENABLE(7'h2B), .TX_DC_OFFSET(5'h8)
    ) u_serdes (
        .clk_ref_i(clk_ref), .clk_reg_i(clk_cfg), .clk_cfg_i(1'b0),
        .clk_core_tx_i(clk_pll), .clk_core_rx_i(rclk), .clk_core_rx_o(clk_rxo),
        .reset_n_i(rst_n), .reset_reg_n_i(rst_n), .reset_core_tx_n_i(rst_pll_n), .reset_core_rx_n_i(rst_pll_n),
        .testmode_i(1'b0), .scan_enable_i(1'b0), .scan_in_i(7'h0), .scan_out_o(),
        .loopback_i(3'b000), .pll_reset_i(!rst_n), .clk_core_pll_o(clk_pll), .reset_core_pll_n_o(rst_pll_n),
        .refclk_sel_o(), .refclk_rterm_o(),
        .RX_SERIO_P_B(ser_rxp), .RX_SERIO_N_B(ser_rxn), .TX_SERIO_P_B(ser_txp), .TX_SERIO_N_B(ser_txn),
        .regfile_we_i(1'b1), .regfile_en_i(rf_en), .regfile_addr_i(rf_addr), .regfile_mask_i(rf_mask),
        .regfile_di_i(rf_di), .regfile_do_o(rf_do), .regfile_rdy_o(rf_rdy),
        .cfg_en_i(1'b0), .reset_cfg_i(1'b0), .cfgfile_di_i(16'h0), .cfgfile_valid_i(1'b0), .cfgfile_addr_i(8'h0),
        .tx_reset_i(!rst_n), .tx_pcs_reset_i(1'b0), .tx_pma_reset_i(1'b0),
        .tx_elec_idle_i(txeiq), .tx_detect_rx_i(detq),
        .tx_prbs_sel_i(3'b000), .tx_prbs_force_err_i(1'b0), .tx_powerdown_n_i(1'b1),
        .tx_data_i(txq), .tx_char_is_k_i(txkq), .tx_polarity_i(1'b0),
        .tx_8b10b_en_i(1'b1), .tx_8b10b_bypass_i(8'h00), .tx_char_dispmode_i(8'h00), .tx_char_dispval_i(8'h00),
        .tx_buf_err_o(tx_buf_err), .tx_resetdone_o(tx_rdone),
        .rx_detect_done_o(det_done), .rx_present_o(present), .TERM_SERIO_O(),
        .rx_reset_i(!rst_n || rx_wd_rst), .rx_pma_reset_i(1'b0), .rx_eqa_reset_i(1'b0), .rx_cdr_reset_i(1'b0),
        .rx_pcs_reset_i(1'b0), .rx_buf_reset_i(rx_buf_rst),
        .rx_prbs_sel_i(3'b000), .rx_prbs_cnt_reset_i(1'b0), .rx_powerdown_n_i(1'b1),
        .rx_en_ei_detector_i(1'b1), .rx_comma_detect_en_i(1'b1), .rx_slide_i(1'b0),
        .rx_polarity_i(rxpolarity ^ (RX_POL_INV != 0)), .rx_8b10b_en_i(1'b1), .rx_8b10b_bypass_i(8'h00),
        .rx_mcomma_align_i(1'b1), .rx_pcomma_align_i(1'b1),
        .rx_prbs_err_o(), .rx_data_o(s_rxd), .rx_char_is_k_o(s_rxk), .rx_char_is_comma_o(),
        .rx_not_in_table_o(s_nit), .rx_disp_err_o(s_disp), .rx_buf_err_o(rx_buf_err),
        .rx_byte_is_aligned_o(aligned), .rx_byte_realign_o(), .rx_resetdone_o(rx_rdone), .rx_ei_en_o(ei_raw)
    );

    // ---------------- RX gearbox (rclk): two SerDes words -> one 128-bit word ----------------
    reg [1:0] eis = 2'b11;
    always @(posedge rclk) eis <= {eis[0], ei_raw};
    reg [63:0] rd0, rd1, rd2; reg [7:0] rk0, rk1, rk2; reg rv0 = 1'b0, rv1 = 1'b0, rv2 = 1'b0, re0, re1, re2;
    always @(posedge rclk) begin
        rd0 <= s_rxd; rk0 <= s_rxk; re0 <= |(s_nit | s_disp); rv0 <= aligned && !eis[1];
        rd1 <= rd0; rk1 <= rk0; re1 <= re0; rv1 <= rv0;
        rd2 <= rd1; rk2 <= rk1; re2 <= re1; rv2 <= rv1;
    end
    reg        rph = 1'b0;                      // SRNS: the recovered clock / 2 (EB write clock)
    always @(posedge rclk) rph <= ~rph;
    wire       gph = SRNS ? rph : ph;           // pairing phase
    reg [127:0] g_d; reg [15:0] g_k; reg g_v = 1'b0, g_e = 1'b0;
    always @(posedge rclk) if (gph) begin
        // the first PLL clock of a PCLK period: g_* is stable at the next PCLK edge
        if (RX_PAIR == 0) begin g_d <= {rd0, rd1}; g_k <= {rk0, rk1}; g_v <= rv0 && rv1; g_e <= re0 | re1; end
        else              begin g_d <= {rd1, rd2}; g_k <= {rk1, rk2}; g_v <= rv1 && rv2; g_e <= re1 | re2; end
    end
    wire [127:0] pd; wire [15:0] pk; wire pv; wire [2:0] pst;
    generate if (SRNS) begin : g_eb
        wire wclk16;
        eerie_bufg u_bw (.I(rph), .O(wclk16));
        wire [4:0] fill;
        reg [2:0] wr = 3'b000;
        // both sides restart (at the middle fill) after a rate change: the PLL clock stops while it relocks
        wire ebr_n = rst_n && !rbusy;
        always @(posedge wclk16 or negedge ebr_n) if (!ebr_n) wr <= 3'b000; else wr <= {wr[1:0], 1'b1};
        eerie_skp_eb16 eb (.wclk(wclk16), .wrst(!wr[2]), .w_v(g_v), .w_d(g_d), .w_k(g_k), .w_err(g_e),
            .rclk(pclk), .rrst(prst || rbusy), .r_v(pv), .r_d(pd), .r_k(pk), .r_status(pst), .r_fill(fill));
    end else begin : g_cc
        assign pd = g_d; assign pk = g_k; assign pv = g_v; assign pst = g_e ? 3'b100 : 3'b000;
    end endgenerate
    reg [2:0] eip = 3'b111;
    always @(posedge pclk) eip <= {eip[1:0], ei_raw};

`ifdef EERIE_PHY_RXWD
    // TASK-6241 (M2 v002 at 5 GT/s): the RX can go deaf with RxValid high (aligned, not idle): the host sees no Ack
    // (replay Timeout + Rollover, no receive errors of its own) and the EP never locks again in Recovery. Watchdog:
    // RxValid for 4096 PCLKs without a word that has a COM and no decode error (L0: a SKP OS every ~75 PCLKs at
    // 5.0 GT/s, training: every PCLK) -> SerDes RX reset for 16 PCLKs, then the next 4096.
    reg [12:0] wd_cnt = 13'd0; reg [4:0] wd_rst = 5'd0; reg wd_com = 1'b0;
    always @(posedge pclk) begin
        wd_com <= pv && !pst[2] && |(pk & {pd[127:120] == 8'hBC, pd[119:112] == 8'hBC, pd[111:104] == 8'hBC, pd[103:96] == 8'hBC,
                                           pd[95:88] == 8'hBC, pd[87:80] == 8'hBC, pd[79:72] == 8'hBC, pd[71:64] == 8'hBC,
                                           pd[63:56] == 8'hBC, pd[55:48] == 8'hBC, pd[47:40] == 8'hBC, pd[39:32] == 8'hBC,
                                           pd[31:24] == 8'hBC, pd[23:16] == 8'hBC, pd[15:8] == 8'hBC, pd[7:0] == 8'hBC});
        if (prst || rbusy || !rxvalid || wd_com || wd_rst != 5'd0) wd_cnt <= 13'd0;
        else wd_cnt <= wd_cnt + 1'b1;
        if (prst) wd_rst <= 5'd0;
        else if (wd_cnt[12]) wd_rst <= 5'd16;
        else if (wd_rst != 5'd0) wd_rst <= wd_rst - 1'b1;
    end
    assign rx_wd_rst = wd_rst != 5'd0;
`else
    assign rx_wd_rst = 1'b0;
`endif
    // ---------------- PhyStatus / RxStatus (pclk) ----------------
    reg [1:0]  pdq = 2'b00; reg [2:0] pdc = 3'd0;
    reg        detp = 1'b0, detw = 1'b0; reg [2:0] dds = 3'b000; reg [10:0] dcnt = 11'd0;
    reg        evp = 1'b0; reg [2:0] evs = 3'b000;
    always @(posedge pclk) begin
        dds <= {dds[1:0], det_done};
        pdq <= powerdown; detp <= txdetectrx;
        evp <= 1'b0;
        if (prst || !rdy1) begin pdc <= 3'd0; detw <= 1'b0; dcnt <= 11'd0; end
        else begin
            if (rdone) begin evp <= 1'b1; evs <= 3'b000; end
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
    // RX data without an extra PCLK register (TASK-6173: the Ack path at 2.5 GT/s is ~40 PCLKs of 64 ns, a
    // register less keeps it under openPCIE_BFM's DL.ACK-LAT limit); pd / pk / pv / pst are registers
    // (the gearbox, stable at the PCLK edge, or the EB16 read side), evp / evs / prst / rbusy too
    assign rxdata = pd; assign rxdatak = pk;
    assign rxvalid = pv && !prst && !rbusy;
    reg evq = 1'b0; reg [2:0] evsq = 3'b000;     // the PhyStatus event, aligned with phystatus
    assign rxstatus = evq ? evsq : (pv ? pst : 3'b000);
    always @(posedge pclk) begin
        rxelecidle <= eip[2] | prst;
        phystatus <= prst || !rdy1 || evp;
        evq <= evp; evsq <= evs;
    end
    assign dbg = {rx_buf_err, tx_buf_err, rx_rdone, tx_rdone, aligned, ei_raw, det_done, present};
endmodule
