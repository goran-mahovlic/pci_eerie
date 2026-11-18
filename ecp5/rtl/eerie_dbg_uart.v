// SPDX-License-Identifier: CERN-OHL-P-2.0
// Promatrač RX puta za ULX4M-LD (TASK-6160): samo čita, ništa ne vraća u PHY ni u pci_eerie.
// Svakih 2^PER_W taktova clk_free šalje na tx (8N2, clk_free/DIV) redak:
//   "Lt f=FF l=LL p=PP K=kkkkkkkk 1=aaaaaaaa 2=bbbbbbbb i=cccccccc v=vvvvvvvv e=eeeeeeee c=cccccccc s=ssssssssssssssss\r\n"
//   f  zastavice: [0] PERST# pušten [1] TX PLL spreman [2] nema LOS [3] CDR zaključan [4] LSM poravnat
//      [5] LANE_RX_RST pušten [6] host detektiran [7] pclk živ (stigla nova slika od zadnjeg retka)
//   l  LTSSM pci_eerie (bit 7 = lnk_up)   s  maska svih LTSSM stanja viđenih od paljenja (bit n = stanje n)
//   K  broj primljenih K28.5 bajtova (izravno s DCU-a, bez obzira na RxValid)
//   1/2/i  bajtovi 0x4A (TS1 ID), 0x45 (TS2 ID), 0xB5 (TS1 ID s obrnutim polaritetom), D-znakovi
//   v  taktovi s PIPE RxValid    e  bajtovi s greškom kôda ili disparity (RX status 100/111)
//   c  CTC događaji (RX status 001 SKP dodan / 010 SKP maknut / 101, 110 preljev)
//   p  [7] trenutni rxpolarity, [6:0] broj promjena rxpolarity od paljenja
// t = oznaka izlaza: tx[k] šalje "a"+k, pa redak sam kaže na kojoj je kuglici (kad je spoj prema hostu nepoznat).
// Brojači su 32-bitni, kumulativni od paljenja (razlika dvaju redaka = promet u ~84 ms).
// Snimač: kružni RAM 1024 x 32 (pclk) piše {ltssm, rxvalid, rxpolarity, dcu_rx_d}; kad LTSSM prvi put uđe u TRIG,
// snima još 768 taktova i stane. Tada se JEDNOM ispiše 1024 retka "Tt aaa LLppdddddd\r\n" (najstariji prvi;
// LL = {ltssm,rxvalid,rxpolarity} kao bajt: ltssm = LL>>2), pa se nastavljaju statusni retci.
`timescale 1ns / 1ps
module eerie_dbg_uart #(
    parameter DIV   = 217,    // 25 MHz / 115200
    parameter PER_W = 21,     // 2^21 / 25 MHz = 84 ms
    parameter NTX   = 1,      // broj izlaza (isti redak, različita oznaka)
    parameter [5:0] TRIG = 6'h05  // okidač snimača: prvi ulazak u ovo LTSSM stanje
) (
    input         clk_free,
    input         pclk,
    input  [6:0]  flags,      // asinkrone, [6:0] kao gore
    input  [5:0]  ltssm,      // pclk
    input         lnk_up,     // pclk
    input  [23:0] dcu_rx_d,   // pclk
    input         rxvalid,    // pclk
    input         rxpolarity, // pclk
    output [NTX-1:0] tx
);
    // ------------------------------------------------ pclk: brojači
    reg [31:0] c_k = 0, c_1 = 0, c_2 = 0, c_i = 0, c_v = 0, c_e = 0, c_c = 0;
    reg [6:0]  c_p = 0;
    reg        pol_q = 0;
    reg [63:0] seen = 0;
    reg [23:0] rd = 0;
    function [1:0] cnt2; input a, b; cnt2 = {1'b0, a} + {1'b0, b}; endfunction
    wire k0 = rd[8],  k1 = rd[20];
    wire [7:0] b0 = rd[7:0], b1 = rd[19:12];
    always @(posedge pclk) begin
        rd   <= dcu_rx_d;
        c_k  <= c_k + cnt2(k0 && b0 == 8'hBC, k1 && b1 == 8'hBC);
        c_1  <= c_1 + cnt2(!k0 && b0 == 8'h4A, !k1 && b1 == 8'h4A);
        c_2  <= c_2 + cnt2(!k0 && b0 == 8'h45, !k1 && b1 == 8'h45);
        c_i  <= c_i + cnt2(!k0 && b0 == 8'hB5, !k1 && b1 == 8'hB5);
        c_e  <= c_e + cnt2(rd[11:9] == 3'b100 || rd[11:9] == 3'b111, rd[23:21] == 3'b100 || rd[23:21] == 3'b111);
        c_c  <= c_c + cnt2(rd[11:9] != 3'b000 && rd[11:9] != 3'b100 && rd[11:9] != 3'b111,
                           rd[23:21] != 3'b000 && rd[23:21] != 3'b100 && rd[23:21] != 3'b111);
        pol_q <= rxpolarity;
        if (pol_q != rxpolarity && c_p != 7'h7F) c_p <= c_p + 1'b1;
        c_v  <= c_v + rxvalid;
        seen[ltssm] <= 1'b1;
    end

    // ------------------------------------------------ pclk: snimač
    reg [31:0] tmem [0:1023];
    reg [9:0]  twa = 0, tpost = 0;
    reg        tarm = 1'b1, ttrig = 1'b0, tfrozen = 1'b0;
    always @(posedge pclk) begin
        if (!tfrozen) begin
            tmem[twa] <= {ltssm, rxvalid, rxpolarity, rd};
            twa <= twa + 1'b1;
            if (tarm && ltssm == TRIG) begin tarm <= 1'b0; ttrig <= 1'b1; tpost <= 10'd767; end
            else if (ttrig) begin tpost <= tpost - 1'b1; if (tpost == 0) tfrozen <= 1'b1; end
        end
    end

    // ------------------------------------------------ CDC: zahtjev (clk_free) -> slika (pclk) -> potvrda
    reg        req = 1'b0, ack = 1'b0;
    reg [2:0]  req_p = 0, ack_f = 0;
    reg [7:0]  sh_l, sh_p;
    reg [31:0] sh_k, sh_1, sh_2, sh_i, sh_v, sh_e, sh_c;
    reg [63:0] sh_s;
    always @(posedge pclk) begin
        req_p <= {req_p[1:0], req};
        if (req_p[2] != req_p[1]) begin
            sh_l <= {lnk_up, 1'b0, ltssm};
            sh_k <= c_k; sh_1 <= c_1; sh_2 <= c_2; sh_i <= c_i; sh_v <= c_v; sh_e <= c_e; sh_c <= c_c; sh_s <= seen;
            sh_p <= {pol_q, c_p};
            ack  <= !ack;
        end
    end

    // ------------------------------------------------ clk_free: slika, redak, UART
    reg [6:0]  fa, fb;
    always @(posedge clk_free) begin fa <= flags; fb <= fa; end
    reg [7:0]  s_f = 0, s_l = 0, s_p = 0;
    reg [31:0] s_k = 0, s_1 = 0, s_2 = 0, s_i = 0, s_v = 0, s_e = 0, s_c = 0;
    reg [63:0] s_s = 0;
    reg        fresh = 1'b0;
    reg [PER_W-1:0] tick = 0;

    function [7:0] hex; input [3:0] n; hex = n < 10 ? 8'h30 + n : 8'h57 + n; endfunction
    // redak: "Lt " 3 + "f=FF " "l=LL " "p=PP " 15 + 7 brojača po 11 + "s=" 16 hex " " + CRLF = 116 znakova
    localparam LEN = 116;
    reg [6:0] idx = 0;
    reg       sending = 1'b0;
    function [7:0] h8; input [1:0] j; input [7:0] v;   // polje "x=HH " (j = 2, 3)
        h8 = hex(j == 2 ? v[7:4] : v[3:0]);
    endfunction
    function [7:0] ch; input [6:0] i;
        reg [6:0] j, f;
        reg [31:0] v;
        begin
            ch = " ";
            if (i == 0) ch = "L";
            else if (i >= 3 && i < 18) begin
                j = (i - 3) % 5; f = (i - 3) / 5;
                if (j == 0) ch = f == 0 ? "f" : f == 1 ? "l" : "p";
                else if (j == 1) ch = "=";
                else if (j < 4) ch = h8(j, f == 0 ? s_f : f == 1 ? s_l : s_p);
            end
            else if (i >= 18 && i < 95) begin
                j = (i - 18) % 11; f = (i - 18) / 11;
                case (f) 0: v = s_k; 1: v = s_1; 2: v = s_2; 3: v = s_i; 4: v = s_v; 5: v = s_e; default: v = s_c; endcase
                if (j == 0) case (f) 0: ch = "K"; 1: ch = "1"; 2: ch = "2"; 3: ch = "i"; 4: ch = "v"; 5: ch = "e"; default: ch = "c"; endcase
                else if (j == 1) ch = "=";
                else if (j < 10) ch = hex(v >> (4 * (9 - j)));
            end
            else if (i == 95) ch = "s";
            else if (i == 96) ch = "=";
            else if (i >= 97 && i < 113) ch = hex(s_s >> (4 * (112 - i)));
            else if (i == 114) ch = 8'h0d;
            else if (i == 115) ch = 8'h0a;
        end
    endfunction

    // ispis snimača: 16 znakova po retku "Tt aaa LLdddddd\r\n" (t = oznaka izlaza kao u statusnom retku)
    reg [2:0]  frz_f = 0;
    reg        dump = 1'b0, dumped = 1'b0;
    reg [9:0]  dline = 0;
    reg [31:0] tq1, tq;
    always @(posedge clk_free) begin tq1 <= tmem[twa + dline]; tq <= tq1; end   // twa je zamrznut
    function [7:0] chd; input [6:0] i;
        begin
            chd = " ";
            if (i == 0) chd = "T";
            else if (i >= 3 && i < 6) chd = hex(i == 3 ? {2'b00, dline[9:8]} : i == 4 ? dline[7:4] : dline[3:0]);
            else if (i >= 7 && i < 15) chd = hex(tq >> (4 * (14 - i)));
            else if (i == 15) chd = 8'h0a;
        end
    endfunction

    reg [8:0]  tcnt = 0;
    reg [3:0]  tbit = 0;
    reg [10*NTX-1:0] tsh = {NTX{10'h3ff}};
    reg [11:0] gap = 0;                                       // mir nakon retka snimke (resinkronizacija prijemnika)
    reg        tbusy = 1'b0;
    genvar g;
    generate for (g = 0; g < NTX; g = g + 1) begin : o
        assign tx[g] = tsh[10*g];
    end endgenerate
    integer k;
    always @(posedge clk_free) begin
        tick  <= tick + 1'b1;
        ack_f <= {ack_f[1:0], ack};
        if (ack_f[2] != ack_f[1] && !sending) begin                  // slika se ne mijenja usred retka
            s_l <= sh_l; s_k <= sh_k; s_1 <= sh_1; s_2 <= sh_2; s_i <= sh_i; s_v <= sh_v; s_e <= sh_e; s_c <= sh_c; s_s <= sh_s; s_p <= sh_p;
            fresh <= 1'b1;
        end
        if (tick == {PER_W{1'b0}}) req <= !req;                       // nova slika ...
        frz_f <= {frz_f[1:0], tfrozen};
        if (!sending && !dump && frz_f[2] && !dumped) begin dump <= 1'b1; dline <= 0; idx <= 0; end
        if (tick == {1'b1, {PER_W-1{1'b0}}} && !sending && !dump) begin  // ... pola perioda kasnije redak
            sending <= 1'b1; idx <= 0; s_f <= {fresh, fb}; fresh <= 1'b0;
        end
        if (!tbusy) begin
            if (gap != 0) gap <= gap - 1'b1;
            else if (dump) begin
                if (idx == 16) begin
                    gap <= 12'hFFF;
                    idx <= 0; dline <= dline + 1'b1;
                    if (dline == 10'h3FF) begin dump <= 1'b0; dumped <= 1'b1; end
                end else begin
                    for (k = 0; k < NTX; k = k + 1)
                        tsh[10*k +: 10] <= {1'b1, idx == 1 ? 8'h61 + k : chd(idx), 1'b0};
                    tbusy <= 1'b1; tcnt <= 0; tbit <= 0; idx <= idx + 1'b1;
                end
            end else if (sending) begin
                if (idx == LEN) sending <= 1'b0;
                else begin
                    for (k = 0; k < NTX; k = k + 1)
                        tsh[10*k +: 10] <= {1'b1, idx == 1 ? 8'h61 + k : ch(idx), 1'b0};
                    tbusy <= 1'b1; tcnt <= 0; tbit <= 0; idx <= idx + 1'b1;
                end
            end
        end else if (tcnt == DIV - 1) begin
            tcnt <= 0; tbit <= tbit + 1'b1;
            for (k = 0; k < NTX; k = k + 1)
                tsh[10*k +: 10] <= tbit >= 9 ? 10'h3ff : {1'b1, tsh[10*k+1 +: 9]};
            if (tbit == 10) tbusy <= 1'b0;                       // 2 stop bita
        end else tcnt <= tcnt + 1'b1;
    end
endmodule
