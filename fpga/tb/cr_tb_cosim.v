// cr_tb_cosim.v - TESTBENCH ONLY. Replays sim/cr_<name>_stim.mem on cr_core.v and prints, after every game step,
// the columns of cr_model.Model.HEADER (cr_cosim.py cmp compares them with the model).
//   word: [0] left [1] right [2] jump [3] skill [4] menu      or  [8] command, [15:12] op, [31:16] argument
//   +STIM=sim/cr_x_stim.mem +OUT=sim/cr_x_rtl.txt      parameter PHYS=1: no animals, no lifts (Task 7 stimulus)
//   parameter STEPS: steps per tick (1 = one step per stimulus word; 2 = the board)
`timescale 1ns/1ps
module cr_tb_cosim;
    parameter PHYS = 0;      // cr_core TEST_MODE: 0 full game, 1 no animals/lifts, 2 animals without lifts and hits
    parameter STEPS = 1;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg gtick = 0, bl = 0, br = 0, ej = 0, es = 0, em = 0, enter = 0, dcmd = 0;
    reg [3:0] dop = 0; reg [15:0] darg = 0;
    wire busy, step_done, exit_req; wire [2:0] mode; wire [1:0] level; wire [12:0] cam_px; wire [31:0] q_data;
    cr_core #(.MEM_DIR("mem/"), .STEPS_PER_TICK(STEPS), .TEST_MODE(PHYS)) dut (
        .clk(clk), .rst(rst), .gtick(gtick), .btn_left(bl), .btn_right(br), .ev_jump(ej), .ev_skill(es),
        .ev_menu(em), .enter(enter), .demo_cmd(dcmd), .demo_op(dop), .demo_arg(darg), .exit_req(exit_req),
        .step_done(step_done), .busy(busy), .mode(mode), .level(level), .cam_px(cam_px), .q_idx(6'd0),
        .q_data(q_data));

    reg [31:0] stim [0:262143];
    reg [1023:0] sf, of;
    integer n, i, fd, steps, worst, t;
    // one line per step, in HEADER order (cr_model.Model.HEADER)
    reg [31:0] ex, ey, eexp, fx, fy, fm; reg [63:0] eact, ealive; integer j, fk;
    integer xbad = 0;
    always @(posedge clk) if (step_done) begin
        // registers that steer the sequencer or index memories must never be unknown (review finding I2)
        if (^{dut.tr_tail, dut.tr_cnt, dut.rt_head, dut.rt_cnt, dut.lfsr, dut.mode_r, dut.stage, dut.xf, dut.yf,
              dut.n_ents, dut.ex_v, dut.chase, dut.follow, dut.retreat, dut.interview, dut.tea_on, dut.rx, dut.ry} === 1'bx) begin
            if (xbad < 3) $display("UNKNOWN register value at step %0d (tr_tail=%h tr_cnt=%h)", steps, dut.tr_tail, dut.tr_cnt);
            xbad = xbad + 1;
        end
        ex = 0; ey = 0; eexp = 0; eact = 0; ealive = 0;
        for (j = 0; j < dut.n_ents; j = j + 1) begin
            ex = ex + (j + 1) * dut.e_x[j];
            ey = ey + (j + 1) * dut.e_y[j];
            eexp = eexp + (j + 1) * dut.e_exp[j];
            eact[j] = dut.e_active[j];
            ealive[j] = dut.e_alive[j];
        end
        $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d ", steps,
            dut.mode_r, dut.stage, dut.xf, dut.yf, dut.vyf, dut.gf, dut.vxf, dut.jumps, dut.elapsed, dut.grounded,
            dut.grace, dut.buffer, dut.face_l ? -1 : 1, dut.walking, dut.cam, dut.stride, dut.time_left);
        $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d ",
            dut.skill, dut.used, dut.chase, dut.interview, dut.protection, dut.follow, dut.retreat, dut.flash,
            dut.notice, dut.message, dut.gold, dut.opened, dut.tea_on, dut.tea_on ? dut.tea_x : 0,
            dut.tea_on ? dut.tea_y : 0, dut.lifts_on ? dut.lt0 : 0, dut.lifts_on ? dut.lt1 : 0);
        $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d ",
            dut.rx, dut.ry, dut.rdir_l ? -1 : 1, dut.rvisible, dut.rwalking, dut.q0, dut.q1,
            (dut.mode_r == 2 || dut.mode_r == 3) ? 100 : dut.prog, dut.near, dut.grow, dut.exit_req);
        fx = 0; fy = 0; fm = 0;
        for (j = 0; j < dut.fp_cnt; j = j + 1) begin
            fk = (dut.fp_head + j) % 128;
            fx = fx + (j + 1) * dut.fp_x[fk];
            fy = fy + (j + 1) * dut.fp_y[fk];
            fm = fm + (j + 1) * (dut.fp_t[fk] * 64 + dut.fp_k[fk] * 4 + (dut.fp_dl[fk] ? 0 : 2) + (dut.fp_sn[fk] ? 0 : 1));
        end
        $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", dut.lfsr, ex, ey, eact, ealive, eexp, dut.contacts,
                  dut.fp_cnt, fx, fy, fm);
        steps = steps + 1;
    end
    initial begin
        if (!$value$plusargs("STIM=%s", sf)) sf = "sim/cr_phys_stim.mem";
        if (!$value$plusargs("OUT=%s", of)) of = "sim/cr_phys_rtl.txt";
        for (i = 0; i < 262144; i = i + 1) stim[i] = 32'hFFFFFFFF;
        $readmemh(sf, stim);
        n = 0; while (n < 262144 && stim[n] !== 32'hFFFFFFFF) n = n + 1;
        fd = $fopen(of, "w"); steps = 0; worst = 0;
        repeat (5) @(posedge clk); @(negedge clk) rst = 0;
        repeat (5) @(posedge clk);
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            if (stim[i][8]) begin
                dop = stim[i][15:12]; darg = stim[i][31:16]; dcmd = 1;
            end else begin
                {em, es, ej, br, bl} = stim[i][4:0]; gtick = 1;
            end
            @(negedge clk) begin dcmd = 0; gtick = 0; {em, es, ej} = 3'b000; end
            t = 1;
            while (busy) begin @(negedge clk); t = t + 1; end
            if (t > worst) worst = t;
        end
        repeat (3) @(posedge clk);
        $fclose(fd);
        // plan Task 7: a step must stay far inside its budget (833 333 clocks at 2 steps per 60 Hz tick)
        $display("CR_TB_COSIM: %0d words, %0d steps printed, slowest word %0d clocks (%0s), unknown registers: %0d steps",
                 n, steps, worst, worst < 400000 ? "budget ok" : "OVER BUDGET", xbad);
        $finish;
    end
endmodule
