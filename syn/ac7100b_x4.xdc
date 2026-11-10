# SPDX-License-Identifier: CERN-OHL-P
# Alinx AC7100B on the OCP-TAP Time Card, PCIe x4 (syn/top_ac7100b_x4.v, Vivado 7-series core)
# Time Card edge lane -> AC7100B CON4 -> GTP quad 216 channel (Time Card V9 schematic J37,
# AC7100B CON4 table): lane0 ch1 (X0Y5), lane1 ch0 (X0Y4), lane2 ch2 (X0Y6), lane3 ch3 (X0Y7)
set_property PACKAGE_PIN F10 [get_ports {sys_clk_p}]
set_property PACKAGE_PIN E10 [get_ports {sys_clk_n}]
set_property PACKAGE_PIN D11 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN D5  [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN B8  [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN B4  [get_ports {pci_exp_txp[1]}]
set_property PACKAGE_PIN B10 [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN B6  [get_ports {pci_exp_txp[2]}]
set_property PACKAGE_PIN D9  [get_ports {pci_exp_rxp[3]}]
set_property PACKAGE_PIN D7  [get_ports {pci_exp_txp[3]}]

set_property PACKAGE_PIN J20 [get_ports {sys_rst_n}]
set_property PULLUP true [get_ports {sys_rst_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst_n}]
set_false_path -from [get_ports sys_rst_n]

set_property PACKAGE_PIN B13 [get_ports {led[0]}]
set_property PACKAGE_PIN C13 [get_ports {led[1]}]
set_property PACKAGE_PIN D14 [get_ports {led[2]}]
set_property PACKAGE_PIN D15 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

create_clock -name sys_clk -period 10.000 [get_ports sys_clk_p]
# the PIPE clock MMCM is fed from lane 0's TXOUTCLK
create_clock -name txoutclk -period 10.000 [get_pins -hier -filter {NAME =~ *pipe_lane[0]*gtpe2_channel_i/TXOUTCLK}]
# PIPE clock mux (BUFGCTRL): 125 MHz (2.5 GT/s) and 250 MHz (5.0 GT/s) are exclusive
set mmcm  [get_cells -hier -filter {REF_NAME == MMCME2_ADV}]
set mux_o [get_pins -hier -filter {NAME =~ *pclk_i1_bufgctrl.pclk_i1/O}]
create_generated_clock -name clk_125mhz_mux -source [get_pins $mmcm/CLKOUT0] -divide_by 1 -add \
    -master_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT0]] $mux_o
create_generated_clock -name clk_250mhz_mux -source [get_pins $mmcm/CLKOUT1] -divide_by 1 -add \
    -master_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT1]] $mux_o
set_clock_groups -name pclk_mux -physically_exclusive -group clk_125mhz_mux -group clk_250mhz_mux

# pci_eerie crossings between the PIPE clock and the user clock use gray-coded FIFO pointers
# and 2-flop synchronizers: constrain them as datapath-only paths
set uclk [get_clocks -of_objects [get_pins $mmcm/CLKOUT2]]
set_max_delay -datapath_only -from [get_clocks {clk_125mhz_mux clk_250mhz_mux}] -to $uclk 4.000
set_max_delay -datapath_only -from $uclk -to [get_clocks {clk_125mhz_mux clk_250mhz_mux}] 4.000
# the FIFO storage is read asynchronously only after its write pointer was synchronized
set_false_path -from [get_cells -hier -filter {NAME =~ *pcie_block_i/*_fifo/mem_reg*}] -to [get_clocks {clk_125mhz_mux clk_250mhz_mux}]
set_false_path -from [get_cells -hier -filter {NAME =~ *pcie_block_i/*_fifo/mem_reg*}] -to $uclk

# pipe_clock: the BUFGCTRL select is changed only while the GT rate change is in
# progress (as in Xilinx's own pipe_clock constraints)
set_false_path -to [get_pins -hier -filter {NAME =~ *pclk_i1_bufgctrl.pclk_i1/S*}]

# JTAG (BSCANE2 USER1)
create_clock -name jtag_tck -period 50.000 [get_pins -hier -filter {NAME =~ *jtag/g_bscan.bscan/TCK}]
set_clock_groups -asynchronous -group [get_clocks jtag_tck] -group [get_clocks -include_generated_clocks txoutclk]
