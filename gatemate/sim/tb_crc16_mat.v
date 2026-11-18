// SPDX-License-Identifier: CERN-OHL-P
// TASK-6161: f_crc16_dl3 / f_dllp_fld4 (gen_crc_mat.py) naspram f_crc16_byte / f_dllp_crc, 100000 nasumičnih riječi
module tb_c16;
`include "eerie_funcs.vh"
`include "eerie_crcmat.vh"
  function [15:0] dlc3; input [23:0] w; dlc3 = f_crc16_byte(f_crc16_byte(f_crc16_byte(16'hFFFF, w[23:16]), w[15:8]), w[7:0]); endfunction
  reg [31:0] d; reg [15:0] c; integer n, e = 0;
  initial begin for (n = 0; n < 100000; n = n + 1) begin d = $random;
    if (f_crc16_dl3(d[23:0]) !== dlc3(d[23:0])) e = e + 1;
    c = f_crc16_byte(dlc3(d[31:8]), d[7:0]);
    if (f_dllp_fld4(d) !== {f_rev8(~c[15:8]), f_rev8(~c[7:0])}) e = e + 1;
    if (f_dllp_fld4(d) !== f_dllp_crc(d)) e = e + 1;
  end $display("%0s: 100000 nasumicnih, %0d razlika", e ? "FAIL" : "PASS", e); end endmodule
