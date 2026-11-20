// rom_sync.v - generic synchronous ROM initialised from a hex .mem file.
// One registered read port -> Vivado infers Block RAM (or LUT ROM for small depths).
// Latency: data for `addr` appears on `q` one clock after the edge that samples `addr`.
// MEM_FILE path: relative to the simulator working dir (Icarus) / added as a project
// source of type "Memory Initialization Files" in Vivado (see vivado/create_project.tcl).
`timescale 1ns/1ps
module rom_sync #(
    parameter WIDTH    = 8,
    parameter DEPTH    = 1024,
    parameter AW       = 10,
    parameter MEM_FILE = "none.mem"
) (
    input  wire             clk,
    input  wire [AW-1:0]    addr,
    output reg  [WIDTH-1:0] q
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];   // Vivado picks BRAM for big depths, LUTs for small ones
    initial $readmemh(MEM_FILE, mem);
    always @(posedge clk) q <= mem[addr];
endmodule
