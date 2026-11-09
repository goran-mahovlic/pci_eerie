// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie additional tests (included by tb/pci_exp_usrapp_tx.v, after the stock tests)
`include "sample_tests1.vh"

// ---------------------------------------------------------------------------
// dump the configuration space (diff the output of baseline vs eerie runs)
// ---------------------------------------------------------------------------
else if (testname == "eerie_cfg_dump")
begin : t_cfg_dump
    integer a;
    TSK_SIMULATION_TIMEOUT(10050);
    TSK_SYSTEM_INITIALIZATION;
    for (a = 0; a < 12'h10C; a = (a == 12'h090) ? 12'h100 : a + 4) begin
        TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, a[11:0], 4'hF);
        DEFAULT_TAG = DEFAULT_TAG + 1;
        TSK_WAIT_FOR_READ_DATA;
        $display("CFGDUMP %03x = %08x", a, P_READ_DATA);
    end
    $display("Test Completed Successfully");
    $finish;
end

// ---------------------------------------------------------------------------
// root port's own configuration space through cfg_mgmt: reset value, bits that read
// back 1 after writing all-ones, and bits that read back 1 after writing all-zeros
// (diff the output of the PCIE_2_1 and pci_eerie root ports). Bits that would take the
// link down are not written: Secondary Bus Reset, Link Disable/Retrain, PM power state.
// ---------------------------------------------------------------------------
else if (testname == "rp_cfg_dump")
begin : t_rp_cfg_dump
    integer a;
    reg [31:0] v0, v1, v2, keep;
    TSK_SIMULATION_TIMEOUT(10050);
    TSK_SYSTEM_INITIALIZATION;
    for (a = 0; a < 12'h130; a = (a == 12'h0FC) ? 12'h100 : a + 4) begin
        keep = (a == 12'h03C) ? 32'h0040_0000 :          // bridge control: Secondary Bus Reset
               (a == 12'h044) ? 32'h0000_0003 :          // PMCSR: power state
               (a == 12'h070) ? 32'h0000_0030 : 32'd0;   // link control: disable, retrain
        board.RP.cfg_usrapp.TSK_READ_CFG_DW(a >> 2);  v0 = board.RP.cfg_usrapp.cfg_do;
        board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(a >> 2, ~keep | (v0 & keep), 4'b0000);
        board.RP.cfg_usrapp.TSK_READ_CFG_DW(a >> 2);  v1 = board.RP.cfg_usrapp.cfg_do;
        board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(a >> 2, v0 & keep, 4'b0000);
        board.RP.cfg_usrapp.TSK_READ_CFG_DW(a >> 2);  v2 = board.RP.cfg_usrapp.cfg_do;
        board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(a >> 2, v0, 4'b0000);
        $display("RPCFG %03x = %08x w1 %08x w0 %08x", a, v0, v1, v2);
    end
    $display("Test Completed Successfully");
    $finish;
end

// ---------------------------------------------------------------------------
// root port link control through cfg_mgmt: Retrain Link, Secondary Bus Reset (hot reset),
// Link Disable; after each the endpoint must answer again (after the hot reset and the link
// disable it has been reset, link down, and is re-enumerated). Works with either root port core.
// ---------------------------------------------------------------------------
else if (testname == "rp_link_test")
begin : t_rp_link
    integer fails, n, step;
    reg [31:0] v, base;
    reg left_l0, saw;
    fails = 0;
    TSK_SIMULATION_TIMEOUT(40050);
    TSK_SYSTEM_INITIALIZATION;
    TSK_BAR_INIT;
    base = BAR_INIT_P_BAR[0][31:0];
    for (step = 0; step < 3; step = step + 1) begin
        board.RP.cfg_usrapp.TSK_READ_CFG_DW(12'h070 >> 2); v = board.RP.cfg_usrapp.cfg_do;
        if (step == 0) begin
            $display("[%t] : rp_link_test: Retrain Link", $realtime);
            board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(12'h070 >> 2, v | 32'h20, 4'b0000);
        end else if (step == 1) begin
            $display("[%t] : rp_link_test: Secondary Bus Reset", $realtime);
            board.RP.cfg_usrapp.TSK_READ_CFG_DW(12'h03C >> 2); v = board.RP.cfg_usrapp.cfg_do;
            board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(12'h03C >> 2, v | 32'h0040_0000, 4'b0000);
        end else begin
            $display("[%t] : rp_link_test: Link Disable", $realtime);
            board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(12'h070 >> 2, v | 32'h10, 4'b0000);
        end
        // the link must leave L0 (and for hot reset / disable, the data link must go down)
        left_l0 = 0; saw = 0;
        for (n = 0; n < 200000 && !(left_l0 && (step == 0 || saw)); n = n + 1) begin
            @(posedge board.RP.trn_clk);
            if (board.RP.pl_ltssm_state != 6'h16) left_l0 = 1;
            if (!board.RP.trn_lnk_up) saw = 1;
            if (step == 1 && board.RP.pl_ltssm_state == 6'h21) saw = 1;
            if (step == 2 && board.RP.pl_ltssm_state == 6'h22) saw = 1;
        end
        $display("[%t] : rp_link_test: step %0d left L0 %0d, link down / state seen %0d, LTSSM %h", $realtime,
                 step, left_l0, saw, board.RP.pl_ltssm_state);
        if (!left_l0 || (step != 0 && !saw)) fails = fails + 1;
        if (step == 1) begin
            TSK_TX_CLK_EAT(2000);
            board.RP.cfg_usrapp.TSK_READ_CFG_DW(12'h03C >> 2); v = board.RP.cfg_usrapp.cfg_do;
            board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(12'h03C >> 2, v & ~32'h0040_0000, 4'b0000);
        end
        if (step == 2) begin
            TSK_TX_CLK_EAT(2000);
            board.RP.cfg_usrapp.TSK_READ_CFG_DW(12'h070 >> 2); v = board.RP.cfg_usrapp.cfg_do;
            board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(12'h070 >> 2, v & ~32'h10, 4'b0000);
        end
        // back to L0 with the data link up
        for (n = 0; n < 400000 && !(board.RP.trn_lnk_up && board.RP.pl_ltssm_state == 6'h16); n = n + 1)
            @(posedge board.RP.trn_clk);
        TSK_TX_CLK_EAT(500);
        if (!board.RP.trn_lnk_up) begin
            $display("[%t] : rp_link_test FAILED step %0d: link did not come back", $realtime, step);
            fails = fails + 1;
        end
        // the endpoint answers; after hot reset / link disable its BARs and Command register were reset
        TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h004, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
        TSK_WAIT_FOR_READ_DATA;
        $display("[%t] : rp_link_test: step %0d EP command/status %h", $realtime, step, P_READ_DATA);
        if ((step != 0) != (P_READ_DATA[2:0] == 3'b000)) begin
            $display("[%t] : rp_link_test FAILED step %0d: unexpected EP command %h", $realtime, step, P_READ_DATA);
            fails = fails + 1;
        end
        if (step != 0) begin
            // re-enumerate: BAR0 and Command again (TSK_BAR_INIT cannot be run twice)
            TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h010, base, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
            TSK_TX_CLK_EAT(200);
            TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h004, 32'h0000_0007, 4'h1); DEFAULT_TAG = DEFAULT_TAG + 1;
            TSK_TX_CLK_EAT(200);
        end
        DATA_STORE[0] = step; DATA_STORE[1] = 8'h5a; DATA_STORE[2] = 8'hc3; DATA_STORE[3] = 8'h3c;
        TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'h10, 4'h0, 4'hF, 1'b0); DEFAULT_TAG = DEFAULT_TAG + 1;
        TSK_TX_CLK_EAT(100);
        P_READ_DATA = 32'hFFFF_FFFF;
        fork
            TSK_TX_MEMORY_READ_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'h10, 4'h0, 4'hF);
            TSK_WAIT_FOR_READ_DATA;
        join
        DEFAULT_TAG = DEFAULT_TAG + 1;
        if (P_READ_DATA !== {DATA_STORE[3], DATA_STORE[2], DATA_STORE[1], DATA_STORE[0]} &&
            P_READ_DATA !== {DATA_STORE[0], DATA_STORE[1], DATA_STORE[2], DATA_STORE[3]}) begin
            $display("[%t] : rp_link_test FAILED step %0d: memory read back %h", $realtime, step, P_READ_DATA);
            fails = fails + 1;
        end else $display("[%t] : rp_link_test: step %0d memory access ok", $realtime, step);
    end
    if (fails == 0) $display("[%t] : rp_link_test PASSED", $realtime);
    if (fails == 0) $display("Test Completed Successfully");
    else $display("[%t] : TEST FAILED (%0d errors)", $realtime, fails);
    $finish;
end

// ---------------------------------------------------------------------------
// multi-lane (EP_LANES / RP_LANES): both sides report the expected link width and the same
// speed, then MWr/MRd of 1..32 DW through the memory application (all packet lengths mod 4)
// ---------------------------------------------------------------------------
else if (testname == "ml_width_test")
begin : t_ml_width
    integer li, j, k, len, fails, exp_w;
    reg [31:0] base, off, exp, rp_ls, ep_ls;
    reg found;
    integer lens [0:7];
    lens[0] = 1; lens[1] = 2; lens[2] = 3; lens[3] = 4; lens[4] = 5; lens[5] = 7; lens[6] = 16; lens[7] = 32;
    fails = 0;
`ifdef EP_LANES
    exp_w = (`EP_LANES < `RP_LANES) ? `EP_LANES : `RP_LANES;
