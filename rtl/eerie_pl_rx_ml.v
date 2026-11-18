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
// Pipelined for the PIPE clock: A) DW assembly, B) framing / symbol decode into per-DW roles,
// C) data path (CRC, DW packing) on registered roles; the LCRC residue is compared at the queue
// output.
`timescale 1ns / 1ps
module eerie_pl_rx_ml #(
    parameter N = 4,
    parameter W4_FIXED = 0           // 1: always x4 (TASK-6161 EERIE_W8 x1 lane), the x2 assembly is removed
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
    reg w4_q = 1'b0;                 // local copy of the (quasi-static) width
    always @(posedge clk) w4_q <= w4;
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
        if (W4_FIXED || w4_q) begin
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

    // ---------------- stage A: assembled DWs ----------------
    reg [1:0]  a_n; reg [31:0] a_w0, a_w1; reg [3:0] a_k0, a_k1; reg a_e0, a_e1;
    always @(posedge clk) begin
        a_n <= rst ? 2'd0 : n_dw;
        a_w0 <= dw0; a_w1 <= dw1; a_k0 <= dk0; a_k1 <= dk1; a_e0 <= de0; a_e1 <= de1;
    end
`ifdef EERIE_ML_ADUP
    // TASK-6161 (GateMate): separate copy of the stage A data for the CRC matrices (each bit fans out
    // to ~100 XOR terms), so the framing decode does not share those long nets
    (* keep *) reg [31:0] a_c0, a_c1;
    always @(posedge clk) begin a_c0 <= dw0; a_c1 <= dw1; end
