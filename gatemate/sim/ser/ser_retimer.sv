// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6170, simulation only: a retimer on the EP -> RC line, for runs with the EP reference clock off
// nominal (+ppm). pcieVHost's serial receiver (PcieVhostSerial / Serialiser) samples with its own clock and
// has no CDR, so any frequency offset slips a bit every 1/ppm UI. This model takes the line at the EP's rate
// (ideal line: the bits between two edges are their distance in UI_IN), aligns on K28.5, keeps a symbol FIFO
// that removes / repeats K28.0 (SKP, disparity neutral) inside SKP ordered sets, and sends at 2 serclk per UI.
// Electrical idle (no edge for 40 UI) passes through as a constant 0, as the host's own idle.
// TASK-6173: gen2 = 1 sends one bit per serclk (5.0 GT/s).
module ser_retimer (
  input  logic serclk,       // 5 GHz: one UI out = 2 periods (the host's own bit clock)
  input  logic din,
  input  real  ui_in_ps,     // EP UI
  input  logic gen2,         // TASK-6173: 5.0 GT/s: one UI out = 1 period
  output logic dout,
  output int   n_ins,
  output int   n_del
);
  localparam [9:0] COMN = 10'b0011111010, COMP = 10'b1100000101;   // K28.5, time order (a first)
  localparam [9:0] SKPN = 10'b0011110100, SKPP = 10'b1100001011;   // K28.0
  localparam int LO = 4, MID = 8, HI = 12;

  logic [9:0] fifo [$];
  logic [9:0] w = '0;
  int         nb = -1;           // bits into the current symbol, -1: not aligned
  bit         idle = 1'b1, lvl = 1'b0, in_skp = 1'b0;
  int         skp_run = 0;
  realtime    t_prev = 0;

  initial begin n_ins = 0; n_del = 0; end

  function automatic bit is_skp(logic [9:0] s); return s == SKPN || s == SKPP; endfunction
  function automatic bit is_com(logic [9:0] s); return s == COMN || s == COMP; endfunction

  task automatic push_bit(bit b);
    w = {w[8:0], b};
    if (is_com(w)) nb = 10;                       // a comma closes a symbol here
    else if (nb >= 0) nb = nb + 1;
    if (nb == 10) begin
      nb = 0;
      if (is_com(w)) begin in_skp = 1'b1; skp_run = 0; end
      else if (is_skp(w) && in_skp) skp_run++;
      else in_skp = 1'b0;
      if (is_skp(w) && in_skp && skp_run >= 2 && fifo.size() > HI) n_del++;   // keep one SKP at least
      else fifo.push_back(w);
    end
  endtask

  // input: bits from edge distances
  always @(din) begin
    realtime now; int n;
    now = $realtime;
    n = $rtoi((now - t_prev) * 1000.0 / ui_in_ps + 0.5);
    if (!idle) for (int i = 0; i < n; i++) push_bit(lvl);
    else begin nb = -1; w = '0; end               // out of idle: realign
    idle = 1'b0; t_prev = now; lvl = din;
  end
  // idle: no edge for 40 UI
  always begin
    #(ui_in_ps * 40 * 1ps);
    if (!idle && ($realtime - t_prev) * 1000.0 > 40.0 * ui_in_ps) idle = 1'b1;
  end

  // output: one bit per 2 serclk
  logic [9:0] cur; int ob = 10; bit ph = 1'b0, started = 1'b0, last_skp = 1'b0;
  initial dout = 1'b0;
  always @(posedge serclk) begin
    ph <= !ph;
    if (ph || gen2) begin
      if (ob == 10) begin
        if (!started && fifo.size() >= MID) started = 1'b1;
        if (started && fifo.size() > 0) begin
          cur = fifo.pop_front(); ob = 0;
          if (is_skp(cur) && fifo.size() < LO) begin fifo.push_front(cur); n_ins++; end   // repeat it
        end else begin
          started = 1'b0;
        end
      end
      if (ob < 10) begin dout <= cur[9 - ob]; ob = ob + 1; end
      else dout <= 1'b0;                          // idle (or starved): constant 0
    end
  end
endmodule
