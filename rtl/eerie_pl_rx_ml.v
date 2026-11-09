// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie: multi-lane receive framing (x2 / x4 links), after eerie_pl_deskew
//
// The aligned symbol stream is turned into DWs (4 consecutive symbols) in which every packet
// starts at symbol 0: at x4 a symbol time is one DW (STP/SDP are on lane 0); at x2 two symbol
// times form a DW, and a logical idle symbol time is dropped when a start would otherwise land
// in the second half (packets and ordered sets are an even number of x2 symbol times).
// TLPs (STP, sequence number, TLP, LCRC, END: the TLP DWs sit 3 symbols into the stream DWs)
// and DLLPs (SDP, 4 bytes, CRC16, END) are parsed up to two DWs per clock, LCRC / CRC16 are
// checked, and the result goes to the DLL in the eerie_pl_rx entry format (see there), through
// a small queue (a clock can complete two entries; the average is below one per clock).
`timescale 1ns / 1ps
module eerie_pl_rx_ml #(
    parameter N = 4
) (
    input              clk,
    input              rst,
    input              w4,             // 1: x4, 0: x2
    input              i_va, i_vb,
    input  [8*N-1:0]   i_da, i_db,
    input  [N-1:0]     i_ka, i_kb,
    input              i_erra, i_errb,

    output reg         rx_err,
    output             pkt_we,
    output     [81:0]  pkt_wd
);
    `include "eerie_funcs.vh"
    localparam K_COM = 8'hBC, K_STP = 8'hFB, K_SDP = 8'h5C, K_END = 8'hFD, K_EDB = 8'hFE;

    // ---------------- DW assembly ----------------
    // unit: x4 -> one DW {lane0..lane3}; x2 -> half DW {lane0, lane1}
    function u_start; input [7:0] d; input k; u_start = k && (d == K_STP || d == K_SDP || d == K_COM); endfunction
    reg        h_v; reg [15:0] h_d; reg [1:0] h_k; reg h_e;     // x2: held half DW
    reg        dw_n;                                            // DWs this clock (0..2)
    reg [1:0]  n_dw;
    reg [31:0] dw0, dw1; reg [3:0] dk0, dk1; reg de0, de1;
    reg        n_hv; reg [15:0] n_hd; reg [1:0] n_hk; reg n_he;
    reg [15:0] u_d [0:1]; reg [1:0] u_k [0:1]; reg u_e [0:1]; reg u_v [0:1];
    integer    ui;
    always @(*) begin
        n_dw = 2'd0; dw0 = 32'd0; dw1 = 32'd0; dk0 = 4'd0; dk1 = 4'd0; de0 = 1'b0; de1 = 1'b0;
        n_hv = h_v; n_hd = h_d; n_hk = h_k; n_he = h_e;
        if (w4) begin
            // compact A/B into DW slots
            if (i_va) begin
                dw0 = {i_da[7:0], i_da[15:8], i_da[23:16], i_da[31:24]}; dk0 = {i_ka[0], i_ka[1], i_ka[2], i_ka[3]};
                de0 = i_erra; n_dw = 2'd1;
                if (i_vb) begin
                    dw1 = {i_db[7:0], i_db[15:8], i_db[23:16], i_db[31:24]}; dk1 = {i_kb[0], i_kb[1], i_kb[2], i_kb[3]};
                    de1 = i_errb; n_dw = 2'd2;
                end
            end else if (i_vb) begin
                dw0 = {i_db[7:0], i_db[15:8], i_db[23:16], i_db[31:24]}; dk0 = {i_kb[0], i_kb[1], i_kb[2], i_kb[3]};
                de0 = i_errb; n_dw = 2'd1;
            end
        end else begin
            u_v[0] = i_va; u_d[0] = {i_da[7:0], i_da[15:8]}; u_k[0] = {i_ka[0], i_ka[1]}; u_e[0] = i_erra;
            u_v[1] = i_vb; u_d[1] = {i_db[7:0], i_db[15:8]}; u_k[1] = {i_kb[0], i_kb[1]}; u_e[1] = i_errb;
            for (ui = 0; ui < 2; ui = ui + 1) if (u_v[ui]) begin
                if (!n_hv) begin
                    n_hv = 1'b1; n_hd = u_d[ui]; n_hk = u_k[ui]; n_he = u_e[ui];
                end else if (u_start(u_d[ui][15:8], u_k[ui][1]) && !u_start(n_hd[15:8], n_hk[1])) begin
                    n_hd = u_d[ui]; n_hk = u_k[ui]; n_he = u_e[ui];       // drop the held filler
                end else begin
                    dw0 = {n_hd, u_d[ui]}; dk0 = {n_hk, u_k[ui]}; de0 = n_he || u_e[ui];
                    n_dw = 2'd1; n_hv = 1'b0;
                end
            end
        end
    end

    // ---------------- parser ----------------
    localparam P_IDLE = 2'd0, P_TLP = 2'd1, P_DLLP = 2'd2;
    reg [1:0]  pst;
    reg [11:0] seq;
    reg [31:0] crc;
    reg [7:0]  carry;
    reg [31:0] hi; reg hi_v, first_beat, tlp_err;
    reg [10:0] ndw;
    reg [23:0] dl_b; reg [15:0] dl_crc; reg dl_bad;

    // next-state copies and up to two output entries
    reg [1:0]  t_pst; reg [11:0] t_seq; reg [31:0] t_crc; reg [7:0] t_carry; reg [31:0] t_hi;
    reg        t_hiv, t_fb, t_terr; reg [10:0] t_ndw; reg [23:0] t_dlb; reg [15:0] t_dlc; reg t_dlbad;
    reg [81:0] oe0, oe1; reg [1:0] on; reg t_rxerr;

    task push; input [81:0] e; begin if (on == 2'd0) oe0 = e; else oe1 = e; on = on + 1'b1; end endtask
    task proc;
        input [31:0] w; input [3:0] k; input e;      // w[31:24] = symbol 0, k[3] = symbol 0
        reg [7:0] b0, b1, b2, b3; reg [31:0] c; reg [15:0] c16; reg bad;
        begin
            b0 = w[31:24]; b1 = w[23:16]; b2 = w[15:8]; b3 = w[7:0];
            case (t_pst)
            P_TLP: begin
                if (k[0] && b3 == K_END && k[3:1] == 3'b000) begin
                    c = f_crc32_byte(f_crc32_byte(f_crc32_byte(t_crc, b0), b1), b2);
                    bad = t_terr || e || c != 32'hDEBB20E3 || t_ndw < 11'd3;
                    if (c != 32'hDEBB20E3) t_rxerr = 1'b1;
                    push({t_hiv, 1'b0, bad, 1'b0, 1'b1, t_seq, t_fb, t_hiv ? t_hi : 32'd0, 32'd0});
                    t_pst = P_IDLE;
                end else if (k[0] && b3 == K_EDB && k[3:1] == 3'b000) begin
                    push({t_hiv, 1'b1, 1'b0, 1'b0, 1'b1, t_seq, t_fb, t_hiv ? t_hi : 32'd0, 32'd0});
                    t_pst = P_IDLE;
                end else if (k != 4'd0) begin
                    // framing error inside the packet
                    t_rxerr = 1'b1;
                    push({1'b0, 1'b0, 1'b1, 1'b0, 1'b1, t_seq, t_fb, 32'd0, 32'd0});
                    t_pst = P_IDLE;
                end else begin
                    t_crc = f_crc32_byte(f_crc32_byte(f_crc32_byte(f_crc32_byte(t_crc, b0), b1), b2), b3);
                    if (e) t_terr = 1'b1;
                    t_ndw = t_ndw + 1'b1;
                    if (t_hiv) begin
                        push({5'b00000, t_seq, t_fb, t_hi, t_carry, b0, b1, b2});
                        t_fb = 1'b0; t_hiv = 1'b0;
                    end else begin
                        t_hi = {t_carry, b0, b1, b2}; t_hiv = 1'b1;
                    end
                    t_carry = b3;
                end
            end
            P_DLLP: begin
                c16 = f_crc16_byte(t_dlc, b0);
                bad = t_dlbad || e || k[3:1] != 3'b000 || !(k[0] && b3 == K_END) ||
                      {f_rev8(~c16[15:8]), f_rev8(~c16[7:0])} != {b1, b2};
                if (bad) t_rxerr = 1'b1;
                push({1'b0, 1'b0, bad, 1'b1, 1'b0, 12'd0, 1'b0, t_dlb, b0, 32'd0});
                t_pst = P_IDLE;
            end
            default: begin
                if (k[3] && b0 == K_STP) begin
                    t_seq = {b1[3:0], b2};
                    t_crc = f_crc32_byte(f_crc32_byte(f_crc32_byte(32'hFFFFFFFF, b1), b2), b3);
                    t_carry = b3; t_ndw = 11'd0; t_hiv = 1'b0; t_fb = 1'b1;
                    t_terr = e || k[2:0] != 3'b000;
                    t_pst = P_TLP;
                end else if (k[3] && b0 == K_SDP) begin
                    t_dlb = {b1, b2, b3};
                    t_dlc = f_crc16_byte(f_crc16_byte(f_crc16_byte(16'hFFFF, b1), b2), b3);
                    t_dlbad = e || k[2:0] != 3'b000;
                    t_pst = P_DLLP;
                end
                // else: logical idle, ordered set symbols: ignored
            end
            endcase
        end
    endtask

    always @(*) begin
        t_pst = pst; t_seq = seq; t_crc = crc; t_carry = carry; t_hi = hi; t_hiv = hi_v; t_fb = first_beat;
        t_terr = tlp_err; t_ndw = ndw; t_dlb = dl_b; t_dlc = dl_crc; t_dlbad = dl_bad;
        oe0 = 82'd0; oe1 = 82'd0; on = 2'd0; t_rxerr = 1'b0;
        if (n_dw >= 2'd1) proc(dw0, dk0, de0);
        if (n_dw == 2'd2) proc(dw1, dk1, de1);
    end

    // ---------------- output queue (2 writes, 1 read per clock) ----------------
    reg [81:0] q [0:7];
    reg [3:0]  qw, qr;
    assign pkt_we = (qw != qr);
    assign pkt_wd = q[qr[2:0]];
    always @(posedge clk) begin
        rx_err <= 1'b0;
        if (rst) begin
            pst <= P_IDLE; h_v <= 1'b0; qw <= 4'd0; qr <= 4'd0;
        end else begin
            pst <= t_pst; seq <= t_seq; crc <= t_crc; carry <= t_carry; hi <= t_hi; hi_v <= t_hiv;
            first_beat <= t_fb; tlp_err <= t_terr; ndw <= t_ndw; dl_b <= t_dlb; dl_crc <= t_dlc; dl_bad <= t_dlbad;
            h_v <= n_hv; h_d <= n_hd; h_k <= n_hk; h_e <= n_he;
            rx_err <= t_rxerr;
            if (on >= 2'd1) q[qw[2:0]] <= oe0;
            if (on == 2'd2) q[(qw + 4'd1) & 4'd7] <= oe1;
            qw <= qw + on;
            if (qw != qr) qr <= qr + 1'b1;
        end
    end
endmodule
