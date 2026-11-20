// tb_s3_cosim.v - TESTBENCH ONLY. Replays sim/s3_<sc>_stim.mem on s3_core.v, prints the state per tick in
// the column order of s3_model.py (HEADER). +STIM=... +OUT=...
`timescale 1ns/1ps
module tb_s3_cosim;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    reg gtick = 0, ev_u = 0, ev_d = 0, ev_tap = 0, enter = 0, demo_cmd = 0; reg [4:0] lvl = 0;
    reg [3:0] demo_op = 0; reg [15:0] demo_arg = 0;
    wire [3071:0] fields; wire [255:0] conds; wire [12:0] cam_px; wire [7:0] wave_ph; wire [15:0] hill_ph;
    s3_core dut (.clk(clk), .rst(rst), .gtick(gtick), .ev_u(ev_u), .ev_d(ev_d), .ev_l(1'b0), .ev_r(1'b0),
        .ev_tap(ev_tap), .ev_back(1'b0), .lvl(lvl), .enter(enter), .exit_req(), .demo_cmd(demo_cmd), .demo_op(demo_op),
        .demo_arg(demo_arg), .fields(fields), .conds(conds), .bg_mode(), .hill_ph(hill_ph), .wave_ph(wave_ph),
        .cam_px(cam_px), .seg_chars(), .leds(), .rgb16(), .rgb17());
    reg [31:0] stim [0:16383]; reg [1023:0] sf, of, ff; integer n, i, j, fd, fd2, alive, axs, acys, rx, ry;
    initial begin
        if (!$value$plusargs("STIM=%s", sf)) sf = "sim/s3_run_stim.mem";
        if (!$value$plusargs("OUT=%s", of)) of = "sim/s3_run_rtl.txt";
        for (i = 0; i < 16384; i = i + 1) stim[i] = 32'hFFFFFFFF;
        $readmemh(sf, stim); n = 0; while (n < 16384 && stim[n] !== 32'hFFFFFFFF) n = n + 1;
        if (!$value$plusargs("FOUT=%s", ff)) ff = "sim/s3_run_rtlf.txt";
        fd = $fopen(of, "w"); fd2 = $fopen(ff, "w");
        repeat (5) @(posedge clk); @(negedge clk) rst = 0;
        repeat (3000) @(posedge clk);
        for (i = 0; i < n; i = i + 1) begin
            if (stim[i][8]) begin
                @(negedge clk) begin demo_op = 4'd1; demo_arg = stim[i][23:16]; demo_cmd = 1; end
                @(negedge clk) demo_cmd = 0;
                repeat (3000) @(posedge clk);
            end else begin
                @(negedge clk) lvl = {1'b0, stim[i][1], stim[i][0], 2'b00};
                @(negedge clk) begin {ev_tap, ev_d, ev_u} = stim[i][4:2]; gtick = 1; end
                @(negedge clk) begin gtick = 0; {ev_tap, ev_d, ev_u} = 3'd0; end
                repeat (4) @(posedge clk);
                while (dut.q != 0) @(posedge clk);
            end
            repeat (3) @(posedge clk);                 // published fields settle after the sequencer
            alive = 0; axs = 0; acys = 0;
            for (j = 0; j < 23; j = j + 1) begin
                if (!dut.a_dead[j]) alive = alive + 1;
                axs = axs + dut.a_x[j]; acys = acys + dut.a_cy[j];
            end
            rx = dut.rep_on ? dut.rx : -1; ry = dut.rep_on ? dut.ry : -1;
            $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", i,
                dut.px, dut.py, dut.vy, dut.jumps, dut.coy, dut.st, dut.gt, dut.hits, dut.hc, dut.used, dut.talk,
                dut.msg_u, dut.cam, alive, rx, ry, axs & 24'hFFFFFF, acys & 24'hFFFFFF);
            $fdisplay(fd2, "%0d %h %h %0d %0d %0d", i, fields, conds, cam_px, wave_ph, hill_ph);
        end
        $fclose(fd); $fclose(fd2); $finish;
    end
endmodule
