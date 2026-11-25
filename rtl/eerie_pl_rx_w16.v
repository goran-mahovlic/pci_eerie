// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6173): physical layer receive front end for a x1 lane on a 128-bit PIPE
// (EERIE_W16: 16 symbols per PIPE clock; 31.25 MHz at 5.0 GT/s, 15.625 MHz at 2.5 GT/s).
// eerie_pl_rx_w8 (with EERIE_W8_IDLEPRE / EERIE_W8_PAPRE) for 16 symbols:
//
//   PIPE -> R0 classify -> R1 raw (TS / EIEOS) flags -> eerie_scr16 descrambler (2) -> R3
//        -> ordered sets: 2-word window, TS / EIOS / SKP decoded at any COM position -> LTSSM events
//        -> packets: in-packet byte mask (both start states, 2 stages) -> compaction -> slot queue
//           -> 0..4 slots of 4 bytes per clock (packets start in slot byte 0)
//
// The slots go through eerie_slot_fifo to eerie_pl_rx_ml (2 slots per clock): the link layer above is
// 64 bits wide, the FIFO takes up the difference while a packet stream is faster than 8 bytes per clock
// (bounded by the advertised credits).
`timescale 1ns / 1ps
module eerie_pl_rx_w16 (
    input              clk,
    input              rst,
    input      [127:0] pipe_rxdata,
    input      [15:0]  pipe_rxdatak,
    input              pipe_rxvalid,
    input      [2:0]   pipe_rxstatus,
    input              pipe_rxelecidle,
    input              descramble_en,

    output reg         os_ts_valid,
    output reg         os_ts2,
    output reg         os_ts_inv,
    output reg [7:0]   os_link,
    output reg         os_link_pad,
    output reg [7:0]   os_lane,
    output reg         os_lane_pad,
    output reg [7:0]   os_nfts,
    output reg [7:0]   os_rate,
    output reg [7:0]   os_ctrl,
    output reg         os_eios,
    output reg         os_skp,
    output reg         os_idle2,          // 8 consecutive symbols of idle data received
    output reg         rx_err,

    output reg [3:0]   sl_v,              // slots 0..3 (a prefix: sl_v = 0000, 0001, 0011, 0111, 1111)
    output reg [127:0] sl_d,              // slot s = sl_d[32*s +: 32], byte 0 = first symbol, in [7:0]
    output reg [15:0]  sl_k,
    output reg [3:0]   sl_e
);
    localparam K_COM = 8'hBC, K_STP = 8'hFB, K_SDP = 8'h5C, K_END = 8'hFD, K_EDB = 8'hFE,
               K_PAD = 8'hF7, K_SKP = 8'h1C, K_FTS = 8'h3C, K_IDL = 8'h7C, K_EIE = 8'hFC;
    integer i, j;

    // ---------------- R0: input register + classification ----------------
    reg [127:0] r_d; reg [15:0] r_k; reg r_v, r_err;
    reg [15:0]  r_com, r_skp, r_stp, r_sdp, r_end, r_edb, r_idl, r_rs, r_pad;
    always @(posedge clk) begin
        r_d <= pipe_rxdata; r_k <= pipe_rxdatak;
        r_v <= pipe_rxvalid && !pipe_rxelecidle && !rst;
        r_err <= pipe_rxvalid && (pipe_rxstatus == 3'b100 || pipe_rxstatus == 3'b111 ||
                                  pipe_rxstatus == 3'b101 || pipe_rxstatus == 3'b110);
        for (i = 0; i < 16; i = i + 1) begin
            r_com[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_COM;
            r_skp[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_SKP;
            r_stp[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_STP;
            r_sdp[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_SDP;
            r_end[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_END;
            r_edb[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_EDB;
            r_idl[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_IDL;
            r_pad[i] <= pipe_rxdatak[i] && pipe_rxdata[8*i +: 8] == K_PAD;
            r_rs[i]  <= !pipe_rxdatak[i] || pipe_rxdata[8*i +: 8] == K_PAD || pipe_rxdata[8*i +: 8] == K_EIE;
        end
    end

    // ---------------- R1: raw (unscrambled TS / EIEOS) symbols ----------------
    // symbol x is raw if it follows a COM, or lies 2..15 symbols after a COM whose next symbol starts a
    // TS / EIEOS (data, PAD or EIE); history of the previous word
    reg [15:0] h_com, h_rs;
    wire [31:0] a_com = {r_com, h_com}, a_rs = {r_rs, h_rs};
    reg  [15:0] raw;
    always @(*) begin
        for (i = 0; i < 16; i = i + 1) begin
            raw[i] = a_com[16 + i - 1];
            for (j = 2; j <= 15; j = j + 1) raw[i] = raw[i] | (a_com[16 + i - j] & a_rs[16 + i - j + 1]);
        end
    end
    // side bus through the descrambler: {err, idl, pad, edb, end, sdp, stp, skp, com}
    localparam SW = 1 + 8 * 16;
    reg [127:0] s_d; reg [15:0] s_k, s_scr, s_com, s_skp; reg s_v; reg [SW-1:0] s_side;
    always @(posedge clk) begin
        if (rst || !r_v) begin h_com <= 16'd0; h_rs <= 16'd0; end
        else begin h_com <= r_com; h_rs <= r_rs; end
        s_d <= r_d; s_k <= r_k; s_v <= r_v; s_com <= r_com; s_skp <= r_skp;
        s_scr <= ~r_k & ~raw & {16{descramble_en}};
        s_side <= {r_err, r_idl, r_pad, r_edb, r_end, r_sdp, r_stp, r_skp, r_com};
    end

    // ---------------- descrambler ----------------
`ifdef EERIE_SCR16_LITE
    wire [15:0] s_com_d = {s_com[15:1], s_com[0] | s_skp[0]};   // word starts inside a SKP OS: LFSR = FFFFh
