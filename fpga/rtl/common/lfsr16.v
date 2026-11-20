// lfsr16.v - 16-bit Fibonacci LFSR, taps 16,15,13,4 - bit-for-bit the same as lfsr_step() in the
// Pygame demos:  fb = q15 ^ q14 ^ q12 ^ q3 ;  q = (q << 1 | fb) & 0xFFFF ;  0 -> 0xACE1.
// The stage logic decides WHEN to step (7 times per game tick + card shuffles), exactly like Pygame,
// so a testbench that seeds both with the same value gets the same card shuffles.
`timescale 1ns/1ps
module lfsr16 #(parameter [15:0] SEED = 16'hACE1) (
    input  wire        clk,
    input  wire        rst,
    input  wire        load,          // load `seed` (testbench / demo); 0 is replaced by SEED
    input  wire [15:0] seed,
    input  wire        step,
    output reg  [15:0] q
);
    wire        fb = q[15] ^ q[14] ^ q[12] ^ q[3];
    wire [15:0] nx = {q[14:0], fb};
    always @(posedge clk) begin
        if (rst)        q <= SEED;
        else if (load)  q <= (seed == 16'd0) ? SEED : seed;
        else if (step)  q <= (nx == 16'd0) ? SEED : nx;
    end
endmodule
