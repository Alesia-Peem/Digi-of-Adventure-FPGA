// qspi_io.v - the ONLY place with Xilinx primitives: QSPI flash pins of the Nexys A7 (S25FL128S).
//   * SCK: the flash clock pin (L16 / CCLK) is a dedicated configuration pin; after configuration user
//     logic reaches it only through STARTUPE2.USRCCLKO (UG470). qspi_reader.v sends >= 8 SCK cycles with
//     CS# high first because the first USRCCLKO edges after configuration are swallowed.
//   * DQ[3:0]: one IOBUF each (I = dq_o, T = ~dq_oe, O = dq_i).  CS#: plain output (QSPI_CSN port).
// SIMULATION (iverilog -DSIMULATION, run_tests.sh): behavioural model, no primitives. The sim clock is then
//   available on `sim_sck` - testbenches connect their flash model to it (e.g. dut.u_qio.sim_sck), because a
//   simulated STARTUPE2 does not drive the CCLK pin. In synthesis `sim_sck` is tied to 0 and left unconnected.
//   create_project.tcl must NOT define SIMULATION.
`timescale 1ns/1ps
module qspi_io (
    input  wire       sck,          // from qspi_reader / pic_stream
    input  wire [3:0] dq_o,
    input  wire [3:0] dq_oe,        // 1 = FPGA drives that DQ
    output wire [3:0] dq_i,
    inout  wire [3:0] dq,           // QSPI_DQ pads
    output wire       sim_sck       // simulation only: the flash clock (0 in synthesis)
);
`ifdef SIMULATION
    assign sim_sck = sck;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_dq
            assign dq[i] = dq_oe[i] ? dq_o[i] : 1'bz;
        end
    endgenerate
    assign dq_i = dq;
`else
    assign sim_sck = 1'b0;
    STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) u_startup (
        .CFGCLK(), .CFGMCLK(), .EOS(), .PREQ(),
        .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
        .USRCCLKO(sck), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1));
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_dq
            IOBUF u_iobuf (.I(dq_o[i]), .T(~dq_oe[i]), .O(dq_i[i]), .IO(dq[i]));
        end
    endgenerate
`endif
endmodule
