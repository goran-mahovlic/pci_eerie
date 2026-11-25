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
    wire [127:0] d_d; wire [15:0] d_k; wire d_v; wire [SW-1:0] d_side;
    eerie_scr16 #(.SW(SW)) dscr (
        .clk(clk), .rst(rst), .v(s_v), .d(s_d), .k(s_k), .scr(s_scr), .com(s_com), .skp(s_skp),
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
    // PA: the start state is a single select; a start off a slot boundary drops the partial slot and
    // the bytes before the start
    reg        in_pkt; reg [1:0] phase;
    wire       ss = in_pkt;
    wire       flush = q1_hs[ss] && ((phase + q1_j0[ss]) & 2'd3) != 2'd0;
    wire [4:0] cnt_all = flush ? q1_cf[ss] : q1_cn[ss];
    reg [127:0] pa_d; reg [15:0] pa_k, pa_m; reg pa_e, pa_fl; reg [63:0] pa_rk; reg [4:0] pa_cnt;
    always @(posedge clk) begin
        pa_rk <= flush ? q1_rf[ss] : q1_rn[ss]; pa_cnt <= rst ? 5'd0 : cnt_all;
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
    always @(*) begin
        for (j = 0; j < 16; j = j + 1) begin
            cw[j] = 8'd0; cwk[j] = 1'b0;
            for (i = 0; i < 16; i = i + 1) if (pa_m[i] && pa_rk[4*i +: 4] == j) begin
                cw[j] = cw[j] | pa_d[8*i +: 8]; cwk[j] = cwk[j] | pa_k[i];
            end
        end
    end
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
