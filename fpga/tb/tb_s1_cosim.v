// tb_s1_cosim.v - TESTBENCH ONLY. Replays a Pygame-generated input script on s1_core.v and prints the
// game state after every game tick in the same format as fpga/tools/cosim_s1.py, which then compares
// the two traces (Verilog vs the original Pygame stage1_demo.py).
//   plusargs: +STIM=sim/s1_full_stim.mem  +OUT=sim/s1_full_rtl.txt  +N=<ticks>
`timescale 1ns/1ps
module tb_s1_cosim;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        gtick = 0, ev_u = 0, ev_d = 0, ev_l = 0, ev_r = 0, ev_tap = 0, ev_back = 0;
    reg [4:0]  lvl = 0;
    reg [15:0] sw = 0;
    reg        enter = 0, demo_cmd = 0;
    reg [3:0]  demo_op = 0;
    reg [15:0] demo_arg = 0;
    wire       exit_req;
    reg        re_enter = 0, started = 0;
    // stage manager stand-in: standalone stage1_demo.py does reset_stage(True) when BTNC is pressed
    // on the clear screen (help stays closed)
    always @(posedge clk) re_enter <= exit_req;

    s1_core dut (
        .clk(clk), .rst(rst), .gtick(gtick), .ev_u(ev_u), .ev_d(ev_d), .ev_l(ev_l), .ev_r(ev_r),
        .ev_tap(ev_tap), .ev_back(ev_back), .lvl(lvl), .sw(sw),
        .enter(enter | re_enter), .help_on_entry(!started), .has_next(1'b0), .in_armor(2'd0), .in_shard(1'b0), .in_boost(1'b0),
        .exit_req(exit_req), .out_armor(), .out_shard(), .out_boost(), .out_form(),
        .demo_cmd(demo_cmd), .demo_op(demo_op), .demo_arg(demo_arg),
        .fields(), .conds(), .bg_mode(), .bg_color(), .cam_x(), .cam_y(), .seg_chars(), .leds(),
        .rgb16(), .rgb17(), .dbg_px(), .dbg_py(), .dbg_pxf(), .dbg_pyf(), .dbg_done(), .dbg_right(),
        .dbg_hearts(), .dbg_lfsr(), .dbg_state());

    reg [31:0] stim [0:8191];
    reg [1023:0] stim_file, out_file;
    integer n, i, fd;
    integer a_v, b_v, c_v, face, rnd, cursor, career, st;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) stim_file = "sim/s1_full_stim.mem";
        if (!$value$plusargs("OUT=%s", out_file))   out_file  = "sim/s1_full_rtl.txt";
        if (!$value$plusargs("N=%d", n))            n = 0;
        for (i = 0; i < 8192; i = i + 1) stim[i] = 32'hFFFFFFFF;
        $readmemh(stim_file, stim);
        if (n == 0) begin n = 0; while (n < 8192 && stim[n] !== 32'hFFFFFFFF) n = n + 1; end
        fd = $fopen(out_file, "w");
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); enter = 1; @(negedge clk); enter = 0;               // Game.__init__ -> reset_stage(True), help on
        started = 1;
        repeat (10) @(posedge clk);
        @(negedge clk); demo_op = 4'd13; demo_arg = 16'h1D2C; demo_cmd = 1; // g.lfsr = SEED
        @(negedge clk); demo_cmd = 0;
        repeat (10) @(posedge clk);
        // all stimulus changes on the FALLING edge -> no race with the design's rising-edge logic
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            lvl = stim[i][3:0];
            sw  = stim[i][26:11];
            @(negedge clk);
            {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} = stim[i][10:5];
            gtick = 1;
            @(negedge clk);
            gtick = 0; {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} = 6'd0;
            repeat (300) @(posedge clk);
            a_v = dut.ans_v[0] ? dut.ans_a : -1;
            b_v = dut.ans_v[1] ? dut.ans_b : -1;
            c_v = dut.ans_v[2] ? dut.ans_c : -1;
            rnd    = dut.dk_active ? dut.dk_rnd : 0;
            cursor = dut.dk_active ? dut.dk_cursor : 0;
            face   = (dut.dk_active && dut.dk_face_up) ? dut.dk_face : -1;
            career = dut.dk_cvalid ? dut.career : -1;
            st     = dut.state;
            $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                i, dut.px_i * 10 + dut.px_f, dut.py_i * 10 + dut.py_f, dut.mode_cu, dut.mode_cu ? dut.cur : 0,
                dut.page, dut.done, dut.right, dut.hearts, dut.armor, dut.lfsr, dut.dk_active, rnd, cursor, face,
                st, dut.lights, dut.door_layer, a_v, b_v, c_v, dut.sdir, dut.spose, dut.form, career,
                dut.shard, dut.boost, dut.show_help, dut.slow_f != 0, dut.freeze_f != 0);
        end
        $fclose(fd);
        $display("tb_s1_cosim: %0d ticks written to %0s", n, out_file);
        $finish;
    end
endmodule
