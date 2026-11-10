# SPDX-License-Identifier: CERN-OHL-P
# Drive the pci_eerie root port test design (syn/top_ypcb_k480t_rp.v) over JTAG from Vivado:
# register bus of syn/eerie_host_app.v through the BSCANE2 USER1 data register (eerie_jtag_bus).
# usage: vivado -mode batch -source tools/eerie_host.tcl -tclargs <cable serial|-> <command> [args]
#   commands: status          link / LTSSM / clocks
#             perst           pulse PERST# (100 ms low ... released 100 ms later) and retrain
#             enum            RP setup, CfgRd0 of 01:00.0, BAR sizing / assignment, memory enable,
#                             NVMe controller registers (CAP, VS, CC, CSTS) if class 01:08:02
#             rd <addr>  | wr <addr> <data>   raw register bus access (hex)
#             poll <addr> <n>                 read n times, print changes
#             mrd <addr> [n] | mwr <addr> <data>   32-bit memory read/write on the link (hex)
#             cfgrd <bus:dev.fn> <reg>        configuration read (type 0 for bus 1, else type 1)
set serial [lindex $argv 0]
set cmd    [lindex $argv 1]
set args   [lrange $argv 2 end]

proc jtag_open {serial} {
    if {[catch {open_hw_manager}]} { open_hw }                              ;# Vivado < 2020
    if {[catch {connect_hw_server -allow_non_jtag}]} { connect_hw_server }
    set t [lindex [get_hw_targets] 0]
    if {$serial ne "-"} { set t [lindex [get_hw_targets *$serial] 0] }
    open_hw_target -jtag_mode on $t
    run_state_hw_jtag RESET
    run_state_hw_jtag IDLE
    scan_ir_hw_jtag 6 -tdi 02            ;# 7-series USER1
}
# one 50-bit DR scan: in {go, we, addr[15:0], data[31:0]}; out {aux[9:0], cnt[7:0], data[31:0]}
proc dr {go we addr data} {
    set v [expr {($go << 49) | ($we << 48) | (($addr & 0xFFFF) << 32) | ($data & 0xFFFFFFFF)}]
    set o [scan_dr_hw_jtag 50 -tdi [format %013llx $v]]
    scan $o %llx r
    return [list [expr {$r & 0xFFFFFFFF}] [expr {($r >> 32) & 0xFF}] [expr {($r >> 40) & 0x3FF}]]
}
proc wr {addr data} {
    set c0 [lindex [dr 0 0 0 0] 1]
    dr 1 1 $addr $data
    set c1 [lindex [dr 0 0 0 0] 1]
    if {$c1 == $c0} { error [format "register write 0x%04x not acknowledged (user clock not running?)" $addr] }
}
proc rd {addr} {
    set c0 [lindex [dr 0 0 0 0] 1]
    dr 1 0 $addr 0
    set r [dr 0 0 0 0]
    if {[lindex $r 1] == $c0} { error [format "register read 0x%04x not acknowledged (user clock not running?)" $addr] }
    return [lindex $r 0]
}
proc ctl {v} { dr 1 1 0xFFFF $v }
proc aux {} { return [lindex [dr 0 0 0 0] 2] }

proc status {} {
    set a [aux]
    puts [format "aux: PERST#=%d core_rst_n=%d user_lnk_up=%d (heartbeats user %d clk_50 %d)" \
        [expr {$a & 1}] [expr {($a >> 1) & 1}] [expr {($a >> 2) & 1}] [expr {($a >> 3) & 1}] [expr {($a >> 4) & 1}]]
    if {[catch {set s [rd 0x0300]} e]} { puts "status: $e"; return }
    set iw [expr {($s >> 11) & 7}]
    puts [format "status %08x: user_lnk_up %d phy_lnk_up %d LTSSM 0x%02x, %s x%d (initial x%s), partner Gen2 %d, LnkSta %d GT/s-code x%d, messages %d" \
        $s [expr {$s & 1}] [expr {($s >> 1) & 1}] [expr {($s >> 2) & 0x3F}] \
        [expr {($s >> 8) & 1 ? "5.0 GT/s" : "2.5 GT/s"}] [expr {1 << (($s >> 9) & 3)}] \
        [expr {$iw == 0 ? "-" : (1 << ($iw - 1))}] [expr {($s >> 14) & 1}] \
        [expr {($s >> 20) & 0xF}] [expr {($s >> 16) & 0xF}] [expr {($s >> 24) & 0xFF}]]
    set u0 [rd 0x0301]; after 100; set u1 [rd 0x0301]
    puts [format "user clock: %.1f MHz (approx.)" [expr {(($u1 - $u0) & 0xFFFFFFFF) / 0.1e6 / 1.0}]]
}

