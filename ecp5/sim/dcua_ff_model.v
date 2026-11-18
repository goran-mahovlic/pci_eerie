// SPDX-License-Identifier: CERN-OHL-P-2.0
// Ponašajni model FF strane ECP5 DCUA kanala u PCIe načinu (TASK-6160), samo za provjeru eerie_ecp5_pipe.
// Nije model analogije: 8b10b/CDR/CTC se ne modeliraju, simboli idu kroz "žicu" kao {K,bajt}.
// Modelirano: PLOL nakon TRST-a, RLOS = partnerov EI, RLOL dok traje RRST (+ kašnjenje), LSM nakon
// LANE_RX_RST, PCIE_DONE pada nakon CT-a i raste nakon DET_T taktova, CON = partner_present,
// TX EI po bajtu (bit 11/23), opcionalni pomak simbola (SHIFT) kao da je zarez u gornjem bajtu.
`timescale 1ns / 1ps
module dcua_ff_model #(
    parameter SHIFT = 0,
    parameter DET_T = 40
) (
    input             pclk,
    input             clk_free,
    input      [23:0] tx_d,
    output reg [23:0] rx_d,
    output reg        plol,
    output reg        rlol,
    output reg        rlos,
    output reg        lsm,
    output reg        pcie_done,
    output            pcie_con,
    input             trst, rrst, lane_rx_rst, pcie_det_en, pcie_ct,
    // žica prema partneru (format pipe_phy_model)
    output     [17:0] line_out,
    output            line_ei_out,
    input      [17:0] line_in,
    input             line_ei_in,
    input             partner_present
);
    assign line_out    = {tx_d[20], tx_d[8], tx_d[19:12], tx_d[7:0]};
    assign line_ei_out = tx_d[11];
    assign pcie_con    = partner_present;

    // PLL: zaključa se 200 taktova nakon TRST-a
    integer pc = 0;
    initial begin plol = 1'b1; rlol = 1'b1; rlos = 1'b1; lsm = 1'b0; pcie_done = 1'b1; end
    always @(posedge clk_free) begin
        if (trst) begin pc <= 0; plol <= 1'b1; end
        else if (pc < 200) pc <= pc + 1; else plol <= 1'b0;
    end
    // CDR: zaključan 50 taktova nakon RRST-a ako ima signala
    integer cc = 0;
    always @(posedge clk_free) begin
        if (rrst || rlos) begin cc <= 0; rlol <= 1'b1; end
        else if (cc < 50) cc <= cc + 1; else rlol <= 1'b0;
    end
    // RX put
    reg [17:0] d1, d2; reg [8:0] hi; reg e1, e2;
    integer lc = 0;
    always @(posedge pclk) begin
        d1 <= line_in; d2 <= d1; e1 <= line_ei_in; e2 <= e1;
        rlos <= e2;
        hi <= {d2[17], d2[15:8]};
        if (lane_rx_rst || rlos) begin lc <= 0; lsm <= 1'b0; end
        else if (lc < 20) lc <= lc + 1; else lsm <= 1'b1;
        if (lane_rx_rst) rx_d <= 24'd0;
        else if (SHIFT) rx_d <= {3'b000, d2[16], d2[7:0], 3'b000, hi[8], hi[7:0]};
        else            rx_d <= {3'b000, d2[17], d2[15:8], 3'b000, d2[16], d2[7:0]};
    end
    // detekcija prijemnika
    reg ct_q; integer dc = -1;
    always @(posedge pclk) begin
        ct_q <= pcie_ct;
        if (pcie_ct && !ct_q) begin pcie_done <= 1'b0; dc <= 0; end
        else if (dc >= 0) begin
            if (dc == DET_T) begin pcie_done <= 1'b1; dc <= -1; end else dc <= dc + 1;
        end
        if (!pcie_det_en && dc < 0) pcie_done <= 1'b1;
    end
endmodule
