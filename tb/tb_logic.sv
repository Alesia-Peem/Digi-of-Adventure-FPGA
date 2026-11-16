// TESTBENCH ONLY. Door + Heart + Inventory + Item effect wired together.
// Verifies: damage only from door, armor absorbs, shards merge, restart restores inventory,
// code2 = 17865, hint rules, undo/freeze/slow rules.
`timescale 1ns/1ps
module tb_logic;
  import game_pkg::*;
  logic clk = 0, rst = 1;
  logic en = 1, up = 0, down = 0, left = 0, right = 0, tap = 0;
  logic checkpoint = 0, grant_valid = 0; logic [3:0] grant_item = 4'd0;
  logic use_req = 0; logic [1:0] use_sel = 2'd0;
  logic [4:0] solved = 5'd0; logic p5_seen = 0, undo_av = 0, obst = 0, tick = 0;
  logic [15:0] rnd = 16'h1234;

  wire [19:0] digits; wire [2:0] cursor, len; wire [1:0] layer;
  wire damage, layer1_ok, door_open;
  wire [1:0] hearts; wire armor_consume, hearts_zero, dmg_taken, dmg_blocked;
  wire consume_valid; wire [3:0] consume_item;
  wire [1:0] n_hh, n_hs, n_un, n_fr, n_ar; wire shard_half, has_boost, armor_available;
  wire hint_show, undo_pulse, use_denied, slow_active, freeze_active;
  wire [2:0] hint_id; wire [1:0] deny_reason; wire [3:0] slow_left, freeze_left;
  wire clear = hearts_zero;      // stage restart on 0 hearts

  always #5 clk = ~clk;

  door_lock dut_door (.clk(clk), .rst(rst), .clear(clear), .en(en), .up(up), .down(down),
    .left(left), .right(right), .tap(tap), .digits(digits), .cursor(cursor), .layer(layer),
    .len(len), .damage(damage), .layer1_ok(layer1_ok), .door_open(door_open));

  heart_system dut_heart (.clk(clk), .rst(rst), .clear(clear), .damage(damage),
    .armor_available(armor_available), .armor_consume(armor_consume), .hearts(hearts),
    .hearts_zero(hearts_zero), .damage_taken(dmg_taken), .damage_blocked(dmg_blocked));

  inventory dut_inv (.clk(clk), .rst(rst), .checkpoint(checkpoint), .restore(hearts_zero),
    .grant_valid(grant_valid), .grant_item(grant_item), .consume_valid(consume_valid),
    .consume_item(consume_item), .consume_armor(armor_consume), .consume_boost(1'b0),
    .n_hint_hard(n_hh), .n_hint_smart(n_hs), .n_undo(n_un), .n_freeze(n_fr), .n_armor(n_ar),
    .shard_half(shard_half), .has_boost(has_boost), .armor_available(armor_available));

  item_effect dut_fx (.clk(clk), .rst(rst), .clear(clear), .tick_1hz(tick), .use_req(use_req),
    .use_sel(use_sel), .n_hint_hard(n_hh), .n_hint_smart(n_hs), .n_undo(n_un), .n_freeze(n_fr),
    .solved(solved), .p5_slide_seen(p5_seen), .undo_available(undo_av), .obstacles_present(obst),
    .rnd(rnd), .grant_valid(grant_valid), .grant_item(grant_item), .consume_valid(consume_valid),
    .consume_item(consume_item), .hint_show(hint_show), .hint_id(hint_id), .undo_pulse(undo_pulse),
    .use_denied(use_denied), .deny_reason(deny_reason), .slow_active(slow_active),
    .freeze_active(freeze_active), .slow_left(slow_left), .freeze_left(freeze_left));

  integer errors = 0, n_dmg = 0, n_blocked = 0, n_open = 0, n_l1 = 0, n_dead = 0;
  integer n_denied = 0, n_hint = 0, n_undo_p = 0;
  reg [1:0] last_deny; reg [2:0] last_hint;
  always @(posedge clk) begin
    if (damage)         n_dmg     <= n_dmg + 1;
    if (dmg_blocked)    n_blocked <= n_blocked + 1;
    if (door_open)      n_open    <= n_open + 1;
    if (layer1_ok)      n_l1      <= n_l1 + 1;
    if (hearts_zero)    n_dead    <= n_dead + 1;
    if (use_denied)   begin n_denied <= n_denied + 1; last_deny <= deny_reason; end
    if (hint_show)    begin n_hint   <= n_hint + 1;   last_hint <= hint_id;     end
    if (undo_pulse)         n_undo_p <= n_undo_p + 1;
  end

  task automatic check(input cond, input [8*40-1:0] msg);
    begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", msg); end end
  endtask
  task automatic pulse_up;    begin @(negedge clk); up    = 1; @(negedge clk); up    = 0; end endtask
  task automatic pulse_right; begin @(negedge clk); right = 1; @(negedge clk); right = 0; end endtask
  task automatic pulse_tap;   begin @(negedge clk); tap   = 1; @(negedge clk); tap   = 0; end endtask
  task automatic pulse_grant(input [3:0] it);
    begin @(negedge clk); grant_item = it; grant_valid = 1; @(negedge clk); grant_valid = 0; repeat (2) @(negedge clk); end
  endtask
  task automatic use_wait(input [1:0] sel);
    begin @(negedge clk); use_sel = sel; use_req = 1; @(negedge clk); use_req = 0; repeat (4) @(negedge clk); end
  endtask
  task automatic tick_n(input integer n);
    integer k;
    begin for (k = 0; k < n; k = k + 1) begin @(negedge clk); tick = 1; @(negedge clk); tick = 0; end end
  endtask
  task automatic enter_code(input [19:0] code, input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) begin
        while (digits[4*i +: 4] != code[4*i +: 4]) pulse_up;
        pulse_right;
      end
      pulse_tap; repeat (4) @(negedge clk);
    end
  endtask

  integer d0, h0, k, seen1, seen3;

  initial begin
    $dumpfile("sim/tb_logic.vcd"); $dumpvars(0, tb_logic);
    repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);
    @(negedge clk); checkpoint = 1; @(negedge clk); checkpoint = 0;   // empty snapshot
    check(hearts == 2'd3, "hearts start at 3");

    // ---- door layer 1 wrong -> -1 heart ----
    enter_code(20'h00086, 2);                                  // "68" (wrong)
    check(n_dmg == 1 && hearts == 2'd2, "wrong L1 costs a heart");

    // ---- armor absorbs the next wrong code ----
    pulse_grant(ITEM_ARMOR);  check(n_ar == 2'd1, "armor granted");
    enter_code(20'h00086, 2);
    check(hearts == 2'd2 && n_ar == 2'd0 && n_blocked == 1, "armor absorbed damage");
    enter_code(20'h00086, 2);
    check(hearts == 2'd1, "second wrong code costs a heart");

    // ---- correct layer 1 ("69") ----
    enter_code(20'h00096, 2);
    check(layer == 2'd1 && n_l1 == 1, "layer 1 solved");
    check(dut_door.code2 == 20'h56871, "code2 digits are 1 7 8 6 5");

    // ---- armor shards merge, then absorb a wrong L2 ----
    pulse_grant(ITEM_ARMOR_SHARD); check(shard_half && n_ar == 2'd0, "1 shard = half");
    pulse_grant(ITEM_ARMOR_SHARD); check(!shard_half && n_ar == 2'd1, "2 shards = armor");
    pulse_tap; repeat (4) @(negedge clk);                       // 00000 wrong
    check(hearts == 2'd1 && n_ar == 2'd0, "armor absorbed L2 error");
    pulse_tap; repeat (6) @(negedge clk);                       // wrong again -> 0 hearts
    check(n_dead == 1, "hearts_zero pulse");
    check(hearts == 2'd3 && layer == 2'd0, "stage restarted (hearts, door)");
    check(n_ar == 2'd0 && !shard_half, "inventory restored to checkpoint");

    // ---- full solve: 69 then 17865 ----
    enter_code(20'h00096, 2);
    enter_code(20'h56871, 5);
    check(layer == 2'd2 && n_open == 1, "door opened with 17865");
    d0 = n_dmg; pulse_tap; check(n_dmg == d0, "no input after opened");

    // ---- hint (hard) ----
    d0 = n_denied; use_wait(USE_HINT_HARD);
    check(n_denied == d0 + 1 && last_deny == DENY_NO_ITEM, "hint without item denied");
    pulse_grant(ITEM_HINT_HARD); check(n_hh == 2'd1, "hint item stored");
    h0 = n_hint; use_wait(USE_HINT_HARD);
    check(n_hint == h0 + 1 && last_hint == HINT_P3 && n_hh == 2'd0, "hard hint = P3, consumed");
    pulse_grant(ITEM_HINT_HARD); solved = 5'b00100;
    d0 = n_denied; use_wait(USE_HINT_HARD);
    check(n_denied == d0 + 1 && last_deny == DENY_NOT_USEFUL && n_hh == 2'd1, "no useless hint, item kept");

    // ---- hint (smart) ----
    solved = 5'b00000; pulse_grant(ITEM_HINT_SMART); use_wait(USE_HINT_SMART);
    check(last_hint == HINT_P5_DARK, "P5 unsolved -> P5 dark hint");
    p5_seen = 1; pulse_grant(ITEM_HINT_SMART); use_wait(USE_HINT_SMART);
    check(last_hint == HINT_P5_DECODE, "P5 slide seen -> decode hint");
    solved = 5'b10001; seen1 = 0; seen3 = 0;                    // P1,P5 solved; P2 unsolved -> P3 excluded
    for (k = 0; k < 20; k = k + 1) begin
      rnd = rnd + 16'h3571; pulse_grant(ITEM_HINT_SMART); use_wait(USE_HINT_SMART);
      if (last_hint == HINT_P2) seen1 = 1;
      else if (last_hint == HINT_P4) seen3 = 1;
      else check(1'b0, "smart hint picked solved/locked puzzle");
    end
    check(seen1 == 1 && seen3 == 1, "both P2 and P4 hints occur");
    solved = 5'b11111; pulse_grant(ITEM_HINT_SMART);
    d0 = n_denied; use_wait(USE_HINT_SMART);
    check(n_denied == d0 + 1 && last_deny == DENY_NOT_USEFUL, "all solved -> no hint");

    // ---- undo ----
    d0 = n_denied; use_wait(USE_UNDO);
    check(n_denied == d0 + 1 && last_deny == DENY_NO_ITEM, "undo without item denied");
    pulse_grant(ITEM_UNDO); undo_av = 0;
    d0 = n_denied; use_wait(USE_UNDO);
    check(n_denied == d0 + 1 && last_deny == DENY_NOT_HERE && n_un == 2'd1, "undo w/o history denied, kept");
    undo_av = 1; use_wait(USE_UNDO);
    check(n_undo_p == 1 && n_un == 2'd0, "undo fired and consumed");

    // ---- freeze ----
    pulse_grant(ITEM_FREEZE); obst = 0;
    d0 = n_denied; use_wait(USE_FREEZE);
    check(n_denied == d0 + 1 && last_deny == DENY_NOT_HERE && n_fr == 2'd1, "freeze needs moving obstacles");
    obst = 1; use_wait(USE_FREEZE);
    check(freeze_active && n_fr == 2'd0, "freeze active");
    tick_n(4); check(freeze_active, "freeze still on at 4 ticks");
    tick_n(1); check(!freeze_active, "freeze ends after 5 ticks");

    // ---- slow ----
    pulse_grant(ITEM_SLOW); check(slow_active, "slow active");
    tick_n(9);  check(slow_active, "slow still on at 9 ticks");
    tick_n(1);  check(!slow_active, "slow ends after 10 ticks");

    if (errors == 0) $display("TB_LOGIC: PASS"); else $display("TB_LOGIC: FAIL (%0d)", errors);
    $finish;
  end

  initial begin #20_000_000; $display("TB_LOGIC: TIMEOUT"); $finish; end
endmodule