`else
    wire [31:0] a_c0 = a_w0, a_c1 = a_w1;
`endif
`ifdef EERIE_ML_KPRE
    // TASK-6161 (GateMate): symbol 0 / 3 K codes decoded before stage A: {STP@0, SDP@0, END@3, EDB@3}
    reg [3:0] a_q0, a_q1;
    function [3:0] kq; input [31:0] w; input [3:0] k;
        kq = {k[3] && w[31:24] == K_STP, k[3] && w[31:24] == K_SDP, k[0] && w[7:0] == K_END, k[0] && w[7:0] == K_EDB};
    endfunction
    always @(posedge clk) begin a_q0 <= kq(dw0, dk0); a_q1 <= kq(dw1, dk1); end
`endif

    // ---------------- stage B: framing (symbol decode only) ----------------
    // role of each DW; the framing state advances here, the data path (stage C) follows the roles
    localparam P_IDLE = 2'd0, P_TLP = 2'd1, P_DLLP = 2'd2;
    localparam R_NONE = 3'd0, R_STP = 3'd1, R_DATA = 3'd2, R_END = 3'd3, R_EDB = 3'd4, R_FERR = 3'd5,
               R_SDP = 3'd6, R_DEND = 3'd7;
    reg [1:0] pst, b_pst;
    reg [2:0] r0, r1;
    reg       f0, f1;          // STP / SDP: K or error in symbols 1-3; DLLP end: framing bad
    function [3:0] role;       // {flag, role} of one DW in framing state st
        input [1:0] st; input [3:0] q; input [3:0] k; input e;   // q: {STP@0, SDP@0, END@3, EDB@3}
        begin
            case (st)
            P_TLP:
                if (q[1] && k[3:1] == 3'b000) role = {1'b0, R_END};
                else if (q[0] && k[3:1] == 3'b000) role = {1'b0, R_EDB};
                else if (k != 4'd0) role = {1'b0, R_FERR};
                else role = {1'b0, R_DATA};
            P_DLLP: role = {e || k[3:1] != 3'b000 || !q[1], R_DEND};
            default:
                if (q[3]) role = {e || k[2:0] != 3'b000, R_STP};
                else if (q[2]) role = {e || k[2:0] != 3'b000, R_SDP};
                else role = {1'b0, R_NONE};
            endcase
        end
    endfunction
`ifndef EERIE_ML_KPRE
    function [3:0] kq; input [31:0] w; input [3:0] k;
        kq = {k[3] && w[31:24] == K_STP, k[3] && w[31:24] == K_SDP, k[0] && w[7:0] == K_END, k[0] && w[7:0] == K_EDB};
    endfunction
    wire [3:0] a_q0 = kq(a_w0, a_k0), a_q1 = kq(a_w1, a_k1);
`endif
    function [1:0] nst; input [1:0] st; input [2:0] r;
        nst = (r == R_STP) ? P_TLP : (r == R_SDP) ? P_DLLP : (r == R_NONE || r == R_DATA) ? st : P_IDLE;
    endfunction
    reg [3:0] c0, c1; reg [1:0] s1;
    always @(*) begin
        c0 = role(pst, a_q0, a_k0, a_e0);
        s1 = (a_n >= 2'd1) ? nst(pst, c0[2:0]) : pst;
        c1 = role(s1, a_q1, a_k1, a_e1);
        b_pst = (a_n == 2'd2) ? nst(s1, c1[2:0]) : s1;
    end
    // LCRC is linear: crc(c, bytes) = crc(c, zeros) ^ crc(0, bytes); the data terms of each DW are
    // computed here, so stage C only applies the state transform
`ifdef EERIE_ML_CRCMAT
    // TASK-6161 (GateMate): explicit XOR masks (syn/gen_crc_mat.py), crc(c, bytes) = M^n c ^ crc(0, bytes)
    `include "eerie_crcmat.vh"
    function [31:0] crcn; input [31:0] c; input [31:0] w; input integer n;   // first n bytes of w
        case (n)
        1: crcn = f_crc32_adv8(c)  ^ f_crc32_dat8(w[31:24]);
        2: crcn = f_crc32_adv16(c) ^ f_crc32_dat16(w[31:16]);
        3: crcn = f_crc32_adv24(c) ^ f_crc32_dat24(w[31:8]);
        default: crcn = f_crc32_adv32(c) ^ f_crc32_dat32(w);
        endcase
    endfunction
`else
    function [31:0] crcn; input [31:0] c; input [31:0] w; input integer n;   // first n bytes of w
        integer j; begin crcn = c; for (j = 0; j < n; j = j + 1) crcn = f_crc32_byte(crcn, w[31-8*j -: 8]); end
    endfunction
`endif
    reg [1:0]  b_n; reg [31:0] b_w0, b_w1; reg b_e0, b_e1;
    // g: 4 data bytes, ge: 3 bytes (END DW), gs: STP DW (bytes 1-3, from the initial value);
    // h*: DW0 terms carried through DW1 (4 or 3 more bytes)
    reg [31:0] b_g0, b_g1, b_ge0, b_ge1, b_gs0, b_gs1, b_h0_4, b_h0_3, b_hs0_4, b_hs0_3;
    wire [31:0] a_g0 = crcn(32'd0, a_c0, 4), a_gs0 = crcn(32'hFFFFFFFF, a_c0 << 8, 3);
    always @(posedge clk) begin
        b_g0 <= a_g0; b_ge0 <= crcn(32'd0, a_c0, 3); b_gs0 <= a_gs0;
        b_g1 <= crcn(32'd0, a_c1, 4); b_ge1 <= crcn(32'd0, a_c1, 3); b_gs1 <= crcn(32'hFFFFFFFF, a_c1 << 8, 3);
`ifdef EERIE_ML_CRCMAT
        // one flat matrix per term (data then zeros); the STP initial value folds to a constant
        b_h0_4 <= f_crc32_d32z32(a_c0); b_h0_3 <= f_crc32_d32z24(a_c0);
        b_hs0_4 <= f_crc32_adv32(f_crc32_adv24(32'hFFFFFFFF)) ^ f_crc32_d24z32(a_c0[23:0]);
        b_hs0_3 <= f_crc32_adv24(f_crc32_adv24(32'hFFFFFFFF)) ^ f_crc32_d24z24(a_c0[23:0]);
`else
        b_h0_4 <= crcn(a_g0, 32'd0, 4); b_h0_3 <= crcn(a_g0, 32'd0, 3);
        b_hs0_4 <= crcn(a_gs0, 32'd0, 4); b_hs0_3 <= crcn(a_gs0, 32'd0, 3);
`endif
    end
`ifdef EERIE_ML_DLCPRE
    // TASK-6161 (GateMate): DLLP CRC16 of the SDP DW (bytes 1-3) and, for SDP in DW0 + END in DW1, the
    // whole check, here in stage B, so stage C does not chain 4 CRC16 bytes and the compare
    function [15:0] dlc3; input [31:0] w;
        dlc3 = f_crc16_byte(f_crc16_byte(f_crc16_byte(16'hFFFF, w[23:16]), w[15:8]), w[7:0]);
    endfunction
    reg [15:0] b_dc0, b_dc1; reg b_dbad01;
`ifdef EERIE_ML_CRCMAT
    // flat affine matrices (syn/gen_crc_mat.py) instead of 3-4 chained CRC16 bytes
    always @(posedge clk) begin
        b_dc0 <= f_crc16_dl3(a_c0[23:0]); b_dc1 <= f_crc16_dl3(a_c1[23:0]);
        b_dbad01 <= f_dllp_fld4({a_c0[23:0], a_c1[31:24]}) != a_c1[23:8];
    end
`else
    wire [15:0] a_dc01 = f_crc16_byte(dlc3(a_c0), a_c1[31:24]);
    always @(posedge clk) begin
        b_dc0 <= dlc3(a_c0); b_dc1 <= dlc3(a_c1);
        b_dbad01 <= {f_rev8(~a_dc01[15:8]), f_rev8(~a_dc01[7:0])} != a_c1[23:8];
    end
`endif
`endif
    always @(posedge clk) begin
        if (rst) begin pst <= P_IDLE; b_n <= 2'd0; end
        else begin pst <= b_pst; b_n <= a_n; end
        b_w0 <= a_w0; b_w1 <= a_w1; b_e0 <= a_e0; b_e1 <= a_e1;
        r0 <= c0[2:0]; f0 <= c0[3]; r1 <= c1[2:0]; f1 <= c1[3];
    end
`ifdef EERIE_ML_CDUP
    // TASK-6161 (GateMate): the LCRC selects of stage C as their own registers (decoded here), so
    // b_n / r0 / r1 do not fan out to the 32-bit CRC muxes as well as to the entry logic
    (* keep *) reg q_d0, q_s0, q_2d, q_2s, q_any;
    always @(posedge clk) begin
        q_d0 <= c0[2:0] == R_DATA; q_s0 <= c0[2:0] == R_STP;
        q_2d <= !rst && a_n == 2'd2 && c1[2:0] == R_DATA; q_2s <= !rst && a_n == 2'd2 && c1[2:0] == R_STP;
        q_any <= !rst && a_n != 2'd0;
    end
`else
    wire q_d0 = r0 == R_DATA, q_s0 = r0 == R_STP;
    wire q_2d = b_n == 2'd2 && r1 == R_DATA, q_2s = b_n == 2'd2 && r1 == R_STP, q_any = b_n != 2'd0;
`endif

    // ---------------- stage C: data path ----------------
    reg [11:0] seq;
    reg [31:0] crc;
    reg [7:0]  carry;
    reg [31:0] hi; reg hi_v, first_beat, tlp_err;
    reg [10:0] ndw;
    reg [23:0] dl_b; reg [15:0] dl_crc; reg dl_bad;

    // next-state copies and up to two output entries; an END entry carries its LCRC residue,
    // compared when the entry leaves the queue
    reg [11:0] t_seq; reg [7:0] t_carry; reg [31:0] t_hi;
    reg        t_hiv, t_fb, t_terr; reg [10:0] t_ndw; reg [23:0] t_dlb; reg [15:0] t_dlc; reg t_dlbad;
    reg [81:0] oe0, oe1; reg [32:0] oc0, oc1; reg [1:0] on; reg t_rxerr;

    // LCRC state and END residues for both DWs, from the registered state and the stage B terms
    // n zero bytes: each Fn is a flat XOR matrix of the state
`ifdef EERIE_ML_CRCMAT
    function [31:0] crcz; input [31:0] c; input integer n;
        case (n)
        1: crcz = f_crc32_adv8(c);  2: crcz = f_crc32_adv16(c); 3: crcz = f_crc32_adv24(c); 4: crcz = f_crc32_adv32(c);
        5: crcz = f_crc32_adv40(c); 6: crcz = f_crc32_adv48(c); 7: crcz = f_crc32_adv56(c); default: crcz = f_crc32_adv64(c);
        endcase
    endfunction
`else
    function [31:0] crcz; input [31:0] c; input integer n;
        integer j; begin crcz = c; for (j = 0; j < n; j = j + 1) crcz = f_crc32_byte(crcz, 8'h00); end
    endfunction
`endif
    wire [31:0] F3c = crcz(crc, 3), F4c = crcz(crc, 4), F7c = crcz(crc, 7), F8c = crcz(crc, 8);
    reg  [31:0] crc_mid, crc_nx, cend0, cend1;
    always @(*) begin
        crc_mid = q_d0 ? F4c ^ b_g0 : q_s0 ? b_gs0 : crc;
        cend0   = F3c ^ b_ge0;
        cend1   = (q_d0 ? F7c ^ b_h0_3 : q_s0 ? b_hs0_3 : F3c) ^ b_ge1;
        if (q_2d)
            crc_nx = (q_d0 ? F8c ^ b_h0_4 : q_s0 ? b_hs0_4 : F4c) ^ b_g1;
        else if (q_2s) crc_nx = b_gs1;
        else if (q_any) crc_nx = crc_mid;
        else crc_nx = crc;
    end

    task push; input [81:0] e; input [32:0] c;
        begin if (on == 2'd0) begin oe0 = e; oc0 = c; end else begin oe1 = e; oc1 = c; end on = on + 1'b1; end
    endtask
    task proc;
        input [31:0] w; input [2:0] r; input f; input e;      // w[31:24] = symbol 0
        input [31:0] cend;                                    // LCRC residue if this DW ends a TLP
        input [15:0] dsdp;                                    // EERIE_ML_DLCPRE: CRC16 of bytes 1-3 (SDP)
        input        dpre_v; input dpre_bad;                  // EERIE_ML_DLCPRE: precomputed DLLP check
        reg [7:0] b0, b1, b2, b3; reg [31:0] c; reg [15:0] c16; reg bad;
        begin
            b0 = w[31:24]; b1 = w[23:16]; b2 = w[15:8]; b3 = w[7:0];
            case (r)
            R_END: begin
                c = cend;
                bad = t_terr || e || t_ndw < 11'd3;
                push({t_hiv, 1'b0, bad, 1'b0, 1'b1, t_seq, t_fb, t_hiv ? t_hi : 32'd0, 32'd0}, {1'b1, c});
            end
            R_EDB: push({t_hiv, 1'b1, 1'b0, 1'b0, 1'b1, t_seq, t_fb, t_hiv ? t_hi : 32'd0, 32'd0}, 33'd0);
            R_FERR: begin
                // framing error inside the packet
                t_rxerr = 1'b1;
                push({1'b0, 1'b0, 1'b1, 1'b0, 1'b1, t_seq, t_fb, 32'd0, 32'd0}, 33'd0);
            end
            R_DATA: begin
                if (e) t_terr = 1'b1;
                t_ndw = t_ndw + 1'b1;
                if (t_hiv) begin
                    push({5'b00000, t_seq, t_fb, t_hi, t_carry, b0, b1, b2}, 33'd0);
                    t_fb = 1'b0; t_hiv = 1'b0;
                end else begin
                    t_hi = {t_carry, b0, b1, b2}; t_hiv = 1'b1;
                end
                t_carry = b3;
            end
            R_DEND: begin
                c16 = f_crc16_byte(t_dlc, b0);
                bad = t_dlbad || f || (dpre_v ? dpre_bad : {f_rev8(~c16[15:8]), f_rev8(~c16[7:0])} != {b1, b2});
                if (bad) t_rxerr = 1'b1;
                push({1'b0, 1'b0, bad, 1'b1, 1'b0, 12'd0, 1'b0, t_dlb, b0, 32'd0}, 33'd0);
            end
            R_STP: begin
                t_seq = {b1[3:0], b2};
                t_carry = b3; t_ndw = 11'd0; t_hiv = 1'b0; t_fb = 1'b1;
                t_terr = f;
            end
            R_SDP: begin
                t_dlb = {b1, b2, b3};
`ifdef EERIE_ML_DLCPRE
                t_dlc = dsdp;
`else
                t_dlc = f_crc16_byte(f_crc16_byte(f_crc16_byte(16'hFFFF, b1), b2), b3);
`endif
                t_dlbad = f;
            end
            default: ;  // logical idle, ordered set symbols: ignored
            endcase
        end
    endtask

    always @(*) begin
        t_seq = seq; t_carry = carry; t_hi = hi; t_hiv = hi_v; t_fb = first_beat;
        t_terr = tlp_err; t_ndw = ndw; t_dlb = dl_b; t_dlc = dl_crc; t_dlbad = dl_bad;
        oe0 = 82'd0; oe1 = 82'd0; oc0 = 33'd0; oc1 = 33'd0; on = 2'd0; t_rxerr = 1'b0;
`ifdef EERIE_ML_DLCPRE
        if (b_n >= 2'd1) proc(b_w0, r0, f0, b_e0, cend0, b_dc0, 1'b0, 1'b0);
        if (b_n == 2'd2) proc(b_w1, r1, f1, b_e1, cend1, b_dc1, r0 == R_SDP, b_dbad01);
`else
        if (b_n >= 2'd1) proc(b_w0, r0, f0, b_e0, cend0, 16'd0, 1'b0, 1'b0);
        if (b_n == 2'd2) proc(b_w1, r1, f1, b_e1, cend1, 16'd0, 1'b0, 1'b0);
`endif
    end

    // ---------------- output queue (2 writes, 1 read per clock) ----------------
    // the LCRC residues are written one clock after their entries; the write pointer seen by the
    // reader (qw_v) lags by that clock
    reg [81:0] q [0:7];
    reg [32:0] qc [0:7];        // {check, LCRC residue}
    reg [3:0]  qw, qw_v, qr;
    reg [1:0]  qd_n; reg [2:0] qd_i; reg [32:0] qd_c0, qd_c1;
`ifdef EERIE_ML_QREG
    reg [81:0] qd_e0, qd_e1;
`endif
    wire       q_crc_bad = qc[qr[2:0]][32] && qc[qr[2:0]][31:0] != 32'hDEBB20E3;
    assign pkt_we = (qw_v != qr);
    assign pkt_wd = q[qr[2:0]] | {2'b00, q_crc_bad, 79'd0};
    always @(posedge clk) begin
        rx_err <= 1'b0;
        if (rst) begin
            h_v <= 1'b0; qw <= 4'd0; qw_v <= 4'd0; qr <= 4'd0; qd_n <= 2'd0;
        end else begin
            seq <= t_seq; crc <= crc_nx; carry <= t_carry; hi <= t_hi; hi_v <= t_hiv;
            first_beat <= t_fb; tlp_err <= t_terr; ndw <= t_ndw; dl_b <= t_dlb; dl_crc <= t_dlc; dl_bad <= t_dlbad;
            h_v <= n_hv; h_d <= n_hd; h_k <= n_hk; h_e <= n_he;
            rx_err <= t_rxerr || (pkt_we && q_crc_bad);
`ifdef EERIE_ML_QREG
            // TASK-6161 (GateMate): entries are written together with their residues, one clock
            // later (always block below, not gated by rst); the reader sees them through qw_v,
            // which already lags qw by that clock
            qd_e0 <= oe0; qd_e1 <= oe1;
`else
            if (on >= 2'd1) q[qw[2:0]] <= oe0;
            if (on == 2'd2) q[(qw + 4'd1) & 4'd7] <= oe1;
`endif
            qw <= qw + on;
            qd_n <= on; qd_i <= qw[2:0]; qd_c0 <= oc0; qd_c1 <= oc1;
`ifndef EERIE_ML_QREG
            if (qd_n >= 2'd1) qc[qd_i] <= qd_c0;
            if (qd_n == 2'd2) qc[qd_i + 3'd1] <= qd_c1;
`endif
            qw_v <= qw;
            if (qw_v != qr) qr <= qr + 1'b1;
        end
    end
`ifdef EERIE_ML_QREG
    // queue RAM writes: the reset only clears the pointers and qd_n (a write in the clock rst
    // rises lands in a slot the reader never reaches before it is rewritten)
    always @(posedge clk) begin
        if (qd_n >= 2'd1) begin q[qd_i] <= qd_e0; qc[qd_i] <= qd_c0; end
        if (qd_n == 2'd2) begin q[qd_i + 3'd1] <= qd_e1; qc[qd_i + 3'd1] <= qd_c1; end
    end
`endif
endmodule
