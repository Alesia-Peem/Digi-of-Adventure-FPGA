// heart_system.v - FEATURE 3 / stage rule: hearts. Same rule as door_damage() / damage() in Pygame:
//   damage while armor > 0  -> armor_consume pulse, hearts unchanged ("ARMOR PROTECTED!")
//   damage without armor    -> hearts - 1, `hit` pulse (red flash); reaching 0 -> `dead` pulse
// !! `damage` may ONLY come from the door / QA controller. Puzzle answers never reach this module. !!
`timescale 1ns/1ps
module heart_system #(parameter [1:0] MAX_HEARTS = 2'd3) (
    input  wire       clk,
    input  wire       rst,
    input  wire       clear,          // stage (re)start -> full hearts
    input  wire       set_en,         // demo hub "Hearts n"
    input  wire [1:0] set_val,
    input  wire       damage,
    input  wire       armor_avail,
    output wire       armor_consume,
    output reg  [1:0] hearts,
    output reg        hit,
    output reg        blocked,
    output reg        dead
);
    assign armor_consume = damage & armor_avail;
    always @(posedge clk) begin
        if (rst || clear) begin
            hearts <= MAX_HEARTS; hit <= 1'b0; blocked <= 1'b0; dead <= 1'b0;
        end else begin
            hit <= 1'b0; blocked <= 1'b0; dead <= 1'b0;
            if (set_en) hearts <= (set_val == 2'd0) ? 2'd1 : set_val;   // set_hearts clamps to 1..3
            else if (damage) begin
                if (armor_avail) blocked <= 1'b1;
                else begin
                    hit <= 1'b1;
                    if (hearts <= 2'd1) begin hearts <= 2'd0; dead <= 1'b1; end
                    else hearts <= hearts - 2'd1;
                end
            end
        end
    end
endmodule
