// tb_s1_feedback.v - TESTBENCH ONLY. Replays fpga/sim/s1_fb_stim.mem (written by tools/s1_feedback.py from the
// NEW demo_py/stage1_demo.py) on s1_core.v and prints the answer / feedback state after every game tick.
//   stim word: [3:0] held buttons (unused here), [10:5] events {back,tap,r,l,d,u}, [26:11] switches,
//              bit 31 = set-up step: put the player into close-up [2:0] (page 0, no message) between two ticks
//   plusargs:  +STIM=sim/s1_fb_stim.mem  +OUT=sim/s1_fb_rtl.txt
// Before the script: help closed (demo op 14) and all three card rounds marked as run, so no card round opens
// (the Pygame side does the same; help / intro / cards / notebook guide are not part of this check).
`timescale 1ns/1ps
module tb_s1_feedback;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        gtick = 0, ev_u = 0, ev_d = 0, ev_l = 0, ev_r = 0, ev_tap = 0, ev_back = 0;
    reg [4:0]  lvl = 0;
    reg [15:0] sw = 0;
    reg        enter = 0, demo_cmd = 0;
    reg [3:0]  demo_op = 0;
    reg [15:0] demo_arg = 0;

    s1_core dut (
        .clk(clk), .rst(rst), .gtick(gtick), .ev_u(ev_u), .ev_d(ev_d), .ev_l(ev_l), .ev_r(ev_r),
        .ev_tap(ev_tap), .ev_back(ev_back), .lvl(lvl), .sw(sw),
        .enter(enter), .help_on_entry(1'b1), .has_next(1'b0), .in_armor(2'd0), .in_shard(1'b0), .in_boost(1'b0),
        .exit_req(), .out_armor(), .out_shard(), .out_boost(), .out_form(),
        .demo_cmd(demo_cmd), .demo_op(demo_op), .demo_arg(demo_arg),
        .fields(), .conds(), .bg_mode(), .bg_color(), .cam_x(), .cam_y(), .seg_chars(), .leds(),
        .rgb16(), .rgb17(), .dbg_px(), .dbg_py(), .dbg_pxf(), .dbg_pyf(), .dbg_done(), .dbg_right(),
        .dbg_hearts(), .dbg_lfsr(), .dbg_state());

    reg [31:0] stim [0:4095];
    reg [1023:0] stim_file, out_file;
    integer n, i, fd;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) stim_file = "sim/s1_fb_stim.mem";
        if (!$value$plusargs("OUT=%s", out_file))   out_file  = "sim/s1_fb_rtl.txt";
        for (i = 0; i < 4096; i = i + 1) stim[i] = 32'hFFFFFFFF;
        $readmemh(stim_file, stim);
        n = 0; while (n < 4096 && stim[n] !== 32'hFFFFFFFF) n = n + 1;
        fd = $fopen(out_file, "w");
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); enter = 1; @(negedge clk); enter = 0;
        repeat (10) @(posedge clk);
        @(negedge clk); demo_op = 4'd14; demo_cmd = 1;                        // help closed
        @(negedge clk); demo_cmd = 0;
        repeat (10) @(posedge clk);
        @(negedge clk); dut.r_run = 3'b111; dut.r_done = 3'b111;              // no card round
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            sw = stim[i][26:11];
            if (stim[i][31]) begin
                dut.mode_cu = 1'b1; dut.cur = stim[i][2:0]; dut.page = 2'd0; dut.cmsg = 8'd0;
                repeat (5) @(posedge clk);
            end else begin
                lvl = stim[i][3:0];
                @(negedge clk);
                {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} = stim[i][10:5];
                gtick = 1;
                @(negedge clk);
                gtick = 0; {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} = 6'd0;
                repeat (300) @(posedge clk);
            end
            $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                i, dut.mode_cu, dut.cur, dut.page, dut.done, dut.right, dut.ans_v, dut.ans_a, dut.ans_b, dut.ans_c,
                dut.cmsg, dut.cmsg_p, dut.toast, dut.toast_t, dut.p2_eq, dut.note_n,
                dut.note_t[0], dut.note_t[1], dut.note_t[2], dut.note_t[3],
                dut.note_t[4], dut.note_t[5], dut.note_t[6], dut.note_t[7]);
        end
        $fclose(fd);
        $display("tb_s1_feedback: %0d ticks written to %0s", n, out_file);
        $finish;
    end
endmodule
