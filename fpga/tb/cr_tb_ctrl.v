// cr_tb_ctrl.v - TESTBENCH ONLY. Button / command timing of cr_core.v at 2 steps per tick (the board):
//   1 enter with jump, skill and menu pulses in the same clock: a new game, none of the presses acts
//   2 one skill pulse with one tick (2 steps) casts once: Phase, skill = T_SKILL - 1 after the 2nd step
//   3 a command arriving while a step runs is kept and applied afterwards
//   4 a restart (STAGE) finishes within 1000 clocks, far below one tick (1 666 667 clocks)
//   5 on the WIN screen a jump or a menu press confirms (exit_req), as Space / Enter in the hub wrapper
//   6 a STAGE command with stage 0 is ignored (stage 0 would address beyond the level ROMs)
`timescale 1ns/1ps
module cr_tb_ctrl;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg gtick = 0, ej = 0, es = 0, em = 0, enter = 0, dcmd = 0;
    reg [3:0] dop = 0; reg [15:0] darg = 0; reg [6:0] q_idx = 0;
    wire busy, step_done, exit_req; wire [2:0] mode; wire [1:0] level; wire [12:0] cam_px; wire [39:0] q_data;
    wire [3071:0] fields; wire [255:0] conds;
    cr_core #(.MEM_DIR("mem/"), .STEPS_PER_TICK(2)) dut (
        .clk(clk), .rst(rst), .gtick(gtick), .btn_left(1'b0), .btn_right(1'b0), .ev_jump(ej), .ev_skill(es),
        .ev_menu(em), .enter(enter), .demo_cmd(dcmd), .demo_op(dop), .demo_arg(darg), .exit_req(exit_req),
        .step_done(step_done), .busy(busy), .mode(mode), .level(level), .cam_px(cam_px), .fields(fields),
        .conds(conds), .q_idx(q_idx), .q_data(q_data));
`include "cr_consts.vh"
    integer bad = 0, t;
    task check; input ok; input [8*48-1:0] what;
        begin
            if (!ok) begin $display("FAIL %0s", what); bad = bad + 1; end
        end
    endtask
    task idle; begin @(negedge clk); while (busy) @(negedge clk); end endtask
    task command; input [3:0] op; input [15:0] arg;
        begin @(negedge clk) begin dop = op; darg = arg; dcmd = 1; end @(negedge clk) dcmd = 0; idle; end
    endtask
    initial begin
        repeat (5) @(posedge clk); @(negedge clk) rst = 0;
        idle;
        // 1
        command(4'd1, 16'd3);
        @(negedge clk) begin enter = 1; gtick = 1; ej = 1; es = 1; em = 1; end
        @(negedge clk) begin enter = 0; gtick = 0; ej = 0; es = 0; em = 0; end
        idle;
        check(dut.stage == 1 && dut.mode_r == 0, "1: enter -> new game at level 1, playing");
        check(dut.used == 0 && dut.jumps == 0, "1: no skill, no jump from presses with enter");
        check(dut.message == CR_MSG_NEW, "1: 'New game' message");
        // 2
        command(4'd1, 16'd3);
        @(negedge clk) begin gtick = 1; es = 1; end
        @(negedge clk) begin gtick = 0; es = 0; end
        idle;
        check(dut.used == 1 && dut.skill == CR_T_SKILL - 1, "2: Phase cast once in a 2-step tick");
        @(negedge clk) gtick = 1; @(negedge clk) gtick = 0; idle;
        check(dut.skill == CR_T_SKILL - 3, "2: the next tick does not cast again");
        // 3
        @(negedge clk) gtick = 1;
        @(negedge clk) gtick = 0;
        @(negedge clk) begin dop = 4'd2; darg = 16'd200 | (16'd16 << 9) | (16'd1 << 14); dcmd = 1; end
        @(negedge clk) dcmd = 0;
        check(busy, "3: the step is still running when the command arrives");
        idle;
        check(dut.xf == 200 * CR_HALF_CELL && dut.yf == 16 * CR_HALF_CELL, "3: PUT applied after the step");
        // 4
        @(negedge clk) begin dop = 4'd1; darg = 16'd2; dcmd = 1; end
        @(negedge clk) dcmd = 0;
        t = 0; while (busy) begin @(negedge clk); t = t + 1; end
        check(t < 1000 && dut.stage == 2, "4: restart finishes fast");
        // 5
        command(4'd1, 16'd3);
        command(4'd2, 16'd495 | (16'd4 << 9) | (16'd1 << 14));      // at the N16 door, x 247.5 m, y 2 m
        repeat (3) begin @(negedge clk) gtick = 1; @(negedge clk) gtick = 0; idle; end
        check(dut.mode_r == 3 && !exit_req, "5: WIN screen, not confirmed yet");
        @(negedge clk) begin gtick = 1; ej = 1; end
        @(negedge clk) begin gtick = 0; ej = 0; end
        idle;
        check(exit_req, "5: jump press confirms the WIN screen");
        command(4'd1, 16'd3);
        command(4'd2, 16'd495 | (16'd4 << 9) | (16'd1 << 14));
        repeat (3) begin @(negedge clk) gtick = 1; @(negedge clk) gtick = 0; idle; end
        @(negedge clk) begin gtick = 1; em = 1; end
        @(negedge clk) begin gtick = 0; em = 0; end
        idle;
        check(exit_req && dut.mode_r == 3, "5: menu press confirms on the WIN screen");
        // 6
        command(4'd1, 16'd2);
        command(4'd2, 16'd40 | (16'd8 << 9));                       // somewhere else, 20 m
        command(4'd1, 16'd0);                                       // stage 0 does not exist: ignored
        check(dut.stage == 2 && dut.xf == 40 * CR_HALF_CELL, "6: STAGE 0 is ignored (no restart)");
        $display("CR_TB_CTRL: %s (%0d failed; restart took %0d clocks)", bad ? "FAIL" : "PASS", bad, t);
        $finish;
    end
endmodule
