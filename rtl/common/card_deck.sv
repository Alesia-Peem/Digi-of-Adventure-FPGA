// Synthesizable. FEATURE 3 (cards): shuffle + select + reveal ONE round (3 cards).
// Separation: RNG (rnd input) | Arrangement (perm) | Selection (cursor) | Item assignment (item_of)
// Arrangement = one of the 6 permutations, picked by rejection sampling (accept rnd[2:0] < 6),
// so every item appears exactly once and no mapping error is possible.
// slot_idx[2*p +: 2] = index (0..2) of the round's item list placed at screen position p (0=left).
// Round 1 list: {HINT_HARD(green), SPEED_BOOST(yellow), ARMOR(red)}
// Round 2 list: {ARMOR_SHARD, SLOW, HINT_SMART}   Round 3 list: {FREEZE, UNDO, ARMOR_SHARD}
// Renderer: round_cur==1 -> back color by slot_idx; round 2/3 -> symbol = position, set = career.
// Only face_up cards may show their front; grant_item stays valid after the reveal.
module card_deck (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,        // stage restart: forget career, go idle
  input  logic        start,        // 1-cycle pulse (ignored unless idle)
  input  logic [1:0]  round_id,     // 1..3
  input  logic [15:0] rnd,          // from lfsr16
  input  logic        en,           // UI context enabled
  input  logic        left, right, tap,
  output logic        active,       // overlay visible
  output logic [1:0]  round_cur,
  output logic [1:0]  cursor,       // 0..2
  output logic [2:0]  face_up,      // one-hot revealed card, 0 = all face-down
  output logic [5:0]  slot_idx,
  output logic [1:0]  career,       // valid when career_valid (0 air/green,1 earth/yellow,2 water/red)
  output logic        career_valid,
  output logic        grant_valid,  // 1-cycle pulse when a card is revealed
  output logic [3:0]  grant_item,
  output logic        round_done    // 1-cycle pulse when the player dismisses the reveal
);
  import game_pkg::*;

  localparam logic [1:0] S_IDLE = 2'd0, S_SAMPLE = 2'd1, S_CHOOSE = 2'd2, S_REVEAL = 2'd3;
  // entry p = {idx@pos2, idx@pos1, idx@pos0}; table = {p5,p4,p3,p2,p1,p0}
  localparam logic [35:0] PERM_TABLE = {6'b00_01_10, 6'b01_00_10, 6'b00_10_01,
                                        6'b10_00_01, 6'b01_10_00, 6'b10_01_00};

  logic [1:0] state;
  logic [2:0] perm;

  assign active   = (state != S_IDLE);
  assign slot_idx = (perm < 3'd6) ? PERM_TABLE[6*perm +: 6] : 6'b10_01_00;

  function automatic logic [3:0] item_of(input logic [1:0] r, input logic [1:0] idx);
    begin
      case (r)
        2'd1: case (idx)
                2'd0: item_of = ITEM_HINT_HARD;
                2'd1: item_of = ITEM_SPEED_BOOST;
                default: item_of = ITEM_ARMOR;
              endcase
        2'd2: case (idx)
                2'd0: item_of = ITEM_ARMOR_SHARD;
                2'd1: item_of = ITEM_SLOW;
                default: item_of = ITEM_HINT_SMART;
              endcase
        default: case (idx)
                2'd0: item_of = ITEM_FREEZE;
                2'd1: item_of = ITEM_UNDO;
                default: item_of = ITEM_ARMOR_SHARD;
              endcase
      endcase
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      state <= S_IDLE; perm <= 3'd0; round_cur <= 2'd1; cursor <= 2'd1; face_up <= 3'b000;
      career <= 2'd0; career_valid <= 1'b0;
      grant_valid <= 1'b0; grant_item <= ITEM_NONE; round_done <= 1'b0;
    end else begin
      grant_valid <= 1'b0;
      round_done  <= 1'b0;
      case (state)
        S_IDLE: begin
          if (start && round_id != 2'd0) begin
            round_cur <= round_id;
            face_up   <= 3'b000;
            state     <= S_SAMPLE;
          end
        end
        S_SAMPLE: begin   // sample ONCE: re-sample only while value is 6 or 7
          if (rnd[2:0] < 3'd6) begin
            perm   <= rnd[2:0];
            cursor <= 2'd1;
            state  <= S_CHOOSE;
          end
        end
        S_CHOOSE: begin
          if (en) begin
            if (left)       cursor <= (cursor == 2'd0) ? 2'd2 : cursor - 2'd1;
            else if (right) cursor <= (cursor == 2'd2) ? 2'd0 : cursor + 2'd1;
            else if (tap) begin
              face_up     <= (3'b001 << cursor);
              grant_valid <= 1'b1;
              grant_item  <= item_of(round_cur, slot_idx[2*cursor +: 2]);
              if (round_cur == 2'd1) begin
                career       <= slot_idx[2*cursor +: 2];
                career_valid <= 1'b1;
              end
              state <= S_REVEAL;
            end
          end
        end
        S_REVEAL: begin   // other cards stay face-down; only tap dismisses
          if (en && tap) begin
            state <= S_IDLE; face_up <= 3'b000; round_done <= 1'b1;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule