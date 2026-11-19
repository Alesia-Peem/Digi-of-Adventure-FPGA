`timescale 1ns/1ps
import stage1_pkg::*;

module tb_stage1;
    logic clk = 0, rst_n = 0, tick_60hz = 0;
    logic [15:0] sw = 0;
    logic hold_u=0, hold_d=0, hold_l=0, hold_r=0;
    logic pulse_u=0, pulse_d=0, pulse_l=0, pulse_r=0, tap_c=0, back_c=0;

    game_state_t state;
    logic in_closeup, lights, card_active, card_flipped, door_layer, has_A, has_B, has_C;
    obj_id_t cur_obj, near_obj;
    logic [1:0]  page, hearts, armor, form, card_round, card_cursor, career, spr_dir, spr_pose, p2_cur, p5_cur;
    logic [2:0]  door_cur;
    logic [3:0]  ans_A, ans_B, ans_C, p3_cur;
    logic [4:0]  done_mask, right_mask, flash_timer, hints_seen;
    logic [11:0] slow_timer, freeze_timer, px, py;
    logic [15:0] p3_truth_out;
    item_id_t    last_item;
    logic [3:0]  p2_used [0:2], p2_pol [0:2], door_dig [0:4];
    logic [2:0]  p3_cfg  [0:8];
    logic [4:0]  p5_chr  [0:2];

    stage1_core dut (.*);

    always #5 clk = ~clk; // 100 MHz

    task automatic do_tap();
        @(posedge clk); tap_c = 1; @(posedge clk); tap_c = 0; repeat(2) @(posedge clk);
    endtask

    task automatic step_frame();
        @(posedge clk); tick_60hz = 1; @(posedge clk); tick_60hz = 0;
    endtask

    initial begin
        $dumpfile("sim/tb_stage1.vcd");
        $dumpvars(0, tb_stage1);

        #20 rst_n = 1;
        repeat(3) @(posedge clk);

        // 1. Round 1 Card auto-triggers -> pick middle card & confirm
        assert(card_active == 1 && card_round == 1);
        do_tap(); // flip
        do_tap(); // close
        $display("[PASS] Card Round 1 done. Item=%0d Armor=%0d", last_item, armor);

        // 2. Walk up to Exit Door (spawn is 1300,405 -> door is 1340,300)
        hold_u = 1;
        repeat(15) step_frame();
        hold_u = 0;
        $display("Player pos=(%0d, %0d), near_obj=%0d", px, py, near_obj);

        $display("=== Stage 1 Simulation Complete ===");
        $finish;
    end
endmodule