// cr_tb_cosim.v - TESTBENCH ONLY. Replays sim/cr_<name>_stim.mem on cr_core.v and prints, after every game step,
// the columns of cr_model.Model.HEADER (cr_cosim.py cmp compares them with the model).
//   word: [0] left [1] right [2] jump [3] skill [4] menu      or  [8] command, [15:12] op, [31:16] argument
//   +STIM=sim/cr_x_stim.mem +OUT=sim/cr_x_rtl.txt      parameter PHYS=1: no animals, no lifts (Task 7 stimulus)
//   parameter STEPS: steps per tick (1 = one step per stimulus word; 2 = the board)
`timescale 1ns/1ps
module cr_tb_cosim;
    parameter PHYS = 0;
    parameter STEPS = 1;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg gtick = 0, bl = 0, br = 0, ej = 0, es = 0, em = 0, enter = 0, dcmd = 0;
    reg [3:0] dop = 0; reg [15:0] darg = 0;
    wire busy, step_done, exit_req; wire [2:0] mode; wire [1:0] level; wire [12:0] cam_px; wire [31:0] q_data;
    cr_core #(.MEM_DIR("mem/"), .STEPS_PER_TICK(STEPS), .PHYS_ONLY(PHYS)) dut (
        .clk(clk), .rst(rst), .gtick(gtick), .btn_left(bl), .btn_right(br), .ev_jump(ej), .ev_skill(es),
        .ev_menu(em), .enter(enter), .demo_cmd(dcmd), .demo_op(dop), .demo_arg(darg), .exit_req(exit_req),
        .step_done(step_done), .busy(busy), .mode(mode), .level(level), .cam_px(cam_px), .q_idx(6'd0),
        .q_data(q_data));

    reg [31:0] stim [0:262143];
    reg [1023:0] sf, of;
    integer n, i, fd, steps, worst, t;
    // one line per step, in HEADER order; columns not built yet print 0
    always @(posedge clk) if (step_done) begin
        $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %s", steps,
            dut.mode_r, dut.stage, dut.xf, dut.yf, dut.vyf, dut.gf, dut.vxf, dut.jumps, dut.elapsed, dut.grounded,
            dut.grace, dut.buffer, dut.face_l ? -1 : 1, dut.walking, dut.cam, dut.stride, dut.time_left,
            "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0");
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
        $display("CR_TB_COSIM: %0d words, %0d steps printed, slowest word %0d clocks", n, steps, worst);
        $finish;
    end
endmodule
