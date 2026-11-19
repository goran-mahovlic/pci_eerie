// SPDX-License-Identifier: CERN-OHL-P-2.0
// Minimalna aplikacija za pci_eerie na 64-bitnom TRN sučelju (TASK-6160).
// BAR0: 16 registara po 32 bita (offset 0x00..0x3C, adresa se zrcali preko BAR-a).
//   0x00  RO  ID         = ID_WORD
//   0x04  RO  brojač user taktova (živ takt)
//   0x08  RO  status     = {LTSSM[5:0] na [13:8], lnk_up na [0]}
//   0x0C..0x3C RW  scratch
// Podržano: MWr32/MWr64 i MRd32/MRd64 duljine 1 DW (ostalo se ignorira).
// TRN konvencija pci_eerie (eerie_tl_rx/tx): td[63:32] = prvi DW zrake, rem=1 => oba DW valjana.
// RW podaci se spremaju i vraćaju kako stignu, pa zapis+čitanje daju istu vrijednost; RO se okreću (bswap).
`timescale 1ns / 1ps
module eerie_bar0_app #(
    parameter [31:0] ID_WORD = 32'h4C44_0E1E,   // "LD" + eerie
    parameter [3:0]  ADDR_XOR = 4'd0            // TASK-6170: 8 = RO registers at 0x20..0x28, 0x00..0x1C scratch
) (
    input             clk,
    input             rst,
    // TRN RX
    input      [63:0] trn_rd,
    input             trn_rrem,
    input             trn_rsof,
    input             trn_reof,
    input             trn_rsrc_rdy,
    input      [7:0]  trn_rbar_hit,
    output            trn_rdst_rdy,
    // TRN TX
    output reg [63:0] trn_td,
    output reg        trn_trem,
    output reg        trn_tsof,
    output reg        trn_teof,
    output reg        trn_tsrc_rdy,
    input             trn_tdst_rdy,
    // ID
    input      [15:0] completer_id,
    input      [5:0]  ltssm,
    input             lnk_up
);
    reg [31:0] regs [0:15];
    reg [31:0] cnt;
    integer i;
    initial for (i = 0; i < 16; i = i + 1) regs[i] = 32'h0;

    initial cnt = 32'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    // ---------------------------------------------------------------- RX
    localparam R_IDLE = 2'd0, R_HDR2 = 2'd1, R_DATA = 2'd2, R_DROP = 2'd3;
    reg [1:0]  rs;
    reg [31:0] dw0, dw1;
    reg        is_wr, is_64, ok;
    reg [3:0]  ridx;
    reg [1:0]  ts;       // TX stanje
    reg        cpl_req;  // čeka se odgovor
    reg [31:0] cpl_data;
    reg [15:0] req_id;
    reg [7:0]  req_tag;
    reg [2:0]  req_tc;
    reg [1:0]  req_attr;
    reg [6:0]  req_low;
    reg [3:0]  req_fbe;

    assign trn_rdst_rdy = !cpl_req;
    wire rx = trn_rsrc_rdy && trn_rdst_rdy;

    // TLP nosi bajt 0 u [31:24] DW-a; RO vrijednosti se okreću da ih CPU (little-endian) čita kako piše
    function [31:0] bswap(input [31:0] v); bswap = {v[7:0], v[15:8], v[23:16], v[31:24]}; endfunction
    function [3:0] lx(input [3:0] a); lx = a ^ ADDR_XOR; endfunction
    function [31:0] rd_reg(input [3:0] pa);
        reg [3:0] a;
        begin a = lx(pa);
        case (a)
        4'd0: rd_reg = bswap(ID_WORD);
        4'd1: rd_reg = bswap(cnt);
        4'd2: rd_reg = bswap({18'd0, ltssm, 7'd0, lnk_up});
        default: rd_reg = regs[a];
        endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            rs <= R_IDLE; cpl_req <= 1'b0;
        end else begin
            if (rx) case (rs)
            R_IDLE: if (trn_rsof) begin
                dw0 <= trn_rd[63:32]; dw1 <= trn_rd[31:0];
                is_wr <= trn_rd[62];                 // Fmt[1]: s podacima
                is_64 <= trn_rd[61];                 // Fmt[0]: 4DW zaglavlje
                ok <= trn_rbar_hit[0] && trn_rd[60:56] == 5'b00000 && trn_rd[41:32] == 10'd1;
                rs <= trn_reof ? R_IDLE : R_HDR2;
            end
            R_HDR2: begin
                // 3DW: [63:32]=adresa, [31:0]=podatak (MWr32); 4DW: [31:0]=niža adresa
                ridx <= is_64 ? trn_rd[5:2] : trn_rd[37:34];
                req_low <= is_64 ? trn_rd[6:0] : trn_rd[38:32];
                if (!is_64 && is_wr && ok && lx(trn_rd[37:34]) > 4'd2) regs[lx(trn_rd[37:34])] <= trn_rd[31:0];
                if (!is_wr && ok) begin
                    cpl_req <= 1'b1;
                    cpl_data <= rd_reg(is_64 ? trn_rd[5:2] : trn_rd[37:34]);
                    req_id <= dw1[31:16]; req_tag <= dw1[15:8]; req_fbe <= dw1[3:0];
                    req_tc <= dw0[22:20]; req_attr <= dw0[13:12];
                end
                rs <= trn_reof ? R_IDLE : R_DATA;
            end
            R_DATA: begin
                if (is_64 && is_wr && ok && lx(ridx) > 4'd2) regs[lx(ridx)] <= trn_rd[63:32];
                rs <= trn_reof ? R_IDLE : R_DROP;
            end
            default: if (trn_reof) rs <= R_IDLE;
            endcase
            if (ts == 2'd2 && trn_tdst_rdy) cpl_req <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- TX (CplD, 1 DW)
    // byte count i lower address iz First BE (PCIe 2.0 tablica 2-21 za 1 DW)
    wire [2:0] bc = req_fbe[0] ? (req_fbe[3] ? 3'd4 : req_fbe[2] ? 3'd3 : req_fbe[1] ? 3'd2 : 3'd1) :
                    req_fbe[1] ? (req_fbe[3] ? 3'd3 : req_fbe[2] ? 3'd2 : 3'd1) :
                    req_fbe[2] ? (req_fbe[3] ? 3'd2 : 3'd1) : 3'd1;
    wire [1:0] la = req_fbe[0] ? 2'd0 : req_fbe[1] ? 2'd1 : req_fbe[2] ? 2'd2 : req_fbe[3] ? 2'd3 : 2'd0;
    always @(posedge clk) begin
        if (rst) begin
            ts <= 2'd0; trn_tsrc_rdy <= 1'b0; trn_tsof <= 1'b0; trn_teof <= 1'b0; trn_trem <= 1'b1;
        end else case (ts)
        2'd0: if (cpl_req && trn_tdst_rdy) begin
            trn_td   <= {1'b0, 2'b10, 5'b01010, 1'b0, req_tc, 4'd0, 2'b00, req_attr, 2'b00, 10'd1,
                         completer_id, 3'b000, 1'b0, 9'd0, bc};
            trn_tsof <= 1'b1; trn_teof <= 1'b0; trn_trem <= 1'b1; trn_tsrc_rdy <= 1'b1;
            ts <= 2'd1;
        end
        2'd1: if (trn_tdst_rdy) begin
            trn_td   <= {req_id, req_tag, 1'b0, req_low[6:2], la, cpl_data};
            trn_tsof <= 1'b0; trn_teof <= 1'b1; trn_trem <= 1'b1;
            ts <= 2'd2;
        end
        default: if (trn_tdst_rdy) begin
            trn_tsrc_rdy <= 1'b0; trn_teof <= 1'b0; ts <= 2'd0;
        end
        endcase
    end
endmodule
