// SPDX-License-Identifier: CERN-OHL-P-2.0
// Minimalna aplikacija za pci_eerie na 64-bitnom TRN sučelju (TASK-6160).
// BAR0: 16 registara po 32 bita (offset 0x00..0x3C, adresa se zrcali preko BAR-a).
//   0x00  RO  ID         = ID_WORD
//   0x04  RO  brojač user taktova (živ takt)
//   0x08  RO  status     = {LTSSM[5:0] na [13:8], lnk_up na [0]}
//   0x0C..0x3C RW  scratch
// Podržano: MWr32/MWr64 i MRd32/MRd64 duljine 1 DW (ostalo se ignorira).
// TRN konvencija pci_eerie (eerie_tl_rx/tx): td[63:32] = prvi DW zrake, rem=1 => oba DW valjana.
// EERIE_BWCNT (TASK-6186, zadano isključeno): brojači prometa za mjerenje propusnosti na EP strani. Čitanje s adresnim bitom 11
//   (BAR0 0x800..0xFFF, bez ADDR_XOR, zrcali se svakih 32 B) daje banku brojača; upisi i donja polovica ostaju kao prije:
//   0x800 MRd TLP-ova   0x804 bajtova tereta MWr   0x808 MWr TLP-ova   0x80C slobodni brojač takta (= 0x24 s ADDR_XOR=8)
//   0x810 poslanih CplD  0x814 MRd >1 DW (bez odgovora)  0x818 MWr >1 DW (ne sprema se)  0x81C oznaka "BW01"
//   Broje se svi MWr/MRd na BAR0 (sve duljine), 32 bita s preljevom; propusnost = razlika bajtova / razlika takta.
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
    // TRN TX (muxirano između CplD completera i eerie_dma requestera — v. arbitar na dnu)
    output     [63:0] trn_td,
    output            trn_trem,
    output            trn_tsof,
    output            trn_teof,
    output            trn_tsrc_rdy,
    input             trn_tdst_rdy,
    // ID
    input      [15:0] completer_id,
    input      [5:0]  ltssm,
    input             lnk_up
`ifdef EERIE_DBGCNT
   ,input      [7:0]  dl_ev,                   // TASK-6184: DL event pulses (pci_eerie DBGVECB), clk domain
    input      [2:0]  rxstatus,                // PIPE RxStatus (same clock with EERIE_W8: uclk = pclk)
    input             rxvalid,
    input      [63:0] phy_dbgc                 // TASK-6185: {pre-EB err words, realign, RX_BUF_ERR, post-EB err words, SKP add, SKP del}
`endif
`ifdef EERIE_ILA
   ,input      [51:0] ila_p,                   // TASK-6190: eerie_dll probes {l0, dls, txq_slots, unAcked, timer on, seqB, seqA, events}
    input      [31:0] phy_ppm,                 // rclk - pclk per 2^24 pclk
    output            uart_tx,
    input             uart_rx
`endif
`ifdef EERIE_ILA3
   ,input      [147:0] ila_w                   // TASK-6192: {txelecidle, TX K, TX data, RxStatus[2], rxelecidle, rxvalid, RX K, RX data}
`endif
);
    reg [31:0] regs [0:15];
    reg [31:0] cnt;
    integer i;
    initial for (i = 0; i < 16; i = i + 1) regs[i] = 32'h0;

    initial cnt = 32'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;
