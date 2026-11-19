// SPDX-License-Identifier: CERN-OHL-P-2.0
// TASK-6170: global clock buffer: CC_BUFG on GateMate (yosys defines SYNTHESIS), a wire in simulation.
`timescale 1ns / 1ps
module eerie_bufg (input I, output O);
`ifdef SYNTHESIS
    CC_BUFG b (.I(I), .O(O));
`else
    assign O = I;
`endif
endmodule
