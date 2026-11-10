# SPDX-License-Identifier: CERN-OHL-P
# Alinx AC7100B on the OCP-TAP Time Card, PCIe x4 pins (syn/top_ac7100b_x4.v; Vivado and openXC7)
# Time Card edge lane -> AC7100B CON4 -> GTP quad 216 channel (Time Card V9 schematic J37,
# AC7100B CON4 table): lane0 ch1 (X0Y5), lane1 ch0 (X0Y4), lane2 ch2 (X0Y6), lane3 ch3 (X0Y7)
set_property PACKAGE_PIN F10 [get_ports {sys_clk_p}]
set_property PACKAGE_PIN E10 [get_ports {sys_clk_n}]
set_property PACKAGE_PIN D11 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN C11 [get_ports {pci_exp_rxn[0]}]
set_property PACKAGE_PIN D5  [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN C5  [get_ports {pci_exp_txn[0]}]
set_property PACKAGE_PIN B8  [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN A8  [get_ports {pci_exp_rxn[1]}]
set_property PACKAGE_PIN B4  [get_ports {pci_exp_txp[1]}]
set_property PACKAGE_PIN A4  [get_ports {pci_exp_txn[1]}]
set_property PACKAGE_PIN B10 [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN A10 [get_ports {pci_exp_rxn[2]}]
set_property PACKAGE_PIN B6  [get_ports {pci_exp_txp[2]}]
set_property PACKAGE_PIN A6  [get_ports {pci_exp_txn[2]}]
set_property PACKAGE_PIN D9  [get_ports {pci_exp_rxp[3]}]
set_property PACKAGE_PIN C9  [get_ports {pci_exp_rxn[3]}]
set_property PACKAGE_PIN D7  [get_ports {pci_exp_txp[3]}]
set_property PACKAGE_PIN C7  [get_ports {pci_exp_txn[3]}]

set_property PACKAGE_PIN J20 [get_ports {sys_rst_n}]
set_property PULLUP true [get_ports {sys_rst_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n}]

set_property PACKAGE_PIN B13 [get_ports {led[0]}]
set_property PACKAGE_PIN C13 [get_ports {led[1]}]
set_property PACKAGE_PIN D14 [get_ports {led[2]}]
set_property PACKAGE_PIN D15 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