`ifdef EERIE_DBGCNT
    // TASK-6184: receive-side error counters since configuration (8 bit saturating, TLP accepted 16 bit wrapping)
    //   0x2C {TLP ok[15:0], duplicate TLP, Nak sent}   0x30 {bad TLP, bad DLLP, own replay timeout, own rollover}
    //   0x34 {8b10b code/disparity err words while in L0 [15:0], EB over/underflow, L0 exits}
    reg [15:0] c_tlp = 16'd0;
    reg [7:0]  c_dup = 8'd0, c_nak = 8'd0, c_btlp = 8'd0, c_bdllp = 8'd0, c_rto = 8'd0, c_rro = 8'd0;
    reg [15:0] c_dec = 16'd0;
    reg [7:0]  c_eb = 8'd0, c_l0x = 8'd0;
    reg        l0q = 1'b0;
    function [7:0] sat(input [7:0] c, input e); sat = (e && c != 8'hFF) ? c + 1'b1 : c; endfunction
    always @(posedge clk) begin
        l0q <= (ltssm == 6'h16);
        if (dl_ev[0]) c_tlp <= c_tlp + 1'b1;
        c_dup <= sat(c_dup, dl_ev[1]); c_nak <= sat(c_nak, dl_ev[3]);
        c_btlp <= sat(c_btlp, dl_ev[4]); c_bdllp <= sat(c_bdllp, dl_ev[5]);
        c_rto <= sat(c_rto, dl_ev[6]); c_rro <= sat(c_rro, dl_ev[7]);
        if (l0q && rxstatus == 3'b100 && c_dec != 16'hFFFF) c_dec <= c_dec + 1'b1;
        c_eb <= sat(c_eb, rxstatus == 3'b101 || rxstatus == 3'b110);
        c_l0x <= sat(c_l0x, l0q && ltssm != 6'h16);
    end
`endif

`ifdef EERIE_ILA
    // TASK-6190: DL event trace (eerie_ila.v); BAR0 0x400..0x7FF (address bit 10, 3DW), UART dump/status
    reg         ila_we = 1'b0, ila_nx = 1'b0;
    reg  [2:0]  ila_wa = 3'd0;
    reg  [31:0] ila_wd = 32'd0;
    wire [31:0] ila_rd;
    reg  [2:0]  ila_ra;
    eerie_ila ila (.clk(clk), .ev_in(ila_p[11:0]), .seqa(ila_p[23:12]), .seqb(ila_p[35:24]), .ltssm(ltssm),
        .ppm_w(phy_ppm), .cnt_w({c_rto, c_rro, c_l0x, c_bdllp}), .dll_st(ila_p[51:36]),
        .we(ila_we), .wa(ila_wa), .wd(ila_wd), .ra(ila_ra), .rd(ila_rd), .rd_next(ila_nx),
`ifdef EERIE_ILA3
        .w_rd(ila_w[63:0]), .w_rk(ila_w[71:64]), .w_rf(ila_w[74:72]), .w_td(ila_w[138:75]), .w_tk(ila_w[146:139]),
        .w_tei(ila_w[147]),
`endif
        .uart_tx(uart_tx), .uart_rx(uart_rx));
`endif

