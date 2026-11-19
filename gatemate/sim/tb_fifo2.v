// SPDX-License-Identifier: CERN-OHL-P
// TASK-6173: eerie_async_fifo2 (2 banke + izlazni red): nasumični paketi upisom, nasumično čitanje 0/1/2 po taktu;
// izlaz mora biti isti niz unosa, a čita se samo cijeli (upisani) paket. SYNC=1 i SYNC=0 (drugi takt).
`timescale 1ns / 1ps
module tb_fifo2;
    reg clk = 0, rclk = 0, rst = 1; always #5 clk = !clk;
    always #(`RHALF) rclk = !rclk;
    wire rc = `SYNCP ? clk : rclk;
    reg we = 0, wl = 0; reg [15:0] wd = 0; wire full; wire [5:0] free;
    reg [1:0] rn = 0; wire [15:0] rd, rd2; wire emp, h2;
    eerie_async_fifo2 #(.W(16), .AW(5), .PKT_MODE(1), .SYNC(`SYNCP)) u (.wr_clk(clk), .wr_rst(rst), .wr_en(we), .wr_data(wd),
        .wr_last(wl), .wr_full(full), .wr_free(free), .rd_clk(rc), .rd_rst(rst), .rd_n(rn), .rd_data(rd), .rd_data2(rd2),
        .rd_empty(emp), .rd_has2(h2));
    integer nw = 0, nr = 0, err = 0, plen = 0;
    reg [15:0] exp_n = 0;
    always @(posedge clk) if (!rst) begin
        if (!full && free > 2 && ($random & 3) != 0 && nw < 20000) begin
            we <= 1; wd <= nw[15:0]; nw = nw + 1; plen = plen + 1;
            wl <= (plen >= 1 + ($random & 7)); if (plen >= 1 + ($random & 7)) plen = 0;
        end else we <= 0;
    end
    reg [1:0] t;
    always @(negedge rc) if (!rst) begin
        t = $random & 3; rn = (t == 3) ? 2'd2 : t[1:0]; if (t == 2) rn = 2'd2;
        if (rn == 2 && !h2) rn = emp ? 0 : 1; if (emp) rn = 0;
    end
    always @(posedge rc) if (!rst) begin
        if (rn >= 1) begin if (rd !== exp_n) begin err = err + 1; if (err < 5) $display("RAZLIKA %h %h", rd, exp_n); end exp_n = exp_n + 1; nr = nr + 1; end
        if (rn == 2) begin if (rd2 !== exp_n) begin err = err + 1; if (err < 5) $display("RAZLIKA2 %h %h", rd2, exp_n); end exp_n = exp_n + 1; nr = nr + 1; end
    end
    initial begin #100 rst = 0; #2000000; $display("%s: upisano %0d, procitano %0d, razlika %0d", (err == 0 && nr > 15000) ? "PASS" : "FAIL", nw, nr, err); $finish; end
endmodule
