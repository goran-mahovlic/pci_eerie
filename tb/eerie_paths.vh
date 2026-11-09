// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie testbench: hierarchical paths into the endpoint
//   EP_PIPE: scope with the endpoint's GT-side PIPE wires (pipe_rx0_data_gt, ...), pipe_clk,
//            pl_ltssm_state, phy_rdy_n
//   EP_BLK:  the PCIE_2_1 / pci_eerie instance
`ifndef EERIE_PATHS_VH
`define EERIE_PATHS_VH
`ifdef EP_ML
`define EP_PIPE board.EP.core
`define EP_BLK  board.EP.core.pcie_top_i.pcie_7x_i.pcie_block_i
`else
`define EP_PIPE board.EP.pcie_7x_i.pcie_block_inst
`define EP_BLK  board.EP.pcie_7x_i.pcie_block_inst.pcie_2_1_block
`endif
`endif
