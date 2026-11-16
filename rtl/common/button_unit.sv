// Synthesizable. One button: 2-FF sync -> debounce -> press / tap / long_press.
//  level      : debounced level (use for walking, hold-to-move)
//  press      : 1-cycle pulse on press (use for menu navigation)
//  tap        : 1-cycle pulse on RELEASE if held shorter than LONG_CYCLES (confirm)
//  long_press : 1-cycle pulse once when held >= LONG_CYCLES (back)
module button_unit #(
  parameter int DEBOUNCE_CYCLES = 1_000_000,   // 10 ms @100 MHz
  parameter int LONG_CYCLES     = 80_000_000   // 0.8 s  @100 MHz
) (
  input  logic clk,
  input  logic rst,
  input  logic raw,
  output logic level,
  output logic press,
  output logic tap,
  output logic long_press
);
  localparam int DW = $clog2(DEBOUNCE_CYCLES + 1);
  localparam int LW = $clog2(LONG_CYCLES + 1);

  logic s1, s2, level_d, long_fired;
  logic [DW-1:0] dcnt;
  logic [LW-1:0] hcnt;

  // synchronizer
  always_ff @(posedge clk) begin
    if (rst) begin s1 <= 1'b0; s2 <= 1'b0; end
    else     begin s1 <= raw;  s2 <= s1;   end
  end

  // debounce: accept a new level only after it is stable for DEBOUNCE_CYCLES
  always_ff @(posedge clk) begin
    if (rst) begin
      level <= 1'b0; dcnt <= '0;
    end else if (s2 != level) begin
      if (dcnt == DEBOUNCE_CYCLES-1) begin level <= s2; dcnt <= '0; end
      else                           dcnt <= dcnt + 1'b1;
    end else begin
      dcnt <= '0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) level_d <= 1'b0; else level_d <= level;
  end
  assign press = level & ~level_d;

  // hold timing: tap on short release, long_press once while held
  always_ff @(posedge clk) begin
    if (rst) begin
      hcnt <= '0; long_fired <= 1'b0; long_press <= 1'b0; tap <= 1'b0;
    end else begin
      long_press <= 1'b0;
      tap        <= 1'b0;
      if (level) begin
        if (!long_fired) begin
          if (hcnt == LONG_CYCLES-1) begin long_press <= 1'b1; long_fired <= 1'b1; end
          else                       hcnt <= hcnt + 1'b1;
        end
      end else begin
        if (level_d && !long_fired) tap <= 1'b1;
        hcnt <= '0; long_fired <= 1'b0;
      end
    end
  end
endmodule