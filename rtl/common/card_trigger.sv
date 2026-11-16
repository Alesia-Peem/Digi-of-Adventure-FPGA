// Synthesizable. Decides WHEN each card round starts (Stage 1 policy).
//  R1: at stage start | R2: >=3 puzzles solved | R3: all 5 solved. Strictly sequential.
module card_trigger (
  input  logic       clk,
  input  logic       rst,
  input  logic       clear,
  input  logic       stage_start,   // 1-cycle pulse
  input  logic [4:0] solved,
  input  logic       deck_active,
  input  logic       round_done,
  output logic       start,         // to card_deck
  output logic [1:0] round_id
);
  logic r1_req, r1_run, r1_done, r2_run, r2_done, r3_run;
  logic [1:0] last;
  wire [2:0] cnt = {2'b00, solved[0]} + {2'b00, solved[1]} + {2'b00, solved[2]}
                 + {2'b00, solved[3]} + {2'b00, solved[4]};

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      r1_req <= 1'b0; r1_run <= 1'b0; r1_done <= 1'b0; r2_run <= 1'b0; r2_done <= 1'b0;
      r3_run <= 1'b0; last <= 2'd0; start <= 1'b0; round_id <= 2'd1;
    end else begin
      start <= 1'b0;
      if (stage_start) r1_req <= 1'b1;
      if (round_done) begin
        case (last)
          2'd1: r1_done <= 1'b1;
          2'd2: r2_done <= 1'b1;
          default: ;
        endcase
      end
      if (!deck_active && !start) begin
        if (r1_req && !r1_run) begin
          start <= 1'b1; round_id <= 2'd1; last <= 2'd1; r1_run <= 1'b1;
        end else if (r1_done && !r2_run && cnt >= 3'd3) begin
          start <= 1'b1; round_id <= 2'd2; last <= 2'd2; r2_run <= 1'b1;
        end else if (r2_done && !r3_run && cnt == 3'd5) begin
          start <= 1'b1; round_id <= 2'd3; last <= 2'd3; r3_run <= 1'b1;
        end
      end
    end
  end
endmodule