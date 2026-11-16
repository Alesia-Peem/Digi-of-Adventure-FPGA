// TESTBENCH ONLY. Phase 1: 3 rounds x 60 shuffles, checks permutation, reveal, item mapping.
// Phase 2: card_trigger schedules rounds 1,2,3 correctly.
`timescale 1ns/1ps
module tb_cards;
  import game_pkg::*;
  logic clk = 0, rst = 1, clear = 0;
  logic start = 0, en = 1, left = 0, right = 0, tap = 0;
  logic [1:0] round_id = 2'd1;
  logic use_trig = 0, stage_start = 0;
  logic [4:0] solved = 5'd0;
  wire  [15:0] rnd;
  wire  trig_start; wire [1:0] trig_rid;
  wire  deck_start = use_trig ? trig_start : start;
  wire  [1:0] deck_rid = use_trig ? trig_rid : round_id;
  wire  active, career_valid, grant_valid, round_done;
  wire  [1:0] round_cur, cursor, career;
  wire  [2:0] face_up;
  wire  [5:0] slot_idx;
  wire  [3:0] grant_item;
  integer errors = 0, n_grant = 0, n_done = 0;
  reg [5:0] perm_seen = 6'b0;

  always #5 clk = ~clk;

  lfsr16 u_lfsr (.clk(clk), .rst(rst), .en(1'b1), .q(rnd));

  card_deck dut (.clk(clk), .rst(rst), .clear(clear), .start(deck_start), .round_id(deck_rid),
    .rnd(rnd), .en(en), .left(left), .right(right), .tap(tap), .active(active),
    .round_cur(round_cur), .cursor(cursor), .face_up(face_up), .slot_idx(slot_idx),
    .career(career), .career_valid(career_valid), .grant_valid(grant_valid),
    .grant_item(grant_item), .round_done(round_done));

  card_trigger u_trig (.clk(clk), .rst(rst), .clear(clear), .stage_start(stage_start),
    .solved(solved), .deck_active(active), .round_done(round_done),
    .start(trig_start), .round_id(trig_rid));

  always @(posedge clk) begin
    if (grant_valid) n_grant <= n_grant + 1;
    if (round_done)  n_done  <= n_done  + 1;
  end

  task automatic pulse_left;  begin @(negedge clk); left  = 1; @(negedge clk); left  = 0; end endtask
  task automatic pulse_right; begin @(negedge clk); right = 1; @(negedge clk); right = 0; end endtask
  task automatic pulse_tap;   begin @(negedge clk); tap   = 1; @(negedge clk); tap   = 0; end endtask
  task automatic fail(input [8*40-1:0] msg);
    begin errors = errors + 1; $display("FAIL: %0s", msg); end
  endtask

  function automatic [3:0] exp_item(input [1:0] r, input [1:0] idx);
    begin
      if (r == 2'd1)      exp_item = (idx == 0) ? ITEM_HINT_HARD   : (idx == 1) ? ITEM_SPEED_BOOST : ITEM_ARMOR;
      else if (r == 2'd2) exp_item = (idx == 0) ? ITEM_ARMOR_SHARD : (idx == 1) ? ITEM_SLOW        : ITEM_HINT_SMART;
      else                exp_item = (idx == 0) ? ITEM_FREEZE      : (idx == 1) ? ITEM_UNDO        : ITEM_ARMOR_SHARD;
    end
  endfunction

  task automatic wait_choose;
    integer g;
    begin
      g = 0;
      while (dut.state != 2'd2 && g < 300) begin @(negedge clk); g = g + 1; end
      if (g >= 300) fail("timeout waiting for CHOOSE");
    end
  endtask

  task automatic finish_round;
    begin wait_choose; pulse_tap; repeat (3) @(negedge clk); pulse_tap; repeat (5) @(negedge clk); end
  endtask

  integer r, t, pick, g0, d0;
  reg [1:0] a, b, c, idx_pick;

  initial begin
    $dumpfile("sim/tb_cards.vcd"); $dumpvars(0, tb_cards);
    repeat (4) @(negedge clk); rst = 0; repeat (3) @(negedge clk);

    pulse_tap; repeat (3) @(negedge clk);                      // tap while idle must do nothing
    if (active || n_grant != 0) fail("idle tap changed state");

    for (r = 1; r <= 3; r = r + 1) begin
      for (t = 0; t < 60; t = t + 1) begin
        repeat (t * 7 + 3) @(negedge clk);
        round_id = r[1:0];
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait_choose;

        a = slot_idx[1:0]; b = slot_idx[3:2]; c = slot_idx[5:4];
        if (a == b || b == c || a == c || a == 2'd3 || b == 2'd3 || c == 2'd3) fail("arrangement not a permutation");
        if (dut.perm < 3'd6) perm_seen[dut.perm] = 1'b1;
        if (face_up != 3'b000) fail("cards must start face-down");

        pick = t % 3;
        if (pick == 0) pulse_left; else if (pick == 2) pulse_right;
        if (cursor != pick[1:0]) fail("cursor mismatch");

        g0 = n_grant;
        pulse_tap; repeat (3) @(negedge clk);
        idx_pick = slot_idx[2*pick +: 2];
        if (face_up != (3'b001 << pick))                fail("only chosen card may be face-up");
        if (n_grant != g0 + 1)                          fail("exactly one grant expected");
        if (grant_item != exp_item(r[1:0], idx_pick))   fail("wrong item for chosen card");
        if (r == 1 && (!career_valid || career != idx_pick)) fail("career not stored");

        pulse_left; repeat (2) @(negedge clk);          // stray input while revealed
        if (face_up != (3'b001 << pick) || n_grant != g0 + 1) fail("state changed in REVEAL");

        d0 = n_done;
        pulse_tap; repeat (3) @(negedge clk);
        if (active || n_done != d0 + 1) fail("round did not close");
      end
    end
    if (perm_seen != 6'b111111) fail("not all 6 arrangements were seen");

    // ---- Phase 2: card_trigger scheduling ----
    use_trig = 1; solved = 5'd0;
    @(negedge clk); stage_start = 1; @(negedge clk); stage_start = 0;
    repeat (20) @(negedge clk);
    if (!active || round_cur != 2'd1) fail("round 1 should start at stage start");
    finish_round;
    solved = 5'b00011; repeat (20) @(negedge clk);
    if (active) fail("round 2 must wait for 3 puzzles");
    solved = 5'b00111; repeat (20) @(negedge clk);
    if (!active || round_cur != 2'd2) fail("round 2 should start at 3 puzzles");
    finish_round;
    repeat (20) @(negedge clk);
    if (active) fail("round 3 must wait for all 5");
    solved = 5'b11111; repeat (20) @(negedge clk);
    if (!active || round_cur != 2'd3) fail("round 3 should start at 5 puzzles");
    finish_round;
    repeat (30) @(negedge clk);
    if (active) fail("no extra rounds expected");

    if (errors == 0) $display("TB_CARDS: PASS"); else $display("TB_CARDS: FAIL (%0d)", errors);
    $finish;
  end

  initial begin #50_000_000; $display("TB_CARDS: TIMEOUT"); $finish; end
endmodule