# send a TLP (list of DWs) and wait until it left
proc send {dws} {
    set i 0
    foreach d $dws { wr $i $d; incr i }
    wr 0x0100 [llength $dws]
    while {[rd 0x0100] & 1} {}
}
# wait for one received TLP, return its DWs (and clear the capture buffer)
proc recv {{tries 50}} {
    for {set t 0} {$t < $tries} {incr t} {
        set r [rd 0x0200]
        if {($r >> 24) & 0xFF} break
    }
    if {!(($r >> 24) & 0xFF)} { error "no TLP received" }
    set beats [expr {$r & 0x3FF}]
    set dws {}
    for {set b 0} {$b < $beats} {incr b} {
        set f [rd [expr {0x1800 + $b}]]
        lappend dws [rd [expr {0x1000 + 2*$b}]]
        if {$f & 2} { lappend dws [rd [expr {0x1000 + 2*$b + 1}]] }
        if {$f & 1} break
    }
    wr 0x0200 0
    return $dws
}
set tag 0
proc ntag {} { global tag; set tag [expr {($tag + 1) & 0xFF}]; return $tag }
proc cpl_check {dws what} {
    set st [expr {([lindex $dws 1] >> 13) & 7}]
    if {$st != 0} { error [format "%s: completion status %d (%s)" $what $st [lindex {SC UR CRS - CA} $st]] }
}
proc bdf {s} {
    scan $s "%x:%x.%x" b d f
    return [expr {($b << 8) | ($d << 3) | $f}]
}
proc cfgrd {b reg} {
    set t [expr {(($b >> 8) == 1) ? 0x04000001 : 0x05000001}]
    send [list $t [expr {([ntag] << 8) | 0x0F}] [expr {($b << 16) | ($reg & 0xFFC)}]]
    set c [recv]; cpl_check $c [format "CfgRd %04x+%03x" $b $reg]
    return [lindex $c 3]
}
proc cfgwr {b reg data} {
    set t [expr {(($b >> 8) == 1) ? 0x44000001 : 0x45000001}]
    send [list $t [expr {([ntag] << 8) | 0x0F}] [expr {($b << 16) | ($reg & 0xFFC)}] $data]
    set c [recv]; cpl_check $c [format "CfgWr %04x+%03x" $b $reg]
}
proc mrd {addr {n 1}} {
    send [list [expr {0x00000000 | $n}] [expr {([ntag] << 8) | 0x0F | ($n > 1 ? 0xF0 : 0)}] [expr {$addr & 0xFFFFFFFC}]]
    set c [recv]; cpl_check $c [format "MRd %08x" $addr]
    return [lrange $c 3 end]
}
proc mwr {addr data} {
    send [list 0x40000001 [expr {([ntag] << 8) | 0x0F}] [expr {$addr & 0xFFFFFFFC}] $data]
}
# completion / config payload DWs are in PCIe byte order (byte 0 in bits 31:24); swap to a
# little-endian register value
proc le {d} { return [expr {(($d & 0xFF) << 24) | (($d & 0xFF00) << 8) | (($d >> 8) & 0xFF00) | (($d >> 24) & 0xFF)}] }
proc mgmt_rd {dw} {
    wr 0x0400 $dw; wr 0x0402 0xF1
    while {[set s [rd 0x0402]] & 1} {}
    if {$s & 2} { error "cfg_mgmt timeout" }
    return [rd 0x0403]
}
proc mgmt_wr {dw data} { wr 0x0400 $dw; wr 0x0401 $data; wr 0x0402 0xF2; while {[rd 0x0402] & 1} {} }

