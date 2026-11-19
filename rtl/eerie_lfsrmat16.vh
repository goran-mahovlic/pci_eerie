// generirano: syn/gen_lfsr_mat16.py — PCIe LFSR ADV8^n (n = 9..16) i scramble bajt (n = 9..15), TASK-6173
function [15:0] f_lfsr_m9;
  input [15:0] l;
  begin
    f_lfsr_m9[0] = ^(l & 16'h07AB);
    f_lfsr_m9[1] = ^(l & 16'h0F57);
    f_lfsr_m9[2] = ^(l & 16'h1EAE);
    f_lfsr_m9[3] = ^(l & 16'h3AF7);
    f_lfsr_m9[4] = ^(l & 16'h7245);
    f_lfsr_m9[5] = ^(l & 16'hE320);
    f_lfsr_m9[6] = ^(l & 16'hC641);
    f_lfsr_m9[7] = ^(l & 16'h8C83);
    f_lfsr_m9[8] = ^(l & 16'h1907);
    f_lfsr_m9[9] = ^(l & 16'h320F);
    f_lfsr_m9[10] = ^(l & 16'h641E);
    f_lfsr_m9[11] = ^(l & 16'hC83D);
    f_lfsr_m9[12] = ^(l & 16'h907A);
    f_lfsr_m9[13] = ^(l & 16'h20F5);
    f_lfsr_m9[14] = ^(l & 16'h41EA);
    f_lfsr_m9[15] = ^(l & 16'h83D5);
  end
endfunction
function [7:0] f_lfsr_b9;
  input [15:0] l;
  begin
    f_lfsr_b9[0] = ^(l & 16'h83D5);
    f_lfsr_b9[1] = ^(l & 16'h41EA);
    f_lfsr_b9[2] = ^(l & 16'h20F5);
    f_lfsr_b9[3] = ^(l & 16'h907A);
    f_lfsr_b9[4] = ^(l & 16'hC83D);
    f_lfsr_b9[5] = ^(l & 16'h641E);
    f_lfsr_b9[6] = ^(l & 16'h320F);
    f_lfsr_b9[7] = ^(l & 16'h1907);
  end
endfunction
function [15:0] f_lfsr_m10;
  input [15:0] l;
  begin
    f_lfsr_m10[0] = ^(l & 16'h1907);
    f_lfsr_m10[1] = ^(l & 16'h320F);
    f_lfsr_m10[2] = ^(l & 16'h641E);
    f_lfsr_m10[3] = ^(l & 16'hD13A);
    f_lfsr_m10[4] = ^(l & 16'hBB72);
    f_lfsr_m10[5] = ^(l & 16'h6FE3);
    f_lfsr_m10[6] = ^(l & 16'hDFC6);
    f_lfsr_m10[7] = ^(l & 16'hBF8C);
    f_lfsr_m10[8] = ^(l & 16'h7F19);
    f_lfsr_m10[9] = ^(l & 16'hFE32);
    f_lfsr_m10[10] = ^(l & 16'hFC64);
    f_lfsr_m10[11] = ^(l & 16'hF8C8);
    f_lfsr_m10[12] = ^(l & 16'hF190);
    f_lfsr_m10[13] = ^(l & 16'hE320);
    f_lfsr_m10[14] = ^(l & 16'hC641);
    f_lfsr_m10[15] = ^(l & 16'h8C83);
  end
endfunction
function [7:0] f_lfsr_b10;
  input [15:0] l;
  begin
    f_lfsr_b10[0] = ^(l & 16'h8C83);
    f_lfsr_b10[1] = ^(l & 16'hC641);
    f_lfsr_b10[2] = ^(l & 16'hE320);
    f_lfsr_b10[3] = ^(l & 16'hF190);
    f_lfsr_b10[4] = ^(l & 16'hF8C8);
    f_lfsr_b10[5] = ^(l & 16'hFC64);
    f_lfsr_b10[6] = ^(l & 16'hFE32);
    f_lfsr_b10[7] = ^(l & 16'h7F19);
  end
endfunction
function [15:0] f_lfsr_m11;
  input [15:0] l;
  begin
    f_lfsr_m11[0] = ^(l & 16'h7F19);
    f_lfsr_m11[1] = ^(l & 16'hFE32);
    f_lfsr_m11[2] = ^(l & 16'hFC64);
    f_lfsr_m11[3] = ^(l & 16'h87D1);
    f_lfsr_m11[4] = ^(l & 16'h70BB);
    f_lfsr_m11[5] = ^(l & 16'h9E6F);
    f_lfsr_m11[6] = ^(l & 16'h3CDF);
    f_lfsr_m11[7] = ^(l & 16'h79BF);
    f_lfsr_m11[8] = ^(l & 16'hF37F);
    f_lfsr_m11[9] = ^(l & 16'hE6FE);
    f_lfsr_m11[10] = ^(l & 16'hCDFC);
    f_lfsr_m11[11] = ^(l & 16'h9BF8);
    f_lfsr_m11[12] = ^(l & 16'h37F1);
    f_lfsr_m11[13] = ^(l & 16'h6FE3);
    f_lfsr_m11[14] = ^(l & 16'hDFC6);
    f_lfsr_m11[15] = ^(l & 16'hBF8C);
  end
endfunction
function [7:0] f_lfsr_b11;
  input [15:0] l;
  begin
    f_lfsr_b11[0] = ^(l & 16'hBF8C);
    f_lfsr_b11[1] = ^(l & 16'hDFC6);
    f_lfsr_b11[2] = ^(l & 16'h6FE3);
    f_lfsr_b11[3] = ^(l & 16'h37F1);
    f_lfsr_b11[4] = ^(l & 16'h9BF8);
    f_lfsr_b11[5] = ^(l & 16'hCDFC);
    f_lfsr_b11[6] = ^(l & 16'hE6FE);
    f_lfsr_b11[7] = ^(l & 16'hF37F);
  end
endfunction
function [15:0] f_lfsr_m12;
  input [15:0] l;
  begin
    f_lfsr_m12[0] = ^(l & 16'hF37F);
    f_lfsr_m12[1] = ^(l & 16'hE6FE);
    f_lfsr_m12[2] = ^(l & 16'hCDFC);
    f_lfsr_m12[3] = ^(l & 16'h6887);
    f_lfsr_m12[4] = ^(l & 16'h2270);
    f_lfsr_m12[5] = ^(l & 16'hB79E);
    f_lfsr_m12[6] = ^(l & 16'h6F3C);
    f_lfsr_m12[7] = ^(l & 16'hDE79);
    f_lfsr_m12[8] = ^(l & 16'hBCF3);
    f_lfsr_m12[9] = ^(l & 16'h79E6);
    f_lfsr_m12[10] = ^(l & 16'hF3CD);
    f_lfsr_m12[11] = ^(l & 16'hE79B);
    f_lfsr_m12[12] = ^(l & 16'hCF37);
    f_lfsr_m12[13] = ^(l & 16'h9E6F);
    f_lfsr_m12[14] = ^(l & 16'h3CDF);
    f_lfsr_m12[15] = ^(l & 16'h79BF);
  end
endfunction
function [7:0] f_lfsr_b12;
  input [15:0] l;
  begin
    f_lfsr_b12[0] = ^(l & 16'h79BF);
    f_lfsr_b12[1] = ^(l & 16'h3CDF);
    f_lfsr_b12[2] = ^(l & 16'h9E6F);
    f_lfsr_b12[3] = ^(l & 16'hCF37);
    f_lfsr_b12[4] = ^(l & 16'hE79B);
    f_lfsr_b12[5] = ^(l & 16'hF3CD);
    f_lfsr_b12[6] = ^(l & 16'h79E6);
    f_lfsr_b12[7] = ^(l & 16'hBCF3);
  end
endfunction
function [15:0] f_lfsr_m13;
  input [15:0] l;
  begin
    f_lfsr_m13[0] = ^(l & 16'hBCF3);
    f_lfsr_m13[1] = ^(l & 16'h79E6);
    f_lfsr_m13[2] = ^(l & 16'hF3CD);
    f_lfsr_m13[3] = ^(l & 16'h5B68);
    f_lfsr_m13[4] = ^(l & 16'h0A22);
    f_lfsr_m13[5] = ^(l & 16'hA8B7);
    f_lfsr_m13[6] = ^(l & 16'h516F);
    f_lfsr_m13[7] = ^(l & 16'hA2DE);
    f_lfsr_m13[8] = ^(l & 16'h45BC);
    f_lfsr_m13[9] = ^(l & 16'h8B79);
    f_lfsr_m13[10] = ^(l & 16'h16F3);
    f_lfsr_m13[11] = ^(l & 16'h2DE7);
    f_lfsr_m13[12] = ^(l & 16'h5BCF);
    f_lfsr_m13[13] = ^(l & 16'hB79E);
    f_lfsr_m13[14] = ^(l & 16'h6F3C);
    f_lfsr_m13[15] = ^(l & 16'hDE79);
  end
endfunction
function [7:0] f_lfsr_b13;
  input [15:0] l;
  begin
    f_lfsr_b13[0] = ^(l & 16'hDE79);
    f_lfsr_b13[1] = ^(l & 16'h6F3C);
    f_lfsr_b13[2] = ^(l & 16'hB79E);
    f_lfsr_b13[3] = ^(l & 16'h5BCF);
    f_lfsr_b13[4] = ^(l & 16'h2DE7);
    f_lfsr_b13[5] = ^(l & 16'h16F3);
    f_lfsr_b13[6] = ^(l & 16'h8B79);
    f_lfsr_b13[7] = ^(l & 16'h45BC);
  end
endfunction
function [15:0] f_lfsr_m14;
  input [15:0] l;
  begin
    f_lfsr_m14[0] = ^(l & 16'h45BC);
    f_lfsr_m14[1] = ^(l & 16'h8B79);
    f_lfsr_m14[2] = ^(l & 16'h16F3);
    f_lfsr_m14[3] = ^(l & 16'h685B);
    f_lfsr_m14[4] = ^(l & 16'h950A);
    f_lfsr_m14[5] = ^(l & 16'h6FA8);
    f_lfsr_m14[6] = ^(l & 16'hDF51);
    f_lfsr_m14[7] = ^(l & 16'hBEA2);
    f_lfsr_m14[8] = ^(l & 16'h7D45);
    f_lfsr_m14[9] = ^(l & 16'hFA8B);
    f_lfsr_m14[10] = ^(l & 16'hF516);
    f_lfsr_m14[11] = ^(l & 16'hEA2D);
    f_lfsr_m14[12] = ^(l & 16'hD45B);
    f_lfsr_m14[13] = ^(l & 16'hA8B7);
    f_lfsr_m14[14] = ^(l & 16'h516F);
    f_lfsr_m14[15] = ^(l & 16'hA2DE);
  end
endfunction
function [7:0] f_lfsr_b14;
  input [15:0] l;
  begin
    f_lfsr_b14[0] = ^(l & 16'hA2DE);
    f_lfsr_b14[1] = ^(l & 16'h516F);
    f_lfsr_b14[2] = ^(l & 16'hA8B7);
    f_lfsr_b14[3] = ^(l & 16'hD45B);
    f_lfsr_b14[4] = ^(l & 16'hEA2D);
    f_lfsr_b14[5] = ^(l & 16'hF516);
    f_lfsr_b14[6] = ^(l & 16'hFA8B);
    f_lfsr_b14[7] = ^(l & 16'h7D45);
  end
endfunction
function [15:0] f_lfsr_m15;
  input [15:0] l;
  begin
    f_lfsr_m15[0] = ^(l & 16'h7D45);
    f_lfsr_m15[1] = ^(l & 16'hFA8B);
    f_lfsr_m15[2] = ^(l & 16'hF516);
    f_lfsr_m15[3] = ^(l & 16'h9768);
    f_lfsr_m15[4] = ^(l & 16'h5395);
    f_lfsr_m15[5] = ^(l & 16'hDA6F);
    f_lfsr_m15[6] = ^(l & 16'hB4DF);
    f_lfsr_m15[7] = ^(l & 16'h69BE);
    f_lfsr_m15[8] = ^(l & 16'hD37D);
    f_lfsr_m15[9] = ^(l & 16'hA6FA);
    f_lfsr_m15[10] = ^(l & 16'h4DF5);
    f_lfsr_m15[11] = ^(l & 16'h9BEA);
    f_lfsr_m15[12] = ^(l & 16'h37D4);
    f_lfsr_m15[13] = ^(l & 16'h6FA8);
    f_lfsr_m15[14] = ^(l & 16'hDF51);
    f_lfsr_m15[15] = ^(l & 16'hBEA2);
  end
endfunction
function [7:0] f_lfsr_b15;
  input [15:0] l;
  begin
    f_lfsr_b15[0] = ^(l & 16'hBEA2);
    f_lfsr_b15[1] = ^(l & 16'hDF51);
    f_lfsr_b15[2] = ^(l & 16'h6FA8);
    f_lfsr_b15[3] = ^(l & 16'h37D4);
    f_lfsr_b15[4] = ^(l & 16'h9BEA);
    f_lfsr_b15[5] = ^(l & 16'h4DF5);
    f_lfsr_b15[6] = ^(l & 16'hA6FA);
    f_lfsr_b15[7] = ^(l & 16'hD37D);
  end
endfunction
function [15:0] f_lfsr_m16;
  input [15:0] l;
  begin
    f_lfsr_m16[0] = ^(l & 16'hD37D);
    f_lfsr_m16[1] = ^(l & 16'hA6FA);
    f_lfsr_m16[2] = ^(l & 16'h4DF5);
    f_lfsr_m16[3] = ^(l & 16'h4897);
    f_lfsr_m16[4] = ^(l & 16'h4253);
    f_lfsr_m16[5] = ^(l & 16'h57DA);
    f_lfsr_m16[6] = ^(l & 16'hAFB4);
    f_lfsr_m16[7] = ^(l & 16'h5F69);
    f_lfsr_m16[8] = ^(l & 16'hBED3);
    f_lfsr_m16[9] = ^(l & 16'h7DA6);
    f_lfsr_m16[10] = ^(l & 16'hFB4D);
    f_lfsr_m16[11] = ^(l & 16'hF69B);
    f_lfsr_m16[12] = ^(l & 16'hED37);
    f_lfsr_m16[13] = ^(l & 16'hDA6F);
    f_lfsr_m16[14] = ^(l & 16'hB4DF);
    f_lfsr_m16[15] = ^(l & 16'h69BE);
  end
endfunction
