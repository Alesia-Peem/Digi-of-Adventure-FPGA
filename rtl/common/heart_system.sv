// Synthesizable. FEATURE 3 / Stage rule: hearts.
// !! `damage` MUST be connected ONLY to door_lock.damage. Puzzle errors never reach this module. !!
// Armor policy: if armor_available, a damage event is absorbed (armor_consume pulse) and hearts stay.
module heart_system #(parameter logic [1:0] MAX_HEARTS = 2'd3) (
  input  logic       clk,
  input  logic       rst,
  input  logic       clear,            // stage restart
  input  logic       damage,           // from door_lock ONLY
  input  logic       armor_available,  // from inventory
  output logic       armor_consume,    // to inventory (same-cycle, combinational)
  output logic [1:0] hearts,
  output logic       hearts_zero,      // 1-cycle pulse -> stage controller restarts the stage
  output logic       damage_taken,     // 1-cycle pulse (UI flash)
  output logic       damage_blocked    // 1-cycle pulse (armor flash)
);
  assign armor_consume = damage & armor_available & (hearts != 2'd0);

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      hearts <= MAX_HEARTS; hearts_zero <= 1'b0; damage_taken <= 1'b0; damage_blocked <= 1'b0;
    end else begin
      hearts_zero <= 1'b0; damage_taken <= 1'b0; damage_blocked <= 1'b0;
      if (damage && hearts != 2'd0) begin
        if (armor_available) begin
          damage_blocked <= 1'b1;
        end else begin
          hearts       <= hearts - 2'd1;
          damage_taken <= 1'b1;
          if (hearts == 2'd1) hearts_zero <= 1'b1;
        end
      end
    end
  end
endmodule