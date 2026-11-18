// SPDX-License-Identifier: CERN-OHL-P
// TASK-6161: eerie_scr8 izvorno vs EERIE_SCR8_MAT + EERIE_SCR8_PTREE — isti nasumični podražaj, izlazi moraju biti jednaki
`timescale 1ns / 1ps
module tb_scr8_eq;
    reg clk = 0, rst = 1, v = 0; reg [63:0] d = 0; reg [7:0] k = 0, scr = 0, com = 0, skp = 0;
    wire [63:0] od_g, od_t; wire [7:0] ok_g, ok_t; wire ov_g, ov_t; wire os_g, os_t;
    scr_gold g (.clk(clk), .rst(rst), .v(v), .d(d), .k(k), .scr(scr), .com(com), .skp(skp), .side(1'b0), .od(od_g), .ok(ok_g), .ov(ov_g), .oside(os_g));
    scr_gate t (.clk(clk), .rst(rst), .v(v), .d(d), .k(k), .scr(scr), .com(com), .skp(skp), .side(1'b0), .od(od_t), .ok(ok_t), .ov(ov_t), .oside(os_t));
    always #5 clk = !clk;
    integer n, err = 0, ncom = 0;
    initial begin
        repeat (3) @(posedge clk); rst <= 0;
        for (n = 0; n < 50000; n = n + 1) begin
            @(posedge clk);
            v <= ($random & 7) != 0; d <= {$random, $random}; k <= $random; scr <= $random;
            com <= (($random & 3) == 0) ? (8'd1 << ($random & 7)) | (($random & 1) ? (8'd1 << ($random & 7)) : 8'd0) : 8'd0;
            skp <= $random & $random;
            if (od_g !== od_t || ok_g !== ok_t || ov_g !== ov_t) begin
                err = err + 1; if (err < 5) $display("RAZLIKA n=%0d %h %h", n, od_g, od_t);
            end
            if (com != 0) ncom = ncom + 1;
        end
        $display("%0s: %0d ciklusa, %0d s COM, %0d razlika", err ? "FAIL" : "PASS", n, ncom, err);
        $finish;
    end
endmodule
