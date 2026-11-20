// input_hub.v - conditions the 5 buttons + 16 switches and turns them into PER-GAME-TICK events.
// Pygame polls its events once per frame; here pulses that happen between two game ticks are
// latched and handed to the game on the next `tick` (ev_* are valid during that tick cycle only),
// so a short press can never be lost and is never seen twice.
//   btn_raw order: [0]=BTNU [1]=BTND [2]=BTNL [3]=BTNR [4]=BTNC
//   lvl  : debounced levels (walking uses levels, like pygame.key.get_pressed())
//   ev_u/d/l/r : press events (KEYDOWN)   ev_tap : BTNC short tap   ev_back : BTNC long press
`timescale 1ns/1ps
module input_hub #(
    parameter DEBOUNCE_CYCLES = 1000000,
    parameter LONG_CYCLES     = 80000000,
    parameter DW = 20,
    parameter LW = 27
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,
    input  wire [4:0]  btn_raw,
    input  wire [15:0] sw_raw,
    output wire [4:0]  lvl,
    output reg         ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back,
    output reg         gtick,      // = tick delayed 1 cycle, aligned with ev_* : the game steps on this
    output reg  [15:0] sw
);
    wire [4:0] press, tap, lng;
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : g_btn
            button_unit #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .LONG_CYCLES(LONG_CYCLES), .DW(DW), .LW(LW)) u_btn (
                .clk(clk), .rst(rst), .raw(btn_raw[i]),
                .level(lvl[i]), .press(press[i]), .tap(tap[i]), .long_press(lng[i]));
        end
    endgenerate

    reg [5:0] pend;   // {back, tap, r, l, d, u} seen since the last tick
    always @(posedge clk) begin
        gtick <= rst ? 1'b0 : tick;
        if (rst) begin
            pend <= 6'd0; {ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back} <= 6'd0;
        end else if (tick) begin
            {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} <= pend | {lng[4], tap[4], press[3:0]};
            pend <= 6'd0;
        end else begin
            {ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back} <= 6'd0;
            pend <= pend | {lng[4], tap[4], press[3:0]};
        end
    end

    reg [15:0] sw_m;
    always @(posedge clk) begin
        if (rst) begin sw_m <= 16'd0; sw <= 16'd0; end
        else     begin sw_m <= sw_raw; sw <= sw_m; end
    end
endmodule
