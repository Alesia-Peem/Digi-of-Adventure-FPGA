// vga_timing.v - 640x480 @ 60 Hz VGA timing (industry standard 800 x 525 total).
// Runs in the 100 MHz system clock domain; `pix_ce` (1 cycle in 4) is the 25 MHz pixel strobe,
// so there is no second clock and no clock-domain crossing anywhere in the design.
// (25.000 MHz instead of 25.175 MHz gives 59.5 Hz; every VGA monitor accepts this.)
//
// Outputs are valid for the pixel (hcount, vcount) during the pix_ce cycle.
//   active     : 1 inside the visible 640x480 area
//   hsync/vsync: active-LOW pulses (640x480 standard polarity)
//   line_start : 1-cycle pulse (with pix_ce) at hcount == 0 of every line
//   frame_end  : 1-cycle pulse (with pix_ce) at the first pixel of vblank (hcount 0, vcount 480)
`timescale 1ns/1ps
module vga_timing (
    input  wire       clk,
    input  wire       rst,
    output reg        pix_ce,
    output reg  [9:0] hcount,
    output reg  [9:0] vcount,
    output wire       active,
    output wire       hsync,
    output wire       vsync,
    output wire       line_start,
    output wire       frame_end
);
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_BP = 48, H_TOT = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33, V_TOT = 525;

    reg [1:0] div;
    always @(posedge clk) begin
        if (rst) begin
            div <= 2'd0; pix_ce <= 1'b0;
        end else begin
            div    <= div + 2'd1;
            pix_ce <= (div == 2'd3);
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            hcount <= 10'd0; vcount <= 10'd0;
        end else if (pix_ce) begin
            if (hcount == H_TOT - 1) begin
                hcount <= 10'd0;
                vcount <= (vcount == V_TOT - 1) ? 10'd0 : vcount + 10'd1;
            end else begin
                hcount <= hcount + 10'd1;
            end
        end
    end

    assign active     = (hcount < H_VIS) && (vcount < V_VIS);
    assign hsync      = ~((hcount >= H_VIS + H_FP) && (hcount < H_VIS + H_FP + H_SYNC));
    assign vsync      = ~((vcount >= V_VIS + V_FP) && (vcount < V_VIS + V_FP + V_SYNC));
    assign line_start = pix_ce && (hcount == 10'd0);
    assign frame_end  = pix_ce && (hcount == 10'd0) && (vcount == V_VIS);
endmodule
