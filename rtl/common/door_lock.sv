// Synthesizable. Two-layer door password. Layer 1 = 2 digits ("69"), Layer 2 = 5 digits.
// Layer 2 code is derived from A,B,C: S=A+B+C; pre = {A,B,C,S/10,S%10}; code[i] = pre[ORD[i]].
// With A=6,B=7,C=5 -> S=18 -> pre=6 7 5 1 8 -> order(0-based)=3,1,4,0,2 -> 1 7 8 6 5.
// digits[4*i +: 4] is digit i (i=0 is the LEFTMOST box). A/B/C must be single digits (1..9).
// Only a wrong confirm produces `damage` (wired to heart_system).
module door_lock #(
  parameter logic [3:0] A = 4'd6, B = 4'd7, C = 4'd5,
  parameter logic [3:0] L1_D0 = 4'd6, L1_D1 = 4'd9     // 'E' = ASCII 69
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,
  input  logic        en,
  input  logic        up, down, left, right, tap,
  output logic [19:0] digits,
  output logic [2:0]  cursor,
  output logic [1:0]  layer,       // 0 = layer1, 1 = layer2, 2 = open
  output logic [2:0]  len,         // digit boxes in the current layer (2 or 5)
  output logic        damage,      // 1-cycle pulse on wrong code
  output logic        layer1_ok,   // 1-cycle pulse
  output logic        door_open    // 1-cycle pulse
);
  localparam int SUM = {28'd0, A} + {28'd0, B} + {28'd0, C};
  localparam logic [3:0]  S_TENS = SUM / 10;
  localparam logic [3:0]  S_ONES = SUM % 10;
  localparam logic [19:0] PRE    = {S_ONES, S_TENS, C, B, A};            // digit i at [4i+:4]
  localparam logic [14:0] ORD    = {3'd2, 3'd0, 3'd4, 3'd1, 3'd3};       // ORD[3i+:3] = source of digit i
  localparam logic [19:0] L1_VEC = {12'd0, L1_D1, L1_D0};

  logic [19:0] code2;
  genvar gi;
  generate
    for (gi = 0; gi < 5; gi = gi + 1) begin : g_code2
      assign code2[4*gi +: 4] = PRE[4*ORD[3*gi +: 3] +: 4];
    end
  endgenerate

  assign len = (layer == 2'd0) ? 3'd2 : 3'd5;
  wire [19:0] mask   = (layer == 2'd0) ? 20'h000FF : 20'hFFFFF;
  wire [19:0] expect_v = (layer == 2'd0) ? L1_VEC : code2;
  wire        match  = (((digits ^ expect_v) & mask) == 20'd0);
  wire [3:0]  cur_d  = digits[4*cursor +: 4];

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      digits <= 20'd0; cursor <= 3'd0; layer <= 2'd0;
      damage <= 1'b0; layer1_ok <= 1'b0; door_open <= 1'b0;
    end else begin
      damage <= 1'b0; layer1_ok <= 1'b0; door_open <= 1'b0;
      if (en && layer != 2'd2) begin
        if (up)
          digits[4*cursor +: 4] <= (cur_d == 4'd9) ? 4'd0 : cur_d + 4'd1;
        else if (down)
          digits[4*cursor +: 4] <= (cur_d == 4'd0) ? 4'd9 : cur_d - 4'd1;
        else if (left)
          cursor <= (cursor == 3'd0) ? len - 3'd1 : cursor - 3'd1;
        else if (right)
          cursor <= (cursor == len - 3'd1) ? 3'd0 : cursor + 3'd1;
        else if (tap) begin
          if (match) begin
            digits <= 20'd0; cursor <= 3'd0;
            if (layer == 2'd0) begin layer <= 2'd1; layer1_ok <= 1'b1; end
            else               begin layer <= 2'd2; door_open <= 1'b1; end
          end else begin
            damage <= 1'b1;   // digits are kept so the player can fix one digit
          end
        end
      end
    end
  end
endmodule