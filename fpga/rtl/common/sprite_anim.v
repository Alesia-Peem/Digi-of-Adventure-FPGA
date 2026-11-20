// sprite_anim.v - FEATURE 1/2: player facing + walk cycle, identical to player_sprite.py:
//   * right/left input wins over up/down; facing is kept when you stop
//   * walking starts with the LEFT leg: cycle stepl, stand, stepr, stand, 0.14 s per frame
//   * stopping (or any non-walking mode) -> stand pose, timer reset
// Time is counted in 1/600 s: one game tick adds 10, a walk frame lasts 84 (= 0.14 s) -> exact.
// dir: 0 front 1 back 2 left 3 right   pose: 0 stand 1 stepl 2 stepr
`timescale 1ns/1ps
// CYCLE2 = 1: the Stage-2 PlayerSprite (stage2_demo.py): cycle stand, stepl, stand, stepr and the timer
//             already counts the first walking tick (t = t + dt while moving, 0 when not).
module sprite_anim #(parameter CYCLE2 = 0) (
    input  wire       clk,
    input  wire       rst,
    input  wire       reset_dir,      // reset(): face front
    input  wire       upd,            // 1-cycle: PlayerSprite.update(dt, dx, dy, moved)
    input  wire       stop,           // 1-cycle: PlayerSprite.stop()
    input  wire [1:0] dxs,            // {valid, positive}: 2'b11 = +1, 2'b10 = -1, 2'b0x = 0
    input  wire [1:0] dys,
    input  wire       moved,
    output reg  [1:0] dir,
    output wire [1:0] pose
);
    reg        moving;
    reg  [6:0] sub;      // 0..83
    reg  [1:0] ph;       // index into WALK_CYCLE
    assign pose = !moving ? 2'd0 :
                  CYCLE2 ? ((ph == 2'd1) ? 2'd1 : (ph == 2'd3) ? 2'd2 : 2'd0) :
                           ((ph == 2'd0) ? 2'd1 : (ph == 2'd2) ? 2'd2 : 2'd0);
    always @(posedge clk) begin
        if (rst || reset_dir) begin
            dir <= 2'd0; moving <= 1'b0; sub <= 7'd0; ph <= 2'd0;
        end else if (stop) begin
            moving <= 1'b0; sub <= 7'd0; ph <= 2'd0;
        end else if (upd) begin
            if (dxs[1])      dir <= dxs[0] ? 2'd3 : 2'd2;
            else if (dys[1]) dir <= dys[0] ? 2'd0 : 2'd1;
            if (moved) begin
                if (moving) begin
                    // exact rational timing (t / 0.14 s); see docs/VERIFICATION.md about float ties in Pygame
                    if (sub + 7'd10 >= 7'd84) begin sub <= sub + 7'd10 - 7'd84; ph <= ph + 2'd1; end
                    else sub <= sub + 7'd10;
                end else begin
                    moving <= 1'b1; sub <= CYCLE2 ? 7'd10 : 7'd0; ph <= 2'd0;
                end
            end else begin
                moving <= 1'b0; sub <= 7'd0; ph <= 2'd0;
            end
        end
    end
endmodule
