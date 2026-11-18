// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie (GateMate, TASK-6161): physical layer receive front end for a x1 Gen1 lane on a 64-bit
// PIPE (8 symbols per PIPE clock, 31.25 MHz). Replaces eerie_pl_rx (lane 0, x1).
//
//   PIPE -> R0 classify -> R1 raw (TS) flags -> eerie_scr8 descrambler (2) -> R3
//        -> ordered sets: 3-word window, TS / EIOS / SKP decoded at any COM position -> LTSSM events
//        -> packets: in-packet byte mask -> compaction -> slot queue -> 4-byte slots (packets start in
//           slot byte 0) -> eerie_pl_rx_ml (x4 framing, LCRC / CRC16, entries for the DLL)
//
// Symbol 0 of a PIPE word is in [7:0] (first on the wire). In a x1 link packets and ordered sets may
// start at any symbol; the packet path keeps only packet bytes (STP/SDP .. END/EDB), so every packet
// (a multiple of 4 bytes) starts on a slot boundary. If a start arrives off a slot boundary (only
// after a malformed packet) the partial slot is discarded.
`timescale 1ns / 1ps
module eerie_pl_rx_w8 (
    input             clk,
    input             rst,
    input      [63:0] pipe_rxdata,
    input      [7:0]  pipe_rxdatak,
    input             pipe_rxvalid,
    input      [2:0]  pipe_rxstatus,
    input             pipe_rxelecidle,
    input             descramble_en,

    output reg        os_ts_valid,
    output reg        os_ts2,
    output reg        os_ts_inv,
    output reg [7:0]  os_link,
    output reg        os_link_pad,
    output reg [7:0]  os_lane,
    output reg        os_lane_pad,
    output reg [7:0]  os_nfts,
    output reg [7:0]  os_rate,
    output reg [7:0]  os_ctrl,
    output reg        os_eios,
    output reg        os_skp,
    output reg        os_idle2,          // 8 consecutive symbols of idle data received (LTSSM: = 4 pairs)
    output reg        rx_err,

    output reg        sl_va, sl_vb,      // slot stream to eerie_pl_rx_ml (N=4, w4=1)
    output reg [31:0] sl_da, sl_db,      // byte 0 of a slot = first symbol, in [7:0]
    output reg [3:0]  sl_ka, sl_kb,
    output reg        sl_ea, sl_eb
);
    localparam K_COM = 8'hBC, K_STP = 8'hFB, K_SDP = 8'h5C, K_END = 8'hFD, K_EDB = 8'hFE,
               K_PAD = 8'hF7, K_SKP = 8'h1C, K_FTS = 8'h3C, K_IDL = 8'h7C, K_EIE = 8'hFC;
    integer i, j;

    // ---------------- R0: input register + classification ----------------
    reg [63:0] r_d; reg [7:0] r_k; reg r_v, r_err;
    reg [7:0]  r_com, r_skp, r_stp, r_sdp, r_end, r_edb, r_idl, r_rs, r_pad;
    always @(posedge clk) begin
        r_d <= pipe_rxdata; r_k <= pipe_rxdatak;
        r_v <= pipe_rxvalid && !pipe_rxelecidle && !rst;
        r_err <= pipe_rxvalid && (pipe_rxstatus == 3'b100 || pipe_rxstatus == 3'b111 ||
                                  pipe_rxstatus == 3'b101 || pipe_rxstatus == 3'b110);
        for (i = 0; i < 8; i = i + 1) begin
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
    // TS / EIEOS (data, PAD or EIE); history of the two previous words
    reg [15:0] h_com, h_rs;                  // [15:8] = previous word, [7:0] = the one before
    wire [23:0] a_com = {r_com, h_com[15:8], h_com[7:0]};
    wire [23:0] a_rs  = {r_rs,  h_rs[15:8],  h_rs[7:0]};
    reg  [7:0]  raw;
    always @(*) begin
        for (i = 0; i < 8; i = i + 1) begin
            raw[i] = a_com[16 + i - 1];
            for (j = 2; j <= 15; j = j + 1) raw[i] = raw[i] | (a_com[16 + i - j] & a_rs[16 + i - j + 1]);
        end
    end
    // side bus through the descrambler: {err, idl, pad, edb, end, sdp, stp, skp, com}
    localparam SW = 1 + 8 * 8;
    reg [63:0] s_d; reg [7:0] s_k, s_scr, s_com, s_skp; reg s_v; reg [SW-1:0] s_side;
    always @(posedge clk) begin
        if (rst || !r_v) begin h_com <= 16'd0; h_rs <= 16'd0; end
        else begin h_com <= {r_com, h_com[15:8]}; h_rs <= {r_rs, h_rs[15:8]}; end
        s_d <= r_d; s_k <= r_k; s_v <= r_v; s_com <= r_com; s_skp <= r_skp;
        s_scr <= ~r_k & ~raw & {8{descramble_en}};
        s_side <= {r_err, r_idl, r_pad, r_edb, r_end, r_sdp, r_stp, r_skp, r_com};
    end

    // ---------------- descrambler ----------------
    wire [63:0] d_d; wire [7:0] d_k; wire d_v; wire [SW-1:0] d_side;
    eerie_scr8 #(.SW(SW)) dscr (
        .clk(clk), .rst(rst), .v(s_v), .d(s_d), .k(s_k), .scr(s_scr), .com(s_com), .skp(s_skp),
        .side(s_side), .od(d_d), .ok(d_k), .ov(d_v), .oside(d_side)
    );
    wire [7:0] d_com = d_side[7:0],   d_skp = d_side[15:8],  d_stp = d_side[23:16], d_sdp = d_side[31:24],
               d_end = d_side[39:32], d_edb = d_side[47:40], d_pad = d_side[55:48], d_idl = d_side[63:56];
    wire       d_err = d_side[64];

    // ======================= ordered sets =======================
    // window: w2 (oldest) / w1 / w0 = 24 symbols; TS starting in w2 end inside the window
    reg [63:0] w1d, w2d; reg [7:0] w1k, w2k, w1com, w2com, w1pad, w2pad, w1skp, w2skp, w1idl, w2idl;
    reg        w1v, w2v;
    wire [191:0] wd = {d_d, w1d, w2d};
    wire [23:0]  wk = {d_k, w1k, w2k}, wpad = {d_pad, w1pad, w2pad};
    reg  [7:0]   ts_hit; reg eios_hit, skp_hit;
    always @(*) begin
        eios_hit = 1'b0; skp_hit = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            // COM in w2 followed by data or PAD: TS1/TS2 (EIEOS / FTS / SKP / IDL have K there)
            ts_hit[i] = w2v && w2com[i] && (!wk[i + 1] || wpad[i + 1]);
            if (w2v && w2com[i] && wk[i + 1] && wd[8*(i+1) +: 8] == K_IDL) eios_hit = 1'b1;
            if (w2v && w2com[i] && wk[i + 1] && wd[8*(i+1) +: 8] == K_SKP) skp_hit = 1'b1;
        end
    end
    reg        a_v; reg [2:0] a_p; reg [191:0] a_wd; reg [23:0] a_wk, a_wpad; reg a_eios, a_skp;
    reg        a_idle;
    reg  [3:0] idle_run; reg [7:0] d_idl8; reg [4:0] idle_lead; reg [3:0] idle_tail; reg idle_stop;
    always @(*) begin
        for (i = 0; i < 8; i = i + 1) d_idl8[i] = !d_k[i] && d_d[8*i +: 8] == 8'd0;
        idle_lead = 5'd0; idle_stop = 1'b0;
        for (i = 0; i < 8; i = i + 1) if (!idle_stop) begin
            if (d_idl8[i]) idle_lead = idle_lead + 1'b1; else idle_stop = 1'b1;
        end
`ifndef EERIE_W8_IDLEPRE
        idle_tail = 4'd0; idle_stop = 1'b0;
        for (i = 7; i >= 0; i = i - 1) if (!idle_stop) begin
            if (d_idl8[i]) idle_tail = idle_tail + 1'b1; else idle_stop = 1'b1;
        end
