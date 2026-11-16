// Synthesizable. 16-bit Fibonacci LFSR, taps 16,15,13,4 (maximal length, XAPP052).
// Free-running: the value at the moment a round starts depends on human timing.
module lfsr16 #(parameter logic [15:0] SEED = 16'hACE1) (
  input  logic        clk,
  input  logic        rst,
  input  logic        en,
  output logic [15:0] q
);
  wire fb = q[15] ^ q[14] ^ q[12] ^ q[3];
  always_ff @(posedge clk) begin
    if (rst)          q <= SEED;
    else if (en)      q <= (q == 16'd0) ? SEED : {q[14:0], fb};  // guard: all-zero lock-up
  end
endmodule