`ifdef EERIE_BWCNT
    reg [31:0] c_mrd = 32'd0, c_wrb = 32'd0, c_wrt = 32'd0, c_cpl = 32'd0, c_mrdl = 32'd0, c_wrl = 32'd0;
    wire       tlp_hdr = trn_rsrc_rdy && trn_rdst_rdy && trn_rsof && trn_rbar_hit[0] && trn_rd[60:56] == 5'b00000;
    wire       tlp_long = trn_rd[41:32] != 10'd1;
    always @(posedge clk) begin
        if (tlp_hdr && trn_rd[62]) begin
            c_wrt <= c_wrt + 1'b1; c_wrb <= c_wrb + {20'd0, trn_rd[41:32] == 10'd0, trn_rd[41:32], 2'b00}; c_wrl <= c_wrl + tlp_long;
        end
        if (tlp_hdr && !trn_rd[62]) begin c_mrd <= c_mrd + 1'b1; c_mrdl <= c_mrdl + tlp_long; end
        if (trn_tsrc_rdy && trn_tdst_rdy && trn_teof) c_cpl <= c_cpl + 1'b1;
    end
    function [31:0] rd_bw(input [2:0] a);
        case (a)
        3'd0: rd_bw = bswap(c_mrd);  3'd1: rd_bw = bswap(c_wrb);  3'd2: rd_bw = bswap(c_wrt);  3'd3: rd_bw = bswap(cnt);
        3'd4: rd_bw = bswap(c_cpl);  3'd5: rd_bw = bswap(c_mrdl); 3'd6: rd_bw = bswap(c_wrl);  default: rd_bw = bswap(32'h4257_3031);
        endcase
    endfunction
`endif

    // ---------------------------------------------------------------- RX
    localparam R_IDLE = 2'd0, R_HDR2 = 2'd1, R_DATA = 2'd2, R_DROP = 2'd3;
    reg [1:0]  rs;
    reg [31:0] dw0, dw1;
    reg        is_wr, is_64, ok;
    reg [3:0]  ridx;
    reg [1:0]  ts;       // TX stanje
    wire       c_tdst;   // gated TX dst-ready za CplD completer (arbitar na dnu; = trn_tdst_rdy bez EERIE_DMA)
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
`ifdef EERIE_DBGCNT
        4'd3: rd_reg = bswap({c_tlp, c_dup, c_nak});
        4'd4: rd_reg = bswap({c_btlp, c_bdllp, c_rto, c_rro});
        4'd5: rd_reg = bswap({c_dec, c_eb, c_l0x});
        4'd6: rd_reg = bswap(phy_dbgc[63:32]);      // 0x38 {EB input err words (rclk), realign, RX_BUF_ERR}
        4'd7: rd_reg = bswap(phy_dbgc[31:0]);       // 0x3C {EB output err words (all states), SKP added, SKP removed}
`endif
        default: rd_reg = regs[a];
        endcase
        end
    endfunction

`ifdef EERIE_ILA
    // the ILA read mux is combinational on ra: drive ra from the header beat being parsed
    always @(*) ila_ra = trn_rd[36:34];
    function [31:0] ila_rd_at(input [2:0] a); ila_rd_at = ila_rd; endfunction
`endif
    always @(posedge clk) begin
