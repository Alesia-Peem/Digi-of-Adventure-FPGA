// button_unit.v - one push button: 2-FF synchroniser -> debounce -> level / press / tap / long_press.
//   level      debounced level (hold-to-walk)
//   press      1-cycle pulse when the button goes down (menu navigation = Pygame KEYDOWN)
//   tap        1-cycle pulse on RELEASE if it was held < LONG_CYCLES (Pygame: Space released early)
//   long_press 1-cycle pulse once when held >= LONG_CYCLES (Pygame: LONG_PRESS_S = 0.8 s -> "back")
// (converted from rtl/common/button_unit.sv - verified behaviour kept)
`timescale 1ns/1ps
module button_unit #(
    parameter DEBOUNCE_CYCLES = 1000000,    // 10 ms @ 100 MHz
    parameter LONG_CYCLES     = 80000000,   // 0.8 s @ 100 MHz
    parameter DW = 20,
    parameter LW = 27
) (
    input  wire clk,
    input  wire rst,
    input  wire raw,
    output reg  level,
    output wire press,
    output reg  tap,
    output reg  long_press
);
    reg s1, s2, level_d, long_fired;
    reg [DW-1:0] dcnt;
    reg [LW-1:0] hcnt;
    always @(posedge clk) begin
        if (rst) begin s1 <= 1'b0; s2 <= 1'b0; end
        else     begin s1 <= raw;  s2 <= s1;   end
    end
    always @(posedge clk) begin
        if (rst) begin
            level <= 1'b0; dcnt <= {DW{1'b0}};
        end else if (s2 != level) begin
            if (dcnt == DEBOUNCE_CYCLES - 1) begin level <= s2; dcnt <= {DW{1'b0}}; end
            else dcnt <= dcnt + 1'b1;
        end else dcnt <= {DW{1'b0}};
    end
    always @(posedge clk) begin
        if (rst) level_d <= 1'b0; else level_d <= level;
    end
    assign press = level & ~level_d;
    always @(posedge clk) begin
        if (rst) begin
            hcnt <= {LW{1'b0}}; long_fired <= 1'b0; long_press <= 1'b0; tap <= 1'b0;
        end else begin
            long_press <= 1'b0; tap <= 1'b0;
            if (level) begin
                if (!long_fired) begin
                    if (hcnt == LONG_CYCLES - 1) begin long_press <= 1'b1; long_fired <= 1'b1; end
                    else hcnt <= hcnt + 1'b1;
                end
            end else begin
                if (level_d && !long_fired) tap <= 1'b1;
                hcnt <= {LW{1'b0}}; long_fired <= 1'b0;
            end
        end
    end
endmodule
