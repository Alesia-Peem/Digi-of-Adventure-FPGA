// reset_sync.v - asynchronous assert, synchronous release. CPU_RESETN is active LOW; rst is active HIGH.
// (converted from rtl/common/reset_sync.sv - logic unchanged)
`timescale 1ns/1ps
module reset_sync (
    input  wire clk,
    input  wire rst_n_async,
    output wire rst
);
    reg [1:0] ff;
    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) ff <= 2'b00;
        else              ff <= {ff[0], 1'b1};
    end
    assign rst = ~ff[1];
endmodule
