// demo_menu.v - on-board version of demo_hub.py (development / demonstration tool).
// While SW12 is ON the buttons drive this menu instead of the game:
//   BTNU / BTND : choose the command (shown on the 7-segment display as "dE  nn")
//   BTNC        : run it                      SW1..SW0 : argument for "hearts" / "form"
//   01 jump: start of stage        02 jump: 3 puzzles answered (card round 2)
//   03 jump: 5 puzzles answered (round 3)     04 jump: all cards done, at the door
//   05 jump: stage 1 cleared       06 action: at the door, notebook has a WRONG value
//   07 action: give 1 armor        08 set hearts = SW1..0 (0 -> 1)
//   09 set form = SW1..0           10 toggle collision debug view
//   11 answer the next puzzle (F5) 12 restart the stage
//   13 go to Stage 1               14 go to Stage 2
//   Stage 2 meanings: 06 skill ready (F9)  07 armor  08 hearts  09 form  11 all 18 parts (F7)  12 restart
//                     15 auto-wire the breadboard (F8)
// The same command bus (cmd/op/arg) is what the testbenches use for game-state injection, so a
// skipped state is set by exactly the same code as on the board (jump_to() of the Pygame demo).
`timescale 1ns/1ps
module demo_menu (
    input  wire        clk,
    input  wire        rst,
    input  wire        on,
    input  wire        gtick,
    input  wire        ev_u, ev_d, ev_tap,
    input  wire [15:0] sw,
    output reg         cmd,
    output reg  [3:0]  op,
    output wire [15:0] arg,
    output wire [39:0] seg_chars
);
    reg [3:0] sel;
    assign arg = {14'd0, sw[1:0]};
    always @(posedge clk) begin
        cmd <= 1'b0;
        if (rst) begin sel <= 4'd1; op <= 4'd0; end
        else if (on && gtick) begin
            if (ev_u)      sel <= (sel == 4'd15) ? 4'd1 : sel + 4'd1;
            else if (ev_d) sel <= (sel == 4'd1) ? 4'd15 : sel - 4'd1;
            else if (ev_tap) begin cmd <= 1'b1; op <= sel; end
        end
    end
    // "dE" then the command number, right aligned
    wire [4:0] tens = (sel >= 4'd10) ? 5'd1 : 5'd12;
    wire [4:0] ones = (sel >= 4'd10) ? {1'b0, sel - 4'd10} : {1'b0, sel};
    assign seg_chars = {5'd21, 5'd13, 5'd12, 5'd12, 5'd12, 5'd12, tens, ones};
endmodule
