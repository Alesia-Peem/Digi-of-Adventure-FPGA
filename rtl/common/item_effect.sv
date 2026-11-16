// Synthesizable. FEATURE 3 (item effect controller): checks use conditions, drives real effects.
// Outputs are what a Stage consumes: hint_show/hint_id, undo_pulse, slow_active, freeze_active.
// Timers decrement on tick_1hz, so a "10 s" effect lasts 9..10 s (prescaler phase).
module item_effect #(
  parameter logic [3:0] SLOW_SECONDS   = 4'd10,
  parameter logic [3:0] FREEZE_SECONDS = 4'd5
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,
  input  logic        tick_1hz,
  // manual use request (from inventory overlay)
  input  logic        use_req,
  input  logic [1:0]  use_sel,
  // inventory counts
  input  logic [1:0]  n_hint_hard, n_hint_smart, n_undo, n_freeze,
  // game conditions
  input  logic [4:0]  solved,
  input  logic        p5_slide_seen,
  input  logic        undo_available,      // some puzzle holds an undoable edit
  input  logic        obstacles_present,   // moving obstacles exist (Stage 3)
  input  logic [15:0] rnd,
  // card grants (for auto effects)
  input  logic        grant_valid,
  input  logic [3:0]  grant_item,
  // to inventory
  output logic        consume_valid,
  output logic [3:0]  consume_item,
  // effects
  output logic        hint_show,
  output logic [2:0]  hint_id,
  output logic        undo_pulse,
  output logic        use_denied,
  output logic [1:0]  deny_reason,
  output logic        slow_active,
  output logic        freeze_active,
  output logic [3:0]  slow_left,
  output logic [3:0]  freeze_left
);
  import game_pkg::*;

  logic       sm_valid;
  logic [2:0] sm_id;
  hint_selector u_sel (.solved(solved), .p5_slide_seen(p5_slide_seen), .rnd(rnd),
                       .valid(sm_valid), .id(sm_id));

  assign slow_active   = (slow_left   != 4'd0);
  assign freeze_active = (freeze_left != 4'd0);

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      consume_valid <= 1'b0; consume_item <= ITEM_NONE;
      hint_show <= 1'b0; hint_id <= HINT_NONE; undo_pulse <= 1'b0;
      use_denied <= 1'b0; deny_reason <= DENY_NONE;
      slow_left <= 4'd0; freeze_left <= 4'd0;
    end else begin
      consume_valid <= 1'b0; hint_show <= 1'b0; undo_pulse <= 1'b0; use_denied <= 1'b0;

      if (tick_1hz) begin
        if (slow_left   != 4'd0) slow_left   <= slow_left   - 4'd1;
        if (freeze_left != 4'd0) freeze_left <= freeze_left - 4'd1;
      end

      if (grant_valid && grant_item == ITEM_SLOW) slow_left <= SLOW_SECONDS;  // auto effect

      if (use_req) begin
        case (use_sel)
          USE_HINT_HARD: begin
            if (n_hint_hard == 2'd0)  begin use_denied <= 1'b1; deny_reason <= DENY_NO_ITEM; end
            else if (solved[2])       begin use_denied <= 1'b1; deny_reason <= DENY_NOT_USEFUL; end
            else begin
              consume_valid <= 1'b1; consume_item <= ITEM_HINT_HARD;
              hint_show <= 1'b1;     hint_id <= HINT_P3;
            end
          end
          USE_HINT_SMART: begin
            if (n_hint_smart == 2'd0) begin use_denied <= 1'b1; deny_reason <= DENY_NO_ITEM; end
            else if (!sm_valid)       begin use_denied <= 1'b1; deny_reason <= DENY_NOT_USEFUL; end
            else begin
              consume_valid <= 1'b1; consume_item <= ITEM_HINT_SMART;
              hint_show <= 1'b1;     hint_id <= sm_id;
            end
          end
          USE_UNDO: begin
            if (n_undo == 2'd0)       begin use_denied <= 1'b1; deny_reason <= DENY_NO_ITEM; end
            else if (!undo_available) begin use_denied <= 1'b1; deny_reason <= DENY_NOT_HERE; end
            else begin
              consume_valid <= 1'b1; consume_item <= ITEM_UNDO; undo_pulse <= 1'b1;
            end
          end
          USE_FREEZE: begin
            if (n_freeze == 2'd0)     begin use_denied <= 1'b1; deny_reason <= DENY_NO_ITEM; end
            else if (!obstacles_present || freeze_left != 4'd0)
                                      begin use_denied <= 1'b1; deny_reason <= DENY_NOT_HERE; end
            else begin
              consume_valid <= 1'b1; consume_item <= ITEM_FREEZE; freeze_left <= FREEZE_SECONDS;
            end
          end
          default: ;
        endcase
      end
    end
  end
endmodule