`ifdef EERIE_ILA
        ila_we <= 1'b0; ila_nx <= 1'b0;
`endif
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
`ifdef EERIE_ILA
                if (!is_64 && is_wr && ok && trn_rd[42]) begin
                    ila_we <= 1'b1; ila_wa <= trn_rd[36:34]; ila_wd <= bswap(trn_rd[31:0]);
                end else
`endif
`ifdef EERIE_DMA
                if (!is_64 && is_wr && ok && trn_rd[40]) begin
                    // deskriptorski upis (bit8 blok) — latchuje dma always blok preko dma_we; NE piši u scratch regs[]
                end else
`endif
                if (!is_64 && is_wr && ok && lx(trn_rd[37:34]) > 4'd2) regs[lx(trn_rd[37:34])] <= trn_rd[31:0];
                if (!is_wr && ok) begin
                    cpl_req <= 1'b1;
`ifdef EERIE_BWCNT
                    cpl_data <= (is_64 ? trn_rd[11] : trn_rd[43]) ? rd_bw(is_64 ? trn_rd[4:2] : trn_rd[36:34])
                                                                 : rd_reg(is_64 ? trn_rd[5:2] : trn_rd[37:34]);
`else
                    cpl_data <= rd_reg(is_64 ? trn_rd[5:2] : trn_rd[37:34]);
`endif
`ifdef EERIE_ILA
                    if (!is_64 && trn_rd[42]) begin
                        cpl_data <= bswap(ila_rd_at(trn_rd[36:34])); ila_nx <= (trn_rd[36:34] == 3'd3);
                    end
`endif
`ifdef EERIE_DMA
                    if (!is_64 && trn_rd[40]) cpl_data <= dma_rdbk(trn_rd[36:34]);  // 0x100/0x104 DMA status/rdata
`endif
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
            if (ts == 2'd2 && c_tdst) cpl_req <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- TX (CplD, 1 DW)
    // byte count i lower address iz First BE (PCIe 2.0 tablica 2-21 za 1 DW)
    wire [2:0] bc = req_fbe[0] ? (req_fbe[3] ? 3'd4 : req_fbe[2] ? 3'd3 : req_fbe[1] ? 3'd2 : 3'd1) :
                    req_fbe[1] ? (req_fbe[3] ? 3'd3 : req_fbe[2] ? 3'd2 : 3'd1) :
                    req_fbe[2] ? (req_fbe[3] ? 3'd2 : 3'd1) : 3'd1;
    wire [1:0] la = req_fbe[0] ? 2'd0 : req_fbe[1] ? 2'd1 : req_fbe[2] ? 2'd2 : req_fbe[3] ? 2'd3 : 2'd0;
    // CplD completer piše u interne c_* registre; arbitar na dnu bira c_* ili eerie_dma d_*.
    reg [63:0] c_td;
    reg        c_trem, c_tsof, c_teof, c_tsrc;
    always @(posedge clk) begin
        if (rst) begin
            ts <= 2'd0; c_tsrc <= 1'b0; c_tsof <= 1'b0; c_teof <= 1'b0; c_trem <= 1'b1;
        end else case (ts)
        2'd0: if (cpl_req && c_tdst) begin
            c_td   <= {1'b0, 2'b10, 5'b01010, 1'b0, req_tc, 4'd0, 2'b00, req_attr, 2'b00, 10'd1,
                       completer_id, 3'b000, 1'b0, 9'd0, bc};
            c_tsof <= 1'b1; c_teof <= 1'b0; c_trem <= 1'b1; c_tsrc <= 1'b1;
            ts <= 2'd1;
        end
        2'd1: if (c_tdst) begin
            c_td   <= {req_id, req_tag, 1'b0, req_low[6:2], la, cpl_data};
            c_tsof <= 1'b0; c_teof <= 1'b1; c_trem <= 1'b1;
            ts <= 2'd2;
        end
        default: if (c_tdst) begin
            c_tsrc <= 1'b0; c_teof <= 1'b0; ts <= 2'd0;
        end
        endcase
    end

`ifdef EERIE_DMA
    // ---------------------------------------------------------------- bus-master DMA (TASK-6215)
    // Deskriptor se upisuje MWr32-om na BAR0 s adresnim bitom 8 (offset 0x100..0x1FF, van scratch/ILA/BWCNT):
    //   0x100 addr_lo   0x104 addr_hi   0x108 wdata   0x10C ctrl={tag[15:8], wr=bit0} + upis pokreće go
    // Status se čita MRd32-om na istom bloku:  0x100 {rdata_v, busy, done_seen}   0x104 rdata (zadnji MRd).
    // eerie_dma formira EP-inicirani MemWr/MemRd na TRN TX; CplD se hvata snoop-om TRN RX (bm_en rutira CplD na R_USER).
    reg        dma_go, dma_wr, dma_done_seen;
    reg [63:0] dma_addr;
    reg [31:0] dma_wdata;
    reg [7:0]  dma_tag;
    wire        dma_busy, dma_done, dma_rdata_v, dma_tx_req;
    wire [31:0] dma_rdata;
    wire [63:0] d_td;
    wire        d_trem, d_tsof, d_teof, d_tsrc, d_tdst;

    // Deskriptorski MWr32 na BAR0 bit8-bloku (0x100..0x1FF): detekcija u R_HDR2 beatu (kombinacijski kvalifikator,
    // klokirana DMA logika ga uzorkuje na istom bridu). dma_hit_rd se koristi u RX FSM-u za status read override.
    wire        dma_we = rx && (rs == R_HDR2) && is_wr && ok && !is_64 && trn_rd[40];
    wire [2:0]  dma_wa = trn_rd[36:34];
    wire [31:0] dma_wd = trn_rd[31:0];
    // Raw readback (bez bswap), kao scratch regs: CM5 čita vrijednost kakvu je upisao / podatak kakav je stigao.
    function [31:0] dma_rdbk(input [2:0] a);
        case (a)
        3'd0:    dma_rdbk = {29'd0, dma_rdata_v, dma_busy, dma_done_seen};  // 0x100 status: b0 done, b1 busy, b2 rdata_v
        3'd1:    dma_rdbk = dma_rdata;                                      // 0x104 zadnji MRd podatak (round-trip)
        default: dma_rdbk = 32'h0;
        endcase
    endfunction

    always @(posedge clk) begin
        if (rst) begin dma_go <= 1'b0; dma_done_seen <= 1'b0; end
        else begin
            dma_go <= 1'b0;                         // 1-takt puls
            // deskriptorski upisi (MWr32 na bit8 bloku) — detektira ih RX FSM niže preko dma_we/dma_wa/dma_wd
            if (dma_we) case (dma_wa)
                3'd0: dma_addr[31:0]  <= dma_wd;
                3'd1: dma_addr[63:32] <= dma_wd;
                3'd2: dma_wdata       <= dma_wd;
                3'd3: begin dma_wr <= dma_wd[0]; dma_tag <= dma_wd[15:8]; dma_go <= 1'b1; dma_done_seen <= 1'b0; end
                default: ;
            endcase
            if (dma_done) dma_done_seen <= 1'b1;    // sticky dok se ne zada novi transfer
        end
    end

    eerie_dma dma (
        .clk(clk), .rst(rst), .req_id(completer_id),
        .go(dma_go), .wr(dma_wr), .addr(dma_addr), .wdata(dma_wdata), .tag(dma_tag),
        .busy(dma_busy), .done(dma_done), .rdata(dma_rdata), .rdata_v(dma_rdata_v), .tx_req(dma_tx_req),
        .trn_td(d_td), .trn_trem(d_trem), .trn_tsof(d_tsof), .trn_teof(d_teof), .trn_tsrc_rdy(d_tsrc),
        .trn_tdst_rdy(d_tdst),
        .trn_rd(trn_rd), .trn_rsof(trn_rsof), .trn_reof(trn_reof), .trn_rsrc_rdy(trn_rsrc_rdy));

    // TX arbitar: CplD ima prednost (host read timeout), DMA dobiva magistralu kad nema completiona u tijeku.
    localparam AR_IDLE = 2'd0, AR_CPL = 2'd1, AR_DMA = 2'd2;
    reg [1:0] arb;
    always @(posedge clk) begin
        if (rst) arb <= AR_IDLE;
        else case (arb)
            AR_IDLE: if (cpl_req)        arb <= AR_CPL;
                     else if (dma_tx_req) arb <= AR_DMA;
            AR_CPL:  if (c_tsrc && c_teof && c_tdst) arb <= AR_IDLE;   // zadnji CplD beat prihvaćen
            AR_DMA:  if (d_tsrc && d_teof && d_tdst) arb <= AR_IDLE;   // zadnji request beat prihvaćen
            default: arb <= AR_IDLE;
        endcase
    end
    assign c_tdst = (arb == AR_CPL) ? trn_tdst_rdy : 1'b0;
    assign d_tdst = (arb == AR_DMA) ? trn_tdst_rdy : 1'b0;
    assign trn_td       = (arb == AR_DMA) ? d_td   : c_td;
    assign trn_trem     = (arb == AR_DMA) ? d_trem : c_trem;
    assign trn_tsof     = (arb == AR_DMA) ? d_tsof : c_tsof;
    assign trn_teof     = (arb == AR_DMA) ? d_teof : c_teof;
    assign trn_tsrc_rdy = (arb == AR_DMA) ? d_tsrc : ((arb == AR_CPL) ? c_tsrc : 1'b0);
`else
    // bez DMA: completer izravno vlada TRN TX-om (ponašanje kao prije TASK-6215)
    assign c_tdst       = trn_tdst_rdy;
    assign trn_td       = c_td;
    assign trn_trem     = c_trem;
    assign trn_tsof     = c_tsof;
    assign trn_teof     = c_teof;
    assign trn_tsrc_rdy = c_tsrc;
`endif
endmodule