`else
    exp_w = 1;
`endif
    if ($value$plusargs("ml_expw=%d", k)) exp_w = k;     // e.g. an x8 pci_eerie build trains to x4
    TSK_SIMULATION_TIMEOUT(20050);
    TSK_SYSTEM_INITIALIZATION;
    board.RP.cfg_usrapp.TSK_READ_CFG_DW(12'h070 >> 2); rp_ls = board.RP.cfg_usrapp.cfg_do;
    TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h070, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_WAIT_FOR_READ_DATA; ep_ls = P_READ_DATA;
    $display("[%t] : ml_width_test: RP link status %h (x%0d, speed %0d), EP link status %h (x%0d, speed %0d), expected x%0d",
             $realtime, rp_ls[31:16], rp_ls[25:20], rp_ls[19:16], ep_ls[31:16], ep_ls[25:20], ep_ls[19:16], exp_w);
    if (rp_ls[25:20] != exp_w || ep_ls[25:20] != exp_w || rp_ls[19:16] != ep_ls[19:16]) begin
        $display("[%t] : ml_width_test FAILED: link width / speed", $realtime); fails = fails + 1;
    end
    TSK_BAR_INIT;
    base = BAR_INIT_P_BAR[0][31:0];
    if (!$value$plusargs("ml_first=%d", k)) k = 0;      // +ml_first=N: start with lens[N]
    for (li = k; li < 8; li = li + 1) begin
        len = lens[li];
        off = li * 32'h80;
        for (j = 0; j < len * 4; j = j + 1) DATA_STORE[j] = (li * 8'h29 + j * 8'h0b + 8'h33) & 8'hff;
        TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, len[9:0], base + off, (len == 1) ? 4'h0 : 4'hF, 4'hF, 1'b0);
        DEFAULT_TAG = DEFAULT_TAG + 1;
        TSK_TX_CLK_EAT(10);
        fork
            TSK_TX_MEMORY_READ_32(DEFAULT_TAG, 3'd0, len[9:0], base + off, (len == 1) ? 4'h0 : 4'hF, 4'hF);
            rp_mon.wait_tlp(5'b01010, 5'b11111, 20000, found);
        join
        DEFAULT_TAG = DEFAULT_TAG + 1;
        if (!found) begin
            $display("[%t] : ml_width_test FAILED len %0d: no completion", $realtime, len); fails = fails + 1;
        end else begin
            for (k = 0; k < len; k = k + 1) begin
                exp = {DATA_STORE[4*k], DATA_STORE[4*k+1], DATA_STORE[4*k+2], DATA_STORE[4*k+3]};
                if (rp_mon.last[3 + k] !== exp) begin
                    $display("[%t] : ml_width_test FAILED len %0d DW %0d: %h != %h", $realtime, len, k,
                             rp_mon.last[3 + k], exp);
                    fails = fails + 1;
                end
            end
        end
    end
    if (fails == 0) $display("[%t] : ml_width_test PASSED", $realtime);
    if (fails == 0) $display("Test Completed Successfully");
    else $display("[%t] : TEST FAILED (%0d errors)", $realtime, fails);
    $finish;
end

// ---------------------------------------------------------------------------
// memory write / read-back with various lengths (needs +define EERIE_APP)
// ---------------------------------------------------------------------------
else if (testname == "eerie_mem_test")
begin : t_mem
    integer li, j, k, len, fails, nbytes;
    reg [31:0] base, off, exp;
    reg found;
    integer lens [0:11];
    lens[0] = 1; lens[1] = 2; lens[2] = 3; lens[3] = 4; lens[4] = 5; lens[5] = 7;
    lens[6] = 8; lens[7] = 15; lens[8] = 16; lens[9] = 17; lens[10] = 31; lens[11] = 32;
    fails = 0;
    TSK_SIMULATION_TIMEOUT(20050);
    TSK_SYSTEM_INITIALIZATION;
    TSK_BAR_INIT;
    base = BAR_INIT_P_BAR[0][31:0];
    for (li = 0; li < 12; li = li + 1) begin
        len = lens[li];
        off = li * 32'h80;
        for (j = 0; j < len * 4; j = j + 1) DATA_STORE[j] = (li * 8'h31 + j * 8'h07 + 8'h5a) & 8'hff;
        TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, len[9:0], base + off, (len == 1) ? 4'h0 : 4'hF, 4'hF, 1'b0);
        DEFAULT_TAG = DEFAULT_TAG + 1;
        TSK_TX_CLK_EAT(10);
        fork
            TSK_TX_MEMORY_READ_32(DEFAULT_TAG, 3'd0, len[9:0], base + off, (len == 1) ? 4'h0 : 4'hF, 4'hF);
            rp_mon.wait_tlp(5'b01010, 5'b11111, 20000, found);
        join
        DEFAULT_TAG = DEFAULT_TAG + 1;
        if (!found) begin
            $display("[%t] : eerie_mem_test FAILED len %0d: no completion", $realtime, len); fails = fails + 1;
        end else begin
            if (rp_mon.last[0][9:0] != len[9:0] || rp_mon.last[1][11:0] != len * 4 || rp_mon.last_n != 3 + len) begin
                $display("[%t] : eerie_mem_test FAILED len %0d: bad CplD header %h %h %h (%0d DW)", $realtime, len,
                         rp_mon.last[0], rp_mon.last[1], rp_mon.last[2], rp_mon.last_n);
                fails = fails + 1;
            end
            for (k = 0; k < len; k = k + 1) begin
                exp = {DATA_STORE[4*k], DATA_STORE[4*k+1], DATA_STORE[4*k+2], DATA_STORE[4*k+3]};
                if (rp_mon.last[3 + k] !== exp) begin
                    $display("[%t] : eerie_mem_test FAILED len %0d DW %0d: %h != %h", $realtime, len, k,
                             rp_mon.last[3 + k], exp);
                    fails = fails + 1;
                end
            end
            $display("[%t] : eerie_mem_test len %0d checked", $realtime, len);
        end
    end
    // back-to-back writes then reads (several outstanding non-posted requests)
    for (li = 0; li < 8; li = li + 1) begin
        for (j = 0; j < 16; j = j + 1) DATA_STORE[j] = (li * 16 + j) & 8'hff;
        TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd4, base + 32'h800 + li * 16, 4'hF, 4'hF, 1'b0);
        DEFAULT_TAG = DEFAULT_TAG + 1;
    end
    for (li = 0; li < 8; li = li + 1) begin
        fork
            TSK_TX_MEMORY_READ_32(DEFAULT_TAG, 3'd0, 10'd4, base + 32'h800 + li * 16, 4'hF, 4'hF);
            rp_mon.wait_tlp(5'b01010, 5'b11111, 20000, found);
        join
        DEFAULT_TAG = DEFAULT_TAG + 1;
        exp = {li[3:0], 4'h0, li[3:0], 4'h1, li[3:0], 4'h2, li[3:0], 4'h3};
        if (!found || rp_mon.last[3] !== exp) begin
            $display("[%t] : eerie_mem_test FAILED b2b %0d: %h != %h", $realtime, li, rp_mon.last[3], exp);
            fails = fails + 1;
        end
    end
    if (fails == 0) $display("[%t] : eerie_mem_test PASSED", $realtime);
    if (fails == 0) $display("Test Completed Successfully");
    else $display("[%t] : TEST FAILED (%0d errors)", $realtime, fails);
    $finish;
end

// ---------------------------------------------------------------------------
// MSI and legacy INTx (needs +define EERIE_APP)
// ---------------------------------------------------------------------------
else if (testname == "eerie_int_test")
begin : t_int
    integer fails;
    reg [31:0] base;
    reg found;
    fails = 0;
    TSK_SIMULATION_TIMEOUT(20050);
    TSK_SYSTEM_INITIALIZATION;
    TSK_BAR_INIT;
    base = BAR_INIT_P_BAR[0][31:0];
    // let the root port forward upstream requests (its own Bus Master Enable)
    board.RP.cfg_usrapp.TSK_WRITE_CFG_DW(32'h00000001, 32'h00000007, 4'b1110);
    // MSI capability at 0x48 (64-bit capable): address 0x4C/0x50, data 0x54
    TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h04C, 32'hFEE0_0000, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(200);
    TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h050, 32'h0000_0000, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(200);
    TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h054, 32'h0000_1234, 4'h3); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(200);
    TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h048, 32'h0001_0000, 4'h4); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(200);
    TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h004, 32'h0000_0007, 4'h1); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(200);
    TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h048, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_WAIT_FOR_READ_DATA;
    $display("[%t] : MSI control = %h", $realtime, P_READ_DATA);
    DATA_STORE[0] = 8'h01; DATA_STORE[1] = 8'h00; DATA_STORE[2] = 8'h00; DATA_STORE[3] = 8'h00;
    fork
        TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'hFF0, 4'h0, 4'hF, 1'b0);
        rp_mon.wait_tlp(5'b00000, 5'b11111, 20000, found);
    join
    DEFAULT_TAG = DEFAULT_TAG + 1;
    if (!found || rp_mon.last[0][31:29] != 3'b010 || rp_mon.last[2] != 32'hFEE0_0000 || rp_mon.last[3] != 32'h3412_0000) begin
        $display("[%t] : eerie_int_test FAILED MSI: %h %h %h %h", $realtime, rp_mon.last[0], rp_mon.last[1],
                 rp_mon.last[2], rp_mon.last[3]);
        fails = fails + 1;
    end else $display("[%t] : MSI write received: addr %h data %h", $realtime, rp_mon.last[2], rp_mon.last[3]);
    // legacy INTx (the root port reports the messages on its cfg_msg_received_* outputs)
    TSK_TX_TYPE0_CONFIGURATION_WRITE(DEFAULT_TAG, 12'h048, 32'h0000_0000, 4'h4); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(200);
    TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'hFF0, 4'h0, 4'hF, 1'b0);
    DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(1000);
    if (rp_mon.inta_assert != 1) begin
        $display("[%t] : eerie_int_test FAILED Assert_INTA count %0d", $realtime, rp_mon.inta_assert);
        fails = fails + 1;
    end else $display("[%t] : Assert_INTA received", $realtime);
    TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h004, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_WAIT_FOR_READ_DATA;
    if (!P_READ_DATA[19]) begin
        $display("[%t] : eerie_int_test FAILED interrupt status bit not set (%h)", $realtime, P_READ_DATA);
        fails = fails + 1;
    end else $display("[%t] : Interrupt Status bit set", $realtime);
    DATA_STORE[0] = 8'h00;
    TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'hFF0, 4'h0, 4'hF, 1'b0);
    DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(1000);
    if (rp_mon.inta_deassert != 1) begin
        $display("[%t] : eerie_int_test FAILED Deassert_INTA count %0d", $realtime, rp_mon.inta_deassert);
        fails = fails + 1;
    end else $display("[%t] : Deassert_INTA received", $realtime);
    if (fails == 0) $display("[%t] : eerie_int_test PASSED", $realtime);
    if (fails == 0) $display("Test Completed Successfully");
    else $display("[%t] : TEST FAILED (%0d errors)", $realtime, fails);
    $finish;