`endif
    end
`ifdef EERIE_W8_IDLEPRE
    // TASK-6161 (GateMate): prefix ANDs instead of the two counting adder chains; lead_ok[k] = first k
    // symbols idle, tail_ok[k] = last k symbols idle (thermometer), tail = highest k
    reg [8:0] lead_ok; reg [7:0] tail_ok;
    always @(*) begin
        lead_ok[0] = 1'b1; tail_ok[0] = 1'b1;
        for (i = 1; i <= 8; i = i + 1) lead_ok[i] = lead_ok[i-1] && d_idl8[i-1];
        for (i = 1; i < 8; i = i + 1) tail_ok[i] = tail_ok[i-1] && d_idl8[8-i];
        idle_tail = 4'd0;
        for (i = 1; i < 8; i = i + 1) if (tail_ok[i]) idle_tail = i;
    end
`endif
    reg  [2:0] p_first; reg p_any;
    always @(*) begin
        p_first = 3'd0; p_any = 1'b0;
        for (i = 7; i >= 0; i = i - 1) if (ts_hit[i]) begin p_first = i; p_any = 1'b1; end
    end
    always @(posedge clk) begin
        if (rst || !d_v) begin w1v <= 1'b0; w2v <= 1'b0; end
        else begin w1v <= d_v; w2v <= w1v; end
        w1d <= d_d; w1k <= d_k; w1com <= d_com; w1pad <= d_pad; w1skp <= d_skp; w1idl <= d_idl;
        w2d <= w1d; w2k <= w1k; w2com <= w1com; w2pad <= w1pad; w2skp <= w1skp; w2idl <= w1idl;
        a_v <= p_any && !rst; a_p <= p_first; a_wd <= wd; a_wk <= wk; a_wpad <= wpad;
        a_eios <= eios_hit && !rst; a_skp <= skp_hit && !rst;
        // run of idle data symbols (descrambled 00, not K) across words
        if (rst || !d_v) idle_run <= 4'd0;
        else idle_run <= (d_idl8 == 8'hFF) ? ((idle_run > 4'd7) ? 4'd15 : idle_run + 4'd8) : idle_tail;
`ifdef EERIE_W8_IDLEPRE
        a_idle <= d_v && !rst && (idle_run[3] || lead_ok[4'd8 - idle_run]);
`else
        a_idle <= d_v && !rst && (idle_run + idle_lead >= 5'd8);
`endif
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
    // PA: in-packet mask (STP/SDP .. END/EDB; any other K inside a packet is kept and ends it, so
    // that eerie_pl_rx_ml reports the framing error)
`ifdef EERIE_W8_PAPRE
    // TASK-6161 (GateMate): stage PP evaluates the in-packet scan for both start states (word begins
    // outside / inside a packet), independent of in_pkt and phase; the PA feedback is then one select.
    // Packed: {n_in, has_st, j0[3:0], cnt[3:0], cnt_flush[3:0], m[7:0], m_flush[7:0]}
    // two steps: PP0 scans the masks for both start states, PP1 counts (j0, popcounts)
    // PP0 packed: {n_in, has_st, st_pos[2:0], m[7:0]}
    function [12:0] pscan; input in0; input v; input [7:0] k, stp, sdp;
        integer x; reg ni, hs; reg [2:0] sp; reg [7:0] mx;
        begin
            ni = in0; mx = 8'd0; hs = 1'b0; sp = 3'd0;
            for (x = 0; x < 8; x = x + 1) begin
                if (ni) begin
                    mx[x] = 1'b1;
                    if (k[x]) ni = 1'b0;                       // END / EDB / framing error / start inside
                end else if (stp[x] || sdp[x]) begin
                    mx[x] = 1'b1; ni = 1'b1;
                    if (!hs) begin hs = 1'b1; sp = x; end
                end
            end
            if (!v) begin mx = 8'd0; ni = 1'b0; hs = 1'b0; end
            pscan = {ni, hs, sp, mx};
        end
    endfunction
    // PP1 packed: {rank_flush[23:0], rank[23:0], n_in, has_st, j0[3:0], cnt[3:0], cnt_flush[3:0], m[7:0],
    // m_flush[7:0]}; rank of byte x = set mask bits below x (its position after the PB compaction)
    function [77:0] pcount; input [12:0] q;
        integer x; reg [3:0] j0x, cn, cf; reg [7:0] mf; reg [23:0] rn, rf;
        begin
            mf = q[7:0]; cn = 4'd0; cf = 4'd0; j0x = 4'd0;
            for (x = 0; x < 8; x = x + 1) begin
                if (q[11] && x < q[10:8] && q[x]) j0x = j0x + 1'b1;
                if (x < q[10:8]) mf[x] = 1'b0;
                rn[3*x +: 3] = cn[2:0]; rf[3*x +: 3] = cf[2:0];
                cn = cn + q[x]; cf = cf + mf[x];
            end
            pcount = {rf, rn, q[12], q[11], j0x, cn, cf, q[7:0], mf};
        end
    endfunction
    reg [12:0] p0_s0, p0_s1; reg [63:0] p0_d; reg [7:0] p0_k; reg p0_e;
    reg [77:0] pp_s0, pp_s1; reg [63:0] pp_d; reg [7:0] pp_k; reg pp_e;
    always @(posedge clk) begin
        p0_s0 <= pscan(1'b0, d_v, d_k, d_stp, d_sdp); p0_s1 <= pscan(1'b1, d_v, d_k, d_stp, d_sdp);
        p0_d <= d_d; p0_k <= d_k; p0_e <= d_err;
        pp_s0 <= pcount(p0_s0); pp_s1 <= pcount(p0_s1);
        pp_d <= p0_d; pp_k <= p0_k; pp_e <= p0_e;
    end
    reg        in_pkt; reg [1:0] phase;
    wire [77:0] pp_s = in_pkt ? pp_s1 : pp_s0;
    wire       flush = pp_s[28] && ((phase + pp_s[25:24]) & 2'd3) != 2'd0;
    wire [7:0] m2 = flush ? pp_s[7:0] : pp_s[15:8];
    wire [3:0] cnt_all = flush ? pp_s[19:16] : pp_s[23:20];
    reg [63:0] pa_d; reg [7:0] pa_k, pa_m; reg pa_e, pa_fl; reg [23:0] pa_rk; reg [3:0] pa_cnt;
    always @(posedge clk) begin
        pa_rk <= flush ? pp_s[77:54] : pp_s[53:30]; pa_cnt <= rst ? 4'd0 : cnt_all;
        if (rst) begin in_pkt <= 1'b0; phase <= 2'd0; end
        else begin
            in_pkt <= pp_s[29];
            phase <= flush ? cnt_all[1:0] : phase + cnt_all[1:0];
        end
        pa_d <= pp_d; pa_k <= pp_k; pa_m <= rst ? 8'd0 : m2; pa_e <= pp_e; pa_fl <= flush && !rst;
    end
`else
    reg        in_pkt, phase_any; reg [1:0] phase;
    reg [7:0]  m; reg st_in; reg n_in; reg [3:0] j0, cnt_all; reg has_st; reg [2:0] st_pos;
    always @(*) begin
        n_in = in_pkt; m = 8'd0; has_st = 1'b0; st_pos = 3'd0; j0 = 4'd0;
        for (i = 0; i < 8; i = i + 1) begin
            if (n_in) begin
                m[i] = 1'b1;
                if (d_k[i] && !d_stp[i] && !d_sdp[i]) n_in = 1'b0;        // END / EDB / framing error
                else if (d_k[i]) n_in = 1'b0;                                // start inside a packet
            end else if (d_stp[i] || d_sdp[i]) begin
                m[i] = 1'b1; n_in = 1'b1;
                if (!has_st) begin has_st = 1'b1; st_pos = i; end
            end
        end
        if (!d_v) begin m = 8'd0; n_in = 1'b0; has_st = 1'b0; end
        for (i = 0; i < 8; i = i + 1) if (has_st && i < st_pos && m[i]) j0 = j0 + 1'b1;
    end
    // a start off a slot boundary: drop the partial slot and the bytes before the start
    wire       flush = has_st && ((phase + j0[1:0]) & 2'd3) != 2'd0;
    reg [7:0]  m2;
    always @(*) begin
        m2 = m;
        if (flush) for (i = 0; i < 8; i = i + 1) if (i < st_pos) m2[i] = 1'b0;
        cnt_all = 4'd0;
        for (i = 0; i < 8; i = i + 1) cnt_all = cnt_all + m2[i];
    end
    reg [63:0] pa_d; reg [7:0] pa_k, pa_m; reg pa_e, pa_fl;
    always @(posedge clk) begin
        if (rst) begin in_pkt <= 1'b0; phase <= 2'd0; end
        else begin
            in_pkt <= n_in;
            phase <= flush ? cnt_all[1:0] : phase + cnt_all[1:0];
        end
        pa_d <= d_d; pa_k <= d_k; pa_m <= rst ? 8'd0 : m2; pa_e <= d_err; pa_fl <= flush && !rst;
    end
`endif
    // PB: compaction (byte of rank r -> position r)
    reg [7:0] cw [0:7]; reg [7:0] cwk; reg [3:0] rk; reg [3:0] ccnt;
`ifdef EERIE_W8_PAPRE
    // ranks from PP1: output byte j = the masked byte of rank j (one-hot OR, no running count)
    always @(*) begin
        for (j = 0; j < 8; j = j + 1) begin
            cw[j] = 8'd0; cwk[j] = 1'b0;
            for (i = 0; i < 8; i = i + 1) if (pa_m[i] && pa_rk[3*i +: 3] == j) begin
                cw[j] = cw[j] | pa_d[8*i +: 8]; cwk[j] = cwk[j] | pa_k[i];
            end
        end
        rk = 4'd0; ccnt = pa_cnt;
    end
`else
    always @(*) begin
        for (j = 0; j < 8; j = j + 1) begin cw[j] = 8'd0; cwk[j] = 1'b0; end
        rk = 4'd0;
        for (i = 0; i < 8; i = i + 1) if (pa_m[i]) begin
            for (j = 0; j < 8; j = j + 1) if (rk == j) begin cw[j] = pa_d[8*i +: 8]; cwk[j] = pa_k[i]; end
            rk = rk + 1'b1;
        end
        ccnt = rk;
    end
`endif
    reg [63:0] pb_d; reg [7:0] pb_k; reg [3:0] pb_n; reg pb_e, pb_fl;
    always @(posedge clk) begin
        for (j = 0; j < 8; j = j + 1) pb_d[8*j +: 8] <= cw[j];
        pb_k <= cwk; pb_n <= rst ? 4'd0 : ccnt; pb_e <= pa_e && pa_m != 8'd0; pb_fl <= pa_fl;
    end
    // PC: slot queue (12 bytes), 0 / 1 / 2 slots out per clock
    reg [7:0] qd [0:11]; reg [11:0] qk, qe; reg [3:0] occ;
    reg [7:0] nd [0:11]; reg [11:0] nk, ne; reg [3:0] npop, r, nocc;
    always @(*) begin
        npop = (occ >= 4'd8) ? 4'd8 : (occ >= 4'd4) ? 4'd4 : 4'd0;
        r = pb_fl ? 4'd0 : occ - npop;
        for (j = 0; j < 12; j = j + 1) begin
            if (j < r) begin           // j + npop <= 11 (r <= 3); explicit 3:1 select, no index arithmetic
                nd[j] = (npop == 4'd8) ? qd[(j + 8) & 15] : (npop == 4'd4) ? qd[j + 4] : qd[j];
                nk[j] = (npop == 4'd8) ? qk[(j + 8) & 15] : (npop == 4'd4) ? qk[j + 4] : qk[j];
                ne[j] = (npop == 4'd8) ? qe[(j + 8) & 15] : (npop == 4'd4) ? qe[j + 4] : qe[j];
            end
            else if (j - r < 8) begin nd[j] = pb_d[8*(j-r) +: 8]; nk[j] = pb_k[j-r]; ne[j] = pb_e; end
            else begin nd[j] = 8'd0; nk[j] = 1'b0; ne[j] = 1'b0; end
        end
        nocc = r + pb_n;
    end
    always @(posedge clk) begin
        if (rst) begin occ <= 4'd0; sl_va <= 1'b0; sl_vb <= 1'b0; end
        else begin
            occ <= nocc;
            sl_va <= occ >= 4'd4; sl_vb <= occ >= 4'd8;
        end
        for (j = 0; j < 12; j = j + 1) begin qd[j] <= nd[j]; qk[j] <= nk[j]; qe[j] <= ne[j]; end
        sl_da <= {qd[3], qd[2], qd[1], qd[0]}; sl_ka <= qk[3:0]; sl_ea <= |qe[3:0];
        sl_db <= {qd[7], qd[6], qd[5], qd[4]}; sl_kb <= qk[7:4]; sl_eb <= |qe[7:4];
        rx_err <= r_err && r_v;
    end
endmodule
