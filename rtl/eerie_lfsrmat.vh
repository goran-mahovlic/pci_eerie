// generirano: syn/gen_lfsr_mat.py — PCIe LFSR ADV8^n i scramble bajt, TASK-6161
function [15:0] f_lfsr_m0;
  input [15:0] l;
  begin
    f_lfsr_m0[0] = ^(l & 16'h0001);
    f_lfsr_m0[1] = ^(l & 16'h0002);
    f_lfsr_m0[2] = ^(l & 16'h0004);
    f_lfsr_m0[3] = ^(l & 16'h0008);
    f_lfsr_m0[4] = ^(l & 16'h0010);
    f_lfsr_m0[5] = ^(l & 16'h0020);
    f_lfsr_m0[6] = ^(l & 16'h0040);
    f_lfsr_m0[7] = ^(l & 16'h0080);
    f_lfsr_m0[8] = ^(l & 16'h0100);
    f_lfsr_m0[9] = ^(l & 16'h0200);
    f_lfsr_m0[10] = ^(l & 16'h0400);
    f_lfsr_m0[11] = ^(l & 16'h0800);
    f_lfsr_m0[12] = ^(l & 16'h1000);
    f_lfsr_m0[13] = ^(l & 16'h2000);
    f_lfsr_m0[14] = ^(l & 16'h4000);
    f_lfsr_m0[15] = ^(l & 16'h8000);
  end
endfunction
function [7:0] f_lfsr_b0;
  input [15:0] l;
  begin
    f_lfsr_b0[0] = ^(l & 16'h8000);
    f_lfsr_b0[1] = ^(l & 16'h4000);
    f_lfsr_b0[2] = ^(l & 16'h2000);
    f_lfsr_b0[3] = ^(l & 16'h1000);
    f_lfsr_b0[4] = ^(l & 16'h0800);
    f_lfsr_b0[5] = ^(l & 16'h0400);
    f_lfsr_b0[6] = ^(l & 16'h0200);
    f_lfsr_b0[7] = ^(l & 16'h0100);
  end
endfunction
function [15:0] f_lfsr_m1;
  input [15:0] l;
  begin
    f_lfsr_m1[0] = ^(l & 16'h0100);
    f_lfsr_m1[1] = ^(l & 16'h0200);
    f_lfsr_m1[2] = ^(l & 16'h0400);
    f_lfsr_m1[3] = ^(l & 16'h0900);
    f_lfsr_m1[4] = ^(l & 16'h1300);
    f_lfsr_m1[5] = ^(l & 16'h2700);
    f_lfsr_m1[6] = ^(l & 16'h4E00);
    f_lfsr_m1[7] = ^(l & 16'h9C00);
    f_lfsr_m1[8] = ^(l & 16'h3801);
    f_lfsr_m1[9] = ^(l & 16'h7002);
    f_lfsr_m1[10] = ^(l & 16'hE004);
    f_lfsr_m1[11] = ^(l & 16'hC008);
    f_lfsr_m1[12] = ^(l & 16'h8010);
    f_lfsr_m1[13] = ^(l & 16'h0020);
    f_lfsr_m1[14] = ^(l & 16'h0040);
    f_lfsr_m1[15] = ^(l & 16'h0080);
  end
endfunction
function [7:0] f_lfsr_b1;
  input [15:0] l;
  begin
    f_lfsr_b1[0] = ^(l & 16'h0080);
    f_lfsr_b1[1] = ^(l & 16'h0040);
    f_lfsr_b1[2] = ^(l & 16'h0020);
    f_lfsr_b1[3] = ^(l & 16'h8010);
    f_lfsr_b1[4] = ^(l & 16'hC008);
    f_lfsr_b1[5] = ^(l & 16'hE004);
    f_lfsr_b1[6] = ^(l & 16'h7002);
    f_lfsr_b1[7] = ^(l & 16'h3801);
  end
endfunction
function [15:0] f_lfsr_m2;
  input [15:0] l;
  begin
    f_lfsr_m2[0] = ^(l & 16'h3801);
    f_lfsr_m2[1] = ^(l & 16'h7002);
    f_lfsr_m2[2] = ^(l & 16'hE004);
    f_lfsr_m2[3] = ^(l & 16'hF809);
    f_lfsr_m2[4] = ^(l & 16'hC813);
    f_lfsr_m2[5] = ^(l & 16'hA827);
    f_lfsr_m2[6] = ^(l & 16'h504E);
    f_lfsr_m2[7] = ^(l & 16'hA09C);
    f_lfsr_m2[8] = ^(l & 16'h4138);
    f_lfsr_m2[9] = ^(l & 16'h8270);
    f_lfsr_m2[10] = ^(l & 16'h04E0);
    f_lfsr_m2[11] = ^(l & 16'h09C0);
    f_lfsr_m2[12] = ^(l & 16'h1380);
    f_lfsr_m2[13] = ^(l & 16'h2700);
    f_lfsr_m2[14] = ^(l & 16'h4E00);
    f_lfsr_m2[15] = ^(l & 16'h9C00);
  end
endfunction
function [7:0] f_lfsr_b2;
  input [15:0] l;
  begin
    f_lfsr_b2[0] = ^(l & 16'h9C00);
    f_lfsr_b2[1] = ^(l & 16'h4E00);
    f_lfsr_b2[2] = ^(l & 16'h2700);
    f_lfsr_b2[3] = ^(l & 16'h1380);
    f_lfsr_b2[4] = ^(l & 16'h09C0);
    f_lfsr_b2[5] = ^(l & 16'h04E0);
    f_lfsr_b2[6] = ^(l & 16'h8270);
    f_lfsr_b2[7] = ^(l & 16'h4138);
  end
endfunction
function [15:0] f_lfsr_m3;
  input [15:0] l;
  begin
    f_lfsr_m3[0] = ^(l & 16'h4138);
    f_lfsr_m3[1] = ^(l & 16'h8270);
    f_lfsr_m3[2] = ^(l & 16'h04E0);
    f_lfsr_m3[3] = ^(l & 16'h48F8);
    f_lfsr_m3[4] = ^(l & 16'hD0C8);
    f_lfsr_m3[5] = ^(l & 16'hE0A8);
    f_lfsr_m3[6] = ^(l & 16'hC150);
    f_lfsr_m3[7] = ^(l & 16'h82A0);
    f_lfsr_m3[8] = ^(l & 16'h0541);
    f_lfsr_m3[9] = ^(l & 16'h0A82);
    f_lfsr_m3[10] = ^(l & 16'h1504);
    f_lfsr_m3[11] = ^(l & 16'h2A09);
    f_lfsr_m3[12] = ^(l & 16'h5413);
    f_lfsr_m3[13] = ^(l & 16'hA827);
    f_lfsr_m3[14] = ^(l & 16'h504E);
    f_lfsr_m3[15] = ^(l & 16'hA09C);
  end
endfunction
function [7:0] f_lfsr_b3;
  input [15:0] l;
  begin
    f_lfsr_b3[0] = ^(l & 16'hA09C);
    f_lfsr_b3[1] = ^(l & 16'h504E);
    f_lfsr_b3[2] = ^(l & 16'hA827);
    f_lfsr_b3[3] = ^(l & 16'h5413);
    f_lfsr_b3[4] = ^(l & 16'h2A09);
    f_lfsr_b3[5] = ^(l & 16'h1504);
    f_lfsr_b3[6] = ^(l & 16'h0A82);
    f_lfsr_b3[7] = ^(l & 16'h0541);
  end
endfunction
function [15:0] f_lfsr_m4;
  input [15:0] l;
  begin
    f_lfsr_m4[0] = ^(l & 16'h0541);
    f_lfsr_m4[1] = ^(l & 16'h0A82);
    f_lfsr_m4[2] = ^(l & 16'h1504);
    f_lfsr_m4[3] = ^(l & 16'h2F48);
    f_lfsr_m4[4] = ^(l & 16'h5BD0);
    f_lfsr_m4[5] = ^(l & 16'hB2E0);
    f_lfsr_m4[6] = ^(l & 16'h65C1);
    f_lfsr_m4[7] = ^(l & 16'hCB82);
    f_lfsr_m4[8] = ^(l & 16'h9705);
    f_lfsr_m4[9] = ^(l & 16'h2E0A);
    f_lfsr_m4[10] = ^(l & 16'h5C15);
    f_lfsr_m4[11] = ^(l & 16'hB82A);
    f_lfsr_m4[12] = ^(l & 16'h7054);
    f_lfsr_m4[13] = ^(l & 16'hE0A8);
    f_lfsr_m4[14] = ^(l & 16'hC150);
    f_lfsr_m4[15] = ^(l & 16'h82A0);
  end
endfunction
function [7:0] f_lfsr_b4;
  input [15:0] l;
  begin
    f_lfsr_b4[0] = ^(l & 16'h82A0);
    f_lfsr_b4[1] = ^(l & 16'hC150);
    f_lfsr_b4[2] = ^(l & 16'hE0A8);
    f_lfsr_b4[3] = ^(l & 16'h7054);
    f_lfsr_b4[4] = ^(l & 16'hB82A);
    f_lfsr_b4[5] = ^(l & 16'h5C15);
    f_lfsr_b4[6] = ^(l & 16'h2E0A);
    f_lfsr_b4[7] = ^(l & 16'h9705);
  end
endfunction
function [15:0] f_lfsr_m5;
  input [15:0] l;
  begin
    f_lfsr_m5[0] = ^(l & 16'h9705);
    f_lfsr_m5[1] = ^(l & 16'h2E0A);
    f_lfsr_m5[2] = ^(l & 16'h5C15);
    f_lfsr_m5[3] = ^(l & 16'h2F2F);
    f_lfsr_m5[4] = ^(l & 16'hC95B);
    f_lfsr_m5[5] = ^(l & 16'h05B2);
    f_lfsr_m5[6] = ^(l & 16'h0B65);
    f_lfsr_m5[7] = ^(l & 16'h16CB);
    f_lfsr_m5[8] = ^(l & 16'h2D97);
    f_lfsr_m5[9] = ^(l & 16'h5B2E);
    f_lfsr_m5[10] = ^(l & 16'hB65C);
    f_lfsr_m5[11] = ^(l & 16'h6CB8);
    f_lfsr_m5[12] = ^(l & 16'hD970);
    f_lfsr_m5[13] = ^(l & 16'hB2E0);
    f_lfsr_m5[14] = ^(l & 16'h65C1);
    f_lfsr_m5[15] = ^(l & 16'hCB82);
  end
endfunction
function [7:0] f_lfsr_b5;
  input [15:0] l;
  begin
    f_lfsr_b5[0] = ^(l & 16'hCB82);
    f_lfsr_b5[1] = ^(l & 16'h65C1);
    f_lfsr_b5[2] = ^(l & 16'hB2E0);
    f_lfsr_b5[3] = ^(l & 16'hD970);
    f_lfsr_b5[4] = ^(l & 16'h6CB8);
    f_lfsr_b5[5] = ^(l & 16'hB65C);
    f_lfsr_b5[6] = ^(l & 16'h5B2E);
    f_lfsr_b5[7] = ^(l & 16'h2D97);
  end
endfunction
function [15:0] f_lfsr_m6;
  input [15:0] l;
  begin
    f_lfsr_m6[0] = ^(l & 16'h2D97);
    f_lfsr_m6[1] = ^(l & 16'h5B2E);
    f_lfsr_m6[2] = ^(l & 16'hB65C);
    f_lfsr_m6[3] = ^(l & 16'h412F);
    f_lfsr_m6[4] = ^(l & 16'hAFC9);
    f_lfsr_m6[5] = ^(l & 16'h7205);
    f_lfsr_m6[6] = ^(l & 16'hE40B);
    f_lfsr_m6[7] = ^(l & 16'hC816);
    f_lfsr_m6[8] = ^(l & 16'h902D);
    f_lfsr_m6[9] = ^(l & 16'h205B);
    f_lfsr_m6[10] = ^(l & 16'h40B6);
    f_lfsr_m6[11] = ^(l & 16'h816C);
    f_lfsr_m6[12] = ^(l & 16'h02D9);
    f_lfsr_m6[13] = ^(l & 16'h05B2);
    f_lfsr_m6[14] = ^(l & 16'h0B65);
    f_lfsr_m6[15] = ^(l & 16'h16CB);
  end
endfunction
function [7:0] f_lfsr_b6;
  input [15:0] l;
  begin
    f_lfsr_b6[0] = ^(l & 16'h16CB);
    f_lfsr_b6[1] = ^(l & 16'h0B65);
    f_lfsr_b6[2] = ^(l & 16'h05B2);
    f_lfsr_b6[3] = ^(l & 16'h02D9);
    f_lfsr_b6[4] = ^(l & 16'h816C);
    f_lfsr_b6[5] = ^(l & 16'h40B6);
    f_lfsr_b6[6] = ^(l & 16'h205B);
    f_lfsr_b6[7] = ^(l & 16'h902D);
  end
endfunction
function [15:0] f_lfsr_m7;
  input [15:0] l;
  begin
    f_lfsr_m7[0] = ^(l & 16'h902D);
    f_lfsr_m7[1] = ^(l & 16'h205B);
    f_lfsr_m7[2] = ^(l & 16'h40B6);
    f_lfsr_m7[3] = ^(l & 16'h1141);
    f_lfsr_m7[4] = ^(l & 16'hB2AF);
    f_lfsr_m7[5] = ^(l & 16'hF572);
    f_lfsr_m7[6] = ^(l & 16'hEAE4);
    f_lfsr_m7[7] = ^(l & 16'hD5C8);
    f_lfsr_m7[8] = ^(l & 16'hAB90);
    f_lfsr_m7[9] = ^(l & 16'h5720);
    f_lfsr_m7[10] = ^(l & 16'hAE40);
    f_lfsr_m7[11] = ^(l & 16'h5C81);
    f_lfsr_m7[12] = ^(l & 16'hB902);
    f_lfsr_m7[13] = ^(l & 16'h7205);
    f_lfsr_m7[14] = ^(l & 16'hE40B);
    f_lfsr_m7[15] = ^(l & 16'hC816);
  end
endfunction
function [7:0] f_lfsr_b7;
  input [15:0] l;
  begin
    f_lfsr_b7[0] = ^(l & 16'hC816);
    f_lfsr_b7[1] = ^(l & 16'hE40B);
    f_lfsr_b7[2] = ^(l & 16'h7205);
    f_lfsr_b7[3] = ^(l & 16'hB902);
    f_lfsr_b7[4] = ^(l & 16'h5C81);
    f_lfsr_b7[5] = ^(l & 16'hAE40);
    f_lfsr_b7[6] = ^(l & 16'h5720);
    f_lfsr_b7[7] = ^(l & 16'hAB90);
  end
endfunction
function [15:0] f_lfsr_m8;
  input [15:0] l;
  begin
    f_lfsr_m8[0] = ^(l & 16'hAB90);
    f_lfsr_m8[1] = ^(l & 16'h5720);
    f_lfsr_m8[2] = ^(l & 16'hAE40);
    f_lfsr_m8[3] = ^(l & 16'hF711);
    f_lfsr_m8[4] = ^(l & 16'h45B2);
    f_lfsr_m8[5] = ^(l & 16'h20F5);
    f_lfsr_m8[6] = ^(l & 16'h41EA);
    f_lfsr_m8[7] = ^(l & 16'h83D5);
    f_lfsr_m8[8] = ^(l & 16'h07AB);
    f_lfsr_m8[9] = ^(l & 16'h0F57);
    f_lfsr_m8[10] = ^(l & 16'h1EAE);
    f_lfsr_m8[11] = ^(l & 16'h3D5C);
    f_lfsr_m8[12] = ^(l & 16'h7AB9);
    f_lfsr_m8[13] = ^(l & 16'hF572);
    f_lfsr_m8[14] = ^(l & 16'hEAE4);
    f_lfsr_m8[15] = ^(l & 16'hD5C8);
  end
endfunction
function [7:0] f_lfsr_b8;
  input [15:0] l;
  begin
    f_lfsr_b8[0] = ^(l & 16'hD5C8);
    f_lfsr_b8[1] = ^(l & 16'hEAE4);
    f_lfsr_b8[2] = ^(l & 16'hF572);
    f_lfsr_b8[3] = ^(l & 16'h7AB9);
    f_lfsr_b8[4] = ^(l & 16'h3D5C);
    f_lfsr_b8[5] = ^(l & 16'h1EAE);
    f_lfsr_b8[6] = ^(l & 16'h0F57);
    f_lfsr_b8[7] = ^(l & 16'h07AB);
  end
endfunction
