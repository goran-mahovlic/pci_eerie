// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6190: DL event trace (ILA) for pci_eerie W8 — BRAM ring of 2**AW entries x 64 bit, read over BAR0 and dumped on a
// UART (works when PCIe is dead). One clock (uclk = pclk with EERIE_1CLK); no reset: survives link resets and rebinds.
//
// Entry: [63:44] time (uclk, 32 ns, wraps 33.5 ms)  [43:30] events  [29:18] seqA  [17:6] seqB  [5:0] LTSSM
//   events: 0 TLP sent (new)  1 TLP sent (replay)  2 Ack rx  3 Nak rx  4 EP replay timeout  5 EP replay start
//           6 DL protocol error (Ack/Nak out of range)  7 EP Ack/Nak sent  8 TLP rx ok  9 TLP rx duplicate
//           10 bad TLP/DLLP rx  11 EP REPLAY_NUM rollover  12 LTSSM changed  13 replay timer off with TLPs unAcked
//   seqA = seq of the TLP sent (0/1), else ACKD_SEQ;  seqB = AckNak_Seq rx (2/3), else Ack/Nak seq sent (7), else NEXT_RCV_SEQ
// Trigger: (events & trig_mask) while armed -> POST more entries are written, then frozen (and dumped on the UART once).
// Recorded: entries with (events & rec_mask) != 0.  Power-on: armed, trig = replay timeout, rec = all.
//
// Control (bar0 app, BAR0 bit 10 set, 3DW): write 0x400 {trig_mask[15:0], rec_mask[15:0]} + re-arm (trig bit 15 = now),
//   write 0x404 read index.  Read 0x400 status {frozen, armed, triggered, wrapped, 2'b0, wptr[9:0], 6'b0, ridx[9:0]},
//   0x404 masks, 0x408 entry[31:0] at ridx, 0x40C entry[63:32] (then ridx+1), 0x410 {trig_ptr, cnt_win}, 0x414 ppm word,
//   0x418 DLL state, 0x41C "ILA2".
// UART 8N1 (DIV clocks/bit): once a frozen buffer is complete, lines "E iiiiiiii hhhhhhhh llllllll tttttttt" oldest first
//   (i = index, h/l = entry, t = trigger position); every 2**STW clocks a status line "S pppppppp ssssssss cccccccc tttttttt"
//   (p = ppm word, s = status, c = cnt word, t = {dll_st, time[31:16]}). Commands: 'a' re-arm, 'f' trigger now, 'd' dump again.
//   ILA2 (TASK-6190 r2): dll_st = {link_l0, dls, txq_slots, unAcked TLPs, replay_timer_on}; 0x418 reads it.
// ILA3 (TASK-6192, EERIE_ILA3): word records — raw PIPE words (RX after the EB, or TX before the SerDes; descramble offline,
//   sw/ila/ila3_dek.py). A second BRAM holds a 16-bit extension per entry: 0 for event entries, for word entries
//   {1, src (1 = TX), valid (RX: rxvalid, TX: !txelecidle), RX elec idle, RX status err (RxStatus[2]), t[2:0], K mask[7:0]}
//   with the 64 data bits (symbol 0 in [7:0]) in the main entry. An event entry wins its clock (that word is skipped).
//   rec_mask[14]: words while LTSSM = Recovery.RcvrCfg / Recovery.Idle;  rec_mask[15]: words in L0 while TLPs are unAcked
//   and no Ack made progress for >= AGE clocks.  trig_mask[14]: Recovery.Idle lasted RIDLE_T clocks.
//   Source: write 0x408 bit 0 (1 = TX) or UART 'r' / 't'.  0x418 = {ext of the entry at ridx, dll_st}; UART "E" lines carry
//   the extension in the top half of the 4th word ({ext, tptr}).  Magic 0x41C "ILA3".
`timescale 1ns / 1ps
module eerie_ila #(
    parameter AW   = 10,
    parameter POST = 256,
    parameter DIV  = 271,      // 31.25 MHz / 115200
    parameter STW  = 25,       // status line every 2**25 clocks (1.07 s)
    parameter AGE  = 160,      // ILA3: L0 word window opens this many clocks (5.1 us) after the last Ack progress
    parameter RIDLE_T = 128    // ILA3: Recovery.Idle dwell trigger (4.1 us; normal exit ~0.9 us)
) (
    input             clk,
    input      [11:0] ev_in,   // DLL pulses (bit 5 = replay_req level, the start is its fall)
    input      [11:0] seqa,
    input      [11:0] seqb,
    input      [5:0]  ltssm,
    input      [31:0] ppm_w,   // phy: {signed rclk - pclk count over the last window}
    input      [31:0] cnt_w,   // free word for the status line (DBGCNT counters)
    input      [15:0] dll_st,  // {link_l0, dls[1:0], txq_slots[5:0], unAcked[5:0], replay_timer_on}
    input             we,
    input      [2:0]  wa,
    input      [31:0] wd,
    input      [2:0]  ra,
    output reg [31:0] rd,
    input             rd_next, // pulse: entry hi word read -> ridx + 1
`ifdef EERIE_ILA3
    input      [63:0] w_rd,    // TASK-6192: PIPE RX word (after the EB), symbol 0 in [7:0]
    input      [7:0]  w_rk,
    input      [2:0]  w_rf,    // {RxStatus[2], rxelecidle, rxvalid}
    input      [63:0] w_td,    // PIPE TX word
    input      [7:0]  w_tk,
    input             w_tei,   // txelecidle
