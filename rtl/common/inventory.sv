// Synthesizable. FEATURE 3 (inventory). Persists across stages.
// checkpoint = save snapshot (pulse at stage entry); restore = reload it (stage restart).
// Shards: 2 shards -> +1 Armor (automatic). Armor saturates at 3.
module inventory (
  input  logic       clk,
  input  logic       rst,
  input  logic       checkpoint,
  input  logic       restore,
  input  logic       grant_valid,
  input  logic [3:0] grant_item,
  input  logic       consume_valid,     // manual items (from item_effect)
  input  logic [3:0] consume_item,
  input  logic       consume_armor,     // from heart_system
  input  logic       consume_boost,     // from a stage that uses Speed Boost
  output logic [1:0] n_hint_hard,
  output logic [1:0] n_hint_smart,
  output logic [1:0] n_undo,
  output logic [1:0] n_freeze,
  output logic [1:0] n_armor,
  output logic       shard_half,        // 1 = holding one shard
  output logic       has_boost,
  output logic       armor_available
);
  import game_pkg::*;

  logic [1:0] nx_hh, nx_hs, nx_un, nx_fr, nx_ar;
  logic       nx_sh, nx_bo;
  logic [11:0] snap;

  assign armor_available = (n_armor != 2'd0);

  always_comb begin
    nx_hh = n_hint_hard; nx_hs = n_hint_smart; nx_un = n_undo; nx_fr = n_freeze;
    nx_ar = n_armor;     nx_sh = shard_half;   nx_bo = has_boost;

    if (consume_valid) begin
      case (consume_item)
        ITEM_HINT_HARD:  if (n_hint_hard  != 2'd0) nx_hh = n_hint_hard  - 2'd1;
        ITEM_HINT_SMART: if (n_hint_smart != 2'd0) nx_hs = n_hint_smart - 2'd1;
        ITEM_UNDO:       if (n_undo       != 2'd0) nx_un = n_undo       - 2'd1;
        ITEM_FREEZE:     if (n_freeze     != 2'd0) nx_fr = n_freeze     - 2'd1;
        default: ;
      endcase
    end
    if (consume_armor && n_armor != 2'd0) nx_ar = nx_ar - 2'd1;
    if (consume_boost && has_boost)       nx_bo = 1'b0;

    if (grant_valid) begin
      case (grant_item)
        ITEM_HINT_HARD:   if (nx_hh != 2'd3) nx_hh = nx_hh + 2'd1;
        ITEM_HINT_SMART:  if (nx_hs != 2'd3) nx_hs = nx_hs + 2'd1;
        ITEM_UNDO:        if (nx_un != 2'd3) nx_un = nx_un + 2'd1;
        ITEM_FREEZE:      if (nx_fr != 2'd3) nx_fr = nx_fr + 2'd1;
        ITEM_ARMOR:       if (nx_ar != 2'd3) nx_ar = nx_ar + 2'd1;
        ITEM_SPEED_BOOST: nx_bo = 1'b1;
        ITEM_ARMOR_SHARD: begin
          if (nx_sh) begin
            nx_sh = 1'b0;
            if (nx_ar != 2'd3) nx_ar = nx_ar + 2'd1;
          end else begin
            nx_sh = 1'b1;
          end
        end
        default: ;   // ITEM_SLOW has no slot (auto effect in item_effect)
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      n_hint_hard <= 2'd0; n_hint_smart <= 2'd0; n_undo <= 2'd0; n_freeze <= 2'd0;
      n_armor <= 2'd0; shard_half <= 1'b0; has_boost <= 1'b0; snap <= 12'd0;
    end else begin
      if (restore)
        {n_hint_hard, n_hint_smart, n_undo, n_freeze, n_armor, shard_half, has_boost} <= snap;
      else
        {n_hint_hard, n_hint_smart, n_undo, n_freeze, n_armor, shard_half, has_boost}
          <= {nx_hh, nx_hs, nx_un, nx_fr, nx_ar, nx_sh, nx_bo};
      if (checkpoint)
        snap <= {n_hint_hard, n_hint_smart, n_undo, n_freeze, n_armor, shard_half, has_boost};
    end
  end
endmodule