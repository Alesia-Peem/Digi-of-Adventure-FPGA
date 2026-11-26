// tb_stage_mgr.v - TESTBENCH ONLY. Unit test of rtl/top/stage_mgr.v (screen sequence of the whole game).
//   OPEN -> S1 -> C12 -> S2 -> C23 -> S3 -> END -> OPEN   (twice around the loop)
// Checked on every clock (monitor) :
//   * the screen changes, bg_mode 5 is entered / left (pic_on) and pic_load pulses ONLY in the cycle after a
//     vblank pulse (R13), and every entry into a picture screen or into Stage 1 / 2 (rooms from the flash)
//     comes with a pic_load (same vblank); Stage 3 never loads a picture
//   * s1/s2/s3_enter pulse only on that cycle, only for the screen that was entered
//   * form never decreases
// Checked by the scenario :
//   * enter pulses, help flags, Stage 1 -> 2 handoff latched at the Stage 1 exit, form >= 1 after C12 and
//     >= 2 after C23, picture id of every placeholder screen
//   * BTNC held across a transition: its release (tap) does NOT act on the new screen; a fresh tap does
//   * a second tap while a transition is pending does not skip a screen
//   * demo menu jumps (13 -> Stage 1, 14 -> Stage 2, 14 + SW0 -> Stage 3) land on the stage, skip cutscenes
//   * exits / taps that do not belong to the running screen are ignored
`timescale 1ns/1ps
module tb_stage_mgr;
`include "pic_map.vh"
    localparam [2:0] OPEN = 3'd0, S1 = 3'd1, C12 = 3'd2, S2 = 3'd3, C23 = 3'd4, S3 = 3'd5, ENDS = 3'd6,
                     BOOT = 3'd7;
    // realistic ratio: on the board the game tick (60.000 Hz) and vblank (59.5 Hz) periods are almost equal, so a
    // tap released just before a vblank reaches the manager only with the NEXT tick, on the new screen
    localparam integer VB_PER = 400, GT_PER = 389;      // vblank / game-tick periods (clk)

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg        vblank = 1'b0, gtick = 1'b0, ev_tap = 1'b0, btnc = 1'b0;
    reg        s1_exit = 1'b0, s2_exit = 1'b0, s3_exit = 1'b0;
    reg  [1:0] s1_armor = 2'd0, s1_form = 2'd0, s2_armor = 2'd0, s2_form = 2'd0;
    reg        s1_shard = 1'b0, s1_boost = 1'b0, s2_shard = 1'b0, s2_boost = 1'b0;
    reg        demo_cmd = 1'b0; reg [3:0] demo_op = 4'd0; reg [15:0] demo_arg = 16'd0;

    wire [2:0] screen; wire on1, on2, on3, pic_on, boot;
    wire       s1_enter, s2_enter, s3_enter, s1_help, s2_help, pic_load, top_cmd;
    wire [1:0] h2_armor, h3_armor, form; wire h2_shard, h2_boost, h3_shard, h3_boost;
    wire [4:0] pic_id;
    stage_mgr dut (
        .clk(clk), .rst(rst), .vblank(vblank), .gtick(gtick), .ev_tap(ev_tap), .btnc_lvl(btnc),
        .s1_exit(s1_exit), .s2_exit(s2_exit), .s3_exit(s3_exit),
        .s1_armor(s1_armor), .s1_shard(s1_shard), .s1_boost(s1_boost), .s1_form(s1_form),
        .s2_armor(s2_armor), .s2_shard(s2_shard), .s2_boost(s2_boost), .s2_form(s2_form),
        .demo_cmd(demo_cmd), .demo_op(demo_op), .demo_arg(demo_arg), .top_cmd(top_cmd),
        .screen(screen), .on1(on1), .on2(on2), .on3(on3), .pic_on(pic_on), .boot(boot),
        .s1_enter(s1_enter), .s2_enter(s2_enter), .s3_enter(s3_enter), .s1_help(s1_help), .s2_help(s2_help),
        .h2_armor(h2_armor), .h2_shard(h2_shard), .h2_boost(h2_boost),
        .h3_armor(h3_armor), .h3_shard(h3_shard), .h3_boost(h3_boost), .form(form),
        .pic_id(pic_id), .pic_load(pic_load));

    integer errors = 0;
    task fail(input [8*80-1:0] msg); begin
        errors = errors + 1; $display("FAIL t=%0t screen=%0d: %0s", $time, screen, msg);
    end endtask

    // ---------------------------------------------------------------- stimulus timing + monitor (negedge)
    // (pic_load also on S1 / S2 entry since the rooms moved to the flash - Task 7)
    integer cyc = 0;
    reg     tap_req = 1'b0;           // deliver one ev_tap with the next game tick
    reg     vb_prev = 1'b0;           // vblank as sampled by the last posedge
    reg [2:0] scr_prev = 3'd7; reg pic_prev = 1'b0; reg [1:0] form_prev = 2'd0;
    integer n_s1 = 0, n_s2 = 0, n_s3 = 0, n_load = 0;
    always @(negedge clk) begin
        if (!rst) begin
            // ---- monitor (outputs of the posedge that sampled vb_prev)
            if (screen != scr_prev && !vb_prev) fail("screen changed outside vblank");
            if (pic_on != pic_prev && !vb_prev) fail("bg_mode 5 entered/left outside vblank");
            if (pic_load && !vb_prev)           fail("pic_load outside vblank");
            if (pic_load && !(pic_on || on1 || on2)) fail("pic_load on Stage 3 / boot (no picture there)");
            // Stage 1 / Stage 2 rooms are streamed from the flash (bg_mode 1 / 2): every entry (normal, demo jump,
            // demo restart) loads the room in the same vblank; Stage 3 loads nothing
            if (s1_enter && !(pic_load && pic_id == PIC_S1_ROOM)) fail("S1 entered without pic_load(PIC_S1_ROOM)");
            if (s2_enter && !(pic_load && pic_id == PIC_S2_ROOM)) fail("S2 entered without pic_load(PIC_S2_ROOM)");
            if (s3_enter && pic_load)          fail("pic_load when entering S3");
            if (pic_load && !(s1_enter || s2_enter || (pic_on && vb_prev))) fail("pic_load without a screen entry");
            if (pic_on && screen != scr_prev && !pic_load) fail("picture screen entered without pic_load");
            if (s1_enter && !(vb_prev && screen == S1)) fail("bad s1_enter");
            if (s2_enter && !(vb_prev && screen == S2)) fail("bad s2_enter");
            if (s3_enter && !(vb_prev && screen == S3)) fail("bad s3_enter");
            if (screen != scr_prev && screen == S1 && !s1_enter) fail("S1 entered without s1_enter");
            if (screen != scr_prev && screen == S2 && !s2_enter) fail("S2 entered without s2_enter");
            if (screen != scr_prev && screen == S3 && !s3_enter) fail("S3 entered without s3_enter");
            if (form < form_prev) fail("form decreased");
            if (on1 != (screen == S1) || on2 != (screen == S2) || on3 != (screen == S3)) fail("on1..3");
            if (pic_on != (screen == OPEN || screen == C12 || screen == C23 || screen == ENDS)) fail("pic_on");
            if (boot != (screen == BOOT)) fail("boot");
            n_s1 = n_s1 + s1_enter; n_s2 = n_s2 + s2_enter; n_s3 = n_s3 + s3_enter; n_load = n_load + pic_load;
        end
        scr_prev = screen; pic_prev = pic_on; form_prev = form;
        // ---- next inputs
        cyc = cyc + 1;
        vblank = (cyc % VB_PER) == 0;
        gtick  = (cyc % GT_PER) == 0;
        ev_tap = gtick && tap_req;
        if (ev_tap) tap_req = 1'b0;
        vb_prev = vblank;
    end

    // ---------------------------------------------------------------- helpers
    task wait_screen(input [2:0] s, input [8*40-1:0] what);
        integer k;
        begin
            k = 0;
            while (screen != s && k < 10 * VB_PER) begin @(negedge clk); k = k + 1; end
            if (screen != s) begin fail(what); $display("     expected screen %0d", s); end
            @(negedge clk);
        end
    endtask
    task tap; begin                    // press (lvl high for a few ticks), release -> one tap with a tick
        btnc = 1'b1; repeat (3 * GT_PER) @(negedge clk);
        btnc = 1'b0; tap_req = 1'b1;
        while (tap_req) @(negedge clk);
    end endtask
    task pulse_exit(input integer which); begin
        if (which == 1) s1_exit = 1'b1; else if (which == 2) s2_exit = 1'b1; else s3_exit = 1'b1;
        @(negedge clk); s1_exit = 1'b0; s2_exit = 1'b0; s3_exit = 1'b0;
    end endtask
    // exit request (which = 1..3) or, which = 0, a tap on a picture screen, then a second short press released
    // ~30..60 clk before the vblank that applies the change, with no game tick between the release and the vblank
    task late_tap(input integer which); begin
        // a game tick 3 clk from now and the vblank 60..90 clk after it
        while (!((cyc % GT_PER) == GT_PER - 3 && (cyc % VB_PER) >= VB_PER - 93 && (cyc % VB_PER) <= VB_PER - 63))
            @(negedge clk);
        if (which == 0) begin tap_req = 1'b1; while (tap_req) @(negedge clk); @(negedge clk); end
        else begin repeat (3) @(negedge clk); pulse_exit(which); end
        btnc = 1'b1; repeat (20) @(negedge clk);
        btnc = 1'b0; tap_req = 1'b1;            // released 30..60 clk before the vblank; tap pending until next tick
    end endtask
    task demo(input [3:0] op, input [15:0] arg); begin
        while (!gtick) @(negedge clk);
        demo_cmd = 1'b1; demo_op = op; demo_arg = arg;
        @(negedge clk); demo_cmd = 1'b0;
    end endtask
    task stay(input [2:0] s, input [8*40-1:0] what); begin   // the screen must not change for 4 frames
        repeat (4 * VB_PER) begin @(negedge clk); if (screen != s) fail(what); end
    end endtask
    task check_pic(input [4:0] id, input [8*40-1:0] what); begin
        if (pic_id != id) begin fail(what); $display("     pic_id %0d expected %0d", pic_id, id); end
    end endtask

    integer loop, e1, e2, e3, ld;
    initial begin
        repeat (5) @(negedge clk); rst = 1'b0;
        if (screen != BOOT) fail("not BOOT after reset");
        for (loop = 0; loop < 2; loop = loop + 1) begin
            // ---- OPEN (title)
            ld = n_load;
            wait_screen(OPEN, "OPEN not reached");
            check_pic(PIC_TITLE, "OPEN picture");
            if (n_load != ld + 1) fail("OPEN: one pic_load expected");
            pulse_exit(1); pulse_exit(2); pulse_exit(3);         // not the running screen: ignored
            stay(OPEN, "OPEN left on a foreign exit_req");
            // ---- OPEN -> S1 (tap), a second tap while pending must not skip S1
            e1 = n_s1;
            btnc = 1'b1; repeat (3 * GT_PER) @(negedge clk); btnc = 1'b0; tap_req = 1'b1;
            while (tap_req) @(negedge clk);
            if (screen == OPEN) begin
                btnc = 1'b1; repeat (2) @(negedge clk); btnc = 1'b0; tap_req = 1'b1;
                while (tap_req) @(negedge clk);
            end
            wait_screen(S1, "S1 not reached by a tap on OPEN");
            if (n_s1 != e1 + 1) fail("S1: one s1_enter expected");
            if (!s1_help) fail("S1 entered from OPEN without help");
            tap; stay(S1, "a tap in S1 moved the manager");
            // ---- S1 -> C12 (exit_req), handoff latched at the exit
            s1_armor = 2'd2; s1_shard = 1'b1; s1_boost = loop[0]; s1_form = (loop == 0) ? 2'd0 : 2'd1;
            if (loop == 0) pulse_exit(1);
            else begin
                // DOUBLE TAP on S1's clear screen: the exit, then a second short press released between the
                // requesting tick and the vblank; input_hub hands its tap out with the next tick (on C12)
                late_tap(1);
                wait_screen(C12, "C12 not reached by s1_exit (double tap)");
                stay(C12, "double tap: the late tap skipped C12");
            end
            s1_armor = 2'd0; s1_shard = 1'b0; s1_boost = 1'b0;           // the stage may change them afterwards
            wait_screen(C12, "C12 not reached by s1_exit");
            check_pic(PIC_CUT12, "C12 picture");
            if (form < 2'd1) fail("form < 1 after C12");
            // ---- C12 -> S2 (tap)
            e2 = n_s2;
            tap; wait_screen(S2, "S2 not reached by a tap on C12");
            if (n_s2 != e2 + 1) fail("S2: one s2_enter expected");
            if (!s2_help) fail("S2 entered from C12 without help");
            if (h2_armor != 2'd2 || h2_shard != 1'b1 || h2_boost != loop[0]) fail("Stage 1 -> 2 handoff");
            if (form < 2'd1) fail("form < 1 in S2");
            // ---- S2 -> C23 with BTNC HELD across the transition (loop 0)
            s2_armor = 2'd1; s2_shard = 1'b1; s2_boost = 1'b1; s2_form = (loop == 0) ? 2'd0 : 2'd2;
            if (loop == 0) btnc = 1'b1;
            pulse_exit(2);
            wait_screen(C23, "C23 not reached by s2_exit");
            check_pic(PIC_CUT23_1, "C23 picture");
            if (form < 2'd2) fail("form < 2 after C23");
            if (h3_armor != 2'd1 || !h3_shard || !h3_boost) fail("Stage 2 -> 3 handoff");
            if (loop == 0) begin
                repeat (2 * GT_PER) @(negedge clk);
                btnc = 1'b0; tap_req = 1'b1; while (tap_req) @(negedge clk);   // release of the held press
                stay(C23, "held BTNC fired again after the transition");
            end
            // ---- C23 -> S3 (fresh tap)
            e3 = n_s3;
            tap; wait_screen(S3, "S3 not reached by a tap on C23");
            if (n_s3 != e3 + 1) fail("S3: one s3_enter expected");
            // ---- S3 -> END (win + tap = s3_exit)
            tap; stay(S3, "a tap in S3 moved the manager");
            pulse_exit(3);
            wait_screen(ENDS, "END not reached by s3_exit");
            check_pic(PIC_END1, "END picture");
            // ---- END -> OPEN; loop 1: BTNC pressed again before the transition and held across it
            if (loop == 1) begin
                // double tap on END: the second tap is released just before the vblank -> must not skip OPEN
                late_tap(0);
                wait_screen(OPEN, "OPEN not reached from END (double tap)");
                stay(OPEN, "double tap: the late tap skipped OPEN");
            end
            if (loop == 1) begin
                tap; wait_screen(S1, "S1 after the double-tap check");
                pulse_exit(1); wait_screen(C12, "C12 (held check)"); tap; wait_screen(S2, "S2 (held check)");
                pulse_exit(2); wait_screen(C23, "C23 (held check)"); tap; wait_screen(S3, "S3 (held check)");
                pulse_exit(3); wait_screen(ENDS, "END (held check)");
                tap;
                btnc = 1'b1;
                wait_screen(OPEN, "OPEN not reached from END");
                repeat (2 * GT_PER) @(negedge clk);
                btnc = 1'b0; tap_req = 1'b1; while (tap_req) @(negedge clk);
                stay(OPEN, "held BTNC fired again on OPEN");
            end else begin
                tap;
            end
        end
        // ---- demo menu jumps (skip the cutscenes)
        wait_screen(OPEN, "OPEN (demo part)");
        e2 = n_s2;
        demo(4'd14, 16'd0); wait_screen(S2, "demo 14 -> S2");
        if (n_s2 != e2 + 1 || s2_help) fail("demo S2: one s2_enter, no help");
        if (h2_armor != 2'd0 || h2_shard || h2_boost) fail("demo S2: handoff cleared");
        e1 = n_s1;
        demo(4'd13, 16'd0); wait_screen(S1, "demo 13 -> S1");
        if (n_s1 != e1 + 1 || s1_help) fail("demo S1: one s1_enter, no help");
        e1 = n_s1;
        demo(4'd13, 16'd0); repeat (2 * VB_PER) @(negedge clk);         // restart of the running stage
        if (screen != S1 || n_s1 != e1 + 1) fail("demo 13 in S1 restarts it");
        demo(4'd14, 16'd1); wait_screen(S3, "demo 14 + SW0 -> S3");
        demo(4'd5, 16'd0);  stay(S3, "a stage demo command moved the manager");
        pulse_exit(3); wait_screen(ENDS, "END from demo S3");
        demo(4'd13, 16'd0); wait_screen(S1, "demo 13 from END -> S1 (leaves bg_mode 5)");
        pulse_exit(1); wait_screen(C12, "C12 (demo part)");
        demo(4'd14, 16'd1); wait_screen(S3, "demo 14 + SW0 from C12 -> S3");
        if (form < 2'd2) fail("form lowered");
        // top_cmd = the demo commands the manager consumes
        demo_op = 4'd13; demo_cmd = 1'b1; #1 if (!top_cmd) fail("top_cmd 13");
        demo_op = 4'd14; #1 if (!top_cmd) fail("top_cmd 14");
        demo_op = 4'd5;  #1 if (top_cmd) fail("top_cmd 5");
        @(negedge clk); demo_cmd = 1'b0;
        repeat (VB_PER) @(negedge clk);
        $display("TB_STAGE_MGR: %0s (errors=%0d, s1/s2/s3 enters %0d/%0d/%0d, pic_loads %0d)",
                 errors == 0 ? "PASS" : "FAIL", errors, n_s1, n_s2, n_s3, n_load);
        $finish;
    end
endmodule
