// Synthesizable (combinational). Picks the target of a "smart" hint.
//  P5 unsolved  -> P5 hint (DARK before the slide was seen, DECODE after)
//  else         -> random among UNSOLVED P1..P4 (P3 only if P2 solved)
//  nothing left -> valid = 0 (caller must not consume the item)
module hint_selector (
  input  logic [4:0]  solved,
  input  logic        p5_slide_seen,
  input  logic [15:0] rnd,
  output logic        valid,
  output logic [2:0]  id
);
  import game_pkg::*;
  logic [3:0] cand;
  logic [2:0] cnt;
  logic [1:0] sel;
  integer i, k;

  always_comb begin
    cand = {~solved[3], (~solved[2]) & solved[1], ~solved[1], ~solved[0]};
    cnt  = {2'b00, cand[0]} + {2'b00, cand[1]} + {2'b00, cand[2]} + {2'b00, cand[3]};
    case (cnt)
      3'd2:    sel = {1'b0, rnd[0]};
      3'd3:    sel = (rnd[1:0] == 2'd3) ? 2'd0 : rnd[1:0];
      3'd4:    sel = rnd[1:0];
      default: sel = 2'd0;
    endcase

    valid = 1'b0;
    id    = HINT_NONE;
    k     = 0;
    if (!solved[4]) begin
      valid = 1'b1;
      id    = p5_slide_seen ? HINT_P5_DECODE : HINT_P5_DARK;
    end else if (cnt != 3'd0) begin
      valid = 1'b1;
      for (i = 0; i < 4; i = i + 1) begin
        if (cand[i]) begin
          if (k == sel) id = i[2:0];
          k = k + 1;
        end
      end
    end
  end
endmodule