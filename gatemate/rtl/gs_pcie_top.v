// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6184: ULX5M-GS v005 on the ULX4M-PCIe-IO card in the CM5 slot: the same endpoint as m2_pcie_top (M2V_s3),
// only pins and clock differ (schematic ~/app/ulx5m-gs-hw/hardware, kicad_netlist.py):
//   PERST#  CM4 pin 109 = GS J1.9 "PCInRES" and CLKREQ# CM4 102 = J1.2 end at the connector, no FPGA ball
//           -> perst_n tied high (reset = power-on only; the host retrains through Detect after a rebind)
//   REFCLK  CM4 110/112 reach SER_CLK only through C136/C137 (removed 04.11.), SER_CLK T12/T13 = GS X2 Si511
//           -> SRNS = 1 (own oscillator, SKP elastic buffer EERIE_SKP_EBB)
//   SerDes  RX U11/V11 <- J1.16/18 (CM4 116/118), TX U13/V13 -> C134/C135 -> J1.22/24 (CM4 122/124); P/N of the host TX
//           crossed on CM5IO M.2 -> handled by LTSSM rxpolarity (eerie Polling.Configuration)
//   LED0..7 IO_SB_A0,B0,A1,B1,B2,A2,B3,A3 active high (D9..D16), the same meaning as M2_LED
`timescale 1ns / 1ps
module gs_pcie_top #(
    parameter SRNS = 1
) (
    input        clk_i,
    output [7:0] led
`ifdef EERIE_ILA
   ,output       uart_tx                 // TASK-6190: IO_NB_B5 / IO_NA_B6 to the probe on .14 (if01), syn/gs_pcie_ila.ccf
   ,input        uart_rx
`endif
);
    m2_pcie_top #(.SRNS(SRNS)) ep (.clk_i(clk_i), .perst_n(1'b1), .clkreq_n(), .led(led)
`ifdef EERIE_ILA
        ,.uart_tx(uart_tx), .uart_rx(uart_rx)
`endif
        );
endmodule
