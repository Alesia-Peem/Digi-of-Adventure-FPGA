// Synthesizable (constants only). Compile this file FIRST.
package game_pkg;
  // ---- Item IDs (global, 4 bit) ----
  localparam logic [3:0] ITEM_NONE        = 4'd0;
  localparam logic [3:0] ITEM_HINT_HARD   = 4'd1;  // green card: hint of hardest puzzle (P3)
  localparam logic [3:0] ITEM_SPEED_BOOST = 4'd2;  // yellow card
  localparam logic [3:0] ITEM_ARMOR       = 4'd3;  // red card
  localparam logic [3:0] ITEM_ARMOR_SHARD = 4'd4;
  localparam logic [3:0] ITEM_SLOW        = 4'd5;
  localparam logic [3:0] ITEM_HINT_SMART  = 4'd6;
  localparam logic [3:0] ITEM_FREEZE      = 4'd7;
  localparam logic [3:0] ITEM_UNDO        = 4'd8;

  // ---- Manual-use selector (inventory overlay) ----
  localparam logic [1:0] USE_HINT_HARD = 2'd0, USE_HINT_SMART = 2'd1,
                         USE_UNDO      = 2'd2, USE_FREEZE     = 2'd3;

  // ---- Hint IDs (renderer maps id -> text) ----
  localparam logic [2:0] HINT_P1 = 3'd0, HINT_P2 = 3'd1, HINT_P3 = 3'd2, HINT_P4 = 3'd3,
                         HINT_P5_DARK = 3'd4, HINT_P5_DECODE = 3'd5, HINT_NONE = 3'd7;

  // ---- Use-denied reasons ----
  localparam logic [1:0] DENY_NONE = 2'd0, DENY_NO_ITEM = 2'd1,
                         DENY_NOT_USEFUL = 2'd2, DENY_NOT_HERE = 2'd3;

  // ---- Career (round 1) ----
  localparam logic [1:0] CAREER_AIR = 2'd0, CAREER_EARTH = 2'd1, CAREER_WATER = 2'd2;

  // ---- Puzzle solved-vector index: [0]=P1 [1]=P2 [2]=P3 [3]=P4 [4]=P5 ----

  // ---- Stage 1 answers (design proposal; verified by hand) ----
  localparam logic [3:0]  ANS_A = 4'd6;            // P1  (SW3:0 = 0110)
  localparam logic [3:0]  ANS_B = 4'd7;            // P2+P3 (count of F=1)
  localparam logic [3:0]  ANS_C = 4'd5;            // P4  (popcount of 11110100)
  localparam logic [15:0] P2_TRUTH_TABLE = 16'hF888; // F = AB + CD
  localparam logic [7:0]  P4_GIVEN  = 8'b0000_1100;
  localparam logic [7:0]  P4_ANSWER = 8'b1111_0100;
endpackage