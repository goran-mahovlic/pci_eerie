// SPDX-License-Identifier: CERN-OHL-P-2.0
// TB za eerie_dbg_uart (TASK-6160): dekodira UART i ispisuje retke; provjera u sim/run_dbg_uart.sh
`timescale 1ns / 1ps
module tb_dbg_uart;
    reg cf = 0, pc = 0;
    always #20 cf = !cf;    // 25 MHz
    always #4  pc = !pc;    // 125 MHz
    reg [23:0] d = 0; reg rv = 0; reg pol = 0; reg [5:0] lt = 6'h00;
    wire [1:0] txv; wire tx = txv[0];
    eerie_dbg_uart #(.DIV(8), .PER_W(15), .NTX(2), .TRIG(6'h07)) dut (.clk_free(cf), .pclk(pc), .flags(7'h55), .ltssm(lt), .lnk_up(1'b0),
        .dcu_rx_d(d), .rxvalid(rv), .rxpolarity(pol), .tx(txv));
    // drugi izlaz mora biti isti redak osim oznake (a/b) u znaku 1
    reg diff = 0; always @(posedge cf) if (txv[0] !== txv[1]) diff <= 1;
    // 1000 pclk taktova: bajt0 = K28.5, bajt1 = 0x4A (TS1 ID); zatim 0xB5 + status greške; zatim tišina
    integer n = 0;
    always @(posedge pc) begin
        n <= n + 1;
        if (n < 1000)       begin d <= {4'b0000, 8'h4A, 4'b0001, 8'hBC}; rv <= 1; lt <= 6'h03; end
        else if (n < 1100)  begin d <= {4'b0000, 8'hB5, 4'b1000, 8'h00}; rv <= 0; lt <= 6'h07; pol <= 1; end
        else if (n < 1150)  begin d <= {4'b0010, 8'h00, 4'b1110, 8'h00}; pol <= 0; end   // 50 x CTC (001) + 50 x disparity (111)
        else                begin d <= 0; rv <= 0; end
    end
    // UART prijemnik: 8 clk_free po bitu
    reg [7:0] b; integer i, nl = 0;
    initial begin
        forever begin
            @(negedge tx); #(40*8/2);
            for (i = 0; i < 8; i = i + 1) begin #(40*8); b[i] = tx; end
            #(40*8*2);
            if (b == 8'h0a) begin nl = nl + 1; if (nl == 3 + 1024 + 1) begin $write("\nDIFF=%0d\n", diff); $finish; end end
            $write("%c", b);
        end
    end
    initial begin #600_000_000; $display("TIMEOUT"); $finish; end
endmodule