proc enum {} {
    status
    puts [format "RP: ID %08x class %08x" [mgmt_rd 0] [mgmt_rd 2]]
    mgmt_wr 1 0x00000006                 ;# memory space + bus master
    mgmt_wr 6 0x00010100                 ;# primary 0, secondary 1, subordinate 1
    mgmt_wr 8 0x1FF01000                 ;# memory window 0x10000000-0x1FFFFFFF
    set v [cfgv 0]
    puts [format "01:00.0: vendor %04x device %04x" [expr {$v & 0xFFFF}] [expr {$v >> 16}]]
    set cc [cfgv 2]
    puts [format "01:00.0: class %06x rev %02x" [expr {$cc >> 8}] [expr {$cc & 0xFF}]]
    set hdr [cfgv 3]; puts [format "01:00.0: header type %02x" [expr {($hdr >> 16) & 0xFF}]]
    # capabilities: link status of the PCIe capability
    set p [expr {[cfgv 0x34] & 0xFF}]
    while {$p} {
        set c [cfgv $p]
        if {($c & 0xFF) == 0x10} {
            set lc [cfgv [expr {$p + 0x0C}]]; set ls [expr {[cfgv [expr {$p + 0x10}]] >> 16}]
            puts [format "01:00.0: PCIe cap at %02x, LnkCap %d GT/s-code x%d, LnkSta %d GT/s-code x%d" \
                $p [expr {$lc & 0xF}] [expr {($lc >> 4) & 0x3F}] [expr {$ls & 0xF}] [expr {($ls >> 4) & 0x3F}]]
        }
        set p [expr {($c >> 8) & 0xFC}]
    }
    # BAR0 (64-bit for NVMe)
    cfgwrv 0x10 0xFFFFFFFF
    set m [cfgv 0x10]
    puts [format "01:00.0: BAR0 mask %08x" $m]
    cfgwrv 0x10 0x10000000
    if {($m & 6) == 4} { cfgwrv 0x14 0 }
    cfgwrv 0x04 0x00000006
    puts [format "01:00.0: command/status %08x, BAR0 %08x" [cfgv 4] [cfgv 0x10]]
    if {($cc >> 8) == 0x010802} {
        set r [mrd 0x10000000 2]
        set cap [expr {([regv [lindex $r 1]] << 32) | [regv [lindex $r 0]]}]
        puts [format "NVMe CAP %016llx: MQES %d, TO %d x 500 ms, DSTRD %d, MPSMIN %d" $cap \
            [expr {($cap & 0xFFFF) + 1}] [expr {($cap >> 24) & 0xFF}] [expr {($cap >> 32) & 0xF}] [expr {($cap >> 48) & 0xF}]]
        set vs [regv [lindex [mrd 0x10000008] 0]]
        puts [format "NVMe VS %08x (%d.%d.%d)" $vs [expr {$vs >> 16}] [expr {($vs >> 8) & 0xFF}] [expr {$vs & 0xFF}]]
        puts [format "NVMe CC %08x CSTS %08x" [regv [lindex [mrd 0x10000014] 0]] [regv [lindex [mrd 0x1000001C] 0]]]
    }
}
# config / memory payload in register (little-endian) order
proc regv {d} { return [le $d] }
proc cfgv {reg} { return [regv [cfgrd [bdf 01:00.0] $reg]] }
proc cfgwrv {reg v} { cfgwr [bdf 01:00.0] $reg [regv $v] }

jtag_open $serial
switch $cmd {
    status { status }
    perst  { ctl 1; after 100; ctl 0; after 300; status }
    enum   { enum }
    rd     { puts [format %08x [rd [expr 0x[lindex $args 0]]]] }
    poll   { set last -1; set t0 [clock milliseconds]
             for {set i 0} {$i < [lindex $args 1]} {incr i} {
                 set v [rd [expr 0x[lindex $args 0]]]
                 if {$v != $last} { puts [format "%6d ms: %08x" [expr {[clock milliseconds] - $t0}] $v]; set last $v }
             } }
    wr     { wr [expr 0x[lindex $args 0]] [expr 0x[lindex $args 1]] }
    ctl    { ctl [expr 0x[lindex $args 0]] }
    mrd    { foreach d [mrd [expr 0x[lindex $args 0]] [expr {[llength $args] > 1 ? [lindex $args 1] : 1}]] { puts [format %08x [regv $d]] } }
    mwr    { mwr [expr 0x[lindex $args 0]] [regv [expr 0x[lindex $args 1]]] }
    cfgrd  { puts [format %08x [regv [cfgrd [bdf [lindex $args 0]] [expr 0x[lindex $args 1]]]]] }
    default { puts "unknown command $cmd" }
}
close_hw_target
