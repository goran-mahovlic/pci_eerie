// SPDX-License-Identifier: CERN-OHL-P-2.0
// EXTREFB parametri iz Lattice bita C (TASK-5904)
`ifdef LD_DCBIAS
  .REFCK_DCBIAS_EN("0b1"),   // pokus E8: DC bias AC-spojenog REFCLK-a
`else
  .REFCK_DCBIAS_EN("0b0"),
`endif
  .REFCK_RTERM("0b1"),
  .REFCK_PWDNB("0b1")