end

// ---------------------------------------------------------------------------
// unsupported requests, messages
// ---------------------------------------------------------------------------
else if (testname == "eerie_ur_test")
begin : t_ur
    integer fails;
    reg [31:0] base;
    reg found;
    fails = 0;
    TSK_SIMULATION_TIMEOUT(20050);
    TSK_SYSTEM_INITIALIZATION;
    TSK_BAR_INIT;
    base = BAR_INIT_P_BAR[0][31:0];
    // memory read outside of any BAR -> UR completion
    fork
        TSK_TX_MEMORY_READ_32(DEFAULT_TAG, 3'd0, 10'd2, base + 32'h0010_0000, 4'hF, 4'hF);
        rp_mon.wait_tlp(5'b01010, 5'b11111, 20000, found);
    join
    DEFAULT_TAG = DEFAULT_TAG + 1;
    if (!found || rp_mon.last[1][15:13] != 3'b001 || rp_mon.last[0][30]) begin
        $display("[%t] : eerie_ur_test FAILED MRd UR: %h %h %h", $realtime, rp_mon.last[0], rp_mon.last[1], rp_mon.last[2]);
        fails = fails + 1;
    end else $display("[%t] : UR completion for unmapped MRd: %h %h %h", $realtime, rp_mon.last[0], rp_mon.last[1], rp_mon.last[2]);
    // (a type 1 configuration read would also get UR, but the root port model's TX
    //  logger aborts the simulation on CfgRd1 frames, so it is not exercised here)
    // IO read without an IO BAR -> UR
    fork
        TSK_TX_IO_READ(DEFAULT_TAG, 32'h0000_1000, 4'hF);
        rp_mon.wait_tlp(5'b01010, 5'b11111, 20000, found);
    join
    DEFAULT_TAG = DEFAULT_TAG + 1;
    if (!found || rp_mon.last[1][15:13] != 3'b001) begin
        $display("[%t] : eerie_ur_test FAILED IORd UR: %h %h", $realtime, rp_mon.last[0], rp_mon.last[1]);
        fails = fails + 1;
    end else $display("[%t] : UR completion for IORd", $realtime);
    // posted write to nowhere is dropped; Set_Slot_Power_Limit and an Unlock message are absorbed
    DATA_STORE[0] = 8'h11; DATA_STORE[1] = 8'h22; DATA_STORE[2] = 8'h33; DATA_STORE[3] = 8'h44;
    TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'h0010_0000, 4'h0, 4'hF, 1'b0);
    DEFAULT_TAG = DEFAULT_TAG + 1;
    DATA_STORE[0] = 8'h19; DATA_STORE[1] = 8'h02; DATA_STORE[2] = 8'h00; DATA_STORE[3] = 8'h00;
    TSK_TX_MESSAGE_DATA(DEFAULT_TAG, 3'd0, 11'd1, 64'h0, 3'b100, 8'h50);
    DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_MESSAGE(DEFAULT_TAG, 3'd0, 11'd0, 64'h0, 3'b011, 8'h00);
    DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_TX_CLK_EAT(500);
    TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h064, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_WAIT_FOR_READ_DATA;
    $display("[%t] : Device Capabilities after Set_Slot_Power_Limit = %h", $realtime, P_READ_DATA);
    if (P_READ_DATA[27:18] != 10'h219) begin
        $display("[%t] : eerie_ur_test FAILED slot power not captured", $realtime); fails = fails + 1;
    end
    // device status: UR detected must be set
    TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h068, 4'hF); DEFAULT_TAG = DEFAULT_TAG + 1;
    TSK_WAIT_FOR_READ_DATA;
    $display("[%t] : Device Control/Status = %h", $realtime, P_READ_DATA);
    if (!P_READ_DATA[19]) begin
        $display("[%t] : eerie_ur_test FAILED UR detected bit not set", $realtime); fails = fails + 1;
    end
    // the device must still work
    board.RP.tx_usrapp.P_READ_DATA = 32'hffff_ffff;
    fork
        TSK_TX_TYPE0_CONFIGURATION_READ(DEFAULT_TAG, 12'h000, 4'hF);
        TSK_WAIT_FOR_READ_DATA;
    join
    DEFAULT_TAG = DEFAULT_TAG + 1;
    if (P_READ_DATA != 32'h999910ee) begin
        $display("[%t] : eerie_ur_test FAILED device dead after URs (%h)", $realtime, P_READ_DATA); fails = fails + 1;
    end
    if (fails == 0) $display("[%t] : eerie_ur_test PASSED", $realtime);
    if (fails == 0) $display("Test Completed Successfully");
    else $display("[%t] : TEST FAILED (%0d errors)", $realtime, fails);
    $finish;
end

// ---------------------------------------------------------------------------
// many single-DW transactions through the user design (works with the
// default pcie_7x_top_aximm application); combine with +inject_rx_tlp / +inject_tx_tlp
// ---------------------------------------------------------------------------
else if (testname == "eerie_stress_test")
begin : t_stress
    integer i, fails, n;
    reg [31:0] base, v;
    fails = 0;
    if (!$value$plusargs("stress_n=%d", n)) n = 40;
    TSK_SIMULATION_TIMEOUT(50050);
    TSK_SYSTEM_INITIALIZATION;
    TSK_BAR_INIT;
    base = BAR_INIT_P_BAR[0][31:0];
    for (i = 0; i < n; i = i + 1) begin
        v = 32'h1000_0000 * (i % 16) + i * 32'h0001_0203;
        DATA_STORE[0] = v[7:0]; DATA_STORE[1] = v[15:8]; DATA_STORE[2] = v[23:16]; DATA_STORE[3] = v[31:24];
        TSK_TX_MEMORY_WRITE_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'h10, 4'h0, 4'hF, 1'b0);
        DEFAULT_TAG = DEFAULT_TAG + 1;
        P_READ_DATA = 32'hffff_ffff;
        fork
            TSK_TX_MEMORY_READ_32(DEFAULT_TAG, 3'd0, 10'd1, base + 32'h10, 4'h0, 4'hF);
            TSK_WAIT_FOR_READ_DATA;
        join
        DEFAULT_TAG = DEFAULT_TAG + 1;
        if (P_READ_DATA != {DATA_STORE[3], DATA_STORE[2], DATA_STORE[1], DATA_STORE[0]}) begin
            $display("[%t] : eerie_stress_test FAILED iteration %0d: %h != %h", $realtime, i, P_READ_DATA,
                     {DATA_STORE[3], DATA_STORE[2], DATA_STORE[1], DATA_STORE[0]});
            fails = fails + 1;
        end
    end
    if (fails == 0) $display("[%t] : eerie_stress_test PASSED (%0d iterations)", $realtime, n);
    if (fails == 0) $display("Test Completed Successfully");
    else $display("[%t] : TEST FAILED (%0d errors)", $realtime, fails);
    $finish;
end
