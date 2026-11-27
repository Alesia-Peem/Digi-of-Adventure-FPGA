// qspi_reader.v - burst reader for the Nexys A7 S25FL128S QSPI flash, command 0x6B (Quad Output Read).
//
// One `start` pulse (accepted only while busy = 0) reads `len` bytes from flash byte address `addr`:
//   CS# low, 0x6B on DQ0 MSB first, 24-bit address on DQ0 MSB first, DUMMY dummy clocks, then
//   2 x len nibbles on DQ[3:0] (high nibble first), CS# high. Every byte -> one `data_valid` pulse.
//   len = 0 does nothing.
// SCK = clk / 2 (50 MHz at 100 MHz), mode 0 (idle low). The FPGA changes DQ0 on SCK falling, the flash
// samples on SCK rising; the flash drives data after SCK falling.
// Throughput: 4 clk per byte (25 MB/s) + 2 * (32 + DUMMY) clk command overhead + GAP clk CS# high.
//
// DQ2 / DQ3 (WP# / HOLD# when the flash's QUAD bit is 0): driven HIGH by the FPGA while idle and during
// the command / address bits, released (tri-state) from the first dummy clock until 3 clk after CS#
// goes high (the flash drives them during the data phase). DQ1 is never driven by the FPGA.
// qspi_dq_oe is per bit: 4'b1101 idle/command, 4'b0000 dummy/data. Top level: one IOBUF per bit.
//
// Start-up: on the board SCK reaches the flash through STARTUPE2.USRCCLKO, which only drives the CCLK pin
// after the end of the configuration startup (STARTUPE2.EOS) and ignores its first 3 clock cycles after
// that (UG470). So after reset the reader stays in S_INIT (SCK low, CS# high, busy) until cfg_eos
// (synchronised, 2 flip-flops) has been 1 for EOS_WAIT clk, then issues INIT_CYC (>= 8) SCK cycles with
// CS# high before the first command. Simulation: tie cfg_eos to 1 (qspi_io does under SIMULATION).
//
// Sampling: DQ is first registered every clk in an input flip-flop placed in the IOB (dq_iob, IOB = TRUE),
// so the pad -> flip-flop path is the fixed IOB input path and the full clk is left for the logic behind
// it. The capture strobe is delayed by one clk to match, so the PAD is sampled at the same moment as
// without the register. LATE_SAMPLE chooses that moment: the nibble launched by SCK falling edge n is
// taken from the pad
//   LATE_SAMPLE = 0 : 1 clk later  (= when SCK rising n+1 is issued; fine in simulation)
//   LATE_SAMPLE = 1 : 2 clk later  (= when SCK falling n+1 is issued, ~20 ns; default)
// Real board: register -> STARTUPE2 -> CCLK pin + flash tV (8 ns) + board + input delay is more than
// one 10 ns clk, but below 20 ns, and the flash holds the old nibble until after the next falling edge
// reaches it (tHO + the same output path). Not verified: no Vivado timing run or board test yet.
`timescale 1ns/1ps
module qspi_reader #(
    parameter integer DUMMY       = 8,     // S25FL128S 0x6B with latency code 00 (default)
    parameter integer INIT_CYC    = 16,    // SCK cycles with CS# high after reset (>= 8)
    parameter integer LATE_SAMPLE = 1,
    parameter integer GAP         = 6,     // clk with CS# high after a burst (tCS = 10 ns min)
    parameter integer EOS_WAIT    = 256    // clk with cfg_eos = 1 (synchronised) before the init clocks (<= 511)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cfg_eos,     // STARTUPE2.EOS (asynchronous; 1 in simulation)
    input  wire        start,
    input  wire [23:0] addr,
    input  wire [15:0] len,
    output wire        busy,
    output reg  [7:0]  data,
    output reg         data_valid,
    output reg         qspi_csn = 1'b1,   // power-up value: flash deselected before the first reset
    output reg         qspi_sck = 1'b0,
    input  wire [3:0]  qspi_dq_i,
    output wire [3:0]  qspi_dq_o,
    output reg  [3:0]  qspi_dq_oe
);
    localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_CMD = 3'd2, S_DUMMY = 3'd3, S_DATA = 3'd4, S_GAP = 3'd5;
    reg [2:0]  st;
    reg        hi;          // 1 = SCK is high now (next clk issues the falling edge)
    reg [31:0] sr;          // {command, address}, MSB on DQ0
    reg [5:0]  bcnt;        // bit / dummy / init / gap counter
    reg [16:0] ncnt;        // nibbles still to read
    reg        nph;         // 0 = next nibble is the high one
    reg [3:0]  nib_hi;
    (* ASYNC_REG = "TRUE" *) reg eos_m = 1'b0, eos_s = 1'b0;   // cfg_eos synchroniser
    reg [8:0]  eos_cnt;     // clk with eos_s = 1 (saturates at EOS_WAIT)
    reg        eos_ok;      // eos_s has been 1 for EOS_WAIT clk -> init clocks may start
    (* IOB = "TRUE" *) reg [3:0] dq_iob = 4'h0;               // DQ input flip-flop (in the IOB)
    reg        smp;         // 1 = dq_iob holds the pad value of the capture moment (strobe delayed 1 clk)
    always @(posedge clk) begin
        eos_m  <= cfg_eos;
        eos_s  <= eos_m;
        dq_iob <= qspi_dq_i;
    end

    assign busy      = (st != S_IDLE);
    assign qspi_dq_o = {2'b11, 1'b0, sr[31]};

    always @(posedge clk) begin
        if (rst) begin
            st <= S_INIT; hi <= 1'b0; bcnt <= 6'd0; ncnt <= 17'd0; nph <= 1'b0; nib_hi <= 4'd0;
            sr <= 32'd0; data <= 8'd0; data_valid <= 1'b0; smp <= 1'b0;
            eos_cnt <= 9'd0; eos_ok <= 1'b0;
            qspi_csn <= 1'b1; qspi_sck <= 1'b0; qspi_dq_oe <= 4'b1101;
        end else begin
            data_valid <= 1'b0;
            // capture one nibble per SCK cycle from dq_iob, one clk after the pad moment chosen by
            // LATE_SAMPLE: high nibble first, data_valid with the low one (the last nibble lands in S_GAP)
            smp <= (st == S_DATA) && (hi == (LATE_SAMPLE != 0));
            if (smp) begin
                if (!nph) nib_hi <= dq_iob;
                else begin data <= {nib_hi, dq_iob}; data_valid <= 1'b1; end
                nph <= ~nph;
            end
            case (st)
            S_INIT: begin                                  // CS# high; SCK toggles once EOS is stable
                if (!eos_s) eos_cnt <= 9'd0;
                else if (eos_cnt != EOS_WAIT) eos_cnt <= eos_cnt + 9'd1;
                else eos_ok <= 1'b1;
                if (eos_ok) begin
                    qspi_sck <= ~hi; hi <= ~hi;
                    if (hi) begin
                        bcnt <= bcnt + 6'd1;
                        if (bcnt == INIT_CYC - 1) begin bcnt <= 6'd0; st <= S_IDLE; end
                    end
                end
            end
            S_IDLE: if (start && len != 16'd0) begin
                sr <= {8'h6B, addr}; ncnt <= {len, 1'b0}; nph <= 1'b0; bcnt <= 6'd0; hi <= 1'b0;
                qspi_csn <= 1'b0; st <= S_CMD;
            end
            S_CMD: begin                                   // 32 bits on DQ0
                qspi_sck <= ~hi; hi <= ~hi;
                if (hi) begin
                    sr <= {sr[30:0], 1'b0}; bcnt <= bcnt + 6'd1;
                    if (bcnt == 6'd31) begin bcnt <= 6'd0; qspi_dq_oe <= 4'b0000; st <= S_DUMMY; end
                end
            end
            S_DUMMY: begin
                qspi_sck <= ~hi; hi <= ~hi;
                if (hi) begin
                    bcnt <= bcnt + 6'd1;
                    if (bcnt == DUMMY - 1) begin bcnt <= 6'd0; st <= S_DATA; end
                end
            end
            S_DATA: begin
                qspi_sck <= ~hi; hi <= ~hi;
                if (hi) begin
                    ncnt <= ncnt - 17'd1;
                    if (ncnt == 17'd1) begin qspi_csn <= 1'b1; bcnt <= 6'd0; st <= S_GAP; end
                end
            end
            S_GAP: begin                                   // CS# high; the flash releases DQ (tDIS)
                bcnt <= bcnt + 6'd1;
                if (bcnt == 6'd2) qspi_dq_oe <= 4'b1101;
                if (bcnt == GAP - 1) begin bcnt <= 6'd0; st <= S_IDLE; end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
