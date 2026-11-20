// tick_gen.v - one-cycle pulse every PERIOD clock cycles.
// Used for the 60 Hz game tick (PERIOD = 1_666_667 @ 100 MHz -> 59.99998 Hz) so game speed and
// timers match the Pygame demos (which run at 60 FPS) and do NOT depend on the VGA refresh rate.
`timescale 1ns/1ps
module tick_gen #(
    parameter PERIOD = 1666667,
    parameter W      = 21
) (
    input  wire clk,
    input  wire rst,
    output reg  tick
);
    reg [W-1:0] cnt;
    always @(posedge clk) begin
        if (rst) begin
            cnt <= {W{1'b0}}; tick <= 1'b0;
        end else if (cnt == PERIOD - 1) begin
            cnt <= {W{1'b0}}; tick <= 1'b1;
        end else begin
            cnt <= cnt + 1'b1; tick <= 1'b0;
        end
    end
endmodule
