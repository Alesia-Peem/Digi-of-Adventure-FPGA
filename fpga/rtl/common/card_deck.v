// card_deck.v - FEATURE 3: one round of the random card system (3 face-down cards).
// Same behaviour as card_start() / cards_input() in the Pygame demos:
//   * the stage passes `perm` = index 0..5 into itertools.permutations([0,1,2]) (chosen with its LFSR,
//     rejection-sampled so all 6 orders are equally likely, ONCE per round - never re-shuffled per frame)
//   * slot p shows item list index perm[p]  -> each item appears exactly once, nothing is lost
//   * cursor starts on the middle card; L/R move (wraps), BTNC turns the card (grant), BTNC again closes
//   * round 1 also sets the CAREER = colour of the turned card (0 air/green 1 earth/yellow 2 water/red)
// CARD_ITEMS: 1 = {HINT_HARD, BOOST, ARMOR}  2 = {SHARD, SLOW, HINT_SMART}  3 = {FREEZE, UNDO, SHARD}
`timescale 1ns/1ps
module card_deck (
    input  wire       clk,
    input  wire       rst,
    input  wire       clear,
    input  wire       start,          // pulse: open a round
    input  wire [1:0] start_round,    // 1..3
    input  wire [2:0] start_perm,     // 0..5
    input  wire       en,             // the stage routes input here this tick
    input  wire       ev_l, ev_r, ev_tap,
    input  wire       set_career,     // demo jump_to: career without playing round 1
    input  wire [1:0] set_career_v,
    output reg        active,
    output reg  [1:0] round,
    output reg  [2:0] perm,
    output reg  [1:0] cursor,
    output reg        face_up,
    output reg  [1:0] face,
    output reg        grant,
    output reg  [3:0] grant_item,
    output reg  [1:0] career,
    output reg        career_valid,
    output reg        round_done
);
`include "game_defs.vh"
    // perm table: slot p -> item index, itertools.permutations([0,1,2]) order
    function [1:0] pidx(input [2:0] pm, input [1:0] p);
        reg [5:0] t;
        begin
            case (pm)
                3'd0: t = {2'd2, 2'd1, 2'd0};   // (0,1,2)  stored {slot2,slot1,slot0}
                3'd1: t = {2'd1, 2'd2, 2'd0};   // (0,2,1)
                3'd2: t = {2'd2, 2'd0, 2'd1};   // (1,0,2)
                3'd3: t = {2'd0, 2'd2, 2'd1};   // (1,2,0)
                3'd4: t = {2'd1, 2'd0, 2'd2};   // (2,0,1)
                default: t = {2'd0, 2'd1, 2'd2};// (2,1,0)
            endcase
            pidx = (p == 2'd0) ? t[1:0] : (p == 2'd1) ? t[3:2] : t[5:4];
        end
    endfunction
    function [3:0] item_of(input [1:0] r, input [1:0] i);
        case (r)
            2'd1: item_of = (i == 2'd0) ? IT_HINT_HARD : (i == 2'd1) ? IT_BOOST : IT_ARMOR;
            2'd2: item_of = (i == 2'd0) ? IT_SHARD : (i == 2'd1) ? IT_SLOW : IT_HINT_SMART;
            default: item_of = (i == 2'd0) ? IT_FREEZE : (i == 2'd1) ? IT_UNDO : IT_SHARD;
        endcase
    endfunction
    wire [1:0] cur_idx = pidx(perm, cursor);
    always @(posedge clk) begin
        grant <= 1'b0; round_done <= 1'b0;
        if (rst || clear) begin
            active <= 1'b0; round <= 2'd1; perm <= 3'd0; cursor <= 2'd1; face_up <= 1'b0; face <= 2'd0;
            grant_item <= IT_NONE;
            career <= set_career ? set_career_v : 2'd0;       // jump_to() sets the career while clearing
            career_valid <= set_career && !rst;
        end else begin
            if (set_career) begin career <= set_career_v; career_valid <= 1'b1; end
            if (start) begin
                active <= 1'b1; round <= start_round; perm <= start_perm; cursor <= 2'd1; face_up <= 1'b0;
            end else if (active && en) begin
                if (!face_up) begin
                    if (ev_l)       cursor <= (cursor == 2'd0) ? 2'd2 : cursor - 2'd1;
                    else if (ev_r)  cursor <= (cursor == 2'd2) ? 2'd0 : cursor + 2'd1;
                    else if (ev_tap) begin
                        face_up <= 1'b1; face <= cursor;
                        grant <= 1'b1; grant_item <= item_of(round, cur_idx);
                        if (round == 2'd1) begin career <= cur_idx; career_valid <= 1'b1; end
                    end
                end else if (ev_tap) begin
                    active <= 1'b0; face_up <= 1'b0; round_done <= 1'b1;
                end
            end
        end
    end
    // image of slot p for the renderer (see asset_convert.py memory map)
endmodule
