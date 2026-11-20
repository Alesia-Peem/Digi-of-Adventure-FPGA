// tb_s2_cosim.v - TESTBENCH ONLY. Replays a Pygame-generated input script (tools/cosim_s2.py) on s2_core.v
// and prints the state after every game tick in the same column order as cosim_s2.py (HEADER).
//   plusargs: +STIM=sim/s2_full_stim.mem  +OUT=sim/s2_full_rtl.txt
`timescale 1ns/1ps
module tb_s2_cosim;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg        gtick = 0, ev_u = 0, ev_d = 0, ev_l = 0, ev_r = 0, ev_tap = 0, ev_back = 0;
    reg [4:0]  lvl = 0;
    reg [15:0] sw = 0;
    reg        enter = 0, demo_cmd = 0, started = 0, re_enter = 0;
    reg [3:0]  demo_op = 0;
    reg [15:0] demo_arg = 0;
    wire       exit_req;
    always @(posedge clk) re_enter <= exit_req;

    s2_core dut (.clk(clk), .rst(rst), .gtick(gtick), .ev_u(ev_u), .ev_d(ev_d), .ev_l(ev_l), .ev_r(ev_r),
        .ev_tap(ev_tap), .ev_back(ev_back), .lvl(lvl), .sw(sw), .enter(enter | re_enter), .help_on_entry(!started),
        .has_next(1'b0), .in_armor(2'd0), .in_shard(1'b0), .in_boost(1'b0), .exit_req(exit_req), .out_armor(),
        .out_shard(), .out_boost(), .out_form(), .demo_cmd(demo_cmd), .demo_op(demo_op), .demo_arg(demo_arg),
        .fields(), .conds(), .bg_mode(), .bg_color(), .zoom_ox(), .zoom_oy(), .zoom_inv(), .wire_src(),
        .src_val(), .wire_hl(), .seg_chars(), .seg_raw_en(), .seg_raw(), .leds(), .rgb16(), .rgb17());

    reg [31:0] stim [0:16383];
    reg [1023:0] stim_file, out_file;
    integer n, i, j, fd, guard;
    integer codes, whash, wcnt, nx, ny, tag, ti, face, rnd_o, cursor, career, spots, hints;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) stim_file = "sim/s2_full_stim.mem";
        if (!$value$plusargs("OUT=%s", out_file))   out_file  = "sim/s2_full_rtl.txt";
        for (i = 0; i < 16384; i = i + 1) stim[i] = 32'hFFFFFFFF;
        $readmemh(stim_file, stim);
        n = 0; while (n < 16384 && stim[n] !== 32'hFFFFFFFF) n = n + 1;
        fd = $fopen(out_file, "w");
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); enter = 1; @(negedge clk); enter = 0;
        started = 1;
        repeat (10) @(posedge clk);
        @(negedge clk); demo_op = 4'd13; demo_arg = 16'h1D2C; demo_cmd = 1;
        @(negedge clk); demo_cmd = 0;
        repeat (40) @(posedge clk);
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            lvl = stim[i][3:0]; sw = stim[i][26:11];
            @(negedge clk);
            {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} = stim[i][10:5]; gtick = 1;
            @(negedge clk);
            gtick = 0; {ev_back, ev_tap, ev_r, ev_l, ev_d, ev_u} = 6'd0;
            repeat (4) @(posedge clk);
            guard = 0;
            while (dut.q != 0 && guard < 200000) begin @(posedge clk); guard = guard + 1; end
            repeat (4) @(posedge clk);
            codes = dut.codes_v ? dut.code0 * 8 + dut.code1 : -1;
            whash = 0; wcnt = 0;
            for (j = 0; j < 54; j = j + 1) begin
                whash = (whash + (j + 1) * dut.w[5 * j +: 5]) % 1000003;
                if (dut.w[5 * j +: 5] != 0) wcnt = wcnt + 1;
            end
            nx = (dut.npc != 0) ? dut.npc_q[31:16] >> 6 : 0;
            ny = (dut.npc != 0) ? dut.npc_q[15:0] >> 6 : 0;
            tag = dut.talk_on ? dut.talk_k : 0; ti = dut.talk_on ? dut.talk_i : 0;
            rnd_o = dut.dk_active ? dut.dk_rnd : 0; cursor = dut.dk_active ? dut.dk_cursor : 0;
            face = (dut.dk_active && dut.dk_face_up) ? dut.dk_face : -1;
            career = dut.dk_cvalid ? dut.career : -1;
            spots = dut.done_spots; hints = dut.read_hints;
            $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                i, dut.px_i * 100 + dut.px_f, dut.py_i * 100 + dut.py_f, dut.mode_cu, dut.mode_cu ? dut.cur : 0,
                dut.page, dut.parts_total, spots, hints, dut.rnd, codes, whash, wcnt, dut.wcur, dut.wpick,
                dut.hearts, dut.armor, dut.n_hh, dut.n_hs, dut.n_un, dut.n_fr, dut.shard, dut.boost, dut.slow,
                dut.lfsr, dut.dk_active, rnd_o, cursor, face, career, dut.npc, nx, ny, dut.talk_on, tag, ti,
                dut.skill_t, dut.skill_used, dut.play_t, dut.zoom_on, dut.zoom_on ? dut.zt : 0, dut.hp_on,
                dut.state, dut.show_help, dut.intro_started, dut.cutscene, dut.sdir, dut.spose, dut.inv_cur,
                dut.note_n);
        end
        $fclose(fd);
        $display("tb_s2_cosim: %0d ticks", n);
        $finish;
    end
endmodule
