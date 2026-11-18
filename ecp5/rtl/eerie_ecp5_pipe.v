// SPDX-License-Identifier: CERN-OHL-P-2.0
// PIPE x1 (16 bita, 2,5 GT/s) nad ECP5 DCUA kanalom u PCIe načinu (TASK-6160).
// DCU daje: 8b10b, poravnanje na zarez (LSM), CTC (umetanje/brisanje SKP), detekciju prijemnika
// (FFC_PCIE_DET_EN/CT -> FFS_PCIE_DONE/CON), TX električni mir po bajtu (FF_TX_D[11]/[23]),
// inverziju polariteta (FFC_SB_INV_RX), gubitak signala (FFS_RLOS).
// Ovdje se pišu: PhyStatus, RxStatus za detekciju, RxValid/RxElecIdle i redoslijed reseta
// (TRST -> PLL lock -> RRST dok ima LOS-a -> CDR lock -> LANE_RX_RST), po TN1261 i Lattice RSL opisu.
// 24-bitna DCU sabirnica po bajtu: [7:0] podatak, [8] K, [9] force_disp / status[0], [10] disp_sel / status[1],
// [11] TX EI / status[2]; drugi bajt na [23:12].
`timescale 1ns / 1ps
module eerie_ecp5_pipe #(
    parameter TRST_W = 6,     // TRST impuls: 2^6 taktova clk_free (2,6 us @ 25 MHz)
    parameter PLL_W  = 17,    // PLL stabilan 2^17 (5,2 ms) prije TX-a
    parameter LOS_W  = 12,    // bez LOS-a 2^12 (164 us) prije puštanja RRST
    parameter LOL_W  = 12,    // CDR zaključan 2^12 (164 us) prije puštanja LANE_RX_RST
    parameter DET_US = 125,   // FFC_PCIE_DET_EN prije CT: 1 us u pclk taktovima
    parameter IGNORE_LOL = 0, // 1: LANE_RX_RST se pušta bez CDR locka (pokus E4: je li RLOL lažan)
    parameter IGNORE_POL = 0, // 1: FFC_SB_INV_RX = FORCE_INV (pokus E5/E6: pci_eerie mijenja polaritet na svaki obrnuti TS, a DCU kasni)
    parameter FORCE_INV  = 0  // vrijednost INV_RX kad je IGNORE_POL = 1
) (
    input             clk_free,       // slobodan takt (25 MHz ploče), ne ovisi o DCU-u
    input             pclk,           // FF_TX_PCLK, 125 MHz
    // DCU
    input      [23:0] dcu_rx_d,
    output reg [23:0] dcu_tx_d,
    input             dcu_plol,
    input             dcu_rlol,
    input             dcu_rlos,
    input             dcu_lsm,
    input             dcu_pcie_done,
    input             dcu_pcie_con,
    output reg        dcu_trst,
    output reg        dcu_rrst,
    output reg        dcu_lane_rx_rst,
    output            dcu_lane_tx_rst,
    output reg        dcu_pcie_det_en,
    output reg        dcu_pcie_ct,
    output            dcu_sb_inv_rx,
    // PIPE prema MAC-u
    output reg [15:0] rxdata,
    output reg [1:0]  rxdatak,
    output reg        rxvalid,
    output reg        rxelecidle,
    output reg [2:0]  rxstatus,
    output reg        phystatus,
    input      [15:0] txdata,
    input      [1:0]  txdatak,
    input             txelecidle,
    input             txcompliance,
    input      [1:0]  powerdown,
    input             txdetectrx,
    input             rxpolarity,
    // stanje
    output            tx_ready,       // pclk domena
    output            rx_ready,       // pclk domena
    output reg        det_con         // zadnji ishod detekcije prijemnika
);
    // ------------------------------------------------------------ RSL (clk_free)
    reg [1:0] plol_f, rlol_f, rlos_f;
    always @(posedge clk_free) begin
        plol_f <= {plol_f[0], dcu_plol}; rlol_f <= {rlol_f[0], dcu_rlol}; rlos_f <= {rlos_f[0], dcu_rlos};
    end
    reg [PLL_W:0] tcnt = 0;
    reg [1:0]     tst = 2'd0;
    reg           txr = 1'b0;
    initial begin dcu_trst = 1'b1; dcu_rrst = 1'b1; dcu_lane_rx_rst = 1'b1; end
    always @(posedge clk_free) begin
        case (tst)
        2'd0: begin dcu_trst <= 1'b1; txr <= 1'b0; tcnt <= tcnt + 1'b1;
                    if (tcnt[TRST_W]) begin tst <= 2'd1; tcnt <= 0; dcu_trst <= 1'b0; end end
        2'd1: begin if (plol_f[1]) tcnt <= 0; else tcnt <= tcnt + 1'b1;
                    if (tcnt[PLL_W]) begin tst <= 2'd2; txr <= 1'b1; end end
        default: if (plol_f[1]) begin tst <= 2'd0; tcnt <= 0; end   // PLL izgubio lock: ispočetka
        endcase
    end
    assign dcu_lane_tx_rst = !txr;

    reg [LOS_W:0] rcnt = 0;
    always @(posedge clk_free) begin
        if (!txr || rlos_f[1]) begin
            dcu_rrst <= 1'b1; dcu_lane_rx_rst <= 1'b1; rcnt <= 0;
        end else if (dcu_rrst) begin
            rcnt <= rcnt + 1'b1;
            if (rcnt[LOS_W]) begin dcu_rrst <= 1'b0; rcnt <= 0; end
        end else if (rlol_f[1] && !IGNORE_LOL) begin
            dcu_lane_rx_rst <= 1'b1; rcnt <= 0;
        end else if (dcu_lane_rx_rst) begin
            rcnt <= rcnt + 1'b1;
            if (rcnt[LOL_W]) dcu_lane_rx_rst <= 1'b0;
        end
    end

    // ------------------------------------------------------------ pclk domena
    reg [2:0] txr_p, rxr_p, rlos_p, lsm_p, done_p, con_p;
    always @(posedge pclk) begin
        txr_p  <= {txr_p[1:0], txr};
        rxr_p  <= {rxr_p[1:0], !dcu_lane_rx_rst};
        rlos_p <= {rlos_p[1:0], dcu_rlos};
        lsm_p  <= {lsm_p[1:0], dcu_lsm};
        done_p <= {done_p[1:0], dcu_pcie_done};
        con_p  <= {con_p[1:0], dcu_pcie_con};
    end
    assign tx_ready = txr_p[2];
    assign rx_ready = rxr_p[2];
    assign dcu_sb_inv_rx = IGNORE_POL ? FORCE_INV[0] : rxpolarity;

    // RX
    always @(posedge pclk) begin
        rxdata     <= {dcu_rx_d[19:12], dcu_rx_d[7:0]};
        rxdatak    <= {dcu_rx_d[20], dcu_rx_d[8]};
        rxelecidle <= rlos_p[2] || !rx_ready;
        rxvalid    <= rx_ready && lsm_p[2] && !rlos_p[2];
    end

    // TX (u mirovanju dok PLL nije spreman)
    wire ei = txelecidle || !tx_ready;
    always @(posedge pclk)
        dcu_tx_d <= {ei, 1'b0, 1'b0, txdatak[1], txdata[15:8],
                     ei, 1'b0, txcompliance, txdatak[0], txdata[7:0]};

    // Detekcija prijemnika (TN1261): DET_EN >= 1 us, CT 2 pclk (4 bajtna takta), DONE pada pa raste, CON = ishod
    localparam D_IDLE = 3'd0, D_EN = 3'd1, D_CT = 3'd2, D_LOW = 3'd3, D_HIGH = 3'd4, D_RES = 3'd5;
    reg [2:0]  dst;
    reg [15:0] dcnt;
    reg        det_q, det_pulse, det_res;
    reg [1:0]  pd_q;
    reg [2:0]  pd_cnt;
    always @(posedge pclk) begin
        det_q <= txdetectrx;
        det_pulse <= 1'b0;
        if (!tx_ready) begin
            dst <= D_IDLE; dcu_pcie_det_en <= 1'b0; dcu_pcie_ct <= 1'b0;
        end else case (dst)
        D_IDLE: if (txdetectrx && !det_q) begin dcu_pcie_det_en <= 1'b1; dcnt <= 0; dst <= D_EN; end
        D_EN:   begin dcnt <= dcnt + 1'b1;
                      if (dcnt == DET_US) begin dcu_pcie_ct <= 1'b1; dcnt <= 0; dst <= D_CT; end end
        D_CT:   begin dcnt <= dcnt + 1'b1;
                      if (dcnt == 16'd1) begin dcu_pcie_ct <= 1'b0; dcnt <= 0; dst <= D_LOW; end end
        D_LOW:  begin dcnt <= dcnt + 1'b1;          // DONE pada (ili je već pao)
                      if (!done_p[2] || dcnt[15]) begin dcnt <= 0; dst <= D_HIGH; end end
        D_HIGH: begin dcnt <= dcnt + 1'b1;
                      if (done_p[2] || dcnt[15]) begin det_res <= done_p[2] && con_p[2]; dst <= D_RES; end end
        default: begin dcu_pcie_det_en <= 1'b0; det_pulse <= 1'b1; det_con <= det_res; dst <= D_IDLE; end
        endcase
    end

    // PhyStatus: ishod detekcije ili promjena PowerDown-a (DCU nema stanja snage; potvrda nakon 4 takta)
    always @(posedge pclk) begin
        pd_q <= powerdown;
        phystatus <= 1'b0; rxstatus <= 3'b000;
        if (!tx_ready) begin
            phystatus <= 1'b1; pd_cnt <= 3'd0;
        end else begin
            if (powerdown != pd_q) pd_cnt <= 3'd4;
            else if (pd_cnt != 3'd0) begin pd_cnt <= pd_cnt - 1'b1; if (pd_cnt == 3'd1) phystatus <= 1'b1; end
            if (det_pulse) begin phystatus <= 1'b1; rxstatus <= det_res ? 3'b011 : 3'b000; end
        end
    end
endmodule
