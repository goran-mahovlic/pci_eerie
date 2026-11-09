// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: Link Training and Status State Machine (x1, Gen1/Gen2)
//
// Upstream port (endpoint), or downstream port (DSP = 1, root port): the downstream port
// assigns link and lane number 0 in Configuration, changes to 5.0 GT/s on its own after the
// link comes up (when both sides support it and the target link speed allows it), and is
// the side that directs Retrain, Hot Reset and Disable.
//
// Lanes (NL > 1): the state machine runs on lane 0's ordered sets; per-lane bookkeeping finds
// the lanes with a receiver (Detect) and a working TS stream (Polling), and the link width in
// Configuration: the downstream port takes the lanes that echo its link number and assigns lane
// numbers 0..W-1; the upstream port echoes them on its lanes (W at most MAXW, lanes outside the
// link send PAD and then go to electrical idle). No lane reversal: lane 0 is lane 0.
//
// State encodings follow the PCIE_2_1 pl_ltssm_state[5:0] values (pg054).
`timescale 1ns / 1ps
module eerie_ltssm #(
    parameter MAX_RATE   = 1,       // 1: 2.5 GT/s, 2: 5.0 GT/s
    parameter FAST_TRAIN = 0,       // shorten timers for simulation
    parameter [7:0] N_FTS_GEN1 = 8'd255,
    parameter [7:0] N_FTS_GEN2 = 8'd255,
    parameter       UPCONFIG   = 1,      // advertise Link Upconfigure Capability (TS2 symbol 4 bit 6)
    parameter       DSP        = 0,      // downstream port (root port)
    parameter       NL         = 1,      // lanes
    parameter       MAXW       = 1       // widest link width used (1, 2, 4)
) (
    input             clk,
    input             rst,

    // PIPE control
    output reg        pipe_txdetectrx,
    output reg [1:0]  pipe_powerdown,
    output reg        pipe_rate,
    output reg [NL-1:0] pipe_rxpolarity,
    input             i_pipe_phystatus,
    input      [2:0]  i_pipe_rxstatus,
    input             i_pipe_rxelecidle,

    // TX path control
    output reg [2:0]  tx_mode,
    output reg [7:0]  tx_link,
    output reg        tx_link_pad,
    output reg [7:0]  tx_lane,
    output reg        tx_lane_pad,
    output     [7:0]  tx_nfts,
    output reg [7:0]  tx_rate,
    output reg [7:0]  tx_ctrl,
    input             tx_ts_done,
    input             tx_eios_done,
    input             tx_idle_pair,
    input             tx_busy,
    output reg        scramble_en,
    output reg        eieos_clr,

    // RX ordered-set events
    input             i_os_ts_valid,
    input             i_os_ts2,
    input             i_os_ts_inv,
    input      [7:0]  i_os_link,
    input             i_os_link_pad,
    input      [7:0]  i_os_lane,
    input             i_os_lane_pad,
    input      [7:0]  i_os_nfts,
    input      [7:0]  i_os_rate,
    input      [7:0]  i_os_ctrl,
    input             i_os_eios,
    input             i_os_idle2,
    // per-lane TS reception and receiver detection (lane l in bit l / byte l)
    input  [NL-1:0]   ml_ts_valid,
    input  [NL-1:0]   ml_ts2,
    input  [NL-1:0]   ml_ts_inv,
    input  [8*NL-1:0] ml_link,
    input  [NL-1:0]   ml_link_pad,
    input  [8*NL-1:0] ml_lane,
    input  [NL-1:0]   ml_lane_pad,
    input  [3*NL-1:0] ml_rxstatus,
    // per-lane TS fields to transmit, lanes that transmit, link width
    output reg [8*NL-1:0] tx_lane_v,
    output reg [NL-1:0]   tx_lane_pad_v,
    output reg [NL-1:0]   tx_link_pad_v,
    output reg [NL-1:0]   lane_en,
    output reg [3:0]      link_width,

    // upper layer interface
    input             retrain_req,       // pulse: go to Recovery (e.g. REPLAY_NUM rollover)
    // downstream port controls (ignored for an upstream port)
    input             dsp_retrain,       // level: Retrain Link requested (until dsp_retrain_ack)
    input             dsp_hot_reset,     // level: send Hot Reset (Secondary Bus Reset)
    input             dsp_disable,       // level: Link Disable
    input             dsp_target_gen2,   // level: target link speed >= 5.0 GT/s
    input             dsp_dl_up,         // level: data link layer up (speed change starts after it)
    output reg        dsp_retrain_ack,   // pulse: the Retrain Link request was taken
    output reg        link_up,           // LinkUp (to the DLL)
    output reg        in_l0,
    output reg [5:0]  ltssm_state,
    output reg        hot_reset,         // in Hot Reset (upstream: received)
    output reg        link_training,
    output reg        partner_gen2,      // partner advertised 5.0 GT/s
    output reg [7:0]  link_num,
    output reg        rcvr_err_ltssm     // unused hook
);
    localparam M_EIDLE = 3'd0, M_TS1 = 3'd1, M_TS2 = 3'd2, M_DATA = 3'd3, M_EIOS = 3'd4,
               M_IDLE = 3'd5;   // M_IDLE: logical idle only (Configuration.Idle / Recovery.Idle)

    localparam ST_DQUIET = 6'h00, ST_DACTIVE = 6'h02, ST_PACTIVE = 6'h04, ST_PCONFIG = 6'h05,
               ST_CLWSTART = 6'h0B, ST_CLWACCEPT = 6'h0D, ST_CLNWAIT = 6'h0F, ST_CLNACCEPT = 6'h10,
               ST_CCOMPLETE = 6'h11, ST_CIDLE = 6'h15, ST_L0 = 6'h16,
               ST_RLOCK = 6'h1C, ST_RCFG = 6'h1D, ST_RSPEED = 6'h1E, ST_RIDLE = 6'h20,
               ST_HOTRST = 6'h21, ST_DISABLED = 6'h22;

    // GT status outputs arrive late in the clock period: register them first
    reg        pipe_phystatus, pipe_rxelecidle;
    reg [2:0]  pipe_rxstatus;
    reg [3*NL-1:0] ml_rxst_q;    // per-lane RX status, registered like pipe_rxstatus
    always @(posedge clk) begin
        pipe_phystatus <= i_pipe_phystatus; pipe_rxstatus <= i_pipe_rxstatus; pipe_rxelecidle <= i_pipe_rxelecidle;
        ml_rxst_q <= ml_rxstatus;
    end

    // ---------------- timers ----------------
    // pclk is 125 MHz at 2.5 GT/s and 250 MHz at 5.0 GT/s (2 symbols / clock)
    reg [7:0]  us_div;
    reg        us_tick;
    reg [15:0] t_us;            // microseconds since state entry
    reg        t_clr;
    always @(posedge clk) begin
        us_tick <= 1'b0;
        if (rst || t_clr) begin
            us_div <= 8'd0; t_us <= 16'd0;
        end else if (us_div == (pipe_rate ? 8'd249 : 8'd124)) begin
            us_div <= 8'd0; us_tick <= 1'b1;
            if (t_us != 16'hFFFF) t_us <= t_us + 1'b1;
        end else us_div <= us_div + 1'b1;
    end
    // nanosecond-ish counter for short electrical idle windows
    reg [11:0] t_cyc;
    reg        ei_time_ok;   // registered: minimum electrical idle time in Recovery.Speed elapsed
    reg [2:0]  sub_d;
    reg        rs_go;        // registered: leave Recovery.Speed

    function [15:0] tmo;     // timeout in us; FAST_TRAIN shrinks the long ones
        input [15:0] ms_val; // value in ms*1000 (i.e. microseconds)
        input [15:0] fast_us;
        tmo = FAST_TRAIN ? fast_us : ms_val;
    endfunction

    localparam [15:0] T_12MS = 16'd12000, T_24MS = 16'd24000, T_48MS = 16'd48000,
                      T_2MS = 16'd2000, T_1MS = 16'd1000;

    // registered timeout flags (valid from the second clock after a state change)
    reg r_to1, r_to2, r_to20, r_to100, r_to1000, r_to12, r_to24, r_to48, r_to2ms, r_tohot, r_to24p;
    reg t_clr_d;
    always @(posedge clk) begin
        t_clr_d  <= t_clr;
        r_to1    <= !t_clr && t_us >= 16'd1;
        r_to2    <= !t_clr && t_us >= 16'd2;
        r_to20   <= !t_clr && t_us >= 16'd20;
        r_to100  <= !t_clr && t_us >= 16'd100;
        r_to1000 <= !t_clr && t_us >= 16'd1000;
        r_to12   <= !t_clr && t_us >= tmo(T_12MS, 16'd2);
        r_to24   <= !t_clr && t_us >= tmo(T_24MS, 16'd400);
        // Polling.Active timeout: with fast training short enough that lanes without a partner
        // (simulation GT models report a receiver on every lane) are dropped before the
        // partner's Polling.Configuration times out
        r_to24p  <= !t_clr && t_us >= tmo(T_24MS, 16'd64);
        r_to48   <= !t_clr && t_us >= tmo(T_48MS, 16'd800);
        r_to2ms  <= !t_clr && t_us >= tmo(T_2MS, 16'd200);
        r_tohot  <= !t_clr && t_us >= tmo(T_2MS, 16'd20);
    end
    wire to_ok   = !t_clr && !t_clr_d;
    wire to1     = r_to1 && to_ok,    to2   = r_to2 && to_ok,   to20 = r_to20 && to_ok;
    wire to100   = r_to100 && to_ok,  to1000 = r_to1000 && to_ok;
    wire to12    = r_to12 && to_ok,   to24  = r_to24 && to_ok,  to48 = r_to48 && to_ok;
    wire to2ms   = r_to2ms && to_ok,  tohot = r_tohot && to_ok,  to24p = r_to24p && to_ok;

    // ---------------- state ----------------
    reg [5:0]  st;
    reg [2:0]  sub;
    reg [10:0] ts_tx_cnt;        // TS sent (in state)
    reg [5:0]  tx_after;         // TS / idle sent after first qualifying receive
    reg        rx_first;         // received first qualifying TS / idle
    reg [3:0]  cnt_a, cnt_b;     // consecutive receive counters
    reg [7:0]  rx_rate_rec;
    reg        directed_speed_change, changed_speed_recovery, successful_speed_neg;
    reg        idle_to_rlock;
    reg        rx_ei_seen;
    reg        rx_ts2_seen;
    reg        cur_gen2;
    reg [7:0]  lane_num;
    reg [7:0]  lane_at_entry;
    reg        rate_target;
    reg        hot_from_rx;
    reg        dis_scr_seen;
    reg        spd_tried;        // downstream port: autonomous speed change done for this link up
    // per-lane bookkeeping
    reg [NL-1:0]  det_m;          // receiver detected
    reg [NL-1:0]  act_m;          // lanes that completed Polling
    reg [NL-1:0]  echo_m;         // lanes taking part in link width negotiation
    reg [3:0]     lc [0:NL-1];    // per-lane consecutive TS counters
    reg [7:0]     rxl [0:NL-1];   // last received lane number
    reg [NL-1:0]  rxl_pad;        // last received lane number was PAD
    reg [NL-1:0]  m_tsv, m_ts2, m_inv, m_lpad, m_npad, m_link0, m_linkeq;
    reg [7:0]     m_lane [0:NL-1];
    reg [3:0]     cfg_w;          // link width being negotiated
    reg [5:0]     clw_wait;       // TS sent since lane 0 qualified (downstream Linkwidth.Start)
    integer       li;
    // widest x1/x2/x4 (<= MAXW) whose lanes 0..W-1 are all set in m
    function [3:0] f_width; input [NL-1:0] m;
        begin
            f_width = 4'd1;
            if (MAXW >= 2 && NL >= 2 && m[0] && m[1 % NL]) f_width = 4'd2;
            if (MAXW >= 4 && NL >= 4 && m[0] && m[1 % NL] && m[2 % NL] && m[3 % NL]) f_width = 4'd4;
        end
    endfunction
    reg        dsp_hot_q, dsp_dis_q, dsp_tgt_q, dsp_dl_q, dsp_rt_q, rt_taken;

    wire [7:0] my_rates = (MAX_RATE >= 2) ? 8'h06 : 8'h02;
    // symbol 4 bit 6: Link Upconfigure Capability in Configuration TS2s, selectable
    // de-emphasis (-3.5 dB) in Recovery; set like the PCIE_2_1 block does
    wire [7:0] my_rates_b6 = my_rates | (UPCONFIG ? 8'h40 : 8'h00);
    assign tx_nfts = cur_gen2 ? N_FTS_GEN2 : N_FTS_GEN1;

    // received ordered-set events, registered together with their classification
    reg        os_ts_valid, os_ts2, os_ts_inv, os_link_pad, os_lane_pad, os_eios, os_idle2;
    reg [7:0]  os_link, os_lane, os_nfts, os_rate, os_ctrl;
    reg        ts1, ts2, ts_padpad, ts_match;
    reg        ts_link_eq, ts_lane_eq, ts_lane_eq_entry;   // vs link_num / lane_num / lane_at_entry
    always @(posedge clk) begin
        os_ts_valid <= i_os_ts_valid && !rst; os_eios <= i_os_eios && !rst; os_idle2 <= i_os_idle2 && !rst;
        os_ts2 <= i_os_ts2; os_ts_inv <= i_os_ts_inv; os_link_pad <= i_os_link_pad; os_lane_pad <= i_os_lane_pad;
        os_link <= i_os_link; os_lane <= i_os_lane; os_nfts <= i_os_nfts; os_rate <= i_os_rate; os_ctrl <= i_os_ctrl;
        ts1 <= i_os_ts_valid && !i_os_ts2 && !rst;
        ts2 <= i_os_ts_valid && i_os_ts2 && !rst;
        ts_padpad <= i_os_link_pad && i_os_lane_pad;
        ts_match  <= !i_os_link_pad && !i_os_lane_pad && i_os_link == link_num && i_os_lane == lane_num;
        ts_link_eq <= (i_os_link == link_num);
        ts_lane_eq <= (i_os_lane == lane_num);
        ts_lane_eq_entry <= (i_os_lane == lane_at_entry);
        for (li = 0; li < NL; li = li + 1) begin
            m_tsv[li]  <= ml_ts_valid[li] && !rst;
            m_ts2[li]  <= ml_ts2[li]; m_inv[li] <= ml_ts_inv[li];
            m_lpad[li] <= ml_link_pad[li]; m_npad[li] <= ml_lane_pad[li];
            m_link0[li] <= (ml_link[8*li +: 8] == 8'd0);
            m_linkeq[li] <= (ml_link[8*li +: 8] == link_num);
            m_lane[li] <= ml_lane[8*li +: 8];
        end
    end
    wire rx_spd_chg  = os_rate[7];
    wire rx_gen2     = os_rate[2];
    wire both_gen2   = (MAX_RATE >= 2) && rx_gen2;

    // state change; the per-state counters are cleared one clock later from the
    // registered t_clr (keeps the deep transition conditions off their reset cones)
    task goto;
        input [5:0] s;
        begin
            st <= s; sub <= 3'd0; t_clr <= 1'b1;
        end
    endtask

    // registered threshold flags (one clock behind the counters; the counters only move
    // on received/transmitted ordered sets, many clocks apart)
    reg a_ge2, a_ge4, a_ge8, b_ge2, b_ge8, ta_ge8, ta_ge16, ta_ge32, ts_ge1024, ts_ge64;
    always @(posedge clk) begin
        a_ge2 <= cnt_a >= 4'd2; a_ge4 <= cnt_a >= 4'd4; a_ge8 <= cnt_a >= 4'd8;
        b_ge2 <= cnt_b >= 4'd2; b_ge8 <= cnt_b >= 4'd8;
        ta_ge8 <= tx_after >= 6'd8; ta_ge16 <= tx_after >= 6'd16; ta_ge32 <= tx_after >= 6'd32;
        ts_ge1024 <= ts_tx_cnt >= 11'd1024; ts_ge64 <= ts_tx_cnt >= 11'd64;
    end
    wire cnt_fresh = !t_clr && !t_clr_d;     // counters were cleared on state entry
    // per-lane conditions
    reg [NL-1:0] lc_ge1, lc_ge2, pol_ok;
    always @(*) for (li = 0; li < NL; li = li + 1) begin
        lc_ge1[li] = (lc[li] >= 4'd1); lc_ge2[li] = (lc[li] >= 4'd2);
        pol_ok[li] = (li == 0) ? a_ge8 : (lc[li] >= 4'd8);
    end
    wire [NL-1:0] LANE0 = 1;
    wire all_det_ok = &(~det_m | pol_ok);
    wire echo_ok    = &(~act_m | lc_ge2);
    wire [NL-1:0] wmask = (cfg_w >= 4'd4) ? {NL{1'b1}} >> (NL > 4 ? NL - 4 : 0) :
                          (cfg_w >= 4'd2) ? {{NL{1'b0}}, 2'b11} : {{NL{1'b0}}, 1'b1};
    // registered Recovery.RcvrCfg rate decisions (rx_rate_rec only changes on received TS)
    reg  rr_spd, rr_nospd;
    always @(posedge clk) begin
        rr_spd   <= rx_rate_rec[7] && (cur_gen2 || ((MAX_RATE >= 2) && rx_rate_rec[2]));
        rr_nospd <= !rx_rate_rec[7] || (!cur_gen2 && !((MAX_RATE >= 2) && rx_rate_rec[2]));
    end

    // saturating increment helpers
    function [3:0] inc4(input [3:0] v); inc4 = (v == 4'hF) ? v : v + 1'b1; endfunction

    always @(posedge clk) begin
        dsp_hot_q <= DSP && dsp_hot_reset; dsp_dis_q <= DSP && dsp_disable;
        dsp_tgt_q <= DSP && dsp_target_gen2; dsp_dl_q <= DSP && dsp_dl_up;
        dsp_rt_q  <= DSP && dsp_retrain;
    end

    always @(posedge clk) begin
        t_clr <= 1'b0;
        eieos_clr <= 1'b0;
        if (rst) begin
            st <= ST_DQUIET; sub <= 3'd0; t_clr <= 1'b1;
            pipe_txdetectrx <= 1'b0; pipe_powerdown <= 2'b10; pipe_rate <= 1'b0; pipe_rxpolarity <= {NL{1'b0}};
            tx_mode <= M_EIDLE; tx_link <= 8'd0; tx_link_pad <= 1'b1; tx_lane <= 8'd0; tx_lane_pad <= 1'b1;
            tx_rate <= my_rates; tx_ctrl <= 8'd0; scramble_en <= 1'b1;
            link_up <= 1'b0; in_l0 <= 1'b0; ltssm_state <= ST_DQUIET; hot_reset <= 1'b0; link_training <= 1'b0;
            partner_gen2 <= 1'b0; link_num <= 8'd0; lane_num <= 8'd0; rcvr_err_ltssm <= 1'b0;
            ts_tx_cnt <= 11'd0; tx_after <= 6'd0; rx_first <= 1'b0; cnt_a <= 4'd0; cnt_b <= 4'd0;
            directed_speed_change <= 1'b0; changed_speed_recovery <= 1'b0; successful_speed_neg <= 1'b0;
            idle_to_rlock <= 1'b0; rx_ei_seen <= 1'b0; rx_ts2_seen <= 1'b0; cur_gen2 <= 1'b0; t_cyc <= 12'd0;
            rate_target <= 1'b0; hot_from_rx <= 1'b0; dis_scr_seen <= 1'b0; rx_rate_rec <= 8'd0;
            spd_tried <= 1'b0; dsp_retrain_ack <= 1'b0; rt_taken <= 1'b0;
            det_m <= {NL{1'b0}}; act_m <= {NL{1'b0}}; echo_m <= {NL{1'b0}}; rxl_pad <= {NL{1'b1}};
            cfg_w <= 4'd1; link_width <= 4'd1; clw_wait <= 6'd0; lane_en <= {NL{1'b0}};
            tx_lane_v <= {8*NL{1'b0}}; tx_lane_pad_v <= {NL{1'b1}}; tx_link_pad_v <= {NL{1'b1}};
            for (li = 0; li < NL; li = li + 1) begin lc[li] <= 4'd0; rxl[li] <= 8'd0; end
        end else begin
            dsp_retrain_ack <= 1'b0;
            if (!dsp_rt_q) rt_taken <= 1'b0;
            ltssm_state <= st;
            sub_d <= sub;
            rs_go <= ei_time_ok && sub_d == 3'd4 && sub == 3'd4 && st == ST_RSPEED;
            ei_time_ok <= (successful_speed_neg && t_cyc >= (pipe_rate ? 12'd200 : 12'd100)) ||
                          (!successful_speed_neg && t_cyc >= (pipe_rate ? 12'd1500 : 12'd750));
            in_l0 <= (st == ST_L0);
            hot_reset <= (st == ST_HOTRST);
            link_training <= (st >= ST_CLWSTART && st <= ST_CIDLE) || (st >= ST_RLOCK && st <= ST_RIDLE);
            if (t_cyc != 12'hFFF) t_cyc <= t_cyc + 1'b1;
            if (tx_ts_done) ts_tx_cnt <= (ts_tx_cnt == 11'h7FF) ? ts_tx_cnt : ts_tx_cnt + 1'b1;
            if (os_eios || pipe_rxelecidle) rx_ei_seen <= 1'b1;
            if (ts2) rx_ts2_seen <= 1'b1;
            if (tx_link_pad) ; // keep lint quiet

            case (st)
            // ------------------------------------------------------------ Detect
            ST_DQUIET: begin
                tx_mode <= M_EIDLE; pipe_powerdown <= 2'b10; pipe_txdetectrx <= 1'b0;
                link_up <= 1'b0; directed_speed_change <= 1'b0; idle_to_rlock <= 1'b0;
                changed_speed_recovery <= 1'b0; pipe_rxpolarity <= {NL{1'b0}}; scramble_en <= 1'b1;
                lane_en <= {NL{1'b0}}; cfg_w <= 4'd1; link_width <= 4'd1;
                rxl_pad <= {NL{1'b1}}; echo_m <= {NL{1'b0}};
                tx_link_pad <= 1'b1; tx_lane_pad <= 1'b1; tx_ctrl <= 8'd0; partner_gen2 <= 1'b0;
                tx_link_pad_v <= {NL{1'b1}}; tx_lane_pad_v <= {NL{1'b1}};
                spd_tried <= 1'b0;
                case (sub)
                3'd0: begin
                    if (pipe_rate) begin
                        pipe_rate <= 1'b0; sub <= 3'd1;           // back to 2.5 GT/s
                    end else sub <= 3'd2;
                end
                3'd1: if (pipe_phystatus) begin sub <= 3'd2; t_clr <= 1'b1; end
                default: begin
                    cur_gen2 <= 1'b0;
                    if (to12 || (!pipe_rxelecidle && to1))
                        goto(ST_DACTIVE);
                end
                endcase
            end
            ST_DACTIVE: begin
                tx_mode <= M_EIDLE;
                case (sub)
                3'd0: begin pipe_txdetectrx <= 1'b1; sub <= 3'd1; end
                3'd1: if (pipe_phystatus) begin
                    pipe_txdetectrx <= 1'b0;
                    for (li = 0; li < NL; li = li + 1) det_m[li] <= (ml_rxst_q[3*li +: 3] == 3'b011);
                    if (pipe_rxstatus == 3'b011) begin
                        goto(ST_PACTIVE);
                    end else goto(ST_DQUIET);
                end else if (to1000) begin
                    pipe_txdetectrx <= 1'b0; goto(ST_DQUIET);
                end
                default: sub <= 3'd0;
                endcase
            end
            // ------------------------------------------------------------ Polling
            ST_PACTIVE: begin
                tx_link_pad <= 1'b1; tx_lane_pad <= 1'b1; tx_ctrl <= 8'd0; tx_rate <= my_rates;
                case (sub)
                3'd0: begin pipe_powerdown <= 2'b00; sub <= 3'd1; end    // P1 -> P0
                3'd1: if (pipe_phystatus) sub <= 3'd2;
                      else if (to100) sub <= 3'd2;
                default: begin
                    tx_mode <= M_TS1; lane_en <= det_m;
                    if (os_ts_valid) begin
                        if (os_ts_inv) pipe_rxpolarity[0] <= ~pipe_rxpolarity[0];
                        if (ts_padpad && (os_ts2 || !os_ctrl[4] || os_ctrl[2]) && !os_ts_inv)
                            cnt_a <= inc4(cnt_a);
                        else cnt_a <= 4'd0;
                    end
                    for (li = 1; li < NL; li = li + 1) if (m_tsv[li]) begin
                        if (m_inv[li]) pipe_rxpolarity[li] <= ~pipe_rxpolarity[li];
                        if (m_lpad[li] && m_npad[li] && !m_inv[li]) lc[li] <= inc4(lc[li]); else lc[li] <= 4'd0;
                    end
                    lc[0] <= cnt_a;
                    // all lanes with a receiver have a TS stream, or after the timeout the ones that do
                    if (a_ge8 && cnt_fresh && (FAST_TRAIN ? ts_ge64 : ts_ge1024) && all_det_ok) begin
                        act_m <= pol_ok; goto(ST_PCONFIG);
                    end else if (to24p) begin
                        if (a_ge8 && cnt_fresh) begin act_m <= pol_ok; goto(ST_PCONFIG); end
                        else goto(ST_DQUIET);
                    end
                end
                endcase
            end
            ST_PCONFIG: begin
                tx_mode <= M_TS2; lane_en <= act_m;
                if (ts2 && ts_padpad) begin cnt_a <= inc4(cnt_a); rx_first <= 1'b1; end
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (rx_first && tx_ts_done && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (a_ge8 && ta_ge16 && cnt_fresh) goto(ST_CLWSTART);
                else if (to48) goto(ST_DQUIET);
            end
            // ------------------------------------------------------------ Configuration
            ST_CLWSTART: if (DSP) begin
                // downstream: propose link number 0, lanes PAD; wait for the partner to echo it
                tx_mode <= M_TS1; tx_link <= 8'd0; tx_link_pad <= 1'b0; tx_lane_pad <= 1'b1; tx_rate <= my_rates;
                link_num <= 8'd0; lane_num <= 8'd0; lane_en <= act_m;
                tx_link_pad_v <= {NL{1'b0}}; tx_lane_pad_v <= {NL{1'b1}};
                if (ts1 && !os_link_pad && ts_link_eq && os_lane_pad) cnt_a <= inc4(cnt_a);
                else if (os_ts_valid) cnt_a <= 4'd0;
                for (li = 1; li < NL; li = li + 1) if (m_tsv[li]) begin
                    if (!m_ts2[li] && !m_lpad[li] && m_link0[li] && m_npad[li]) lc[li] <= inc4(lc[li]); else lc[li] <= 4'd0;
                end
                lc[0] <= cnt_a;
                if (a_ge2 && tx_ts_done && clw_wait != 6'h3F) clw_wait <= clw_wait + 1'b1;
                if (dsp_dis_q && ts_ge64) goto(ST_DISABLED);
                else if (a_ge2 && cnt_fresh && (echo_ok || clw_wait >= 6'd8)) begin
                    cfg_w <= f_width(act_m & lc_ge2); goto(ST_CLWACCEPT);
                end else if (to24) goto(ST_DQUIET);
            end else begin
                tx_mode <= M_TS1; tx_link_pad <= 1'b1; tx_lane_pad <= 1'b1; tx_rate <= my_rates;
                if (ts1 && !os_link_pad && os_lane_pad) begin
                    if (cnt_a != 0 && ts_link_eq) cnt_a <= inc4(cnt_a);
                    else cnt_a <= 4'd1;
                    link_num <= os_link;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && os_ctrl[1]) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                lane_en <= act_m;
                for (li = 1; li < NL; li = li + 1) if (m_tsv[li]) begin
                    if (!m_ts2[li] && !m_lpad[li] && m_npad[li]) lc[li] <= inc4(lc[li]); else lc[li] <= 4'd0;
                end
                if (b_ge2 && cnt_fresh) goto(ST_DISABLED);
                else if (a_ge2 && cnt_fresh) begin
                    tx_link <= link_num; tx_link_pad <= 1'b0;
                    echo_m <= act_m & (lc_ge1 | LANE0);
                    tx_link_pad_v <= ~(act_m & (lc_ge1 | LANE0));
                    goto(ST_CLWACCEPT);
                end else if (to24) goto(ST_DQUIET);
            end
            ST_CLWACCEPT: if (DSP) begin
                // downstream: assign lane number 0 to the (only) lane
                tx_mode <= M_TS1; tx_lane <= 8'd0; tx_lane_pad <= 1'b0; lane_at_entry <= 8'd0;
                for (li = 0; li < NL; li = li + 1) begin
                    tx_lane_v[8*li +: 8] <= li; tx_lane_pad_v[li] <= (li >= cfg_w); tx_link_pad_v[li] <= (li >= cfg_w);
                end
                goto(ST_CLNWAIT);
            end else begin
                tx_mode <= M_TS1;
                if (ts1 && !os_link_pad && ts_link_eq && !os_lane_pad) begin
                    if (cnt_a != 0 && ts_lane_eq) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd1;
                    lane_num <= os_lane;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && ts_padpad) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (a_ge2 && cnt_fresh) begin
                    tx_lane <= lane_num; tx_lane_pad <= 1'b0; lane_at_entry <= lane_num;
                    // width: the lanes that received a lane number (contiguous from lane 0, <= MAXW)
                    cfg_w <= f_width(echo_m & ~rxl_pad);
                    for (li = 0; li < NL; li = li + 1) begin
                        tx_lane_v[8*li +: 8] <= (li == 0) ? lane_num : rxl[li];
                        tx_lane_pad_v[li] <= (li >= f_width(echo_m & ~rxl_pad));
                        tx_link_pad_v[li] <= (li >= f_width(echo_m & ~rxl_pad));
                    end
                    goto(ST_CLNWAIT);
                end else if ((b_ge2 && cnt_fresh) || to2ms) goto(ST_DQUIET);
            end
            ST_CLNWAIT: if (DSP) begin
                // downstream: wait for TS1s that carry a lane number (the partner's echo)
                tx_mode <= M_TS1;
                if (ts1 && !os_link_pad && !os_lane_pad) cnt_a <= inc4(cnt_a);
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (a_ge2 && cnt_fresh) goto(ST_CLNACCEPT);
                else if (to2ms) goto(ST_DQUIET);
            end else begin
                tx_mode <= M_TS1;
                if (ts1 && !os_lane_pad && !ts_lane_eq_entry && !os_link_pad) cnt_a <= inc4(cnt_a);
                else if (ts2) cnt_a <= inc4(cnt_a);
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && ts_padpad) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (a_ge2 && cnt_fresh) goto(ST_CLNACCEPT);
                else if ((b_ge2 && cnt_fresh) || to2ms) goto(ST_DQUIET);
            end
            ST_CLNACCEPT: if (DSP) begin
                // downstream: two TS1s whose link and lane numbers match the transmitted ones
                tx_mode <= M_TS1;
                if (ts1 && ts_match) cnt_a <= inc4(cnt_a); else if (os_ts_valid) cnt_a <= 4'd0;
                if (a_ge2 && cnt_fresh) begin
                    if (f_width(~rxl_pad) < cfg_w) begin
                        // the partner answered PAD on some lanes: narrower link, assign again
                        cfg_w <= f_width(~rxl_pad);
                        for (li = 0; li < NL; li = li + 1) begin
                            tx_lane_pad_v[li] <= (li >= f_width(~rxl_pad)); tx_link_pad_v[li] <= (li >= f_width(~rxl_pad));
                        end
                        goto(ST_CLNWAIT);
                    end else goto(ST_CCOMPLETE);
                end else if (to2ms) goto(ST_DQUIET);
            end else begin
                tx_mode <= M_TS1;
                if (ts2 && ts_match) cnt_a <= inc4(cnt_a); else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && !os_link_pad && ts_link_eq && !os_lane_pad && !ts_lane_eq) begin
                    if (cnt_b != 0) cnt_b <= inc4(cnt_b); else cnt_b <= 4'd1;
                    lane_num <= os_lane;
                end else if (os_ts_valid && !(ts2 && ts_match)) cnt_b <= 4'd0;
                if (a_ge2 && cnt_fresh) goto(ST_CCOMPLETE);
                else if (b_ge2 && cnt_fresh) begin
                    tx_lane <= lane_num; lane_at_entry <= lane_num; goto(ST_CLNWAIT);
                end else if (to2ms) goto(ST_DQUIET);
            end
            ST_CCOMPLETE: begin
                tx_mode <= M_TS2; tx_rate <= my_rates_b6;
                if (ts2 && ts_match) begin
                    if (cnt_a != 0 && os_rate == rx_rate_rec) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd1;
                    rx_rate_rec <= os_rate;
                    rx_first <= 1'b1;
                    if (os_ctrl[3]) cnt_b <= inc4(cnt_b); else cnt_b <= 4'd0;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (rx_first && tx_ts_done && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (a_ge8 && ta_ge16 && cnt_fresh) begin
                    partner_gen2 <= rx_rate_rec[2];
                    if (b_ge2) scramble_en <= 1'b0;
                    changed_speed_recovery <= 1'b0;
                    goto(ST_CIDLE);
                end else if (to2ms) goto(ST_DQUIET);
            end
            ST_CIDLE: begin
                tx_mode <= M_IDLE; link_up <= 1'b1; link_width <= cfg_w;
                if (os_idle2) begin cnt_a <= inc4(cnt_a); rx_first <= 1'b1; end
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (rx_first && tx_idle_pair && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (a_ge4 && ta_ge8 && cnt_fresh) goto(ST_L0);
                else if (to2ms) begin
                    if (!idle_to_rlock) begin idle_to_rlock <= 1'b1; goto(ST_RLOCK); end
                    else goto(ST_DQUIET);
                end
            end
            // ------------------------------------------------------------ L0
            ST_L0: begin
                tx_mode <= M_DATA; link_up <= 1'b1; idle_to_rlock <= 1'b0;
                tx_ctrl <= 8'd0;
                if (os_ts_valid) begin
                    if (ts1 && os_rate[7] && both_gen2) ; // speed change request handled in RcvrLock
                    goto(ST_RLOCK);
                end else if (retrain_req) goto(ST_RLOCK);
                else if (dsp_rt_q && !rt_taken) begin
                    rt_taken <= 1'b1; dsp_retrain_ack <= 1'b1; goto(ST_RLOCK);
                end
                else if (dsp_hot_q || dsp_dis_q) goto(ST_RLOCK);   // via Recovery.Idle
                else if (DSP && !spd_tried && dsp_dl_q && to20 && dsp_tgt_q && partner_gen2 &&
                         (MAX_RATE >= 2) && !cur_gen2) begin
                    // downstream port: change to 5.0 GT/s once after the link came up
                    spd_tried <= 1'b1; directed_speed_change <= 1'b1;
                    goto(ST_RLOCK);
                end
            end
            // ------------------------------------------------------------ Recovery
            ST_RLOCK: begin
                tx_mode <= M_TS1; tx_link_pad <= 1'b0; tx_lane_pad <= 1'b0;
                rx_ei_seen <= 1'b0;            // collect the partner's EIOS from RcvrCfg on
                tx_link <= link_num; tx_lane <= lane_num;
                tx_rate <= {directed_speed_change, my_rates_b6[6:0]};
                successful_speed_neg <= 1'b0;
                if (os_ts_valid && ts_match) begin
                    rx_first <= 1'b1;
                    if (os_rate[7] == directed_speed_change) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd0;
                    if (ts1 && os_rate[7] && both_gen2) begin
                        cnt_b <= inc4(cnt_b);
                        if (cnt_b >= 4'd7 && !directed_speed_change) begin
                            directed_speed_change <= 1'b1; cnt_a <= 4'd0;
                        end
                    end else cnt_b <= 4'd0;
                end else if (os_ts_valid) begin
                    cnt_a <= 4'd0; cnt_b <= 4'd0;
                end
                if (a_ge8 && cnt_fresh) goto(ST_RCFG);
                else if (to24) begin
                    if (cur_gen2 && !changed_speed_recovery) begin
                        rate_target <= 1'b0; goto(ST_RSPEED);
                    end else if (changed_speed_recovery) begin
                        rate_target <= 1'b0; goto(ST_RSPEED);
                    end else if (rx_first) begin
                        directed_speed_change <= 1'b0; goto(ST_CLWSTART);
                    end else goto(ST_DQUIET);
                end
            end
            ST_RCFG: begin
                tx_mode <= M_TS2;
                tx_rate <= {directed_speed_change, my_rates_b6[6:0]};
                if (ts2 && ts_match) begin
                    if (cnt_a != 0 && os_rate == rx_rate_rec) cnt_a <= inc4(cnt_a); else cnt_a <= 4'd1;
                    rx_rate_rec <= os_rate;
                    if (!rx_ts2_seen) eieos_clr <= 1'b1;
                    if (!rx_first) rx_first <= 1'b1;
                end else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && !ts_match) cnt_b <= inc4(cnt_b); else if (os_ts_valid) cnt_b <= 4'd0;
                if (os_ts_valid && !rx_first) rx_first <= 1'b1;
                if (rx_first && tx_ts_done && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (hot_from_rx) ;
                if (a_ge8 && cnt_fresh && rr_spd && ta_ge32) begin
                    successful_speed_neg <= 1'b1;
                    partner_gen2 <= rx_rate_rec[2];
                    rate_target <= (MAX_RATE >= 2) && rx_rate_rec[2];
                    goto(ST_RSPEED);
                end else if (a_ge8 && cnt_fresh && rr_spd && os_eios) begin
                    // the partner already went to Recovery.Speed (it sent its 32 TS2s first)
                    successful_speed_neg <= 1'b1;
                    partner_gen2 <= rx_rate_rec[2];
                    rate_target <= (MAX_RATE >= 2) && rx_rate_rec[2];
                    goto(ST_RSPEED);
                end else if (a_ge8 && ta_ge16 && cnt_fresh && rr_nospd) begin
                    partner_gen2 <= rx_rate_rec[2];
                    directed_speed_change <= 1'b0; changed_speed_recovery <= 1'b0;
                    goto(ST_RIDLE);
                end else if (b_ge8 && ta_ge16 && cnt_fresh) begin
                    directed_speed_change <= 1'b0; changed_speed_recovery <= 1'b0;
                    goto(ST_CLWSTART);
                end else if (!rx_ts2_seen && (os_eios || (pipe_rxelecidle && to2)) &&
                             (changed_speed_recovery || cur_gen2)) begin
                    rate_target <= 1'b0; goto(ST_RSPEED);
                end else if (to48) goto(ST_DQUIET);
            end
            ST_RSPEED: begin
                directed_speed_change <= 1'b0;
                case (sub)
                3'd0: begin
                    // send EIOS (1 at 2.5 GT/s, 2 at 5 GT/s) then electrical idle
                    tx_mode <= M_EIOS; rx_ei_seen <= rx_ei_seen | os_eios;
                    if (tx_eios_done) begin
                        if (cnt_a >= (cur_gen2 ? 4'd1 : 4'd0)) begin tx_mode <= M_EIDLE; sub <= 3'd1; end
                        cnt_a <= inc4(cnt_a);
                    end
                end
                3'd1: begin
                    tx_mode <= M_EIDLE;
                    if (rx_ei_seen || to20) begin sub <= 3'd2; t_cyc <= 12'd0; end
                end
                3'd2: begin
                    if (pipe_rate != rate_target) begin
                        pipe_rate <= rate_target; sub <= 3'd3;
                    end else sub <= 3'd4;
                    t_cyc <= 12'd0;
                end
                3'd3: if (pipe_phystatus) begin sub <= 3'd4; t_cyc <= 12'd0; end
                default: begin
                    cur_gen2 <= pipe_rate;
                    // >= 800 ns after successful negotiation, >= 6 us otherwise
                    if (rs_go) begin
                        changed_speed_recovery <= successful_speed_neg ? 1'b1 : 1'b0;
                        rx_ei_seen <= 1'b0;
                        goto(ST_RLOCK);
                    end
                end
                endcase
                if (to48) goto(ST_DQUIET);
            end
            ST_RIDLE: begin
                tx_mode <= M_IDLE;
                if (os_idle2) begin cnt_a <= inc4(cnt_a); rx_first <= 1'b1; end
                else if (os_ts_valid) cnt_a <= 4'd0;
                if (ts1 && os_ctrl[0]) cnt_b <= inc4(cnt_b);
                else if (ts1 && os_lane_pad) cnt_b <= 4'd0;
                if (rx_first && tx_idle_pair && tx_after != 6'h3F) tx_after <= tx_after + 1'b1;
                if (dsp_hot_q) goto(ST_HOTRST);
                else if (dsp_dis_q) goto(ST_DISABLED);
                else if (b_ge2 && cnt_fresh) goto(ST_HOTRST);
                else if (ts1 && os_ctrl[1]) goto(ST_DISABLED);
                else if (ts1 && os_lane_pad) goto(ST_CLWSTART);
                else if (a_ge4 && ta_ge8 && cnt_fresh) goto(ST_L0);
                else if (to2ms) begin
                    if (!idle_to_rlock) begin idle_to_rlock <= 1'b1; goto(ST_RLOCK); end
                    else goto(ST_DQUIET);
                end
            end
            // ------------------------------------------------------------ Hot Reset / Disabled
            ST_HOTRST: begin
                link_up <= 1'b0;
                tx_mode <= M_TS1; tx_ctrl <= 8'h01;
                // upstream: stay while hot reset TS1s arrive; downstream: while directed
                if (DSP ? dsp_hot_q : (ts1 && os_ctrl[0])) t_clr <= 1'b1;
                if (tohot) begin tx_ctrl <= 8'd0; goto(ST_DQUIET); end
            end
            ST_DISABLED: if (DSP) begin
                // downstream: TS1s with the Disable Link bit, EIOS, then electrical idle while directed
                link_up <= 1'b0;
                case (sub)
                3'd0: begin tx_mode <= M_TS1; tx_ctrl <= 8'h02; if (ts_ge64) sub <= 3'd1; end
                3'd1: begin tx_mode <= M_EIOS; if (tx_eios_done) begin tx_mode <= M_EIDLE; sub <= 3'd2; end end
                default: begin
                    tx_mode <= M_EIDLE; tx_ctrl <= 8'd0;
                    if (!dsp_dis_q) goto(ST_DQUIET);
                end
                endcase
            end else begin
                link_up <= 1'b0;
                case (sub)
                3'd0: begin tx_mode <= M_EIOS; if (tx_eios_done) begin tx_mode <= M_EIDLE; sub <= 3'd1; end end
                3'd1: begin tx_mode <= M_EIDLE; if (pipe_rxelecidle) sub <= 3'd2; end
                default: begin tx_mode <= M_EIDLE; if (!pipe_rxelecidle) goto(ST_DQUIET); end
                endcase
            end
            default: goto(ST_DQUIET);
            endcase
            // Configuration: remember the lane number each lane receives
            if (st >= ST_CLWSTART && st <= ST_CIDLE)
                for (li = 0; li < NL; li = li + 1) if (m_tsv[li]) begin
                    rxl[li] <= m_lane[li]; rxl_pad[li] <= m_npad[li];
                end
            // from Lanenum.Wait on only the lanes of the link transmit
            if ((st >= ST_CLNWAIT && st <= ST_L0) || (st >= ST_RLOCK && st <= ST_DISABLED)) lane_en <= wmask;
            if (t_clr) begin
                ts_tx_cnt <= 11'd0; tx_after <= 6'd0; rx_first <= 1'b0;
                cnt_a <= 4'd0; cnt_b <= 4'd0; t_cyc <= 12'd0; rx_ts2_seen <= 1'b0;
                clw_wait <= 6'd0;
                for (li = 0; li < NL; li = li + 1) lc[li] <= 4'd0;
            end
        end
    end
endmodule
