# SPDX-License-Identifier: CERN-OHL-P
# Program a 7-series FPGA over JTAG with Vivado.
# usage: vivado -mode batch -source tools/prog.tcl -tclargs <bitfile> [cable serial]
if {[catch {open_hw_manager}]} { open_hw }
if {[catch {connect_hw_server -allow_non_jtag}]} { connect_hw_server }
set t [lindex [get_hw_targets] 0]
if {[llength $argv] > 1} { set t [lindex [get_hw_targets *[lindex $argv 1]] 0] }
open_hw_target $t
set dev [lindex [get_hw_devices xc7*] 0]
puts "TARGET $t DEVICE $dev [get_property PART $dev]"
current_hw_device $dev
set_property PROGRAM.FILE [lindex $argv 0] $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "DONE=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
disconnect_hw_server
