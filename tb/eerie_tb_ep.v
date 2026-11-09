// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie testbench endpoint: pcie_7x (with either PCIE_2_1 or pci_eerie inside
// pcie_block) plus the memory application (eerie_tb_app) on the AXI-stream interface.
`timescale 1ns / 1ps
module eerie_tb_ep #(
    parameter ENABLE_GEN2 = 0,
    parameter GT_DEVICE   = "GTX"
) (
    output pci_exp_txp, output pci_exp_txn,
    input  pci_exp_rxp, input  pci_exp_rxn,
    input  sys_clk_p,   input  sys_clk_n,
    input  sys_rst_n
);
    wire sys_clk;
    IBUFDS_GTE2 refclk_ibuf (.O(sys_clk), .ODIV2(), .I(sys_clk_p), .CEB(1'b0), .IB(sys_clk_n));

    wire        user_clk, user_reset, user_lnk_up;
    wire        s_axis_tx_tready;
    wire [63:0] s_axis_tx_tdata;
    wire [7:0]  s_axis_tx_tkeep;
    wire        s_axis_tx_tlast, s_axis_tx_tvalid;
    wire [63:0] m_axis_rx_tdata;
    wire [7:0]  m_axis_rx_tkeep;
    wire        m_axis_rx_tlast, m_axis_rx_tvalid;
    wire [21:0] m_axis_rx_tuser;
    wire [7:0]  cfg_bus_number;
    wire [4:0]  cfg_device_number;
    wire [2:0]  cfg_function_number;
    wire        cfg_to_turnoff, cfg_interrupt_rdy, cfg_interrupt_msienable;
    wire        cfg_interrupt, cfg_interrupt_assert;

    pcie_7x #(
        .PCIE_GT_DEVICE(GT_DEVICE), .PCIE_USE_MODE("3.0"),
        .LINK_CAP_MAX_LINK_SPEED(ENABLE_GEN2 ? 4'h2 : 4'h1), .LINK_CTRL2_TARGET_LINK_SPEED(ENABLE_GEN2 ? 4'h2 : 4'h1),
        .LINK_STATUS_SLOT_CLOCK_CONFIG("TRUE"), .USER_CLK_FREQ(ENABLE_GEN2 ? 2 : 1),
        .CFG_DEV_ID(16'h9999), .BAR0(32'hFFFFF000),
        .DEV_CAP_MAX_PAYLOAD_SUPPORTED(1), .VC0_RX_RAM_LIMIT(13'h3FF),
        .VC0_TOTAL_CREDITS_CD(370), .VC0_TOTAL_CREDITS_CH(72), .VC0_TOTAL_CREDITS_NPH(4),
        .VC0_TOTAL_CREDITS_NPD(8), .VC0_TOTAL_CREDITS_PD(32), .VC0_TOTAL_CREDITS_PH(4), .VC0_TX_LASTPACKET(28)
    ) pcie_7x_i (
        .pci_exp_txn(pci_exp_txn), .pci_exp_txp(pci_exp_txp), .pci_exp_rxn(pci_exp_rxn), .pci_exp_rxp(pci_exp_rxp),
        .pipe_mmcm_lock(), .pipe_mmcm_rst_n(1'b1),
        .user_clk_out(user_clk), .user_reset_out(user_reset), .user_lnk_up(user_lnk_up),
        .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tuser(4'd0), .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tvalid(m_axis_rx_tvalid), .m_axis_rx_tready(1'b1), .m_axis_rx_tuser(m_axis_rx_tuser),
        .tx_cfg_gnt(1'b1), .rx_np_ok(1'b1), .rx_np_req(1'b1), .cfg_trn_pending(1'b0),
        .cfg_pm_halt_aspm_l0s(1'b0), .cfg_pm_halt_aspm_l1(1'b0), .cfg_pm_force_state_en(1'b0),
        .cfg_pm_force_state(2'b00), .cfg_dsn(64'h0000000101000a35), .cfg_turnoff_ok(cfg_to_turnoff), .cfg_pm_wake(1'b0),
        .cfg_interrupt(cfg_interrupt), .cfg_interrupt_rdy(cfg_interrupt_rdy), .cfg_interrupt_assert(cfg_interrupt_assert),
        .cfg_interrupt_di(8'h00), .cfg_interrupt_do(), .cfg_interrupt_mmenable(),
        .cfg_interrupt_msienable(cfg_interrupt_msienable), .cfg_interrupt_msixenable(), .cfg_interrupt_msixfm(),
        .cfg_interrupt_stat(1'b0), .cfg_pciecap_interrupt_msgnum(5'd0),
        .cfg_status(), .cfg_command(), .cfg_dstatus(), .cfg_lstatus(), .cfg_pcie_link_state(), .cfg_dcommand(),
        .cfg_lcommand(), .cfg_dcommand2(), .cfg_pmcsr_pme_en(), .cfg_pmcsr_powerstate(), .cfg_pmcsr_pme_status(),
        .cfg_received_func_lvl_rst(), .tx_buf_av(), .tx_err_drop(), .tx_cfg_req(), .cfg_to_turnoff(cfg_to_turnoff),
        .cfg_bus_number(cfg_bus_number), .cfg_device_number(cfg_device_number), .cfg_function_number(cfg_function_number),
        .sys_clk(sys_clk), .sys_rst_n(sys_rst_n), .gt_reset_fsm(), .pl_ltssm_state(),
        .pipe_pclk_in(1'b0), .pipe_dclk_in(1'b0), .pipe_oobclk_in(1'b0), .pipe_userclk1_in(1'b0),
        .pipe_userclk2_in(1'b0), .pipe_mmcm_lock_in(1'b0), .pipe_rxusrclk_in(1'b0), .pipe_rxoutclk_in(1'b0),
        .pipe_pclk_sel_out(), .pipe_txoutclk_out()
    );


    eerie_tb_app app (
        .user_clk(user_clk), .user_reset(user_reset),
        .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep),
        .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .cfg_bus_number(cfg_bus_number), .cfg_device_number(cfg_device_number), .cfg_function_number(cfg_function_number),
        .cfg_interrupt_rdy(cfg_interrupt_rdy), .cfg_interrupt(cfg_interrupt), .cfg_interrupt_assert(cfg_interrupt_assert)
    );
endmodule
