// SPDX-License-Identifier: CERN-OHL-P-2.0
// Jedinični test eerie_skp_eb (TASK-6161; -DEERIE_SKP_EBB: eerie_skp_ebb, TASK-6176): wclk 31,25 MHz, rclk pomaknut za PPM (+ sporiji, - brži).
// Ulaz: nasumični podatci + SKP OS (COM + 3 SKP) svakih ~1180 simbola na bilo kojem položaju + COM bez SKP-a.
// Provjera: izlaz bez SKP simbola == ulaz bez SKP simbola; svaki SKP OS na izlazu ima 1..5 SKP; nema podljeva.
`timescale 1ps / 1ps
module tb_skp_eb;
    integer PPM = 600;
    integer NW = 60000;
    reg wclk = 0, rclk = 0, rst = 1;
    real rhalf;
    initial begin
        if (!$value$plusargs("ppm=%d", PPM)) PPM = 600;
        if (!$value$plusargs("nw=%d", NW)) NW = 60000;
        rhalf = 16000.0 * (1.0 + PPM * 1.0e-6);
    end
    always #16000 wclk = !wclk;
    always begin #(rhalf) rclk = !rclk; end
    // ---------------- generator (simboli -> riječi) ----------------
    reg [8:0] ref_q [0:1048575]; integer ref_w = 0, ref_r = 0;     // ulaz bez SKP
    reg [63:0] w_d, g_d; reg [7:0] w_k, g_k; reg w_v = 0;
    integer gap = 700, sk = 0, i, nwr = 0, com_free = 0;
    reg [8:0] sym;
    integer seed = 7;
    always @(posedge wclk) begin
        if (rst) w_v <= 0;
        else if (nwr < NW) begin
            for (i = 0; i < 8; i = i + 1) begin
                if (sk > 0) begin sym = {1'b1, 8'h1C}; sk = sk - 1; end
                else if (gap == 0) begin sym = {1'b1, 8'hBC}; sk = 3; gap = 1150 + ($random(seed) & 63); end
                else if (gap == 300) begin sym = {1'b1, 8'hBC}; gap = gap - 1; end   // COM bez SKP (npr. TS)
                else begin sym = {1'b0, $random(seed)} & 9'h0FF; gap = gap - 1; end
                g_d[8*i +: 8] = sym[7:0]; g_k[i] = sym[8];
                if (!(sym[8] && sym[7:0] == 8'h1C)) begin ref_q[ref_w] = sym; ref_w = ref_w + 1; end
            end
            w_d <= g_d; w_k <= g_k; w_v <= 1; nwr = nwr + 1;
        end else w_v <= 0;
    end
    wire r_v; wire [63:0] r_d; wire [7:0] r_k; wire [2:0] r_st; wire [4:0] r_fill;
`ifdef EERIE_SKP_EBB
    eerie_skp_ebb eb (.wclk(wclk), .wrst(rst), .w_v(w_v), .w_d(w_d), .w_k(w_k), .w_err(1'b0),
        .rclk(rclk), .rrst(rst), .r_v(r_v), .r_d(r_d), .r_k(r_k), .r_status(r_st), .r_fill(r_fill));
`else
    eerie_skp_eb eb (.wclk(wclk), .wrst(rst), .w_v(w_v), .w_d(w_d), .w_k(w_k), .w_err(1'b0),
        .rclk(rclk), .rrst(rst), .r_v(r_v), .r_d(r_d), .r_k(r_k), .r_status(r_st), .r_fill(r_fill));
`endif
    // ---------------- provjera ----------------
    integer n_ins = 0, n_del = 0, n_under = 0, n_bad = 0, n_os = 0, run = 0, n_runbad = 0, started = 0, nout = 0;
    integer fmin = 99, fmax = 0;
    reg in_os = 0; reg [8:0] s;
    always @(posedge wclk) if (eb.wfound && w_v && !rst) n_del = n_del + 1;
    always @(posedge rclk) if (!rst) begin
        if (r_v) started = 1;
        if (started) begin
            if (r_st == 3'b001) n_ins = n_ins + 1;
            
            if ((!r_v || r_st == 3'b110) && nwr < NW) n_under = n_under + 1;
            if (r_fill < fmin && nout > 100) fmin = r_fill; if (r_fill > fmax) fmax = r_fill;
        end
        if (r_v) for (i = 0; i < 8; i = i + 1) begin
            s = {r_k[i], r_d[8*i +: 8]};
            if (s == 9'h1BC) begin if (in_os && (run < 1 || run > 5)) begin n_runbad = n_runbad + 1; $display("%t los niz (COM) run=%0d", $time, run); end in_os = 1; run = 0; end
            else if (s == 9'h11C) begin run = run + 1; end
            else begin if (in_os && run > 0) begin n_os = n_os + 1; if (run > 5) begin n_runbad = n_runbad + 1; $display("%t los niz run=%0d", $time, run); end end in_os = 0; run = 0; end
            if (s != 9'h11C) begin
                if (ref_r < ref_w && ref_q[ref_r] !== s) begin
                    if (n_bad < 5) $display("MISMATCH na %0d: dobiveno %h ocekivano %h", ref_r, s, ref_q[ref_r]);
                    n_bad = n_bad + 1;
                end
                ref_r = ref_r + 1;
            end
        end
        if (r_v) nout = nout + 1;
    end
    initial begin
        #200000 rst = 0;
        wait (nwr >= NW); #2000000;
        $display("ppm=%0d rijeci=%0d usporedeno=%0d/%0d simbola, SKP OS=%0d, umetnuto=%0d, uklonjeno=%0d, podljev=%0d, krivih=%0d, SKP-niz izvan 1..5=%0d, popunjenost %0d..%0d",
                 PPM, NW, ref_r, ref_w, n_os, n_ins, n_del, n_under, n_bad, n_runbad, fmin, fmax);
        if (n_bad == 0 && n_runbad == 0 && n_under <= 1 && ref_r > ref_w - 64) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