`endif
    output reg        uart_tx = 1'b1,
    input             uart_rx
);
    localparam N = 1 << AW;
    reg [63:0] mem [0:N-1];
    reg [31:0] t = 32'd0;
    always @(posedge clk) t <= t + 1'b1;

    // ---------------- capture ----------------
    reg [5:0]  lt_q = 6'd0;
    reg        rr_q = 1'b0;
    reg [15:0] trig_mask = 16'h0010, rec_mask = 16'hFFFF;
    reg        armed = 1'b1, trig = 1'b0, frozen = 1'b0, wrapped = 1'b0, dumped = 1'b0;
    reg [AW-1:0] wptr = 0, tptr = 0, ridx = 0;
    reg [AW:0]   post = 0;
    reg          c_we = 1'b0;
    reg [63:0]   c_d;
    reg          force_t = 1'b0, rearm_u = 1'b0, dump_u = 1'b0;
    reg          dump_done = 1'b0, cmd_v = 1'b0;
    reg [7:0]    cmd = 8'd0;
    reg         ton_q = 1'b0;
    wire [13:0] ev = {ton_q && !dll_st[0] && dll_st[6:1] != 6'd0, lt_q != ltssm, ev_in[11:6], rr_q && !ev_in[5], ev_in[4:0]};
    wire        hit = |(ev & rec_mask[13:0]);
`ifdef EERIE_ILA3
    // TASK-6192: word records. Inputs registered once (timing); LTSSM 0x1D RcvrCfg, 0x20 Recovery.Idle, 0x16 L0
    reg [63:0] w_d = 64'd0; reg [7:0] w_k = 8'd0; reg [2:0] w_f = 3'd0; reg w_src = 1'b0;
    reg [5:0]  ua_q = 6'd0; reg [8:0] age = 9'd0; reg [8:0] rid = 9'd0; reg rid_hit = 1'b0;
    reg        w_rec = 1'b0;
    always @(posedge clk) begin
        w_d <= w_src ? w_td : w_rd; w_k <= w_src ? w_tk : w_rk; w_f <= w_src ? {2'b00, !w_tei} : w_rf;
        ua_q <= dll_st[6:1];
        if (dll_st[6:1] == 6'd0 || dll_st[6:1] < ua_q || ltssm != 6'h16) age <= 9'd0;
        else if (age != 9'h1FF) age <= age + 1'b1;
        if (ltssm != 6'h20) rid <= 9'd0; else if (rid != 9'h1FF) rid <= rid + 1'b1;
        rid_hit <= (rid == RIDLE_T - 1);
        w_rec <= (rec_mask[14] && (ltssm == 6'h1D || ltssm == 6'h20)) || (rec_mask[15] && ltssm == 6'h16 && age >= AGE);
    end
    wire        tg  = |(ev & trig_mask[13:0]) || trig_mask[15] || force_t || (trig_mask[14] && rid_hit);
    reg  [15:0] c_x = 16'd0;
    reg  [15:0] memx [0:N-1];
`else
    wire        tg  = |(ev & trig_mask[13:0]) || trig_mask[15] || force_t;
`endif
    always @(posedge clk) begin
        lt_q <= ltssm; rr_q <= ev_in[5]; ton_q <= dll_st[0];
        c_we <= 1'b0; force_t <= 1'b0;
        if (we && wa == 3'd0) begin
            trig_mask <= {wd[31:16]}; rec_mask <= wd[15:0];
            armed <= 1'b1; trig <= 1'b0; frozen <= 1'b0; wrapped <= 1'b0; dumped <= 1'b0;
        end else if (rearm_u) begin
            armed <= 1'b1; trig <= 1'b0; frozen <= 1'b0; wrapped <= 1'b0; dumped <= 1'b0;
            trig_mask[15] <= 1'b0;
        end else if (!frozen) begin
            if (armed && !trig && tg) begin
                trig <= 1'b1; armed <= 1'b0; tptr <= wptr; post <= POST;
                trig_mask[15] <= 1'b0;
            end
`ifdef EERIE_ILA3
            if (hit || (armed && !trig && tg) || w_rec) begin
                c_we <= 1'b1;
                if (hit || (armed && !trig && tg)) begin c_d <= {t[19:0], ev, seqa, seqb, ltssm}; c_x <= 16'd0; end
                else begin c_d <= w_d; c_x <= {1'b1, w_src, w_f[0], w_f[1], w_f[2], t[2:0], w_k}; end
`else
            if (hit || (armed && !trig && tg)) begin
                c_we <= 1'b1; c_d <= {t[19:0], ev, seqa, seqb, ltssm};
`endif
                wptr <= wptr + 1'b1;
                if (&wptr) wrapped <= 1'b1;
                if (trig) begin
                    post <= post - 1'b1;
                    if (post == 1) frozen <= 1'b1;
                end
            end
        end
        if (dump_done) dumped <= 1'b1;
        if (we && wa == 3'd1) ridx <= wd[AW-1:0];
        else if (rd_next) ridx <= ridx + 1'b1;
        if (cmd_v && cmd == 8'h66) force_t <= 1'b1;   // 'f'
    end
    always @(posedge clk) if (c_we) mem[wptr - 1'b1] <= c_d;
`ifdef EERIE_ILA3
    always @(posedge clk) if (c_we) memx[wptr - 1'b1] <= c_x;
    reg  [15:0]  qx;
    always @(posedge clk) begin
        if (we && wa == 3'd2) w_src <= wd[0];
        else if (cmd_v && cmd == 8'h72) w_src <= 1'b0;   // 'r'
        else if (cmd_v && cmd == 8'h74) w_src <= 1'b1;   // 't'
    end
`endif

    // ---------------- read port (shared: BAR0 index / UART dump) ----------------
    reg          dumping = 1'b0;
    reg [AW:0]   dcnt = 0;
    wire [AW-1:0] daddr = (wrapped ? wptr : {AW{1'b0}}) + dcnt[AW-1:0];
    reg  [63:0]  q;
    always @(posedge clk) q <= mem[dumping ? daddr : ridx];
`ifdef EERIE_ILA3
    always @(posedge clk) qx <= memx[dumping ? daddr : ridx];
`endif

    always @(*) case (ra)
        3'd0: rd = {frozen, armed, trig, wrapped, 2'b00, {(10-AW){1'b0}}, wptr, 6'd0, {(10-AW){1'b0}}, ridx};
        3'd1: rd = {trig_mask, rec_mask};
        3'd2: rd = q[31:0];
        3'd3: rd = q[63:32];
        3'd4: rd = {{(16-AW){1'b0}}, tptr, cnt_w[15:0]};
        3'd5: rd = ppm_w;
`ifdef EERIE_ILA3
        3'd6: rd = {qx, dll_st};
        default: rd = 32'h494C_4133;              // "ILA3"
`else
        3'd6: rd = {16'd0, dll_st};
        default: rd = 32'h494C_4132;              // "ILA2"
`endif
    endcase

    // ---------------- UART ----------------
    // RX: 'a' re-arm, 'f' trigger now, 'd' dump again
    reg [2:0]  rxs = 3'b111;
    reg [15:0] rc = 0;
    reg [3:0]  rb = 0;
    reg [7:0]  rsh = 0;
    reg        rbusy = 1'b0;
    always @(posedge clk) begin
        rxs <= {rxs[1:0], uart_rx}; cmd_v <= 1'b0;
        if (!rbusy) begin
            if (rxs[2:1] == 2'b10) begin rbusy <= 1'b1; rc <= DIV + DIV / 2; rb <= 4'd0; end
        end else if (rc != 0) rc <= rc - 1'b1;
        else begin
            rc <= DIV - 1;
            if (rb == 4'd8) begin rbusy <= 1'b0; if (rxs[2]) begin cmd <= rsh; cmd_v <= 1'b1; end end
            else begin rsh <= {rxs[2], rsh[7:1]}; rb <= rb + 1'b1; end
        end
    end
    always @(posedge clk) begin rearm_u <= cmd_v && cmd == 8'h61; if (cmd_v && cmd == 8'h64) dump_u <= 1'b1; else if (dumping) dump_u <= 1'b0; end

    // TX: a line = prefix + 4 x (space + 8 hex) + CR LF = 39 characters
    reg [31:0] lw [0:3];
    reg [5:0]  ci = 0;
    reg        lbusy = 1'b0;
    reg [7:0]  lpre;
    reg [9:0]  tsh = 10'h3FF;
    reg [15:0] tc = 0;
    reg [3:0]  tb = 0;
    reg        tbusy = 1'b0;
    reg [1:0]  dph = 0;            // dump read pipeline
    reg [1:0]  lgd = 0;            // a new line or character: ch settles 2 clocks after ci / lw change
    wire       lgo = (lgd == 2'd3);
    always @(posedge clk) lgd <= (!lbusy || tbusy) ? 2'd0 : (lgo ? lgd : lgd + 1'b1);
    function [7:0] hx(input [3:0] n); hx = (n < 10) ? 8'h30 + n : 8'h57 + n; endfunction
    // character position ci: 0 prefix, 1..36 = 4 x (space + 8 nibbles), 37 CR, 38 LF. No division: cn (0 = space,
    // 1..8 nibbles) and cw (word) count along, nsh shifts the word out MSB first (TASK-6190: /9 %9 made a 45 ns path)
    reg  [3:0] cn = 0;
    reg  [1:0] cw = 0;
    reg  [31:0] nsh = 0;
    reg  [7:0] ch = 8'h20;          // the character of position ci, registered (stable a whole byte time before use)
    always @(posedge clk) ch <= (ci == 0) ? lpre : (ci == 6'd37) ? 8'h0D : (ci == 6'd38) ? 8'h0A :
                                (cn == 0) ? 8'h20 : hx(nsh[31:28]);
    always @(posedge clk) begin
        dump_done <= 1'b0;
        // byte transmitter
        if (tbusy) begin
            if (tc != 0) tc <= tc - 1'b1;
            else begin
                tc <= DIV - 1;
                if (tb == 4'd10) tbusy <= 1'b0;          // the stop bit has had its full period
                else begin uart_tx <= tsh[0]; tsh <= {1'b1, tsh[9:1]}; tb <= tb + 1'b1; end
            end
        end else if (lbusy && lgo) begin
            tsh <= {1'b1, ch, 1'b0}; tbusy <= 1'b1; tb <= 4'd0; tc <= 0;
            if (ci == 6'd38) begin lbusy <= 1'b0; ci <= 0; end else ci <= ci + 1'b1;
            if (ci == 0) begin cn <= 0; cw <= 0; nsh <= lw[0]; end
            else if (ci <= 6'd36) begin
                if (cn == 0) cn <= 1;                                  // space sent, nsh = lw[cw]
                else begin
                    nsh <= {nsh[27:0], 4'h0};
                    if (cn == 8) begin cn <= 0; cw <= cw + 1'b1; nsh <= lw[cw + 1'b1]; end else cn <= cn + 1'b1;
                end
            end
        end
        // line sources
        if (!lbusy && !tbusy && dph == 0) begin
            if (dumping) begin
                if (dcnt == (wrapped ? N : wptr)) begin dumping <= 1'b0; dump_done <= 1'b1; end
                else dph <= 2'd1;            // q follows daddr in 2 clocks
            end else if (frozen && !dumped && !dump_done || dump_u) begin
                dumping <= 1'b1; dcnt <= 0;
            end else if (t[STW-1:0] == 0) begin
                lpre <= 8'h53; lw[0] <= ppm_w;
                lw[1] <= {frozen, armed, trig, wrapped, 2'b00, {(10-AW){1'b0}}, wptr, 4'd0, ltssm, 2'b00};
                lw[2] <= cnt_w; lw[3] <= {dll_st, t[31:16]}; lbusy <= 1'b1;
            end
        end else if (dph == 2'd1) dph <= 2'd2;
        else if (dph == 2'd2) dph <= 2'd3;
        else if (dph == 2'd3) begin
            dph <= 0; lpre <= 8'h45; lw[0] <= {{(32-AW){1'b0}}, daddr}; lw[1] <= q[63:32]; lw[2] <= q[31:0];
`ifdef EERIE_ILA3
            lw[3] <= {qx, {(16-AW){1'b0}}, tptr}; lbusy <= 1'b1; dcnt <= dcnt + 1'b1;
`else
            lw[3] <= {{(32-AW){1'b0}}, tptr}; lbusy <= 1'b1; dcnt <= dcnt + 1'b1;
`endif
        end
    end
endmodule
