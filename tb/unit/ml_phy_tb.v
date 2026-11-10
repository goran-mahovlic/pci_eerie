// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie unit test: multi-lane PHY loopback (no GT model)
//   packet words (as framed by the DLL) -> eerie_pl_tx_ml -> N x eerie_pl_tx -> per-lane skew
//   -> N x eerie_pl_rx -> eerie_pl_deskew -> eerie_pl_rx_ml -> entries, checked against the sent
//   TLPs / DLLPs (contents and no error flag).
//   run: tb/unit/run_ml_phy.sh [W] [skew0 skew1 skew2 skew3]
`timescale 1ns / 1ps
module ml_phy_tb;
    parameter N = 4;
    parameter W = 4;                       // link width (2 or 4)
    parameter [8*4-1:0] SKEW = 32'h00010302; // per-lane skew in symbols (lane l in [8l+7:8l])
    parameter NPKT = 300;
    `include "eerie_funcs.vh"

    reg clk = 0, rst = 1;
    always #2 clk = ~clk;

    // ---------------- packet FIFO model (FWFT) ----------------
    reg [66:0] fq [0:65535];
    integer    fw = 0, fr = 0;
    wire       f_empty = (fw == fr);
    wire [66:0] f_data = fq[fr];
    wire       f_pop;
    always @(posedge clk) if (f_pop && !f_empty) fr <= fr + 1;

    // expected DW stream per packet: TLP DWs (or 1 DLLP DW), kept in order
    reg [31:0] exp_dw [0:262143];
    integer    exp_len [0:4095];
    reg        exp_dllp [0:4095];
    integer    exp_n = 0, exp_w = 0;

    task put_word; input half, last, sop; input [63:0] d; begin fq[fw] = {half, last, sop, d}; fw = fw + 1; end endtask
    // frame a byte stream into words
    reg [7:0] bs [0:8191]; integer bn;
    task flush_bytes; integer i; reg [63:0] d; begin
        for (i = 0; i < bn; i = i + 8) begin
            d = {bs[i], bs[i+1], bs[i+2], bs[i+3], (i+4 < bn) ? bs[i+4] : 8'h00, (i+5 < bn) ? bs[i+5] : 8'h00,
                 (i+6 < bn) ? bs[i+6] : 8'h00, (i+7 < bn) ? bs[i+7] : 8'h00};
            put_word(i + 4 >= bn, i + 8 >= bn, i == 0, d);
        end
    end endtask
    reg exp_bad [0:4095]; reg badcrc = 0; integer nbad = 0;
    initial badcrc = $test$plusargs("badcrc");
    task send_tlp; input integer ndw; input [11:0] seq; integer i; reg [31:0] c, dw, lc; begin
        bn = 0;
        bs[bn] = 8'hFB; bn = bn + 1; bs[bn] = {4'h0, seq[11:8]}; bn = bn + 1; bs[bn] = seq[7:0]; bn = bn + 1;
        c = f_crc32_byte(f_crc32_byte(32'hFFFFFFFF, {4'h0, seq[11:8]}), seq[7:0]);
        exp_len[exp_n] = ndw; exp_dllp[exp_n] = 0; exp_n = exp_n + 1;
        for (i = 0; i < ndw; i = i + 1) begin
            dw = $random;
            if (i == 0) dw = {3'b010, 5'b00000, 14'd0, ndw[9:0] - 10'd3};   // looks like a MWr header
            exp_dw[exp_w] = dw; exp_w = exp_w + 1;
            c = f_crc32_dw(c, dw);
            bs[bn] = dw[31:24]; bs[bn+1] = dw[23:16]; bs[bn+2] = dw[15:8]; bs[bn+3] = dw[7:0]; bn = bn + 4;
        end
        lc = f_lcrc_field(c);
        exp_bad[exp_n - 1] = badcrc && (exp_n % 5 == 2);    // +badcrc: corrupt every 5th LCRC
        if (exp_bad[exp_n - 1]) lc[exp_n % 32] = !lc[exp_n % 32];
        bs[bn] = lc[31:24]; bs[bn+1] = lc[23:16]; bs[bn+2] = lc[15:8]; bs[bn+3] = lc[7:0]; bn = bn + 4;
        bs[bn] = 8'hFD; bn = bn + 1;
        flush_bytes;
    end endtask
    task send_dllp; reg [31:0] d; reg [15:0] cr; begin
        d = $random; d[31:24] = 8'h00;     // Ack-like
        cr = f_dllp_crc(d);
        put_word(1'b0, 1'b1, 1'b1, {8'h5C, d, cr, 8'hFD});
        exp_len[exp_n] = 1; exp_dllp[exp_n] = 1; exp_n = exp_n + 1; exp_dw[exp_w] = d; exp_w = exp_w + 1;
    end endtask

    // ---------------- TX ----------------
    wire [8*N-1:0] st_s0, st_s1; wire [N-1:0] st_k0, st_k1; wire st_idle, st_busy;
    eerie_pl_tx_ml #(.N(N), .SKP_INTERVAL(300)) tx_ml (
        .clk(clk), .rst(rst), .en(1'b1), .w4(W == 4), .run(1'b1), .data_mode(1'b1),
        .pkt_rd_data(f_data), .pkt_rd_empty(f_empty), .pkt_rd_en(f_pop),
        .s0(st_s0), .s1(st_s1), .k0(st_k0), .k1(st_k1), .idle(st_idle), .busy(st_busy));
    wire [16*N-1:0] txd; wire [2*N-1:0] txk; wire [N-1:0] txei;
    // ---------------- RX ----------------
    wire [N-1:0] ln_v, ln_err; wire [16*N-1:0] ln_d; wire [2*N-1:0] ln_k, ln_com, ln_skp;
    reg  [16*N-1:0] rxd; reg [2*N-1:0] rxk; reg [N-1:0] rxv;
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : lane
        eerie_pl_tx pl_tx (.clk(clk), .rst(rst), .mode((g < W) ? 3'd3 : 3'd0), .ts_link(8'd0), .ts_link_pad(1'b0),
            .ts_lane(g), .ts_lane_pad(1'b0), .ts_nfts(8'd0), .ts_rate(8'd2), .ts_ctrl(8'd0), .scramble_en(1'b1),
            .gen2(1'b0), .eieos_clr(1'b0), .ts_done(), .eios_done(), .idle_pair(), .busy(),
            .ext_en(g < W), .ext_busy(st_busy), .ext_s0(st_s0[8*g +: 8]), .ext_s1(st_s1[8*g +: 8]),
            .ext_k0(st_k0[g]), .ext_k1(st_k1[g]), .ext_idle(st_idle),
            .pkt_rd_data(67'd0), .pkt_rd_empty(1'b1), .pkt_rd_en(),
            .pipe_txdata(txd[16*g +: 16]), .pipe_txdatak(txk[2*g +: 2]), .pipe_txelecidle(txei[g]));
        // symbol skew: a shift register of symbols; with +elastic lane 1 alternately gains and loses
        // a SKP symbol in each SKP ordered set (GT elastic buffer clock compensation)
        reg [8:0] sh [0:15]; reg shv [0:15]; integer i, s, sk, nel; reg ins;
        initial begin sk = SKEW[8*g +: 8]; ins = 1'b1; nel = 0; end
        always @(posedge clk) begin
            if ($test$plusargs("elastic") && g == 1) begin
                if (ins && sh[sk] == {1'b1, 8'h1C} && sk < 12) begin sk <= sk + 1; ins <= 1'b0; nel = nel + 1; end
                else if (!ins && sk > 0 && sh[sk-1] == {1'b1, 8'h1C}) begin sk <= sk - 1; ins <= 1'b1; nel = nel + 1; end
            end
            for (i = 15; i >= 2; i = i - 1) begin sh[i] <= sh[i-2]; shv[i] <= shv[i-2]; end
            // sh[0] = newest symbol (PIPE slot 1), sh[1] = the one before it (slot 0)
            sh[0] <= {txk[2*g+1], txd[16*g+8 +: 8]}; shv[0] <= !txei[g];
            sh[1] <= {txk[2*g],   txd[16*g +: 8]};   shv[1] <= !txei[g];
        end
        always @(*) begin
            s = sk;
            // the pair delivered: symbols s+1 (older, slot 0) and s (slot 1) of the history
            rxd[16*g +: 8] = sh[s+1][7:0]; rxk[2*g] = sh[s+1][8];
            rxd[16*g+8 +: 8] = sh[s][7:0]; rxk[2*g+1] = sh[s][8];
            rxv[g] = shv[s+1] === 1'b1 && shv[s] === 1'b1;
        end
        eerie_pl_rx pl_rx (.clk(clk), .rst(rst), .pipe_rxdata(rxd[16*g +: 16]), .pipe_rxdatak(rxk[2*g +: 2]),
            .pipe_rxvalid(rxv[g]), .pipe_rxstatus(3'd0), .pipe_rxelecidle(!rxv[g]), .descramble_en(1'b1),
            .os_ts_valid(), .os_ts2(), .os_ts_inv(), .os_link(), .os_link_pad(), .os_lane(), .os_lane_pad(),
            .os_nfts(), .os_rate(), .os_ctrl(), .os_eios(), .os_skp(), .os_idle2(), .os_pkt_start(), .rx_err(),
            .pkt_we(), .pkt_wd(),
            .ln_v(ln_v[g]), .ln_d(ln_d[16*g +: 16]), .ln_k(ln_k[2*g +: 2]), .ln_com(ln_com[2*g +: 2]),
            .ln_skp(ln_skp[2*g +: 2]), .ln_err(ln_err[g]));
    end endgenerate
    wire d_va, d_vb, d_ea, d_eb; wire [8*N-1:0] d_da, d_db; wire [N-1:0] d_ka, d_kb;
    eerie_pl_deskew #(.N(N)) deskew (.clk(clk), .rst(rst), .act((N'(1) << W) - 1),
        .ln_v(ln_v), .ln_d(ln_d), .ln_k(ln_k), .ln_com(ln_com), .ln_skp(ln_skp), .ln_err(ln_err),
        .o_va(d_va), .o_vb(d_vb), .o_da(d_da), .o_db(d_db), .o_ka(d_ka), .o_kb(d_kb), .o_erra(d_ea), .o_errb(d_eb));
    wire m_we, m_err; wire [81:0] m_wd;
    eerie_pl_rx_ml #(.N(N)) rx_ml (.clk(clk), .rst(rst), .w4(W == 4),
        .i_va(d_va), .i_vb(d_vb), .i_da(d_da), .i_db(d_db), .i_ka(d_ka), .i_kb(d_kb), .i_erra(d_ea), .i_errb(d_eb),
        .rx_err(m_err), .pkt_we(m_we), .pkt_wd(m_wd));

    // ---------------- debug trace (+trace) ----------------
    always @(posedge clk) if ($test$plusargs("trace") && $time < 1800000) begin
        $display("%0t ST s0=%h s1=%h k0=%b k1=%b pop=%b | DK va=%b vb=%b da=%h db=%h ka=%b kb=%b | cnt0=%0d cnt1=%0d",
                 $time, st_s0, st_s1, st_k0, st_k1, f_pop, d_va, d_vb, d_da, d_db, d_ka, d_kb,
                 deskew.wp[0] - deskew.rp[0], deskew.wp[1] - deskew.rp[1]);
    end

    always @(posedge clk) if ($test$plusargs("trace3") && $time > 1690 && $time < 1712)
        $display("%0t DS wp0=%0d rp0=%0d p_v=%b p_skp=%b ln_v=%b popc0=%0d pa=%b pb=%b", $time, deskew.wp[0], deskew.rp[0],
                 deskew.p_v, deskew.p_skp[1:0], ln_v, deskew.popc[0], deskew.pa, deskew.pb);
    always @(posedge clk) if ($test$plusargs("trace2") && $time > 1680 && $time < 1712)
        $display("%0t L0 txd=%h txk=%b txei=%b | rxd=%h rxk=%b rxv=%b | ln_v=%b ln_d=%h ln_k=%b skp=%b com=%b | pltx st=%0d ext_act=%b",
                 $time, txd[15:0], txk[1:0], txei[0], rxd[15:0], rxk[1:0], rxv[0], ln_v[0], ln_d[15:0], ln_k[1:0],
                 ln_skp[1:0], ln_com[1:0], lane[0].pl_tx.st, lane[0].pl_tx.ext_act);

    // ---------------- checker ----------------
    integer got = 0, rd = 0, errs = 0, k, pk = 0;
    reg [31:0] cur [0:4095]; integer cn = 0;
    always @(posedge clk) if (m_we) begin
        if (m_wd[78]) begin                       // DLLP
            if (m_wd[79]) begin $display("[%0t] ERR DLLP %0d flagged bad", $time, pk); errs = errs + 1; end
            if (!exp_dllp[pk] || exp_dw[rd] !== m_wd[63:32]) begin
                $display("[%0t] ERR DLLP %0d mismatch %h exp %h (dllp=%0d)", $time, pk, m_wd[63:32], exp_dw[rd], exp_dllp[pk]);
                errs = errs + 1;
            end
            rd = rd + exp_len[pk]; pk = pk + 1;
        end else if (!m_wd[77]) begin             // data beat
            cur[cn] = m_wd[63:32]; cur[cn+1] = m_wd[31:0]; cn = cn + 2;
        end else begin                            // end marker
            if (m_wd[81]) begin cur[cn] = m_wd[63:32]; cn = cn + 1; end
            if (m_wd[79] && exp_bad[pk] && !m_wd[80]) nbad = nbad + 1;
            else if (m_wd[79] || m_wd[80] || exp_bad[pk]) begin $display("[%0t] ERR TLP %0d flagged bad=%0d null=%0d exp_bad=%0d (%0d DW)", $time, pk, m_wd[79], m_wd[80], exp_bad[pk], exp_len[pk]); errs = errs + 1; end
            if (exp_dllp[pk] || cn != exp_len[pk]) begin
                $display("[%0t] ERR TLP %0d length %0d exp %0d", $time, pk, cn, exp_len[pk]); errs = errs + 1;
            end else for (k = 0; k < cn; k = k + 1) if (cur[k] !== exp_dw[rd + k]) begin
                $display("[%0t] ERR TLP %0d DW %0d %h exp %h", $time, pk, k, cur[k], exp_dw[rd + k]); errs = errs + 1;
            end
            rd = rd + exp_len[pk]; pk = pk + 1; cn = 0;
        end
    end

    integer p, len;
    initial begin
        repeat (10) @(posedge clk); rst = 0;
        repeat (400) @(posedge clk);        // first SKP OS syncs the descramblers / deskew
        for (p = 0; p < NPKT; p = p + 1) begin
            len = 3 + ($random & 32'h3F);
            if (($random & 3) == 0) send_dllp; else send_tlp(len, p[11:0]);
            if (($random & 7) == 0) repeat ($random & 15) @(posedge clk);
        end
        wait (fr == fw);
        repeat (200) @(posedge clk);
        $display("lane 1 elastic SKP insertions/removals: %0d", lane[1].nel);
        if (badcrc) $display("bad LCRC TLPs flagged: %0d", nbad);
        $display("ml_phy_tb W=%0d skew=%h: %0d packets checked of %0d, %0d errors -> %s", W, SKEW, pk, exp_n, errs,
                 (errs == 0 && pk == exp_n) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