`else
    wire [15:0] s_com_d = s_com;
`endif
    wire [127:0] d_d; wire [15:0] d_k; wire d_v; wire [SW-1:0] d_side;
    eerie_scr16 #(.SW(SW)) dscr (
        .clk(clk), .rst(rst), .v(s_v), .d(s_d), .k(s_k), .scr(s_scr), .com(s_com_d), .skp(s_skp),
        .side(s_side), .od(d_d), .ok(d_k), .ov(d_v), .oside(d_side)
    );
    wire [15:0] d_com = d_side[15:0],   d_skp = d_side[31:16],  d_stp = d_side[47:32], d_sdp = d_side[63:48],
                d_end = d_side[79:64],  d_edb = d_side[95:80],  d_pad = d_side[111:96], d_idl = d_side[127:112];
    wire        d_err = d_side[128];

    // ======================= ordered sets =======================
    // window: w1 (older) / w0 = 32 symbols; a TS starting in w1 ends inside the window
    reg [127:0] w1d; reg [15:0] w1k, w1com, w1pad; reg w1v;
    wire [255:0] wd = {d_d, w1d};
    wire [31:0]  wk = {d_k, w1k}, wpad = {d_pad, w1pad};
    reg  [15:0]  ts_hit; reg eios_hit, skp_hit;
    always @(*) begin
        eios_hit = 1'b0; skp_hit = 1'b0;
        for (i = 0; i < 16; i = i + 1) begin
            // COM in w1 followed by data or PAD: TS1/TS2 (EIEOS / FTS / SKP / IDL have K there)
            ts_hit[i] = w1v && w1com[i] && (!wk[i + 1] || wpad[i + 1]);
            if (w1v && w1com[i] && wk[i + 1] && wd[8*(i+1) +: 8] == K_IDL) eios_hit = 1'b1;
            if (w1v && w1com[i] && wk[i + 1] && wd[8*(i+1) +: 8] == K_SKP) skp_hit = 1'b1;
        end
    end
    reg  [3:0] p_first; reg p_any;
    always @(*) begin
        p_first = 4'd0; p_any = 1'b0;
        for (i = 15; i >= 0; i = i - 1) if (ts_hit[i]) begin p_first = i; p_any = 1'b1; end
    end
    // idle data (descrambled 00, not K): 8 in a row inside the word, or across the word boundary
    reg [15:0] d_idl16; reg [16:0] lead_ok; reg [4:0] idle_tail; reg in8;
    always @(*) begin
        for (i = 0; i < 16; i = i + 1) d_idl16[i] = !d_k[i] && d_d[8*i +: 8] == 8'd0;
        lead_ok[0] = 1'b1;
        for (i = 1; i <= 16; i = i + 1) lead_ok[i] = lead_ok[i-1] && d_idl16[i-1];
        idle_tail = 5'd0;
        for (i = 1; i <= 8; i = i + 1) if ((d_idl16 >> (16 - i)) == ((17'd1 << i) - 1)) idle_tail = i;
        in8 = 1'b0;
        for (i = 0; i <= 8; i = i + 1) if (&d_idl16[i +: 8]) in8 = 1'b1;
    end
`ifdef EERIE_RXW16_TSPRE
    // TASK-6238: the TS body checks per COM position (1 bit each) instead of muxing 10 ID bytes + 16 K bits:
    // ok = ID bytes (symbols 6..15) all equal and a TS1/TS2 ID, no K in symbols 3..15, K in 1/2 only as PAD
    reg  [23:0] t_eq; reg [15:0] t_ok, t_ts2, t_inv; reg [7:0] t_id;
    always @(*) begin
        for (i = 0; i < 24; i = i + 1) t_eq[i] = wd[8*(i+6) +: 8] == wd[8*(i+7) +: 8];
        for (i = 0; i < 16; i = i + 1) begin
            t_id = wd[8*(i+6) +: 8];
            t_ok[i] = (&t_eq[i +: 9]) && (t_id == 8'h4A || t_id == 8'h45 || t_id == 8'hB5 || t_id == 8'hBA) &&
                      wk[i+3 +: 13] == 13'd0 && !(wk[i+1] && !wpad[i+1]) && !(wk[i+2] && !wpad[i+2]);
            t_ts2[i] = t_id == 8'h45 || t_id == 8'hBA;
            t_inv[i] = t_id == 8'hB5 || t_id == 8'hBA;
        end
    end
    reg [15:0] a_ok, a_ts2, a_inv;
    always @(posedge clk) begin a_ok <= t_ok; a_ts2 <= t_ts2; a_inv <= t_inv; end
`endif
    reg        a_v; reg [3:0] a_p; reg [255:0] a_wd; reg [31:0] a_wk, a_wpad; reg a_eios, a_skp, a_idle;
    reg  [3:0] idle_run;                   // idle symbols at the end of the previous word (0..8)
    always @(posedge clk) begin
        if (rst || !d_v) w1v <= 1'b0; else w1v <= d_v;
        w1d <= d_d; w1k <= d_k; w1com <= d_com; w1pad <= d_pad;
        a_v <= p_any && !rst; a_p <= p_first; a_wd <= wd; a_wk <= wk; a_wpad <= wpad;
        a_eios <= eios_hit && !rst; a_skp <= skp_hit && !rst;
        if (rst || !d_v) idle_run <= 4'd0; else idle_run <= idle_tail[3:0];
        a_idle <= d_v && !rst && (in8 || lead_ok[4'd8 - idle_run]);
    end
    // B: fields of the TS at a_p
    reg        b_v; reg [7:0] b_link, b_lane, b_nfts, b_rate, b_ctrl; reg [79:0] b_id; reg [15:0] b_k;
    reg        b_lpad, b_npad;
    always @(posedge clk) begin
        b_v <= a_v && !rst;
        b_link <= a_wd[8*(a_p+1) +: 8]; b_lane <= a_wd[8*(a_p+2) +: 8]; b_nfts <= a_wd[8*(a_p+3) +: 8];
        b_rate <= a_wd[8*(a_p+4) +: 8]; b_ctrl <= a_wd[8*(a_p+5) +: 8];
        b_id   <= a_wd[8*(a_p+6) +: 80];
        b_k    <= a_wk[a_p +: 16];
        b_lpad <= a_wpad[a_p + 1]; b_npad <= a_wpad[a_p + 2];
    end
`ifdef EERIE_RXW16_TSPRE
    reg b_ok, b_ts2, b_inv;
    always @(posedge clk) begin b_ok <= a_ok[a_p]; b_ts2 <= a_ts2[a_p]; b_inv <= a_inv[a_p]; end
    always @(posedge clk) begin
        os_ts_valid <= b_v && b_ok && !rst;
        os_ts2      <= b_ts2;
        os_ts_inv   <= b_inv;
        os_link <= b_link; os_link_pad <= b_lpad; os_lane <= b_lane; os_lane_pad <= b_npad;
        os_nfts <= b_nfts; os_rate <= b_rate; os_ctrl <= b_ctrl;
        os_eios <= a_eios; os_skp <= a_skp; os_idle2 <= a_idle;
    end
`else
    // C: checks, events
    reg c_bad;
    always @(*) begin
        c_bad = (b_k[1] && !b_lpad) || (b_k[2] && !b_npad) || (b_k[15:3] != 13'd0) ||
                !(b_id[7:0] == 8'h4A || b_id[7:0] == 8'h45 || b_id[7:0] == 8'hB5 || b_id[7:0] == 8'hBA);
        for (i = 1; i < 10; i = i + 1) if (b_id[8*i +: 8] != b_id[7:0]) c_bad = 1'b1;
    end
    always @(posedge clk) begin
        os_ts_valid <= b_v && !c_bad && !rst;
        os_ts2      <= (b_id[7:0] == 8'h45 || b_id[7:0] == 8'hBA);
        os_ts_inv   <= (b_id[7:0] == 8'hB5 || b_id[7:0] == 8'hBA);
        os_link <= b_link; os_link_pad <= b_lpad; os_lane <= b_lane; os_lane_pad <= b_npad;
        os_nfts <= b_nfts; os_rate <= b_rate; os_ctrl <= b_ctrl;
        os_eios <= a_eios; os_skp <= a_skp; os_idle2 <= a_idle;
    end
`endif

    // ======================= packets =======================
    // PP0: in-packet mask for both start states (word begins outside / inside a packet): STP/SDP ..
    // END/EDB; any other K inside a packet is kept and ends it, so that eerie_pl_rx_ml reports the
    // framing error. PP1: counts and byte ranks (position after the compaction) for both.
    task pscan; input in0; input v; input [15:0] k, stp, sdp;
        output ni; output hs; output [3:0] sp; output [15:0] mx;
        integer x;
        begin
            ni = in0; mx = 16'd0; hs = 1'b0; sp = 4'd0;
            for (x = 0; x < 16; x = x + 1) begin
                if (ni) begin
                    mx[x] = 1'b1;
                    if (k[x]) ni = 1'b0;                       // END / EDB / framing error / start inside
                end else if (stp[x] || sdp[x]) begin
                    mx[x] = 1'b1; ni = 1'b1;
                    if (!hs) begin hs = 1'b1; sp = x; end
                end
            end
            if (!v) begin mx = 16'd0; ni = 1'b0; hs = 1'b0; end
        end
    endtask
`ifdef EERIE_RXW16_PPF
    // TASK-6241: PP0 / PP1 shallow, at the same latency, instead of the 16-symbol serial scan (pscan: 17 levels)
    // and the serial byte counters (u_cn / u_cf: 21 levels, the ep.app.clk critical path of G7H_s2 at 23.4 MHz).
    // The packet state is a 2-state machine per symbol: f_x(0) = start (STP/SDP), f_x(1) = !K (any K inside
    // a packet ends it). PP0 composes f_0..f_x as a Kogge-Stone prefix (4 mux levels) for both start states:
    //   state before x = nib[x], mask = nib | start.
    // The first start outside a packet (sp) without the scan: start state 0, the first STP/SDP; start state 1,
    // the first STP/SDP after the first K (the K ends the packet the word began in). pre[x] = x >= sp (prefix OR).
    // PP1: ranks from 4-byte groups (in-group prefix counts + group offsets), j0 = mask bytes before sp (mod 4).
    integer    s, x, lv, sh2, g;
    reg [15:0] f0 [0:4], f1 [0:4]; reg [15:0] nib [0:1], mq [0:1], mfq [0:1], prq [0:1]; reg [1:0] niq;
    reg [15:0] st16, kb16, s1st;
    always @(*) begin
        for (x = 0; x < 16; x = x + 1) begin st16[x] = d_stp[x] | d_sdp[x]; f0[0][x] = st16[x]; f1[0][x] = !d_k[x]; end
        for (lv = 0; lv < 4; lv = lv + 1) begin
            sh2 = 1 << lv;
            for (x = 0; x < 16; x = x + 1)
                if (x >= sh2) begin       // P[x] o P[x - sh2]: the older function first
                    f0[lv+1][x] = f0[lv][x - sh2] ? f1[lv][x] : f0[lv][x];
                    f1[lv+1][x] = f1[lv][x - sh2] ? f1[lv][x] : f0[lv][x];
                end else begin f0[lv+1][x] = f0[lv][x]; f1[lv+1][x] = f1[lv][x]; end
        end
        kb16[0] = 1'b0;
        for (x = 1; x < 16; x = x + 1) kb16[x] = kb16[x-1] | d_k[x-1];     // a K before x
        s1st = st16 & kb16;
        prq[0][0] = st16[0]; prq[1][0] = s1st[0];
        for (x = 1; x < 16; x = x + 1) begin prq[0][x] = prq[0][x-1] | st16[x]; prq[1][x] = prq[1][x-1] | s1st[x]; end
        for (s = 0; s < 2; s = s + 1) begin
            nib[s] = {s ? f1[4][14:0] : f0[4][14:0], s[0]};
            mq[s]  = d_v ? (nib[s] | st16) : 16'd0;
            mfq[s] = (d_v && prq[s][15]) ? (mq[s] & prq[s]) : mq[s];
            niq[s] = d_v && (s ? f1[4][15] : f0[4][15]);
        end
    end
    reg        q0_ni [0:1], q0_hs [0:1]; reg [15:0] q0_m [0:1], q0_mf [0:1];
    reg [127:0] p0_d; reg [15:0] p0_k; reg p0_e;
    always @(posedge clk) begin
        for (s = 0; s < 2; s = s + 1) begin
            q0_ni[s] <= niq[s]; q0_hs[s] <= d_v && prq[s][15]; q0_m[s] <= mq[s]; q0_mf[s] <= mfq[s];
        end
        p0_d <= d_d; p0_k <= d_k; p0_e <= d_err;
    end
    // PP1: ranks (4 bits per byte) and the counts; the bytes before sp are the mask bytes not in mf
    reg        q1_ni [0:1], q1_hs [0:1]; reg [1:0] q1_j0 [0:1]; reg [4:0] q1_cn [0:1], q1_cf [0:1];
    reg [15:0] q1_m [0:1], q1_mf [0:1]; reg [63:0] q1_rn [0:1], q1_rf [0:1];
    reg [4:0]  u_on [0:4], u_of [0:4]; reg [63:0] u_rn, u_rf; reg [1:0] v_an, v_af, u_j0; reg [2:0] v_tn [0:3], v_tf [0:3];
    reg [31:0] v_pn, v_pf; reg [15:0] u_b;
    reg [127:0] pp_d; reg [15:0] pp_k; reg pp_e;
    always @(posedge clk) begin
        for (s = 0; s < 2; s = s + 1) begin
            u_b = q0_m[s] & ~q0_mf[s]; u_j0 = 2'd0;
            for (x = 0; x < 16; x = x + 1) u_j0 = u_j0 + u_b[x];
            for (g = 0; g < 4; g = g + 1) begin
                v_an = 2'd0; v_af = 2'd0; v_tn[g] = 3'd0; v_tf[g] = 3'd0;
                for (x = 0; x < 4; x = x + 1) begin
                    v_pn[2*(4*g+x) +: 2] = v_an; v_pf[2*(4*g+x) +: 2] = v_af;
                    v_an = v_an + q0_m[s][4*g+x]; v_af = v_af + q0_mf[s][4*g+x];
                    v_tn[g] = v_tn[g] + q0_m[s][4*g+x]; v_tf[g] = v_tf[g] + q0_mf[s][4*g+x];
                end
            end
            u_on[0] = 5'd0; u_of[0] = 5'd0;
            for (g = 0; g < 4; g = g + 1) begin u_on[g+1] = u_on[g] + v_tn[g]; u_of[g+1] = u_of[g] + v_tf[g]; end
            for (x = 0; x < 16; x = x + 1) begin
                u_rn[4*x +: 4] = u_on[x/4][3:0] + v_pn[2*x +: 2];
                u_rf[4*x +: 4] = u_of[x/4][3:0] + v_pf[2*x +: 2];
            end
            q1_ni[s] <= q0_ni[s]; q1_hs[s] <= q0_hs[s]; q1_j0[s] <= u_j0; q1_cn[s] <= u_on[4]; q1_cf[s] <= u_of[4];
            q1_m[s] <= q0_m[s]; q1_mf[s] <= q0_mf[s]; q1_rn[s] <= u_rn; q1_rf[s] <= u_rf;
        end
        pp_d <= p0_d; pp_k <= p0_k; pp_e <= p0_e;
    end
`else
    // (fsm_encoding none: yosys took q0_sp for a state machine and its extraction never ended)
    (* fsm_encoding = "none" *) reg [3:0] q0_sp [0:1];
    reg        q0_ni [0:1], q0_hs [0:1]; reg [15:0] q0_m [0:1];
    reg        t_ni, t_hs; reg [3:0] t_sp; reg [15:0] t_m;
    reg [127:0] p0_d; reg [15:0] p0_k; reg p0_e;
    integer    s;
    always @(posedge clk) begin
        for (s = 0; s < 2; s = s + 1) begin
            pscan(s, d_v, d_k, d_stp, d_sdp, t_ni, t_hs, t_sp, t_m);
            q0_ni[s] <= t_ni; q0_hs[s] <= t_hs; q0_sp[s] <= t_sp; q0_m[s] <= t_m;
        end
        p0_d <= d_d; p0_k <= d_k; p0_e <= d_err;
    end
    // PP1 per start state: j0 = mask bytes before the first start, cn / cf = byte counts without / with the
    // flush of the bytes before the start, rn / rf = ranks
    reg        q1_ni [0:1], q1_hs [0:1]; reg [1:0] q1_j0 [0:1]; reg [4:0] q1_cn [0:1], q1_cf [0:1];
    reg [15:0] q1_m [0:1], q1_mf [0:1]; reg [63:0] q1_rn [0:1], q1_rf [0:1];
    reg [4:0]  u_j0, u_cn, u_cf; reg [15:0] u_mf; reg [63:0] u_rn, u_rf; integer x;
    reg [127:0] pp_d; reg [15:0] pp_k; reg pp_e;
    always @(posedge clk) begin
        for (s = 0; s < 2; s = s + 1) begin
            u_mf = q0_m[s]; u_cn = 5'd0; u_cf = 5'd0; u_j0 = 5'd0;
            for (x = 0; x < 16; x = x + 1) begin
                if (q0_hs[s] && x < q0_sp[s] && q0_m[s][x]) u_j0 = u_j0 + 1'b1;
                if (x < q0_sp[s]) u_mf[x] = 1'b0;
                u_rn[4*x +: 4] = u_cn[3:0]; u_rf[4*x +: 4] = u_cf[3:0];
                u_cn = u_cn + q0_m[s][x]; u_cf = u_cf + u_mf[x];
            end
            q1_ni[s] <= q0_ni[s]; q1_hs[s] <= q0_hs[s]; q1_j0[s] <= u_j0[1:0]; q1_cn[s] <= u_cn; q1_cf[s] <= u_cf;
            q1_m[s] <= q0_m[s]; q1_mf[s] <= u_mf; q1_rn[s] <= u_rn; q1_rf[s] <= u_rf;
        end
        pp_d <= p0_d; pp_k <= p0_k; pp_e <= p0_e;
    end
`endif
    // PA: the start state is a single select; a start off a slot boundary drops the partial slot and
    // the bytes before the start
    reg        in_pkt; reg [1:0] phase;
    wire       ss = in_pkt;
    wire       flush = q1_hs[ss] && ((phase + q1_j0[ss]) & 2'd3) != 2'd0;
    wire [4:0] cnt_all = flush ? q1_cf[ss] : q1_cn[ss];
    reg [127:0] pa_d; reg [15:0] pa_k, pa_m; reg pa_e, pa_fl; reg [63:0] pa_rk; reg [4:0] pa_cnt;
`ifdef EERIE_RXW16_CNET
    // TASK-6238: byte x moves down by z = x - rank (the masked-out bytes before it)
    wire [63:0] rk_sel = flush ? q1_rf[ss] : q1_rn[ss];
    reg  [63:0] z_sel;
    always @(*) for (x = 0; x < 16; x = x + 1) z_sel[4*x +: 4] = x[3:0] - rk_sel[4*x +: 4];
`endif
    always @(posedge clk) begin
`ifdef EERIE_RXW16_CNET
        pa_rk <= z_sel; pa_cnt <= rst ? 5'd0 : cnt_all;
`else
        pa_rk <= flush ? q1_rf[ss] : q1_rn[ss]; pa_cnt <= rst ? 5'd0 : cnt_all;
`endif
        if (rst) begin in_pkt <= 1'b0; phase <= 2'd0; end
        else begin
            in_pkt <= q1_ni[ss];
            phase <= flush ? cnt_all[1:0] : phase + cnt_all[1:0];
        end
        pa_d <= pp_d; pa_k <= pp_k; pa_m <= rst ? 16'd0 : (flush ? q1_mf[ss] : q1_m[ss]); pa_e <= pp_e;
        pa_fl <= flush && !rst;
    end
    // PB: compaction (output byte j = the masked byte of rank j)
    reg [7:0] cw [0:15]; reg [15:0] cwk;
`ifdef EERIE_RXW16_CNET
    // TASK-6238: compress network, 4 stages (LSB first: byte moves down by 1, 2, 4, 8 when that bit of its
    // z is set; collision free for a compaction), instead of the 16 x 16 rank match; pa_rk holds z
    reg [143:0] ce [0:4]; reg [15:0] cv [0:4]; reg [63:0] cz [0:4]; integer st, sh;
    reg         c_stay, c_mv;
    always @(*) begin
        for (i = 0; i < 16; i = i + 1) begin
            ce[0][9*i +: 9] = pa_m[i] ? {pa_k[i], pa_d[8*i +: 8]} : 9'd0;
            cv[0][i] = pa_m[i]; cz[0][4*i +: 4] = pa_rk[4*i +: 4];
        end
        for (st = 0; st < 4; st = st + 1) begin
            sh = 1 << st;
            for (i = 0; i < 16; i = i + 1) begin
                c_stay = cv[st][i] && !cz[st][4*i + st];
                c_mv   = (i + sh < 16) ? (cv[st][(i + sh) % 16] && cz[st][4*((i + sh) % 16) + st]) : 1'b0;
                ce[st+1][9*i +: 9] = (c_stay ? ce[st][9*i +: 9] : 9'd0) | (c_mv ? ce[st][9*((i + sh) % 16) +: 9] : 9'd0);
                cz[st+1][4*i +: 4] = c_stay ? cz[st][4*i +: 4] : c_mv ? cz[st][4*((i + sh) % 16) +: 4] : 4'd0;
                cv[st+1][i] = c_stay || c_mv;
            end
        end
        for (j = 0; j < 16; j = j + 1) begin cw[j] = ce[4][9*j +: 8]; cwk[j] = ce[4][9*j + 8]; end
    end
`else
    always @(*) begin
        for (j = 0; j < 16; j = j + 1) begin
            cw[j] = 8'd0; cwk[j] = 1'b0;
            for (i = 0; i < 16; i = i + 1) if (pa_m[i] && pa_rk[4*i +: 4] == j) begin
                cw[j] = cw[j] | pa_d[8*i +: 8]; cwk[j] = cwk[j] | pa_k[i];
            end
        end
    end
`endif
    reg [127:0] pb_d; reg [15:0] pb_k; reg [4:0] pb_n; reg pb_e, pb_fl;
    always @(posedge clk) begin
        for (j = 0; j < 16; j = j + 1) pb_d[8*j +: 8] <= cw[j];
        pb_k <= cwk; pb_n <= rst ? 5'd0 : pa_cnt; pb_e <= pa_e && pa_m != 16'd0; pb_fl <= pa_fl;
    end
    // PC: slot queue (19 bytes): every complete slot leaves each clock, at most 3 bytes stay
    reg [7:0] qd [0:18]; reg [18:0] qk, qe; reg [4:0] occ;
    reg [7:0] nd [0:18]; reg [18:0] nk, ne; reg [4:0] npop, r, nocc;
    always @(*) begin
        npop = {occ[4:2], 2'b00};
        r = pb_fl ? 5'd0 : occ - npop;
        for (j = 0; j < 19; j = j + 1) begin
            if (j < r) begin           // j < 3: one of 5 positions, no index arithmetic
                nd[j] = (npop == 5'd16) ? qd[j + 16] : (npop == 5'd12) ? qd[j + 12] :
                        (npop == 5'd8) ? qd[j + 8] : (npop == 5'd4) ? qd[j + 4] : qd[j];
                nk[j] = (npop == 5'd16) ? qk[j + 16] : (npop == 5'd12) ? qk[j + 12] :
                        (npop == 5'd8) ? qk[j + 8] : (npop == 5'd4) ? qk[j + 4] : qk[j];
                ne[j] = (npop == 5'd16) ? qe[j + 16] : (npop == 5'd12) ? qe[j + 12] :
                        (npop == 5'd8) ? qe[j + 8] : (npop == 5'd4) ? qe[j + 4] : qe[j];
            end
            else if (j - r < 16) begin nd[j] = pb_d[8*(j-r) +: 8]; nk[j] = pb_k[j-r]; ne[j] = pb_e; end
            else begin nd[j] = 8'd0; nk[j] = 1'b0; ne[j] = 1'b0; end
        end
        nocc = r + pb_n;
    end
    always @(posedge clk) begin
        if (rst) begin occ <= 5'd0; sl_v <= 4'd0; end
        else begin
            occ <= nocc;
            sl_v <= {occ >= 5'd16, occ >= 5'd12, occ >= 5'd8, occ >= 5'd4};
        end
        for (j = 0; j < 19; j = j + 1) begin qd[j] <= nd[j]; qk[j] <= nk[j]; qe[j] <= ne[j]; end
        for (j = 0; j < 16; j = j + 1) sl_d[8*j +: 8] <= qd[j];
        sl_k <= qk[15:0];
        for (j = 0; j < 4; j = j + 1) sl_e[j] <= |qe[4*j +: 4];
        rx_err <= r_err && r_v;
    end
endmodule
