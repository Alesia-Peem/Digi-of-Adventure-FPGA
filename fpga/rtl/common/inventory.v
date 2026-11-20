// inventory.v - FEATURE 3: inventory + item-effect timers, shared by every stage.
//   STORE_MODE 0 (Stage 1 rules, grant() in stage1_demo.py): effects happen when the card is turned:
//       ARMOR +1 (max 3) | SHARD: 2 shards forge 1 armor | BOOST flag | SLOW 10 s | FREEZE 5 s
//       hints / undo are applied by the stage itself (they change puzzle state)
//   STORE_MODE 1 (Stage 2 rules, grant() in stage2_demo.py): hint / undo / freeze go into counters
//       (max 3) and are used later from the inventory overlay (use_* inputs).
//   Armor, shards and the boost flag are carried between stages (load_* at stage entry);
//   `restore` puts back the values the stage started with (stage restart after 0 hearts).
// Timers count game frames (60 per second) and only run while `run` is 1 (normal play).
`timescale 1ns/1ps
module inventory (
    input  wire       clk,
    input  wire       rst,
    input  wire       tick,
    input  wire       run,
    input  wire       store_mode,
    // stage entry / restart
    input  wire       load,            // pulse: take the values below and remember them
    input  wire [1:0] load_armor,
    input  wire       load_shard,
    input  wire       load_boost,
    input  wire       restore,         // pulse: back to the values loaded at stage entry
    // events
    input  wire       grant,           // card turned (1-cycle)
    input  wire [3:0] grant_item,
    input  wire       armor_consume,   // from heart_system
    input  wire       add_armor,       // demo hub "Give 1 Armor"
    input  wire       use_hh, use_hs, use_undo, use_freeze,   // Stage-2 inventory use (already checked)
    input  wire       boost_consume,
    // state
    output reg  [1:0] armor,
    output reg        shard,
    output reg        boost,
    output reg  [1:0] n_hh, n_hs, n_undo, n_freeze,
    output reg  [9:0] slow_f,          // frames left
    output reg  [8:0] freeze_f,
    output reg        forged           // 1-cycle: the last grant merged 2 shards into armor
);
`include "game_defs.vh"
    reg [1:0] s_armor; reg s_shard, s_boost;
    wire [1:0] armor_up = (armor == 2'd3) ? 2'd3 : armor + 2'd1;
    function [1:0] inc3(input [1:0] x); inc3 = (x == 2'd3) ? 2'd3 : x + 2'd1; endfunction
    always @(posedge clk) begin
        forged <= 1'b0;
        if (rst) begin
            armor <= 2'd0; shard <= 1'b0; boost <= 1'b0; n_hh <= 2'd0; n_hs <= 2'd0; n_undo <= 2'd0;
            n_freeze <= 2'd0; slow_f <= 10'd0; freeze_f <= 9'd0;
            s_armor <= 2'd0; s_shard <= 1'b0; s_boost <= 1'b0;
        end else if (load) begin
            armor <= load_armor; shard <= load_shard; boost <= load_boost;
            s_armor <= load_armor; s_shard <= load_shard; s_boost <= load_boost;
            n_hh <= 2'd0; n_hs <= 2'd0; n_undo <= 2'd0; n_freeze <= 2'd0; slow_f <= 10'd0; freeze_f <= 9'd0;
        end else if (restore) begin
            armor <= s_armor; shard <= s_shard; boost <= s_boost;
            n_hh <= 2'd0; n_hs <= 2'd0; n_undo <= 2'd0; n_freeze <= 2'd0; slow_f <= 10'd0; freeze_f <= 9'd0;
        end else begin
            if (tick && run) begin
                if (slow_f != 10'd0) slow_f <= slow_f - 10'd1;
                if (freeze_f != 9'd0) freeze_f <= freeze_f - 9'd1;
            end
            if (armor_consume && armor != 2'd0) armor <= armor - 2'd1;
            else if (add_armor) armor <= armor_up;
            if (boost_consume) boost <= 1'b0;
            if (use_hh && n_hh != 2'd0) n_hh <= n_hh - 2'd1;
            if (use_hs && n_hs != 2'd0) n_hs <= n_hs - 2'd1;
            if (use_undo && n_undo != 2'd0) n_undo <= n_undo - 2'd1;
            if (use_freeze && n_freeze != 2'd0) n_freeze <= n_freeze - 2'd1;
            if (grant) begin
                case (grant_item)
                    IT_ARMOR: armor <= armor_up;
                    IT_BOOST: boost <= 1'b1;
                    IT_SLOW:  slow_f <= 10'd600;
                    IT_SHARD: if (shard) begin shard <= 1'b0; armor <= armor_up; forged <= 1'b1; end
                              else shard <= 1'b1;
                    IT_FREEZE: if (store_mode) n_freeze <= inc3(n_freeze); else freeze_f <= 9'd300;
                    IT_HINT_HARD:  if (store_mode) n_hh <= inc3(n_hh);
                    IT_HINT_SMART: if (store_mode) n_hs <= inc3(n_hs);
                    IT_UNDO:       if (store_mode) n_undo <= inc3(n_undo);
                    default: ;
                endcase
            end
        end
    end
endmodule
