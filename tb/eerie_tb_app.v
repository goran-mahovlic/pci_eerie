// SPDX-License-Identifier: CERN-OHL-P
// pci_eerie testbench endpoint application (64-bit AXI-stream, 7-series PCIe core format):
//   * MWr32/MWr64 of any length into a 4 KB memory (address bits [11:2])
//   * MRd32/MRd64 up to 32 DW answered with a single CplD
//   * write to offset 0xFF0 triggers an interrupt (data bit 0 = assert for INTx)
// Used by eerie_tb_ep (pcie_7x, x1) and eerie_tb_ep_ml (Vivado core, x1..x8).
`timescale 1ns / 1ps
module eerie_tb_app (
    input             user_clk,
    input             user_reset,
    input             s_axis_tx_tready,
    output reg [63:0] s_axis_tx_tdata,
    output reg [7:0]  s_axis_tx_tkeep,
    output reg        s_axis_tx_tlast,
    output reg        s_axis_tx_tvalid,
    input      [63:0] m_axis_rx_tdata,
    input      [7:0]  m_axis_rx_tkeep,
    input             m_axis_rx_tlast,
    input             m_axis_rx_tvalid,
    input      [7:0]  cfg_bus_number,
    input      [4:0]  cfg_device_number,
    input      [2:0]  cfg_function_number,
    input             cfg_interrupt_rdy,
    output reg        cfg_interrupt,
    output reg        cfg_interrupt_assert
);
    reg         user_reset_q;
    always @(posedge user_clk) user_reset_q <= user_reset;

    // ---------------------------------------------------------------- memory
    reg [31:0] mem [0:1023];
    integer mi;
    initial for (mi = 0; mi < 1024; mi = mi + 1) mem[mi] = 32'h0;

    // ---------------------------------------------------------------- RX
    // AXI 7-series format: tdata[31:0] = first DW, [63:32] = second DW
    reg        rx_in, rx_wr, rx_4dw, rx_first;
    reg [9:0]  rx_addr;
    reg [31:0] h0, h1;
    reg        rd_req; reg [31:0] rd_h0, rd_h1; reg [9:0] rd_addr;
    reg        irq_req; reg irq_val;
    wire [31:0] d_lo = m_axis_rx_tdata[31:0], d_hi = m_axis_rx_tdata[63:32];
    reg        rd_busy;
    always @(posedge user_clk) begin
        if (user_reset_q) begin
            rx_in <= 1'b0; rd_req <= 1'b0; irq_req <= 1'b0;
        end else begin
            if (rd_req && rd_busy) rd_req <= 1'b0;
            if (m_axis_rx_tvalid) begin
                if (!rx_in) begin
                    // beat 0: DW0, DW1
                    h0 <= d_lo; h1 <= d_hi; rx_in <= !m_axis_rx_tlast; rx_first <= 1'b1;
                    rx_wr <= d_lo[30]; rx_4dw <= d_lo[29];
                end else begin
                    rx_first <= 1'b0;
                    if (rx_first) begin
                        // beat 1: DW2, DW3
                        if (!rx_4dw) begin
                            rx_addr <= d_lo[11:2] + 1'b1;
                            if (rx_wr) begin
                                mem[d_lo[11:2]] <= d_hi;
                                if (d_lo[11:2] == 10'h3FC) begin irq_req <= 1'b1; irq_val <= d_hi[24]; end
                            end else if (h0[28:24] == 5'b00000) begin
                                rd_req <= 1'b1; rd_h0 <= h0; rd_h1 <= h1; rd_addr <= d_lo[11:2];
                            end
                        end else begin
                            rx_addr <= d_hi[11:2];
                            if (!rx_wr && h0[28:24] == 5'b00000) begin
                                rd_req <= 1'b1; rd_h0 <= h0; rd_h1 <= h1; rd_addr <= d_hi[11:2];
                            end
                        end
                    end else if (rx_wr && h0[28:24] == 5'b00000) begin
                        mem[rx_addr] <= d_lo;
                        if (m_axis_rx_tkeep[4]) mem[rx_addr + 1'b1] <= d_hi;
                        if (rx_addr == 10'h3FC) begin irq_req <= 1'b1; irq_val <= d_lo[24]; end
                        rx_addr <= rx_addr + 2'd2;
                    end
                    if (m_axis_rx_tlast) rx_in <= 1'b0;
                end
            end
            if (irq_req && cfg_interrupt_rdy) irq_req <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- TX (completions)
    reg [9:0]  c_len, c_left;
    reg [9:0]  c_addr;
    reg [1:0]  c_st;
    reg        c_odd;
    wire [15:0] cid = {cfg_bus_number, cfg_device_number, cfg_function_number};
    always @(posedge user_clk) begin
        if (user_reset_q) begin
            rd_busy <= 1'b0; s_axis_tx_tvalid <= 1'b0; c_st <= 2'd0;
        end else begin
            case (c_st)
            2'd0: begin
                s_axis_tx_tvalid <= 1'b0;
                if (rd_req && !rd_busy) begin
                    rd_busy <= 1'b1;
                    c_len  <= rd_h0[9:0]; c_addr <= rd_addr;
                    // DW0 CplD, DW1 completer/bytecount
                    s_axis_tx_tdata <= {cid, 3'b000, 1'b0, {rd_h0[9:0], 2'b00},
                                        {3'b010, 5'b01010, 1'b0, rd_h0[22:20], 4'h0, 2'b00, rd_h0[13:12], 2'b00, rd_h0[9:0]}};
                    s_axis_tx_tkeep <= 8'hFF; s_axis_tx_tlast <= 1'b0; s_axis_tx_tvalid <= 1'b1;
                    c_st <= 2'd1;
                end
            end
            2'd1: if (s_axis_tx_tready) begin
                // DW2 requester/tag/lower address, DW3 first data
                s_axis_tx_tdata <= {mem[c_addr], rd_h1[31:16], rd_h1[15:8], 1'b0, c_addr[4:0], 2'b00};
                s_axis_tx_tlast <= (c_len == 10'd1);
                c_addr <= c_addr + 1'b1; c_left <= c_len - 1'b1;
                c_st <= (c_len == 10'd1) ? 2'd3 : 2'd2;
            end
            2'd2: if (s_axis_tx_tready) begin
                s_axis_tx_tdata <= {mem[c_addr + 1'b1], mem[c_addr]};
                s_axis_tx_tkeep <= (c_left == 10'd1) ? 8'h0F : 8'hFF;
                s_axis_tx_tlast <= (c_left <= 10'd2);
                c_addr <= c_addr + 2'd2;
                c_left <= (c_left <= 10'd2) ? 10'd0 : c_left - 2'd2;
                if (c_left <= 10'd2) c_st <= 2'd3;
            end
            default: if (s_axis_tx_tready) begin
                s_axis_tx_tvalid <= 1'b0; s_axis_tx_tlast <= 1'b0; rd_busy <= 1'b0; c_st <= 2'd0;
            end
            endcase
        end
    end

    // ---------------------------------------------------------------- interrupt
    always @(posedge user_clk) begin
        if (user_reset_q) begin cfg_interrupt <= 1'b0; cfg_interrupt_assert <= 1'b0; end
        else if (cfg_interrupt && cfg_interrupt_rdy) cfg_interrupt <= 1'b0;
        else if (irq_req && !cfg_interrupt) begin cfg_interrupt <= 1'b1; cfg_interrupt_assert <= irq_val; end
    end
endmodule
