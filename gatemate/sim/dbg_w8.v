// Debug monitori za tb_w8 (TASK-6161): Config.Idle brojači EP-a
`timescale 1ns / 1ps
module dbg_w8;
    wire c = tb_w8.sclk;
    reg [5:0] rq = 6'h3f;
    integer n_idle = 0, n_txidle = 0, n_ts = 0, n_skp = 0, n_err = 0;
    always @(posedge c) if (tb_w8.ep.core.eerie.p_ltssm == 6'h15) begin
        if (tb_w8.ep.core.eerie.l_idle2[0]) n_idle = n_idle + 1;
        if (tb_w8.ep.core.eerie.l_idle_pair[0]) n_txidle = n_txidle + 1;
        if (tb_w8.ep.core.eerie.l_tsv[0]) n_ts = n_ts + 1;
        if (tb_w8.ep.core.eerie.l_skp[0]) n_skp = n_skp + 1;
    end
    always @(posedge c) if (tb_w8.ep.core.eerie.p_ltssm == 6'h15 && $time < 30000 && $time > 14000 && ($time % 1000) < 32)
        $display("%t CIDLE: rx_idle_words=%0d tx_idle_words=%0d ts=%0d skp=%0d cnt_a=%0d tx_after=%0d rxd=%h rxk=%h",
                 $time, n_idle, n_txidle, n_ts, n_skp, tb_w8.ep.core.eerie.ltssm.cnt_a, tb_w8.ep.core.eerie.ltssm.tx_after,
                 tb_w8.ep_rxd, tb_w8.ep_rxk);
    always @(posedge tb_w8.pclk) if (tb_w8.rp_ltssm != rq) begin rq = tb_w8.rp_ltssm; $display("%t RP LTSSM 0x%02h", $time, rq); end
endmodule
