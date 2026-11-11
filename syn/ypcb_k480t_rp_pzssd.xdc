# SPDX-License-Identifier: CERN-OHL-P
# YPCB K480T (xc7k480tffg1156-2) as a root port into a PUZHI PZ-SSD adapter, x4 (syn/top_ypcb_k480t_rp.v, Vivado 7-series core).
# Lanes as github.com/TiferKing/ypcb_00338_1p1_hack constraints (edge lane n on GTX quad 116
# channel 3-n), but in reverse order: the PUZHI PZ-SSD adapter connects M.2 lanes 0..3 to edge
# lanes 3..0 (found on hardware: an x2 SSD shows up on edge lanes 2-3), and pci_eerie has no lane
# reversal, so core lane n uses edge lane 3-n.
# The 100 MHz reference clock comes from the edge connector (supplied by the M.2 adapter);
# PERST# (edge connector) is driven by the FPGA.
set_property PACKAGE_PIN J8 [get_ports sys_clk_p]
set_property PACKAGE_PIN J7 [get_ports sys_clk_n]
set_property PACKAGE_PIN L4 [get_ports {pci_exp_rxp[0]}]
set_property PACKAGE_PIN M2 [get_ports {pci_exp_txp[0]}]
set_property PACKAGE_PIN K6 [get_ports {pci_exp_rxp[1]}]
set_property PACKAGE_PIN K2 [get_ports {pci_exp_txp[1]}]
set_property PACKAGE_PIN J4 [get_ports {pci_exp_rxp[2]}]
set_property PACKAGE_PIN H2 [get_ports {pci_exp_txp[2]}]
set_property PACKAGE_PIN H6 [get_ports {pci_exp_rxp[3]}]
set_property PACKAGE_PIN F2 [get_ports {pci_exp_txp[3]}]

set_property PACKAGE_PIN Y26 [get_ports perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports perst_n]
set_false_path -to [get_ports perst_n]

set_property PACKAGE_PIN AA28 [get_ports clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50]
create_clock -name clk_50 -period 20.000 [get_ports clk_50]

set_property PACKAGE_PIN N30 [get_ports {led[0]}]
set_property PACKAGE_PIN M30 [get_ports {led[1]}]
set_property PACKAGE_PIN P30 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

create_clock -name sys_clk -period 10.000 [get_ports sys_clk_p]
# the PIPE clock MMCM is fed from lane 0's TXOUTCLK
create_clock -name txoutclk -period 10.000 [get_pins -hier -filter {NAME =~ *pipe_lane[0]*gtxe2_channel_i/TXOUTCLK}]
# JTAG (BSCANE2 USER1)
create_clock -name jtag_tck -period 50.000 [get_pins -hier -filter {NAME =~ *jtag/g_bscan.bscan/TCK}]
# PIPE clock mux (BUFGCTRL): 125 MHz (2.5 GT/s) and 250 MHz (5.0 GT/s) are exclusive
set mmcm  [get_cells -hier -filter {REF_NAME == MMCME2_ADV}]
set mux_o [get_pins -hier -filter {NAME =~ *pclk_i1_bufgctrl.pclk_i1/O}]
create_generated_clock -name clk_125mhz_mux -source [get_pins $mmcm/CLKOUT0] -divide_by 1 -add \
    -master_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT0]] $mux_o
create_generated_clock -name clk_250mhz_mux -source [get_pins $mmcm/CLKOUT1] -divide_by 1 -add \
    -master_clock [get_clocks -of_objects [get_pins $mmcm/CLKOUT1]] $mux_o
set_clock_groups -name pclk_mux -physically_exclusive -group clk_125mhz_mux -group clk_250mhz_mux
# pipe_clock: the BUFGCTRL select changes only while the GT rate change is in progress
set_false_path -to [get_pins -hier -filter {NAME =~ *pclk_i1_bufgctrl.pclk_i1/S*}]

# pci_eerie crossings between the PIPE clock and the user clock (gray-coded FIFO pointers, 2-flop
# synchronizers), as syn/pci_eerie_timing.xdc
set uclk [get_clocks -of_objects [get_pins $mmcm/CLKOUT2]]
set_max_delay -datapath_only -from [get_clocks {clk_125mhz_mux clk_250mhz_mux}] -to $uclk 4.000
set_max_delay -datapath_only -from $uclk -to [get_clocks {clk_125mhz_mux clk_250mhz_mux}] 4.000
set_false_path -from [get_cells -hier -filter {NAME =~ *pcie_block_i/*_fifo/mem_reg*}] -to [get_clocks {clk_125mhz_mux clk_250mhz_mux}]
set_false_path -from [get_cells -hier -filter {NAME =~ *pcie_block_i/*_fifo/mem_reg*}] -to $uclk

set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks txoutclk] \
    -group [get_clocks clk_50] -group [get_clocks jtag_tck] -group [get_clocks sys_clk]
