// SPDX-License-Identifier: CERN-OHL-P
// TASK-6173: eerie_scr16 (EERIE_W16) i eerie_scr8 prema serijskom modelu po simbolu (isti LFSR kao eerie_pl_rx/tx:
// COM postavi FFFFh nakon svog simbola, SKP ne pomiče, ostali pomiču za 8). Nasumični podražaj, latencija 2 takta.
`timescale 1ns / 1ps
module tb_scr16_eq;
    `include "eerie_funcs.vh"
    reg clk = 0, rst = 1, v = 0; reg [127:0] d = 0; reg [15:0] k = 0, scr = 0, com = 0, skp = 0;
    wire [127:0] od16; wire [15:0] ok16; wire ov16, os16; wire [63:0] od8; wire [7:0] ok8; wire ov8, os8;
    eerie_scr16 #(.SW(1)) u16 (.clk(clk), .rst(rst), .v(v), .d(d), .k(k), .scr(scr), .com(com), .skp(skp), .side(1'b0),
        .od(od16), .ok(ok16), .ov(ov16), .oside(os16));
    eerie_scr8 #(.SW(1)) u8 (.clk(clk), .rst(rst), .v(v), .d(d[63:0]), .k(k[7:0]), .scr(scr[7:0]), .com(com[7:0]),
        .skp(skp[7:0]), .side(1'b0), .od(od8), .ok(ok8), .ov(ov8), .oside(os8));
    always #5 clk = !clk;
    reg [15:0] s16 = 16'hFFFF, s8 = 16'hFFFF;
    reg [127:0] e16 [0:2]; reg [63:0] e8 [0:2]; reg ev [0:2];
    integer n, i, err16 = 0, err8 = 0, ncom = 0;
    task model; input integer ns; inout [15:0] s; output [127:0] o;
        begin
            o = d;
            if (v) for (i = 0; i < ns; i = i + 1) begin
                if (scr[i]) o[8*i +: 8] = d[8*i +: 8] ^ f_lfsr_byte(s);
                if (com[i]) s = 16'hFFFF; else if (!skp[i]) s = f_lfsr_adv8(s);
            end
        end
    endtask
    reg [127:0] t16, t8;
    initial begin
        repeat (3) @(posedge clk); rst <= 0;
        for (n = 0; n < 100000; n = n + 1) begin
            @(negedge clk);
            v = ($random & 7) != 0; d = {$random, $random, $random, $random}; k = $random; scr = $random;
            com = (($random & 3) == 0) ? (16'd1 << ($random & 15)) | (($random & 1) ? (16'd1 << ($random & 15)) : 16'd0) : 16'd0;
            skp = $random & $random;
            model(16, s16, t16); model(8, s8, t8);
            e16[2] = e16[1]; e16[1] = e16[0]; e16[0] = t16; e8[2] = e8[1]; e8[1] = e8[0]; e8[0] = t8[63:0];
            ev[2] = ev[1]; ev[1] = ev[0]; ev[0] = v;
            if (n > 3 && ev[2]) begin
                if (od16 !== e16[2]) begin err16 = err16 + 1; if (err16 < 4) $display("RAZLIKA16 n=%0d %h %h", n, od16, e16[2]); end
                if (od8 !== e8[2]) begin err8 = err8 + 1; if (err8 < 4) $display("RAZLIKA8 n=%0d %h %h", n, od8, e8[2]); end
            end
            if (com != 0) ncom = ncom + 1;
        end
        $display("%0s: %0d ciklusa, %0d s COM, scr16 %0d razlika, scr8 %0d razlika", (err16 || err8) ? "FAIL" : "PASS", n, ncom, err16, err8);
        $finish;
    end
endmodule
