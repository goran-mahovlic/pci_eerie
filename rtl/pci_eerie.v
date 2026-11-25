// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: open-source soft PCI Express endpoint for 7-series FPGAs.
//
// IO-level drop-in replacement for the PCIE_2_1 integrated block: same port
// names and parameters (all accepted, the relevant subset is honoured), PIPE
// interface towards the GT wrapper, TRN interface towards the user, and the
// MIM ports used for the external TX (replay/queue) and RX buffer BRAMs.
//
// Scope: endpoint or root port (PCIE_CAP_DEVICE_PORT_TYPE 0 / 4), x1, 2.5 / 5.0 GT/s,
// 64-bit TRN, USERCLK2 == USERCLK.  See README.md for the list of supported features.
`timescale 1ns / 1ps
module pci_eerie #(
`include "pci_eerie_params.vh"
) (
`include "pci_eerie_ports.vh"
);
    // ------------------------------------------------------------------
    // derived configuration
    // ------------------------------------------------------------------
    localparam MAX_RATE  = (LINK_CAP_MAX_LINK_SPEED >= 4'h2) ? 2 : 1;
    localparam DSP       = (PCIE_CAP_DEVICE_PORT_TYPE == 4'h4);   // root port (downstream port)
    // lanes: LINK_CAP_MAX_LINK_WIDTH (1, 2, 4, 8); links up to x4 are used (an x8 core trains to x4)
    localparam NL        = (LINK_CAP_MAX_LINK_WIDTH >= 6'd8) ? 8 : (LINK_CAP_MAX_LINK_WIDTH >= 6'd4) ? 4 :
                           (LINK_CAP_MAX_LINK_WIDTH >= 6'd2) ? 2 : 1;
    localparam MAXW      = (NL >= 4) ? 4 : NL;
    localparam FAST      = (PL_FAST_TRAIN == "TRUE");
    localparam CPL_INF   = (VC0_CPL_INFINITE == "TRUE");
    localparam MPS_BYTES = 128 << DEV_CAP_MAX_PAYLOAD_SUPPORTED;
    localparam MAX_TLP_BEATS = 2 + MPS_BYTES / 8;
    localparam RXB_AW    = (VC0_RX_RAM_LIMIT >= 13'h1000) ? 13 : (VC0_RX_RAM_LIMIT >= 13'h800) ? 12 :
                           (VC0_RX_RAM_LIMIT >= 13'h400) ? 11 : (VC0_RX_RAM_LIMIT >= 13'h200) ? 10 :
                           (VC0_RX_RAM_LIMIT >= 13'h100) ? 9 : 8;
    // round VC0_RX_RAM_LIMIT+1 up to a power of two (the BRAMs are sized the same way)
    localparam TXB_AW    = RXB_AW;
    localparam TXB_RLAT  = TL_TX_RAM_RDATA_LATENCY;
    localparam RXB_RLAT  = TL_RX_RAM_RDATA_LATENCY;
    localparam MAX_UNACK = (VC0_TX_LASTPACKET + 1 > 31) ? 31 : VC0_TX_LASTPACKET + 1;
    // replay timer in user clocks, for 4 symbol times per user clock (62.5 MHz @ 2.5 GT/s,
    // 125 MHz @ 5 GT/s); with a 62.5 MHz user clock at 5 GT/s it is twice as long
    localparam [15:0] REPLAY_T = (LL_REPLAY_TIMEOUT_EN == "TRUE") ? LL_REPLAY_TIMEOUT[14:2] + 16'd64 :
                                 (MPS_BYTES <= 128) ? 16'd400 : (MPS_BYTES <= 256) ? 16'd500 :
                                 (MPS_BYTES <= 512) ? 16'd700 : 16'd1200;

    wire pclk = PIPECLK;
    wire uclk = USERCLK;

    // ------------------------------------------------------------------
    // configuration-style inputs: in simulation an undriven (Z/X) pin reads as
    // it would in hardware (data/IDs 0, active-low requests inactive), so a
    // floating wrapper port cannot poison TLPs with X.  No logic in synthesis.
    // ------------------------------------------------------------------
`ifndef SYNTHESIS
    // synthesis translate_off
`define EERIE_SIM_XFILTER
    // synthesis translate_on
`endif
`ifdef EERIE_SIM_XFILTER
    function [63:0] xz0; input [63:0] v; integer i;
        begin for (i = 0; i < 64; i = i + 1) xz0[i] = (v[i] === 1'b1); end
    endfunction
    function xz1; input v; xz1 = (v !== 1'b0); endfunction
`else
    function [63:0] xz0; input [63:0] v; xz0 = v; endfunction
    function xz1; input v; xz1 = v; endfunction
`endif
    wire [4:0]  s_msgnum    = xz0(CFGPCIECAPINTERRUPTMSGNUM);
    wire [63:0] s_dsn       = xz0(CFGDSN);
    wire [7:0]  s_int_di    = xz0(CFGINTERRUPTDI);
    wire [15:0] s_vend_id   = xz0(CFGVENDID), s_dev_id = xz0(CFGDEVID);
    wire [15:0] s_ssvid     = xz0(CFGSUBSYSVENDID), s_ssid = xz0(CFGSUBSYSID);
    wire [7:0]  s_rev_id    = xz0(CFGREVID);
    wire        s_int_n     = xz1(CFGINTERRUPTN), s_int_assert_n = xz1(CFGINTERRUPTASSERTN);
    wire        s_trnpend_n = xz1(CFGTRNPENDINGN), s_pmwake_n = xz1(CFGPMWAKEN);
    wire        s_turnoff_n = xz1(CFGPMTURNOFFOKN);
    wire        s_err_ur_n  = xz1(CFGERRURN), s_err_cor_n = xz1(CFGERRCORN), s_err_abort_n = xz1(CFGERRCPLABORTN);
    wire        s_mg_rd_n   = xz1(CFGMGMTRDENN), s_mg_wr_n = xz1(CFGMGMTWRENN);
    wire        s_mg_rw1c_n = xz1(CFGMGMTWRRW1CASRWN), s_mg_ro_n = xz1(CFGMGMTWRREADONLYN);
    wire [3:0]  s_mg_be_n   = ~xz0(~CFGMGMTBYTEENN);
    wire [9:0]  s_mg_addr   = xz0(CFGMGMTDWADDR);
    wire [31:0] s_mg_di     = xz0(CFGMGMTDI);
    wire        s_tcfg_gnt  = xz0(TRNTCFGGNT);
    wire [15:0] s_ds_id     = xz0({CFGDSBUSNUMBER, CFGDSDEVICENUMBER, CFGDSFUNCTIONNUMBER});
    wire        s_tx_hotrst = xz0(PLTRANSMITHOTRST);

    // ------------------------------------------------------------------
    // resets
    // ------------------------------------------------------------------
    wire arst = !SYSRSTN || !PLRSTN;
    wire p_rst, u_rst;
    eerie_reset_sync rs_p (.clk(pclk), .arst(arst), .rst(p_rst));
    eerie_reset_sync rs_u (.clk(uclk), .arst(arst), .rst(u_rst));

    // ------------------------------------------------------------------
    // physical layer (PIPE clock domain), NL lanes
    // ------------------------------------------------------------------
    // one eerie_pl_rx / eerie_pl_tx per lane (ordered sets, scrambling, x1 framing on lane 0);
    // x2 / x4 links use the deskew + eerie_pl_rx_ml receive framing and the eerie_pl_tx_ml striper
    localparam M_EIDLE = 3'd0, M_DATA = 3'd3, M_IDLE = 3'd5;
    wire [16*8-1:0] a_rxd  = {PIPERX7DATA, PIPERX6DATA, PIPERX5DATA, PIPERX4DATA,
                              PIPERX3DATA, PIPERX2DATA, PIPERX1DATA, PIPERX0DATA};
    wire [2*8-1:0]  a_rxk  = {PIPERX7CHARISK, PIPERX6CHARISK, PIPERX5CHARISK, PIPERX4CHARISK,
                              PIPERX3CHARISK, PIPERX2CHARISK, PIPERX1CHARISK, PIPERX0CHARISK};
    wire [8-1:0]    a_rxv  = {PIPERX7VALID, PIPERX6VALID, PIPERX5VALID, PIPERX4VALID,
                              PIPERX3VALID, PIPERX2VALID, PIPERX1VALID, PIPERX0VALID};
    wire [3*8-1:0]  a_rxst = {PIPERX7STATUS, PIPERX6STATUS, PIPERX5STATUS, PIPERX4STATUS,
                              PIPERX3STATUS, PIPERX2STATUS, PIPERX1STATUS, PIPERX0STATUS};
    wire [8-1:0]    a_rxei = {PIPERX7ELECIDLE, PIPERX6ELECIDLE, PIPERX5ELECIDLE, PIPERX4ELECIDLE,
                              PIPERX3ELECIDLE, PIPERX2ELECIDLE, PIPERX1ELECIDLE, PIPERX0ELECIDLE};
    wire [16*8-1:0] a_txd;
    wire [2*8-1:0]  a_txk;
    wire [8-1:0]    a_txei;
    wire [8-1:0]    a_rxpol;

    wire [NL-1:0]   l_tsv, l_ts2, l_inv, l_lpad, l_npad, l_eios, l_skp, l_idle2, l_pst, l_rxerr, l_pwe;
    wire [8*NL-1:0] l_link, l_lane, l_nfts, l_rate, l_ctrl;
    wire [82*NL-1:0] l_pwd;
    wire [NL-1:0]   ln_v, ln_err;
    wire [16*NL-1:0] ln_d;
    wire [2*NL-1:0] ln_k, ln_com, ln_skp;
    wire [NL-1:0]   l_ts_done, l_eios_done, l_idle_pair, l_busy, l_rd_en;

    wire        scramble_en;
    wire        pl_descr_en = scramble_en && (DISABLE_SCRAMBLING != "TRUE");
    wire [2:0]  tx_mode;
    wire [7:0]  tx_link, tx_lane, tx_nfts, tx_rate, tx_ctrl;
    wire        tx_link_pad, tx_lane_pad;
    wire [8*NL-1:0] tx_lane_v;
    wire [NL-1:0]   tx_lane_pad_v, tx_link_pad_v, lane_en, rxpol;
    wire [3:0]  p_width;
    wire [1:0]  p_powerdown;
    wire        eieos_clr;
    wire [66:0] pltx_rd_data;
    wire        pltx_rd_empty, pltx_rd_en;
    wire        retrain_p;
    wire        p_link_up, p_in_l0, p_hot_reset, p_link_training, p_partner_gen2;
    wire [5:0]  p_ltssm;
    wire [7:0]  p_link_num;
    wire        p_rate;
    // root port: link controls from the configuration space (user clock), synchronized below
    wire        p_dsp_retrain, p_dsp_hot, p_dsp_dis, p_dsp_tgt2, p_dl_up, p_retrain_ack;

    // registered link width for the data path (the width settles in Configuration, long before
    // any data): keeps the LTSSM out of the multi-lane data path's timing
    reg  [3:0]  p_width_d = 4'd1;
    always @(posedge pclk) p_width_d <= p_width;
    wire        ml = (NL > 1) && (p_width_d >= 4'd2);          // x2 / x4 data path
    wire        st_pop;                                       // striper FIFO pop
    wire [8*NL-1:0] st_s0, st_s1;
    wire [NL-1:0]   st_k0, st_k1;
    wire        st_idle, st_busy;
    wire        l0_pop;

`ifdef EERIE_W16
    // ------------------------------------------------------------------
    // TASK-6173 (GateMate): x1 lane on a 128-bit PIPE, 16 symbols per PIPE clock (31.25 MHz at 5.0 GT/s,
    // 15.625 MHz at 2.5 GT/s: fixed width, the PIPE clock follows the rate). PIPE lanes 0..7 carry
    // symbols 0..15 of the one lane (lane 0 = symbols 0,1 = first on the wire); valid / status /
    // electrical idle / polarity are those of lane 0. The receive slots go through eerie_slot_fifo to
    // the 64-bit receive framing (eerie_pl_rx_ml, 8 bytes per clock); the transmit path takes the 8-byte
    // packet FIFO entries two at a time.
    // ------------------------------------------------------------------
    wire [127:0] w16_rxd = a_rxd;
    wire [15:0]  w16_rxk = a_rxk;
    wire [127:0] w16_txd; wire [15:0] w16_txk; wire w16_txei;
    wire [3:0]   w16_sv, w16_se; wire [127:0] w16_sd; wire [15:0] w16_sk;
    wire         w8_va, w8_vb, w8_ea, w8_eb, w8_err, w8_mlerr, w16_ovf;
    wire [31:0]  w8_da, w8_db; wire [3:0] w8_ka, w8_kb;
    wire [1:0]   pltx_rd_n; wire pltx_rd_has2; wire [66:0] pltx_rd_data2;
    eerie_pl_rx_w16 pl_rx_w16 (
        .clk(pclk), .rst(p_rst),
        .pipe_rxdata(w16_rxd), .pipe_rxdatak(w16_rxk), .pipe_rxvalid(PIPERX0VALID),
        .pipe_rxstatus(PIPERX0STATUS), .pipe_rxelecidle(PIPERX0ELECIDLE), .descramble_en(pl_descr_en),
        .os_ts_valid(l_tsv[0]), .os_ts2(l_ts2[0]), .os_ts_inv(l_inv[0]),
        .os_link(l_link[7:0]), .os_link_pad(l_lpad[0]), .os_lane(l_lane[7:0]), .os_lane_pad(l_npad[0]),
        .os_nfts(l_nfts[7:0]), .os_rate(l_rate[7:0]), .os_ctrl(l_ctrl[7:0]),
        .os_eios(l_eios[0]), .os_skp(l_skp[0]), .os_idle2(l_idle2[0]), .rx_err(w8_err),
        .sl_v(w16_sv), .sl_d(w16_sd), .sl_k(w16_sk), .sl_e(w16_se)
    );
    eerie_slot_fifo #(.AW(9)) slot_fifo (
        .clk(pclk), .rst(p_rst),
        .i_v(w16_sv), .i_d(w16_sd), .i_k(w16_sk), .i_e(w16_se),
        .o_va(w8_va), .o_vb(w8_vb), .o_da(w8_da), .o_db(w8_db), .o_ka(w8_ka), .o_kb(w8_kb),
        .o_ea(w8_ea), .o_eb(w8_eb), .o_ovf(w16_ovf)
    );
    assign l_pst[0] = 1'b0;
    wire        plrx_we, rx_err;
    wire [81:0] plrx_wd;
    eerie_pl_rx_ml #(.N(4), .W4_FIXED(1)) rx_ml_w8 (
        .clk(pclk), .rst(p_rst), .w4(1'b1),
        .i_va(w8_va), .i_vb(w8_vb), .i_da(w8_da), .i_db(w8_db), .i_ka(w8_ka), .i_kb(w8_kb),
        .i_erra(w8_ea), .i_errb(w8_eb), .rx_err(w8_mlerr), .pkt_we(plrx_we), .pkt_wd(plrx_wd)
    );
    assign rx_err = w8_err || w8_mlerr || w16_ovf;
    eerie_pl_tx_w16 pl_tx_w16 (
        .clk(pclk), .rst(p_rst),
        .mode(lane_en[0] ? tx_mode : M_EIDLE),
        .ts_link(tx_link), .ts_link_pad(tx_link_pad || tx_link_pad_v[0]),
        .ts_lane(tx_lane), .ts_lane_pad(tx_lane_pad || tx_lane_pad_v[0]),
        .ts_nfts(tx_nfts), .ts_rate(tx_rate), .ts_ctrl(tx_ctrl), .scramble_en(pl_descr_en),
        .gen2(p_rate), .eieos_clr(eieos_clr),
        .ts_done(l_ts_done[0]), .eios_done(l_eios_done[0]), .idle_pair(l_idle_pair[0]), .busy(l_busy[0]),
        .pkt_rd_data(pltx_rd_data), .pkt_rd_data2(pltx_rd_data2), .pkt_rd_empty(pltx_rd_empty),
        .pkt_rd_has2(pltx_rd_has2), .pkt_rd_n(pltx_rd_n),
        .pipe_txdata(w16_txd), .pipe_txdatak(w16_txk), .pipe_txelecidle(w16_txei)
    );
    assign a_txd = w16_txd; assign a_txk = w16_txk;
    assign a_txei = {8{w16_txei}};
    assign a_rxpol = {7'd0, rxpol[0]};
    assign pltx_rd_en = 1'b0;
    assign l0_pop = 1'b0; assign st_pop = 1'b0;
    assign st_s0 = 0; assign st_s1 = 0; assign st_k0 = 0; assign st_k1 = 0; assign st_idle = 1'b0; assign st_busy = 1'b0;
`elsif EERIE_W8
    // ------------------------------------------------------------------
    // TASK-6161 (GateMate): x1 lane on a 64-bit PIPE, 8 symbols per PIPE clock (31.25 MHz at Gen1).
    // PIPE lanes 0..3 carry symbols 0..7 of the one lane (lane 0 = symbols 0,1 = first on the wire);
    // valid / status / electrical idle / polarity are those of lane 0.
    // ------------------------------------------------------------------
    wire [63:0] w8_rxd = {PIPERX3DATA, PIPERX2DATA, PIPERX1DATA, PIPERX0DATA};
    wire [7:0]  w8_rxk = {PIPERX3CHARISK, PIPERX2CHARISK, PIPERX1CHARISK, PIPERX0CHARISK};
    wire [63:0] w8_txd; wire [7:0] w8_txk; wire w8_txei;
    wire        w8_va, w8_vb, w8_ea, w8_eb, w8_err, w8_mlerr;
    wire [31:0] w8_da, w8_db; wire [3:0] w8_ka, w8_kb;
    eerie_pl_rx_w8 pl_rx_w8 (
        .clk(pclk), .rst(p_rst),
        .pipe_rxdata(w8_rxd), .pipe_rxdatak(w8_rxk), .pipe_rxvalid(PIPERX0VALID),
        .pipe_rxstatus(PIPERX0STATUS), .pipe_rxelecidle(PIPERX0ELECIDLE), .descramble_en(pl_descr_en),
        .os_ts_valid(l_tsv[0]), .os_ts2(l_ts2[0]), .os_ts_inv(l_inv[0]),
        .os_link(l_link[7:0]), .os_link_pad(l_lpad[0]), .os_lane(l_lane[7:0]), .os_lane_pad(l_npad[0]),
        .os_nfts(l_nfts[7:0]), .os_rate(l_rate[7:0]), .os_ctrl(l_ctrl[7:0]),
        .os_eios(l_eios[0]), .os_skp(l_skp[0]), .os_idle2(l_idle2[0]), .rx_err(w8_err),
        .sl_va(w8_va), .sl_vb(w8_vb), .sl_da(w8_da), .sl_db(w8_db), .sl_ka(w8_ka), .sl_kb(w8_kb),
        .sl_ea(w8_ea), .sl_eb(w8_eb)
    );
    assign l_pst[0] = 1'b0;
    wire        plrx_we, rx_err;
    wire [81:0] plrx_wd;
    eerie_pl_rx_ml #(.N(4), .W4_FIXED(1)) rx_ml_w8 (
        .clk(pclk), .rst(p_rst), .w4(1'b1),
        .i_va(w8_va), .i_vb(w8_vb), .i_da(w8_da), .i_db(w8_db), .i_ka(w8_ka), .i_kb(w8_kb),
        .i_erra(w8_ea), .i_errb(w8_eb), .rx_err(w8_mlerr), .pkt_we(plrx_we), .pkt_wd(plrx_wd)
    );
    assign rx_err = w8_err || w8_mlerr;
    eerie_pl_tx_w8 pl_tx_w8 (
        .clk(pclk), .rst(p_rst),
        .mode(lane_en[0] ? tx_mode : M_EIDLE),
        .ts_link(tx_link), .ts_link_pad(tx_link_pad || tx_link_pad_v[0]),
        .ts_lane(tx_lane), .ts_lane_pad(tx_lane_pad || tx_lane_pad_v[0]),
        .ts_nfts(tx_nfts), .ts_rate(tx_rate), .ts_ctrl(tx_ctrl), .scramble_en(pl_descr_en),
        .ts_done(l_ts_done[0]), .eios_done(l_eios_done[0]), .idle_pair(l_idle_pair[0]), .busy(l_busy[0]),
        .pkt_rd_data(pltx_rd_data), .pkt_rd_empty(pltx_rd_empty), .pkt_rd_en(pltx_rd_en),
        .pipe_txdata(w8_txd), .pipe_txdatak(w8_txk), .pipe_txelecidle(w8_txei)
    );
    assign a_txd = {64'd0, w8_txd}; assign a_txk = {8'd0, w8_txk};
    assign a_txei = {4'b1111, {4{w8_txei}}};
    assign a_rxpol = {7'd0, rxpol[0]};
    assign l0_pop = 1'b0; assign st_pop = 1'b0;
    assign st_s0 = 0; assign st_s1 = 0; assign st_k0 = 0; assign st_k1 = 0; assign st_idle = 1'b0; assign st_busy = 1'b0;
`else
    genvar gl;
    generate for (gl = 0; gl < NL; gl = gl + 1) begin : lane
        eerie_pl_rx pl_rx (
            .clk(pclk), .rst(p_rst),
            .pipe_rxdata(a_rxd[16*gl +: 16]), .pipe_rxdatak(a_rxk[2*gl +: 2]), .pipe_rxvalid(a_rxv[gl]),
            .pipe_rxstatus(a_rxst[3*gl +: 3]), .pipe_rxelecidle(a_rxei[gl]), .descramble_en(pl_descr_en),
            .os_ts_valid(l_tsv[gl]), .os_ts2(l_ts2[gl]), .os_ts_inv(l_inv[gl]),
            .os_link(l_link[8*gl +: 8]), .os_link_pad(l_lpad[gl]), .os_lane(l_lane[8*gl +: 8]), .os_lane_pad(l_npad[gl]),
            .os_nfts(l_nfts[8*gl +: 8]), .os_rate(l_rate[8*gl +: 8]), .os_ctrl(l_ctrl[8*gl +: 8]),
            .os_eios(l_eios[gl]), .os_skp(l_skp[gl]), .os_idle2(l_idle2[gl]), .os_pkt_start(l_pst[gl]),
            .rx_err(l_rxerr[gl]), .pkt_we(l_pwe[gl]), .pkt_wd(l_pwd[82*gl +: 82]),
            .ln_v(ln_v[gl]), .ln_d(ln_d[16*gl +: 16]), .ln_k(ln_k[2*gl +: 2]), .ln_com(ln_com[2*gl +: 2]),
            .ln_skp(ln_skp[2*gl +: 2]), .ln_err(ln_err[gl])
        );
        wire ext = ml && (gl < p_width_d);
        eerie_pl_tx pl_tx (
            .clk(pclk), .rst(p_rst),
            .mode(lane_en[gl] ? tx_mode : M_EIDLE),
            .ts_link(tx_link), .ts_link_pad(tx_link_pad || tx_link_pad_v[gl]),
            .ts_lane(gl == 0 ? tx_lane : tx_lane_v[8*gl +: 8]), .ts_lane_pad(tx_lane_pad || tx_lane_pad_v[gl]),
            .ts_nfts(tx_nfts), .ts_rate(tx_rate), .ts_ctrl(tx_ctrl),
            .scramble_en(pl_descr_en), .gen2(p_rate), .eieos_clr(eieos_clr),
            .ts_done(l_ts_done[gl]), .eios_done(l_eios_done[gl]), .idle_pair(l_idle_pair[gl]), .busy(l_busy[gl]),
            .ext_en(ext), .ext_busy(st_busy), .ext_s0(st_s0[8*gl +: 8]), .ext_s1(st_s1[8*gl +: 8]),
            .ext_k0(st_k0[gl]), .ext_k1(st_k1[gl]), .ext_idle(st_idle),
            .pkt_rd_data(pltx_rd_data), .pkt_rd_empty(gl == 0 ? (pltx_rd_empty || ml) : 1'b1),
            .pkt_rd_en(l_rd_en[gl]),
            .pipe_txdata(a_txd[16*gl +: 16]), .pipe_txdatak(a_txk[2*gl +: 2]), .pipe_txelecidle(a_txei[gl])
        );
        assign a_rxpol[gl] = rxpol[gl];
    end
    for (gl = NL; gl < 8; gl = gl + 1) begin : unused_lane
        assign a_txd[16*gl +: 16] = 16'd0; assign a_txk[2*gl +: 2] = 2'b00; assign a_txei[gl] = 1'b1;
        assign a_rxpol[gl] = 1'b0;
    end
    endgenerate
    // lane 0 pops the packet FIFO itself at x1 (it sees the FIFO as empty while the link is x2 / x4)
    assign l0_pop = !ml && l_rd_en[0];
    assign pltx_rd_en = ml ? st_pop : l0_pop;

    wire        plrx_we, rx_err;
    wire [81:0] plrx_wd;
    generate if (NL > 1) begin : mlp
        wire       d_va, d_vb, d_ea, d_eb;
        wire [8*NL-1:0] d_da, d_db;
        wire [NL-1:0]   d_ka, d_kb;
        eerie_pl_deskew #(.N(NL)) deskew (
            .clk(pclk), .rst(p_rst || !ml), .act(lane_en),
            .ln_v(ln_v), .ln_d(ln_d), .ln_k(ln_k), .ln_com(ln_com), .ln_skp(ln_skp), .ln_err(ln_err),
            .o_va(d_va), .o_vb(d_vb), .o_da(d_da), .o_db(d_db), .o_ka(d_ka), .o_kb(d_kb), .o_erra(d_ea), .o_errb(d_eb)
        );
        wire       m_we, m_err;
        wire [81:0] m_wd;
        eerie_pl_rx_ml #(.N(NL)) rx_ml (
            .clk(pclk), .rst(p_rst || !ml), .w4(p_width_d >= 4'd4),
            .i_va(d_va), .i_vb(d_vb), .i_da(d_da), .i_db(d_db), .i_ka(d_ka), .i_kb(d_kb), .i_erra(d_ea), .i_errb(d_eb),
            .rx_err(m_err), .pkt_we(m_we), .pkt_wd(m_wd)
        );
        eerie_pl_tx_ml #(.N(NL)) tx_ml (
            .clk(pclk), .rst(p_rst), .en(ml), .w4(p_width_d >= 4'd4),
            .run(tx_mode == M_DATA || tx_mode == M_IDLE), .data_mode(tx_mode == M_DATA),
            .pkt_rd_data(pltx_rd_data), .pkt_rd_empty(pltx_rd_empty), .pkt_rd_en(st_pop),
            .s0(st_s0), .s1(st_s1), .k0(st_k0), .k1(st_k1), .idle(st_idle), .busy(st_busy)
        );
        assign plrx_we = ml ? m_we : l_pwe[0];
        assign plrx_wd = ml ? m_wd : l_pwd[81:0];
        assign rx_err  = ml ? m_err : l_rxerr[0];
    end else begin : x1p
        assign st_pop = 1'b0; assign st_s0 = 8'd0; assign st_s1 = 8'd0; assign st_k0 = 1'b0; assign st_k1 = 1'b0;
        assign st_idle = 1'b0; assign st_busy = 1'b0;
        assign plrx_we = l_pwe[0]; assign plrx_wd = l_pwd[81:0]; assign rx_err = l_rxerr[0];
    end
    endgenerate
`endif

    eerie_ltssm #(
`ifdef EERIE_W16
        .US_DIV1(8'd15), .US_DIV2(8'd30),      // TASK-6173: 15.625 / 31.25 MHz
`elsif EERIE_W8
        .US_DIV1(8'd30),
`endif
        .MAX_RATE(MAX_RATE), .FAST_TRAIN(FAST), .N_FTS_GEN1(N_FTS_GEN1), .N_FTS_GEN2(N_FTS_GEN2),
        .UPCONFIG(UPCONFIG_CAPABLE == "TRUE"), .DSP(DSP), .NL(NL), .MAXW(MAXW)
    ) ltssm (
        .clk(pclk), .rst(p_rst),
        .pipe_txdetectrx(PIPETXRCVRDET), .pipe_powerdown(p_powerdown), .pipe_rate(p_rate),
        .pipe_rxpolarity(rxpol), .i_pipe_phystatus(PIPERX0PHYSTATUS), .i_pipe_rxstatus(PIPERX0STATUS),
        .i_pipe_rxelecidle(PIPERX0ELECIDLE),
`ifdef EERIE_RXLOCK_REC
        .i_pipe_rxvalid(PIPERX0VALID),
`endif
        .tx_mode(tx_mode), .tx_link(tx_link), .tx_link_pad(tx_link_pad), .tx_lane(tx_lane), .tx_lane_pad(tx_lane_pad),
        .tx_nfts(tx_nfts), .tx_rate(tx_rate), .tx_ctrl(tx_ctrl),
        .tx_ts_done(l_ts_done[0]), .tx_eios_done(l_eios_done[0]), .tx_idle_pair(l_idle_pair[0]), .tx_busy(l_busy[0]),
        .scramble_en(scramble_en), .eieos_clr(eieos_clr),
        .i_os_ts_valid(l_tsv[0]), .i_os_ts2(l_ts2[0]), .i_os_ts_inv(l_inv[0]), .i_os_link(l_link[7:0]),
        .i_os_link_pad(l_lpad[0]), .i_os_lane(l_lane[7:0]), .i_os_lane_pad(l_npad[0]), .i_os_nfts(l_nfts[7:0]),
        .i_os_rate(l_rate[7:0]), .i_os_ctrl(l_ctrl[7:0]), .i_os_eios(l_eios[0]), .i_os_idle2(l_idle2[0]),
        .ml_ts_valid(l_tsv), .ml_ts2(l_ts2), .ml_ts_inv(l_inv), .ml_link(l_link), .ml_link_pad(l_lpad),
        .ml_lane(l_lane), .ml_lane_pad(l_npad), .ml_rxstatus(a_rxst[3*NL-1:0]),
        .tx_lane_v(tx_lane_v), .tx_lane_pad_v(tx_lane_pad_v), .tx_link_pad_v(tx_link_pad_v), .lane_en(lane_en),
        .link_width(p_width),
        .retrain_req(retrain_p),
        .dsp_retrain(p_dsp_retrain), .dsp_hot_reset(p_dsp_hot), .dsp_disable(p_dsp_dis),
        .dsp_target_gen2(p_dsp_tgt2), .dsp_dl_up(p_dl_up), .dsp_retrain_ack(p_retrain_ack),
        .link_up(p_link_up), .in_l0(p_in_l0), .ltssm_state(p_ltssm), .hot_reset(p_hot_reset),
        .link_training(p_link_training), .partner_gen2(p_partner_gen2), .link_num(p_link_num),
        .rcvr_err_ltssm()
    );
    assign PIPETX0POWERDOWN  = p_powerdown;
    assign PIPETXRATE        = p_rate;
    assign PIPETXDEEMPH      = 1'b1;          // -3.5 dB
    assign PIPETXMARGIN      = 3'b000;
    assign PIPETXRESET       = 1'b0;
    assign PIPETX0COMPLIANCE = 1'b0;

    assign PLLTSSMSTATE      = p_ltssm;
    assign PLSELLNKRATE      = p_rate;
    assign PLSELLNKWIDTH     = (p_width >= 4'd8) ? 2'b11 : (p_width >= 4'd4) ? 2'b10 : (p_width >= 4'd2) ? 2'b01 : 2'b00;
    assign PLPHYLNKUPN       = !p_link_up;
    assign PLLINKGEN2CAP     = (MAX_RATE >= 2);
    assign PLLINKPARTNERGEN2SUPPORTED = p_partner_gen2;
    assign PLLINKUPCFGCAP    = 1'b0;
    assign PLINITIALLINKWIDTH = (p_width >= 4'd8) ? 3'b100 : (p_width >= 4'd4) ? 3'b011 : (p_width >= 4'd2) ? 3'b010 : 3'b001;
    assign PLLANEREVERSALMODE = 2'b00;
    assign PLRXPMSTATE       = 2'b00;
    assign PLTXPMSTATE       = 3'b000;
    assign PLRECEIVEDHOTRST  = p_hot_reset;
    assign PLDIRECTEDCHANGEDONE = 1'b0;
    assign PLDBGVEC          = 12'd0;
    assign PL2LINKUP         = p_link_up;
    assign PL2RECEIVERERR    = rx_err;
    assign PL2RECOVERY       = (p_ltssm >= 6'h1C && p_ltssm <= 6'h20);
    assign PL2RXELECIDLE     = PIPERX0ELECIDLE;
    assign PL2RXPMSTATE      = 2'b00;
    assign PL2SUSPENDOK      = 1'b0;
    assign PL2L0REQ          = 1'b0;

    // ------------------------------------------------------------------
    // clock domain crossing
    // ------------------------------------------------------------------
    wire u_link_up, u_in_l0, u_rate, u_training, u_hot_reset;
    eerie_sync_bits #(.W(5)) sync_u (.clk(uclk), .d({p_link_up, p_in_l0, p_rate, p_link_training, p_hot_reset}),
                                     .q({u_link_up, u_in_l0, u_rate, u_training, u_hot_reset}));
    reg  u_lrst = 1'b1;                               // link-scope reset, user clock (registered)
    always @(posedge uclk) u_lrst <= u_rst || !u_link_up;
    wire p_lrst;                                      // same, delayed into the PIPE clock domain
    eerie_sync_bits #(.W(1), .INIT(1'b1)) sync_lrst (.clk(pclk), .d(u_lrst), .q(p_lrst));
    wire [3:0] u_width;
    eerie_sync_bits #(.W(4), .INIT(4'd1)) sync_w (.clk(uclk), .d(p_width), .q(u_width));
    wire u_retrain;
    eerie_sync_pulse sync_retrain (.src_clk(uclk), .src_pulse(u_retrain), .dst_clk(pclk), .dst_pulse(retrain_p));
    wire [15:0] c_lnkctl, c_lnkctl2, c_brctl;
    wire        dl_up;
    eerie_sync_bits #(.W(5)) sync_dsp (.clk(pclk),
        .d({c_lnkctl[5], c_brctl[6] || s_tx_hotrst, c_lnkctl[4], c_lnkctl2[3:0] >= 4'd2, dl_up}),
        .q({p_dsp_retrain, p_dsp_hot, p_dsp_dis, p_dsp_tgt2, p_dl_up}));
    wire u_retrain_ack;
    eerie_sync_pulse sync_rt_ack (.src_clk(pclk), .src_pulse(p_retrain_ack), .dst_clk(uclk), .dst_pulse(u_retrain_ack));

    wire [81:0] plrx_rd_d;
    wire        plrx_rd_empty, plrx_rd;
`ifdef EERIE_1CLK
    localparam FIFO_SYNC = 1;     // TASK-6173: USERCLK == PIPECLK, the PL <-> DLL FIFOs without synchronizers
`else
    localparam FIFO_SYNC = 0;
`endif
    eerie_async_fifo #(.W(82), .AW(4), .PKT_MODE(0), .SYNC(FIFO_SYNC)) rx_fifo (
        .wr_clk(pclk), .wr_rst(p_lrst || p_rst), .wr_en(plrx_we), .wr_data(plrx_wd), .wr_last(1'b1), .wr_full(), .wr_free(),
        .rd_clk(uclk), .rd_rst(u_lrst), .rd_en(plrx_rd), .rd_data(plrx_rd_d), .rd_empty(plrx_rd_empty)
    );

    wire        pltx_we, pltx_full;
    wire [66:0] pltx_wd;
    wire [7:0]  pltx_free;
`ifdef EERIE_W16
    eerie_async_fifo2 #(.W(67), .AW(7), .PKT_MODE(1), .SYNC(FIFO_SYNC)) tx_fifo (
        .wr_clk(uclk), .wr_rst(u_lrst), .wr_en(pltx_we), .wr_data(pltx_wd), .wr_last(pltx_wd[65]),
        .wr_full(pltx_full), .wr_free(pltx_free),
        .rd_clk(pclk), .rd_rst(p_lrst || p_rst), .rd_n(pltx_rd_n), .rd_data(pltx_rd_data), .rd_data2(pltx_rd_data2),
        .rd_empty(pltx_rd_empty), .rd_has2(pltx_rd_has2)
    );
`else
    eerie_async_fifo #(.W(67), .AW(7), .PKT_MODE(1), .SYNC(FIFO_SYNC)) tx_fifo (
        .wr_clk(uclk), .wr_rst(u_lrst), .wr_en(pltx_we), .wr_data(pltx_wd), .wr_last(pltx_wd[65]),
        .wr_full(pltx_full), .wr_free(pltx_free),
        .rd_clk(pclk), .rd_rst(p_lrst || p_rst), .rd_en(pltx_rd_en), .rd_data(pltx_rd_data), .rd_empty(pltx_rd_empty)
    );
`endif

    // ------------------------------------------------------------------
    // data link layer (user clock domain)
    // ------------------------------------------------------------------
    wire        c_pme_en, c_pme_sts, c_msi_en, c_msix_en, c_msix_fm, flr_pulse;
    wire        dl_init;
    wire        tlrx_v, tlrx_sop, tlrx_half, tlrx_end, tlrx_ok;
    wire [63:0] tlrx_d;
    wire        txq_v, txq_sop, txq_eop, txq_half, txq_abort;
    wire [63:0] txq_d;
    wire [5:0]  txq_slots;
    wire [7:0]  fc_ph, fc_nph, fc_cplh;
    wire [11:0] fc_pd, fc_npd, fc_cpld;
    wire [2:0]  fc_upd_req;
    wire [7:0]  lim_ph, lim_nph, lim_cplh, cons_ph, cons_nph, cons_cplh;
    wire [11:0] lim_pd, lim_npd, lim_cpld, cons_pd, cons_npd, cons_cpld;
    wire [5:0]  inf_mask;
    wire        e_bad_tlp, e_bad_dllp, e_rro, e_rto, e_dlp;
`ifdef EERIE_W8_RPLY
    wire [15:0] rply_lim;
`endif
`ifdef EERIE_DBGCNT
    wire [2:0]  dl_dbg_ev;
`ifdef EERIE_ILA
    wire [51:0] dl_ila;
`endif
`endif
    wire [31:0] dllp_rx_data;
    wire        dllp_rx_v;
    wire        txb_we, txb_re;
    wire [12:0] txb_waddr, txb_raddr;
    wire [68:0] txb_wdata;

`ifdef EERIE_W16
    // TASK-6173: 750 user clocks are 24 us at 31.25 MHz (5.0 GT/s); eerie_dll halves it at 2.5 GT/s (15.625 MHz).
    // An Ack goes out as soon as it is due (openPCIE_BFM rule DL.ACK-LAT: at 15.625 MHz a clock is 16 symbol
    // times at 2.5 GT/s, the receive -> Ack path is ~40 clocks of the 2588 ns limit)
    localparam [15:0] UPDFC_P = 16'd750;
    localparam [7:0]  ACK_DLY = 8'd0;
`elsif EERIE_W8
`ifdef EERIE_ACK0
    localparam [7:0]  ACK_DLY = 8'd0;   // TASK-6185 (#13, GSK): Ack as soon as due (W16 rule DL.ACK-LAT)
`else
    localparam [7:0]  ACK_DLY = 8'd2;
`endif
    // TASK-6170 (openPCIE_BFM rule FC.UPDATE-PERIOD): the user clock is 31.25 MHz with EERIE_W8, not 62.5;
    // 1500 clocks were 48 us (spec: 30 us, +50 %), 750 are 24 us as on the 16-bit path
    localparam [15:0] UPDFC_P = 16'd750;
`else
    localparam [7:0]  ACK_DLY = 8'd2;
    localparam [15:0] UPDFC_P = 16'd1500;
`endif
    eerie_dll #(
        .TXB_AW(TXB_AW), .TXB_RLAT(TXB_RLAT), .MAX_TLP_BEATS(MAX_TLP_BEATS), .NDESC_AW(5),
        .MAX_UNACKED(MAX_UNACK), .REPLAY_TIMEOUT(REPLAY_T), .ACK_DELAY(ACK_DLY), .UPDFC_PERIOD(UPDFC_P),
        .CPL_INFINITE(CPL_INF)
    ) dll (
        .clk(uclk), .rst(u_rst), .link_up(u_link_up), .link_l0(u_in_l0),
`ifdef EERIE_W16
        .link_gen2(u_rate),
`endif
`ifdef EERIE_W8_RPLY
        .replay_lim(rply_lim),
`endif
        .dl_up(dl_up), .dl_init(dl_init), .retrain_req(u_retrain),
        .plrx_d(plrx_rd_d), .plrx_empty(plrx_rd_empty), .plrx_rd(plrx_rd),
        .pltx_we(pltx_we), .pltx_wd(pltx_wd), .pltx_full(pltx_full), .pltx_free(pltx_free),
        .tlrx_v(tlrx_v), .tlrx_d(tlrx_d), .tlrx_sop(tlrx_sop), .tlrx_half(tlrx_half), .tlrx_end(tlrx_end), .tlrx_ok(tlrx_ok),
        .txq_v(txq_v), .txq_d(txq_d), .txq_sop(txq_sop), .txq_eop(txq_eop), .txq_half(txq_half), .txq_abort(txq_abort),
        .txq_slots(txq_slots),
        .fc_ph(fc_ph), .fc_pd(fc_pd), .fc_nph(fc_nph), .fc_npd(fc_npd), .fc_cplh(fc_cplh), .fc_cpld(fc_cpld),
        .fc_upd_req(fc_upd_req),
        .lim_ph(lim_ph), .lim_pd(lim_pd), .lim_nph(lim_nph), .lim_npd(lim_npd), .lim_cplh(lim_cplh), .lim_cpld(lim_cpld),
        .cons_ph(cons_ph), .cons_pd(cons_pd), .cons_nph(cons_nph), .cons_npd(cons_npd), .cons_cplh(cons_cplh), .cons_cpld(cons_cpld),
        .inf_mask(inf_mask),
        .err_bad_tlp(e_bad_tlp), .err_bad_dllp(e_bad_dllp), .err_replay_rollover(e_rro), .err_replay_timeout(e_rto),
`ifdef EERIE_DBGCNT
        .dbg_ev(dl_dbg_ev),
`ifdef EERIE_ILA
        .ila_p(dl_ila),
`endif
`endif
        .err_dl_protocol(e_dlp), .dllp_rx_data(dllp_rx_data), .dllp_rx_v(dllp_rx_v),
        .txb_we(txb_we), .txb_waddr(txb_waddr), .txb_wdata(txb_wdata), .txb_re(txb_re), .txb_raddr(txb_raddr),
        .txb_rdata(MIMTXRDATA)
    );
    assign MIMTXWEN = txb_we;  assign MIMTXWADDR = txb_waddr; assign MIMTXWDATA = txb_wdata;
    assign MIMTXREN = txb_re;  assign MIMTXRADDR = txb_raddr;

    assign LL2BADDLLPERR  = e_bad_dllp;
    assign LL2BADTLPERR   = e_bad_tlp;
    assign LL2PROTOCOLERR = e_dlp;
    assign LL2RECEIVERERR = 1'b0;
    assign LL2REPLAYROERR = e_rro;
    assign LL2REPLAYTOERR = e_rto;
    assign LL2SUSPENDOK   = 1'b0;
    assign LL2TFCINIT1SEQ = 1'b0;
    assign LL2TFCINIT2SEQ = 1'b0;
    assign LL2TXIDLE      = 1'b0;
    assign LL2LINKSTATUS  = {dl_up, dl_init, 3'b000};
    assign TRNRDLLPDATA   = {32'd0, dllp_rx_data};
    assign TRNRDLLPSRCRDY = {1'b0, dllp_rx_v};
    assign TRNTDLLPDSTRDY = 1'b0;
    assign TRNLNKUP       = dl_up;
    assign USERRSTN       = !u_rst;
    assign LNKCLKEN       = 1'b1;
    assign RECEIVEDFUNCLVLRSTN = !flr_pulse;

    // ------------------------------------------------------------------
    // transaction layer + configuration space
    // ------------------------------------------------------------------
    wire [15:0] c_command, c_status, c_devctl, c_devsts, c_lnksts, c_devctl2;
`ifdef EERIE_W8_RPLY
    // TASK-6190: REPLAY_T counts 4 symbol times per user clock (62.5 MHz); EERIE_W8 runs 8 (31.25 MHz), so the timer was
    // twice too long there, and it followed the supported MPS (512: 700 clocks = 22.4 us) instead of the programmed one.
    // Limit = 1.5 x PCIe 2.0 Table 3-4 (x1, 2.5 GT/s: 711/1248/1677/3213/6285 symbols; -0/+100 % allowed) in 8-symbol clocks
    assign rply_lim = (c_devctl[7:5] == 3'd0) ? 16'd133 : (c_devctl[7:5] == 3'd1) ? 16'd234 :
                      (c_devctl[7:5] == 3'd2) ? 16'd314 : (c_devctl[7:5] == 3'd3) ? 16'd602 : 16'd1178;
`endif
    wire [7:0]  c_rootctl;
    wire [1:0]  c_pm_state;
    wire [2:0]  c_msi_mme;
    wire [63:0] c_msi_addr;
    wire [15:0] c_msi_data;
    wire [7:0]  c_int_line;
    wire [31:0] c_bar0, c_bar1, c_bar2, c_bar3, c_bar4, c_bar5, c_rom;
    wire        c_rom_en;
    wire [31:0] cfg_rd_data;

    // TL RX config requests and the management port share the config space
    wire        tl_cfg_v, tl_cfg_wr;
    wire [9:0]  tl_cfg_a;
    wire [3:0]  tl_cfg_be;
    wire [31:0] tl_cfg_wd;
    reg         mg_busy, mg_done;
    wire        mg_req = (!s_mg_rd_n || !s_mg_wr_n) && !mg_busy && !mg_done && !tl_cfg_v;
    always @(posedge uclk) begin
        if (u_rst) begin mg_busy <= 1'b0; mg_done <= 1'b0; end
        else begin
            mg_done <= mg_busy;
            mg_busy <= mg_req;
        end
    end
    assign CFGMGMTRDWRDONEN = !mg_done;
    assign CFGMGMTDO        = cfg_rd_data;

    wire        icpl_v, icpl_hasd, icpl_ack;
    wire [2:0]  icpl_status, icpl_tc;
    wire [31:0] icpl_data;
    wire [15:0] icpl_reqid;
    wire [7:0]  icpl_tag;
    wire [1:0]  icpl_attr;
    wire [6:0]  icpl_laddr;
    wire [11:0] icpl_bcnt;
    wire [7:0]  bus_num;
    wire [4:0]  dev_num;
    wire        msg_received, msg_pme_to, msg_unlock, msg_setslot;
    wire [15:0] msg_data;
    wire [7:0]  msg_code;
    wire [9:0]  msg_slot_pwr;
    wire        e_ur, e_ur_np, e_malformed, e_overflow, e_poisoned;
    wire        intx_state;

    eerie_cfg #(
        .CLASS_CODE(CLASS_CODE), .BAR0(BAR0), .BAR1(BAR1), .BAR2(BAR2), .BAR3(BAR3), .BAR4(BAR4), .BAR5(BAR5),
        .EXPANSION_ROM(EXPANSION_ROM), .CARDBUS_CIS_POINTER(CARDBUS_CIS_POINTER), .HEADER_TYPE(HEADER_TYPE),
        .INTERRUPT_PIN(INTERRUPT_PIN), .CAPABILITIES_PTR(CAPABILITIES_PTR), .CMD_INTX_IMPLEMENTED(CMD_INTX_IMPLEMENTED),
        .PM_CAP_ON(PM_CAP_ON), .PM_BASE_PTR(PM_BASE_PTR), .PM_CAP_NEXTPTR(PM_CAP_NEXTPTR), .PM_CAP_VERSION(PM_CAP_VERSION),
        .PM_CAP_PME_CLOCK(PM_CAP_PME_CLOCK), .PM_CAP_DSI(PM_CAP_DSI), .PM_CAP_AUXCURRENT(PM_CAP_AUXCURRENT),
        .PM_CAP_D1SUPPORT(PM_CAP_D1SUPPORT), .PM_CAP_D2SUPPORT(PM_CAP_D2SUPPORT), .PM_CAP_PMESUPPORT(PM_CAP_PMESUPPORT),
        .PM_CSR_NOSOFTRST(PM_CSR_NOSOFTRST), .PM_CSR_B2B3(PM_CSR_B2B3), .PM_CSR_BPCCEN(PM_CSR_BPCCEN),
        .PM_DATA({PM_DATA7, PM_DATA6, PM_DATA5, PM_DATA4, PM_DATA3, PM_DATA2, PM_DATA1, PM_DATA0}),
        .PM_DATA_SCALE({PM_DATA_SCALE7, PM_DATA_SCALE6, PM_DATA_SCALE5, PM_DATA_SCALE4,
                        PM_DATA_SCALE3, PM_DATA_SCALE2, PM_DATA_SCALE1, PM_DATA_SCALE0}),
        .MSI_CAP_ON(MSI_CAP_ON), .MSI_BASE_PTR(MSI_BASE_PTR), .MSI_CAP_NEXTPTR(MSI_CAP_NEXTPTR),
        .MSI_CAP_MULTIMSGCAP(MSI_CAP_MULTIMSGCAP), .MSI_CAP_64_BIT_ADDR_CAPABLE(MSI_CAP_64_BIT_ADDR_CAPABLE),
        .MSI_CAP_PER_VECTOR_MASKING_CAPABLE(MSI_CAP_PER_VECTOR_MASKING_CAPABLE),
        .MSIX_CAP_ON(MSIX_CAP_ON), .MSIX_BASE_PTR(MSIX_BASE_PTR), .MSIX_CAP_NEXTPTR(MSIX_CAP_NEXTPTR),
        .MSIX_CAP_TABLE_SIZE(MSIX_CAP_TABLE_SIZE), .MSIX_CAP_TABLE_BIR(MSIX_CAP_TABLE_BIR),
        .MSIX_CAP_TABLE_OFFSET(MSIX_CAP_TABLE_OFFSET), .MSIX_CAP_PBA_BIR(MSIX_CAP_PBA_BIR),
        .MSIX_CAP_PBA_OFFSET(MSIX_CAP_PBA_OFFSET),
        .PCIE_BASE_PTR(PCIE_BASE_PTR), .PCIE_CAP_NEXTPTR(PCIE_CAP_NEXTPTR),
        .PCIE_CAP_CAPABILITY_VERSION(PCIE_CAP_CAPABILITY_VERSION), .PCIE_CAP_DEVICE_PORT_TYPE(PCIE_CAP_DEVICE_PORT_TYPE),
        .PCIE_CAP_SLOT_IMPLEMENTED(PCIE_CAP_SLOT_IMPLEMENTED), .ROOT_CAP_CRS_SW_VISIBILITY(ROOT_CAP_CRS_SW_VISIBILITY),
        .DEV_CAP_MAX_PAYLOAD_SUPPORTED(DEV_CAP_MAX_PAYLOAD_SUPPORTED),
        .DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT(DEV_CAP_PHANTOM_FUNCTIONS_SUPPORT),
        .DEV_CAP_EXT_TAG_SUPPORTED(DEV_CAP_EXT_TAG_SUPPORTED),
        .DEV_CAP_ENDPOINT_L0S_LATENCY(DEV_CAP_ENDPOINT_L0S_LATENCY), .DEV_CAP_ENDPOINT_L1_LATENCY(DEV_CAP_ENDPOINT_L1_LATENCY),
        .DEV_CAP_ROLE_BASED_ERROR(DEV_CAP_ROLE_BASED_ERROR),
        .DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE(DEV_CAP_FUNCTION_LEVEL_RESET_CAPABLE),
        .DEV_CONTROL_EXT_TAG_DEFAULT(DEV_CONTROL_EXT_TAG_DEFAULT),
        .LINK_CAP_MAX_LINK_SPEED(LINK_CAP_MAX_LINK_SPEED), .LINK_CAP_MAX_LINK_WIDTH(LINK_CAP_MAX_LINK_WIDTH),
        .LINK_CAP_ASPM_SUPPORT(LINK_CAP_ASPM_SUPPORT),
        .LINK_CAP_L0S_EXIT_LATENCY_GEN1(LINK_CAP_L0S_EXIT_LATENCY_GEN1), .LINK_CAP_L0S_EXIT_LATENCY_GEN2(LINK_CAP_L0S_EXIT_LATENCY_GEN2),
        .LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN1(LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN1),
        .LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN2(LINK_CAP_L0S_EXIT_LATENCY_COMCLK_GEN2),
        .LINK_CAP_L1_EXIT_LATENCY_GEN1(LINK_CAP_L1_EXIT_LATENCY_GEN1), .LINK_CAP_L1_EXIT_LATENCY_GEN2(LINK_CAP_L1_EXIT_LATENCY_GEN2),
        .LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN1(LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN1),
        .LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN2(LINK_CAP_L1_EXIT_LATENCY_COMCLK_GEN2),
        .LINK_CAP_CLOCK_POWER_MANAGEMENT(LINK_CAP_CLOCK_POWER_MANAGEMENT),
        .LINK_CAP_SURPRISE_DOWN_ERROR_CAPABLE(LINK_CAP_SURPRISE_DOWN_ERROR_CAPABLE),
        .LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP(LINK_CAP_DLL_LINK_ACTIVE_REPORTING_CAP),
        .LINK_CAP_LINK_BANDWIDTH_NOTIFICATION_CAP(LINK_CAP_LINK_BANDWIDTH_NOTIFICATION_CAP),
        .LINK_CAP_ASPM_OPTIONALITY(LINK_CAP_ASPM_OPTIONALITY),
        .LINK_STATUS_SLOT_CLOCK_CONFIG(LINK_STATUS_SLOT_CLOCK_CONFIG),
        .LINK_CTRL2_TARGET_LINK_SPEED(LINK_CTRL2_TARGET_LINK_SPEED), .LINK_CTRL2_DEEMPHASIS(LINK_CTRL2_DEEMPHASIS),
        .CPL_TIMEOUT_RANGES_SUPPORTED(CPL_TIMEOUT_RANGES_SUPPORTED),
        .CPL_TIMEOUT_DISABLE_SUPPORTED(CPL_TIMEOUT_DISABLE_SUPPORTED),
        .DSN_CAP_ON(DSN_CAP_ON), .DSN_BASE_PTR(DSN_BASE_PTR), .DSN_CAP_NEXTPTR(DSN_CAP_NEXTPTR)
    ) cfg (
        // a root port keeps its configuration across link down; an endpoint's is reset by it
        .clk(uclk), .rst(DSP ? u_rst : u_lrst),
        .req_v(tl_cfg_v || mg_req), .req_wr(tl_cfg_v ? tl_cfg_wr : !s_mg_wr_n),
        .req_dwaddr(tl_cfg_v ? tl_cfg_a : s_mg_addr), .req_be(tl_cfg_v ? tl_cfg_be : ~s_mg_be_n),
        .req_wdata(tl_cfg_v ? tl_cfg_wd : s_mg_di),
        .req_rw1c_as_rw(!tl_cfg_v && !s_mg_rw1c_n), .req_ro_wr(!tl_cfg_v && !s_mg_ro_n),
        .rd_data(cfg_rd_data),
        .vend_id(s_vend_id), .dev_id(s_dev_id), .rev_id(s_rev_id), .subsys_vend_id(s_ssvid),
        .subsys_id(s_ssid), .dsn(s_dsn), .pciecap_int_msgnum(s_msgnum),
        .link_speed(u_rate ? 4'd2 : 4'd1), .link_width({2'b00, u_width}), .link_training(u_training), .dll_active(dl_up),
        .intx_status(intx_state), .trn_pending(!s_trnpend_n),
        .set_ur_detected(e_ur || !s_err_ur_n), .set_corr_detected(!s_err_cor_n || e_bad_tlp || e_bad_dllp || e_rto || e_rro),
        .set_nonfatal_detected(e_poisoned), .set_fatal_detected(e_malformed || e_overflow || e_dlp),
        .set_sig_target_abort(!s_err_abort_n), .set_rcv_master_abort(1'b0), .set_sig_sys_error(1'b0),
        .set_detected_parity(e_poisoned), .set_master_data_parity(1'b0), .set_rcv_target_abort(1'b0),
        .set_pme_status(1'b0), .slot_pwr_v(msg_setslot), .slot_pwr(msg_slot_pwr),
        .set_pme_req(DSP && msg_received && msg_code == 8'h18), .pme_req_id(msg_data),
        .lnk_retrain_clr(u_retrain_ack),
        .command(c_command), .status(c_status), .dev_control(c_devctl), .dev_status(c_devsts),
        .link_control(c_lnkctl), .link_status(c_lnksts), .dev_control2(c_devctl2), .link_control2(c_lnkctl2),
        .pm_power_state(c_pm_state), .pm_pme_en(c_pme_en), .pm_pme_status(c_pme_sts),
        .msi_enable(c_msi_en), .msi_mme(c_msi_mme), .msi_addr(c_msi_addr), .msi_data(c_msi_data),
        .msix_enable(c_msix_en), .msix_fmask(c_msix_fm), .int_line(c_int_line), .flr_pulse(flr_pulse),
        .bridge_control(c_brctl), .root_control(c_rootctl),
        .bar0(c_bar0), .bar1(c_bar1), .bar2(c_bar2), .bar3(c_bar3), .bar4(c_bar4), .bar5(c_bar5),
        .rom_bar(c_rom), .rom_en(c_rom_en)
    );

    eerie_tl_rx #(
        .RXB_AW(RXB_AW), .RXB_RLAT(RXB_RLAT),
        .BAR0(BAR0), .BAR1(BAR1), .BAR2(BAR2), .BAR3(BAR3), .BAR4(BAR4), .BAR5(BAR5), .EXPANSION_ROM(EXPANSION_ROM),
        .INIT_PH(VC0_TOTAL_CREDITS_PH), .INIT_PD(VC0_TOTAL_CREDITS_PD),
        .INIT_NPH(VC0_TOTAL_CREDITS_NPH), .INIT_NPD(VC0_TOTAL_CREDITS_NPD),
        .INIT_CPLH(VC0_TOTAL_CREDITS_CH), .INIT_CPLD(VC0_TOTAL_CREDITS_CD), .CPL_INFINITE(CPL_INF), .DSP(DSP)
    ) tl_rx (
        .clk(uclk), .rst(u_lrst),
        .tlrx_v(tlrx_v), .tlrx_d(tlrx_d), .tlrx_sop(tlrx_sop), .tlrx_half(tlrx_half), .tlrx_end(tlrx_end), .tlrx_ok(tlrx_ok),
        .rxb_we(MIMRXWEN), .rxb_waddr(MIMRXWADDR), .rxb_wdata(MIMRXWDATA),
        .rxb_re(MIMRXREN), .rxb_raddr(MIMRXRADDR), .rxb_rdata(MIMRXRDATA),
        .command(c_command), .bar0(c_bar0), .bar1(c_bar1), .bar2(c_bar2), .bar3(c_bar3), .bar4(c_bar4), .bar5(c_bar5),
        .rom_bar(c_rom), .rom_en(c_rom_en),
        .trn_rd(TRNRD[63:0]), .trn_rrem(TRNRREM[0]), .trn_rsof(TRNRSOF), .trn_reof(TRNREOF),
        .trn_rsrc_rdy(TRNRSRCRDY), .trn_rdst_rdy(TRNRDSTRDY), .trn_rerrfwd(TRNRERRFWD), .trn_rbar_hit(TRNRBARHIT),
        .cfg_req_v(tl_cfg_v), .cfg_req_wr(tl_cfg_wr), .cfg_req_dwaddr(tl_cfg_a), .cfg_req_be(tl_cfg_be),
        .cfg_req_wdata(tl_cfg_wd), .cfg_rd_data(cfg_rd_data), .bus_num(bus_num), .dev_num(dev_num),
        .icpl_v(icpl_v), .icpl_status(icpl_status), .icpl_hasd(icpl_hasd), .icpl_data(icpl_data),
        .icpl_reqid(icpl_reqid), .icpl_tag(icpl_tag), .icpl_tc(icpl_tc), .icpl_attr(icpl_attr),
        .icpl_laddr(icpl_laddr), .icpl_bcnt(icpl_bcnt), .icpl_ack(icpl_ack),
        .msg_received(msg_received), .msg_data(msg_data), .msg_code(msg_code), .msg_pme_to(msg_pme_to), .msg_unlock(msg_unlock),
        .msg_setslot(msg_setslot), .msg_slot_pwr(msg_slot_pwr),
        .err_ur(e_ur), .err_ur_np(e_ur_np), .err_malformed(e_malformed), .err_overflow(e_overflow), .err_poisoned(e_poisoned),
        .fc_ph(fc_ph), .fc_pd(fc_pd), .fc_nph(fc_nph), .fc_npd(fc_npd), .fc_cplh(fc_cplh), .fc_cpld(fc_cpld),
        .fc_upd_req(fc_upd_req)
    );
    assign TRNRD[127:64]  = 64'd0;
    assign TRNRREM[1]     = 1'b0;
    assign TRNRSRCDSC     = 1'b0;
    assign TRNRECRCERR    = 1'b0;

    // PME_Turn_Off -> PME_TO_Ack once the user agrees (CFGPMTURNOFFOKN)
    reg pme_to_pend, pme_ack_req;
    always @(posedge uclk) begin
        pme_ack_req <= 1'b0;
        if (u_lrst) pme_to_pend <= 1'b0;
        else if (msg_pme_to) pme_to_pend <= 1'b1;
        else if (pme_to_pend && !s_turnoff_n) begin pme_to_pend <= 1'b0; pme_ack_req <= 1'b1; end
    end
    reg pm_wake_d;
    always @(posedge uclk) pm_wake_d <= !s_pmwake_n;
    wire pm_pme_req = !s_pmwake_n && !pm_wake_d;

    wire tdst_rdy;
    wire int_rdy;
    wire [5:0] tbuf_av;
    eerie_tl_tx #(.INTERRUPT_PIN(INTERRUPT_PIN)) tl_tx (
        .clk(uclk), .rst(u_lrst), .dl_up(dl_up),
        .trn_td(TRNTD[63:0]), .trn_trem(TRNTREM[0]), .trn_tsof(TRNTSOF), .trn_teof(TRNTEOF), .trn_tsrc_rdy(TRNTSRCRDY),
        .trn_tsrc_dsc(TRNTSRCDSC), .trn_terrfwd(TRNTERRFWD),
        .trn_tdst_rdy(tdst_rdy), .trn_terr_drop(TRNTERRDROP), .trn_tbuf_av(tbuf_av), .trn_tcfg_req(TRNTCFGREQ),
        .trn_tcfg_gnt(s_tcfg_gnt),
        .txq_v(txq_v), .txq_d(txq_d), .txq_sop(txq_sop), .txq_eop(txq_eop), .txq_half(txq_half), .txq_abort(txq_abort),
        .txq_slots(txq_slots),
        .req_id(DSP ? s_ds_id : {bus_num, dev_num, 3'b000}), .command(c_command),
        .msi_enable(c_msi_en), .msi_mme(c_msi_mme), .msi_addr(c_msi_addr), .msi_data(c_msi_data),
        .icpl_v(icpl_v), .icpl_status(icpl_status), .icpl_hasd(icpl_hasd), .icpl_data(icpl_data),
        .icpl_reqid(icpl_reqid), .icpl_tag(icpl_tag), .icpl_tc(icpl_tc), .icpl_attr(icpl_attr),
        .icpl_laddr(icpl_laddr), .icpl_bcnt(icpl_bcnt), .icpl_ack(icpl_ack),
        .int_req(!s_int_n), .int_assert(!s_int_assert_n), .int_di(s_int_di),
        .int_rdy(int_rdy), .intx_state(intx_state),
        .pme_to_ack_req(pme_ack_req), .pm_pme_req(pm_pme_req)
    );
    assign TRNTDSTRDY  = {4{tdst_rdy}};
    assign TRNTBUFAV   = tbuf_av;

    // ------------------------------------------------------------------
    // configuration status outputs
    // ------------------------------------------------------------------
    assign CFGCOMMANDIOENABLE        = c_command[0];
    assign CFGCOMMANDMEMENABLE       = c_command[1];
    assign CFGCOMMANDBUSMASTERENABLE = c_command[2];
    assign CFGCOMMANDSERREN          = c_command[8];
    assign CFGCOMMANDINTERRUPTDISABLE = c_command[10];
    assign CFGBRIDGESERREN           = c_brctl[1];
    assign CFGDEVCONTROLCORRERRREPORTINGEN  = c_devctl[0];
    assign CFGDEVCONTROLNONFATALREPORTINGEN = c_devctl[1];
    assign CFGDEVCONTROLFATALERRREPORTINGEN = c_devctl[2];
    assign CFGDEVCONTROLURERRREPORTINGEN    = c_devctl[3];
    assign CFGDEVCONTROLENABLERO            = c_devctl[4];
    assign CFGDEVCONTROLMAXPAYLOAD          = c_devctl[7:5];
    assign CFGDEVCONTROLEXTTAGEN            = c_devctl[8];
    assign CFGDEVCONTROLPHANTOMEN           = c_devctl[9];
    assign CFGDEVCONTROLAUXPOWEREN          = c_devctl[10];
    assign CFGDEVCONTROLNOSNOOPEN           = c_devctl[11];
    assign CFGDEVCONTROLMAXREADREQ          = c_devctl[14:12];
    assign CFGDEVSTATUSCORRERRDETECTED      = c_devsts[0];
    assign CFGDEVSTATUSNONFATALERRDETECTED  = c_devsts[1];
    assign CFGDEVSTATUSFATALERRDETECTED     = c_devsts[2];
    assign CFGDEVSTATUSURDETECTED           = c_devsts[3];
    assign CFGDEVCONTROL2CPLTIMEOUTVAL      = c_devctl2[3:0];
    assign CFGDEVCONTROL2CPLTIMEOUTDIS      = c_devctl2[4];
    assign CFGDEVCONTROL2ARIFORWARDEN       = 1'b0;
    assign CFGDEVCONTROL2ATOMICREQUESTEREN  = 1'b0;
    assign CFGDEVCONTROL2ATOMICEGRESSBLOCK  = 1'b0;
    assign CFGDEVCONTROL2IDOREQEN           = 1'b0;
    assign CFGDEVCONTROL2IDOCPLEN           = 1'b0;
    assign CFGDEVCONTROL2LTREN              = 1'b0;
    assign CFGDEVCONTROL2TLPPREFIXBLOCK     = 1'b0;
    assign CFGLINKCONTROLASPMCONTROL        = c_lnkctl[1:0];
    assign CFGLINKCONTROLRCB                = c_lnkctl[3];
    assign CFGLINKCONTROLLINKDISABLE        = c_lnkctl[4];
    assign CFGLINKCONTROLRETRAINLINK        = c_lnkctl[5];
    assign CFGLINKCONTROLCOMMONCLOCK        = c_lnkctl[6];
    assign CFGLINKCONTROLEXTENDEDSYNC       = c_lnkctl[7];
    assign CFGLINKCONTROLCLOCKPMEN          = c_lnkctl[8];
    assign CFGLINKCONTROLHWAUTOWIDTHDIS     = c_lnkctl[9];
    assign CFGLINKCONTROLBANDWIDTHINTEN     = c_lnkctl[10];
    assign CFGLINKCONTROLAUTOBANDWIDTHINTEN = c_lnkctl[11];
    assign CFGLINKSTATUSCURRENTSPEED        = c_lnksts[1:0];
    assign CFGLINKSTATUSNEGOTIATEDWIDTH     = c_lnksts[7:4];
    assign CFGLINKSTATUSLINKTRAINING        = c_lnksts[11];
    assign CFGLINKSTATUSDLLACTIVE           = dl_up;
    assign CFGLINKSTATUSBANDWIDTHSTATUS     = 1'b0;
    assign CFGLINKSTATUSAUTOBANDWIDTHSTATUS = 1'b0;
    assign CFGPMCSRPOWERSTATE  = c_pm_state;
    assign CFGPMCSRPMEEN       = c_pme_en;
    assign CFGPMCSRPMESTATUS   = c_pme_sts;
    assign CFGPCIELINKSTATE    = u_in_l0 ? 3'b000 : 3'b100;
    assign CFGPMRCVASREQL1N    = 1'b1;
    assign CFGPMRCVENTERL1N    = 1'b1;
    assign CFGPMRCVENTERL23N   = 1'b1;
    assign CFGPMRCVREQACKN     = 1'b1;
    assign CFGINTERRUPTRDYN    = !int_rdy;
    assign CFGINTERRUPTDO      = c_msi_data[7:0];
    assign CFGINTERRUPTMMENABLE = c_msi_mme;
    assign CFGINTERRUPTMSIENABLE = c_msi_en;
    assign CFGINTERRUPTMSIXENABLE = c_msix_en;
    assign CFGINTERRUPTMSIXFM  = c_msix_fm;
    // CFGMSGDATA carries the captured bus/device number when no message is reported
    assign CFGMSGRECEIVED      = msg_received;
    assign CFGMSGDATA          = msg_received ? msg_data : {bus_num, dev_num, 3'b000};
    assign CFGMSGRECEIVEDPMETO = msg_pme_to;
    assign CFGMSGRECEIVEDUNLOCK = msg_unlock;
    assign CFGMSGRECEIVEDSETSLOTPOWERLIMIT = msg_setslot;
    // root port: messages from the link (requester ID on CFGMSGDATA in the same cycle)
    wire m_rp = DSP && msg_received;
    assign CFGMSGRECEIVEDASSERTINTA   = m_rp && msg_code == 8'h20;
    assign CFGMSGRECEIVEDASSERTINTB   = m_rp && msg_code == 8'h21;
    assign CFGMSGRECEIVEDASSERTINTC   = m_rp && msg_code == 8'h22;
    assign CFGMSGRECEIVEDASSERTINTD   = m_rp && msg_code == 8'h23;
    assign CFGMSGRECEIVEDDEASSERTINTA = m_rp && msg_code == 8'h24;
    assign CFGMSGRECEIVEDDEASSERTINTB = m_rp && msg_code == 8'h25;
    assign CFGMSGRECEIVEDDEASSERTINTC = m_rp && msg_code == 8'h26;
    assign CFGMSGRECEIVEDDEASSERTINTD = m_rp && msg_code == 8'h27;
    assign CFGMSGRECEIVEDERRCOR       = m_rp && msg_code == 8'h30;
    assign CFGMSGRECEIVEDERRNONFATAL  = m_rp && msg_code == 8'h31;
    assign CFGMSGRECEIVEDERRFATAL     = m_rp && msg_code == 8'h33;
    assign CFGMSGRECEIVEDPMASNAK      = m_rp && msg_code == 8'h14;
    assign CFGMSGRECEIVEDPMPME        = m_rp && msg_code == 8'h18;
    assign CFGMSGRECEIVEDPMETOACK     = m_rp && msg_code == 8'h1B;
    assign CFGTRANSACTION      = tl_cfg_v;
    assign CFGTRANSACTIONTYPE  = tl_cfg_wr;
    assign CFGTRANSACTIONADDR  = tl_cfg_a[6:0];
    assign CFGVCTCVCMAP        = 7'h7F;
    assign CFGERRCPLRDYN       = 1'b0;
    assign CFGERRAERHEADERLOGSETN = 1'b1;
    assign CFGAERECRCCHECKEN   = 1'b0;  assign CFGAERECRCGENEN = 1'b0;
    assign CFGAERROOTERRCORRERRRECEIVED = 1'b0;  assign CFGAERROOTERRCORRERRREPORTINGEN = 1'b0;
    assign CFGAERROOTERRFATALERRRECEIVED = 1'b0; assign CFGAERROOTERRFATALERRREPORTINGEN = 1'b0;
    assign CFGAERROOTERRNONFATALERRRECEIVED = 1'b0; assign CFGAERROOTERRNONFATALERRREPORTINGEN = 1'b0;
    assign CFGROOTCONTROLSYSERRCORRERREN = c_rootctl[0]; assign CFGROOTCONTROLSYSERRNONFATALERREN = c_rootctl[1];
    assign CFGROOTCONTROLSYSERRFATALERREN = c_rootctl[2]; assign CFGROOTCONTROLPMEINTEN = c_rootctl[3];
    assign CFGSLOTCONTROLELECTROMECHILCTLPULSE = 1'b0;

    // flow control information (TRNFCSEL: 0xx receive allocation, 1xx transmit available)
    assign TRNFCPH   = TRNFCSEL[2] ? lim_ph   - cons_ph   : fc_ph;
    assign TRNFCPD   = TRNFCSEL[2] ? lim_pd   - cons_pd   : fc_pd;
    assign TRNFCNPH  = TRNFCSEL[2] ? lim_nph  - cons_nph  : fc_nph;
    assign TRNFCNPD  = TRNFCSEL[2] ? lim_npd  - cons_npd  : fc_npd;
    assign TRNFCCPLH = TRNFCSEL[2] ? lim_cplh - cons_cplh : fc_cplh;
    assign TRNFCCPLD = TRNFCSEL[2] ? lim_cpld - cons_cpld : fc_cpld;

    assign TL2ASPMSUSPENDCREDITCHECKOK = 1'b0;
    assign TL2ASPMSUSPENDREQ = 1'b0;
    assign TL2ERRFCPE        = 1'b0;
    assign TL2ERRMALFORMED   = e_malformed;
    assign TL2ERRRXOVERFLOW  = e_overflow;
    assign TL2PPMSUSPENDOK   = 1'b0;
    assign TL2ERRHDR         = 64'd0;

    // ------------------------------------------------------------------
    // unused lanes / debug / DRP
    // ------------------------------------------------------------------
    assign PIPETX0DATA = a_txd[15:0];    assign PIPETX0CHARISK = a_txk[1:0];   assign PIPETX0ELECIDLE = a_txei[0];
    assign PIPETX1DATA = a_txd[31:16];   assign PIPETX1CHARISK = a_txk[3:2];   assign PIPETX1ELECIDLE = a_txei[1];
    assign PIPETX2DATA = a_txd[47:32];   assign PIPETX2CHARISK = a_txk[5:4];   assign PIPETX2ELECIDLE = a_txei[2];
    assign PIPETX3DATA = a_txd[63:48];   assign PIPETX3CHARISK = a_txk[7:6];   assign PIPETX3ELECIDLE = a_txei[3];
    assign PIPETX4DATA = a_txd[79:64];   assign PIPETX4CHARISK = a_txk[9:8];   assign PIPETX4ELECIDLE = a_txei[4];
    assign PIPETX5DATA = a_txd[95:80];   assign PIPETX5CHARISK = a_txk[11:10]; assign PIPETX5ELECIDLE = a_txei[5];
    assign PIPETX6DATA = a_txd[111:96];  assign PIPETX6CHARISK = a_txk[13:12]; assign PIPETX6ELECIDLE = a_txei[6];
    assign PIPETX7DATA = a_txd[127:112]; assign PIPETX7CHARISK = a_txk[15:14]; assign PIPETX7ELECIDLE = a_txei[7];
    assign PIPERX0POLARITY = a_rxpol[0]; assign PIPERX1POLARITY = a_rxpol[1]; assign PIPERX2POLARITY = a_rxpol[2];
    assign PIPERX3POLARITY = a_rxpol[3]; assign PIPERX4POLARITY = a_rxpol[4]; assign PIPERX5POLARITY = a_rxpol[5];
    assign PIPERX6POLARITY = a_rxpol[6]; assign PIPERX7POLARITY = a_rxpol[7];
    assign PIPETX1COMPLIANCE = 1'b0; assign PIPETX2COMPLIANCE = 1'b0; assign PIPETX3COMPLIANCE = 1'b0;
    assign PIPETX4COMPLIANCE = 1'b0; assign PIPETX5COMPLIANCE = 1'b0; assign PIPETX6COMPLIANCE = 1'b0;
    assign PIPETX7COMPLIANCE = 1'b0;
    // lanes outside the link are in P1 like the electrical idle lanes of the hard block
    assign PIPETX1POWERDOWN = (NL > 1) ? p_powerdown : 2'b10; assign PIPETX2POWERDOWN = (NL > 2) ? p_powerdown : 2'b10;
    assign PIPETX3POWERDOWN = (NL > 3) ? p_powerdown : 2'b10; assign PIPETX4POWERDOWN = (NL > 4) ? p_powerdown : 2'b10;
    assign PIPETX5POWERDOWN = (NL > 5) ? p_powerdown : 2'b10; assign PIPETX6POWERDOWN = (NL > 6) ? p_powerdown : 2'b10;
    assign PIPETX7POWERDOWN = (NL > 7) ? p_powerdown : 2'b10;

    reg drp_rdy;
    always @(posedge DRPCLK) drp_rdy <= DRPEN;
    assign DRPRDY = drp_rdy;
    assign DRPDO  = 16'd0;
    // DBGVECA (pclk, sticky since configuration): PIPE receive / receiver detection status for
    // hardware bring-up. Lane l (0..3) in [8l+7:8l]: {phystatus seen while TxDetectRx, last nonzero
    // RxStatus[2:0], RxStatus 011 (receiver present) seen while TxDetectRx, RxValid seen,
    // RxElecIdle low seen, RxElecIdle now}; [32] TxDetectRx seen, [34:33] PowerDown now,
    // [47:40] TxDetectRx assertions (mod 256), [53:48] LTSSM state
    wire [7:0] a_phys = {PIPERX7PHYSTATUS, PIPERX6PHYSTATUS, PIPERX5PHYSTATUS, PIPERX4PHYSTATUS,
                         PIPERX3PHYSTATUS, PIPERX2PHYSTATUS, PIPERX1PHYSTATUS, PIPERX0PHYSTATUS};
    reg  [63:0] dbg = 64'd0;
    reg         dbg_det_q = 1'b0;
    integer     dl;
    always @(posedge pclk) begin
        dbg_det_q <= PIPETXRCVRDET;
        for (dl = 0; dl < 4; dl = dl + 1) begin
            dbg[8*dl]   <= a_rxei[dl];
            if (!a_rxei[dl]) dbg[8*dl+1] <= 1'b1;
            if (a_rxv[dl]) dbg[8*dl+2] <= 1'b1;
            if (PIPETXRCVRDET && a_rxst[3*dl +: 3] == 3'b011) dbg[8*dl+3] <= 1'b1;
            if (a_rxst[3*dl +: 3] != 3'b000) dbg[8*dl+4 +: 3] <= a_rxst[3*dl +: 3];
            if (PIPETXRCVRDET && a_phys[dl]) dbg[8*dl+7] <= 1'b1;
        end
        if (PIPETXRCVRDET) dbg[32] <= 1'b1;
        dbg[34:33] <= p_powerdown;
        if (PIPETXRCVRDET && !dbg_det_q) dbg[47:40] <= dbg[47:40] + 1'b1;
        dbg[53:48] <= p_ltssm;
    end
    assign DBGVECA = dbg;
`ifdef EERIE_DBGCNT
    // TASK-6184 (uclk pulses): [0] TLP accepted, [1] duplicate TLP, [2] Ack sent, [3] Nak sent, [4] bad TLP (LCRC/framing),
    // [5] bad DLLP, [6] own replay timeout, [7] own REPLAY_NUM rollover
`ifdef EERIE_ILA
    // TASK-6190: [59:8] eerie_dll ILA probes
    assign DBGVECB = {4'd0, dl_ila, e_rro, e_rto, e_bad_dllp, e_bad_tlp, dl_dbg_ev[2:1], dl_dbg_ev[0], tlrx_end && tlrx_ok};
`else
    assign DBGVECB = {56'd0, e_rro, e_rto, e_bad_dllp, e_bad_tlp, dl_dbg_ev[2:1], dl_dbg_ev[0], tlrx_end && tlrx_ok};
`endif
`else
    assign DBGVECB = 64'd0;
`endif
    assign DBGVECC = 12'd0;
    assign DBGSCLRA = 1'b0; assign DBGSCLRB = 1'b0; assign DBGSCLRC = 1'b0; assign DBGSCLRD = 1'b0;
    assign DBGSCLRE = 1'b0; assign DBGSCLRF = 1'b0; assign DBGSCLRG = 1'b0; assign DBGSCLRH = 1'b0;
    assign DBGSCLRI = 1'b0; assign DBGSCLRJ = 1'b0; assign DBGSCLRK = 1'b0;
endmodule
