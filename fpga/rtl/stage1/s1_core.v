// s1_core.v - STAGE 1 "Final Exam": complete game logic, a port of class Game in stage1_demo.py.
//
// Structure (one module, because every Pygame handler touches the same game state):
//   * Once per game tick (60 Hz, `gtick`), a small sequencer runs Game.update() in Pygame order:
//       7 x LFSR step -> flash -> help / clear / over -> timers -> card_trigger (+shuffle)
//       -> cards_input | notebook (SW14) | map_update (move X, move Y, animate, find_near) | closeup_input
//     Each step takes a few 100 MHz cycles; a tick has 1.67 million cycles, so there is no hurry.
//   * Shared FEATURE modules are instantiated here: lfsr16, card_deck, inventory, heart_system,
//     sprite_anim, s1_collision.
//   * Everything the screen needs is exported as FIELDS / CONDS (see tools/ui_spec.py) - this module
//     never draws anything.
// Positions are world pixels of the 2000 x 1116 room with one decimal digit (int + tenths), so the
// Pygame speeds (360 px/s -> 6.0 px per tick, x1.2 workshop jacket, x0.5 slow) are exact.
`timescale 1ns/1ps
module s1_core (
    input  wire          clk,
    input  wire          rst,
    input  wire          gtick,
    input  wire          ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back,
    input  wire [4:0]    lvl,            // [0]U [1]D [2]L [3]R [4]C
    input  wire [15:0]   sw,
    // stage manager
    input  wire          enter,          // pulse: start the stage (reset_stage(True))
    input  wire          help_on_entry,  // show "HOW TO PLAY" first (standalone start)
    input  wire          has_next,       // a next stage exists (text of the clear screen)
    input  wire [1:0]    in_armor,
    input  wire          in_shard,
    input  wire          in_boost,
    output reg           exit_req,       // pulse: player pressed BTNC on the clear screen
    output wire [1:0]    out_armor,
    output wire          out_shard,
    output wire          out_boost,
    output wire [1:0]    out_form,
    // demo hub / testbench state injection (demo_hub.py jump_to / do_action / set_*)
    input  wire          demo_cmd,
    input  wire [3:0]    demo_op,
    input  wire [15:0]   demo_arg,
    // UI contract
    output wire [3071:0] fields,
    output wire [255:0]  conds,
    output wire [1:0]    bg_mode,
    output wire [11:0]   bg_color,
    output wire [10:0]   cam_x,
    output wire [9:0]    cam_y,
    // board outputs
    output reg  [39:0]   seg_chars,
    output wire [15:0]   leds,
    output wire [2:0]    rgb16,          // {R,G,B}: career colour
    output wire [2:0]    rgb17,          // red while the damage flash is on
    // observation (testbenches)
    output wire [11:0]   dbg_px, dbg_py,
    output wire [3:0]    dbg_pxf, dbg_pyf,
    output wire [4:0]    dbg_done, dbg_right,
    output wire [1:0]    dbg_hearts,
    output wire [15:0]   dbg_lfsr,
    output wire [2:0]    dbg_state       // {mode closeup, over, clear}
);
`include "game_defs.vh"
`include "ui_map.vh"

    // ================================================================ constants (stage1_demo.py)
    localparam [3:0]  ANS_A = 4'd6;                // 0x2A - 0b10011 - 0o21 = 42 - 19 - 17
    localparam [15:0] P2_TRUTH = 16'hF888;          // F = AB + CD
    localparam [7:0]  P4_ANSWER = 8'b1111_0100;     // -12 in 8-bit two's complement
    // PC password "CPE" (letters 2, 15, 4). Door layer 1 = ord('E') = 69. Layer 2: A=6 B=7 C=5,
    // S=18 -> row 6 7 5 1 8 -> order 4-2-5-1-3 -> 1 7 8 6 5  (checked again in tb_s1_puzzles.v)
    localparam [4:0]  PW0 = 5'd2, PW1 = 5'd15, PW2 = 5'd4;
    localparam [7:0]  L1C = {4'd6, 4'd9};
    localparam [19:0] L2C = {4'd1, 4'd7, 4'd8, 4'd6, 4'd5};
    localparam [11:0] SPAWN_X = 12'd1300, SPAWN_Y = 12'd405;
    localparam [7:0]  OVER_FRAMES = 8'd180, TOAST_FRAMES = 8'd150, FLASH_FRAMES = 8'd24;

    // object kinds / ids (OBJS order)
    localparam [2:0] O_WB = 3'd0, O_PAPER = 3'd1, O_NAND = 3'd2, O_TWOS = 3'd3, O_SCREEN = 3'd4,
                     O_PC = 3'd5, O_LIGHTSW = 3'd6, O_DOOR = 3'd7;
    function [11:0] obj_ax(input [2:0] o);
        case (o) 3'd0: obj_ax = 300; 3'd1: obj_ax = 700; 3'd2: obj_ax = 1370; 3'd3: obj_ax = 570;
                 3'd4: obj_ax = 1560; 3'd5: obj_ax = 1540; 3'd6: obj_ax = 1150; default: obj_ax = 1340; endcase
    endfunction
    function [11:0] obj_ay(input [2:0] o);
        case (o) 3'd0: obj_ay = 580; 3'd1: obj_ay = 400; 3'd2: obj_ay = 920; 3'd3: obj_ay = 690;
                 3'd4: obj_ay = 400; 3'd5: obj_ay = 620; 3'd6: obj_ay = 310; default: obj_ay = 300; endcase
    endfunction
    function [7:0] obj_r(input [2:0] o);
        case (o) 3'd0: obj_r = 180; 3'd1: obj_r = 130; 3'd2: obj_r = 190; 3'd3: obj_r = 150;
                 3'd4: obj_r = 120; 3'd5: obj_r = 120; 3'd6: obj_r = 100; default: obj_r = 120; endcase
    endfunction
    function paged(input [2:0] o);      // PAGED = whiteboard paper nand twos pc
        paged = (o == O_WB) || (o == O_PAPER) || (o == O_NAND) || (o == O_TWOS) || (o == O_PC);
    endfunction

    // p2_table(): truth table of up to 3 product terms {usedA..D, plainA..D}; minterm m: A = m[3]
    function [15:0] p2_table(input [7:0] t1, input [7:0] t2, input [7:0] t3);
        integer m, j; reg [3:0] vv; reg [7:0] tt; reg f, ok;
        begin
            p2_table = 16'd0;
            for (m = 0; m < 16; m = m + 1) begin
                vv = m[3:0]; f = 1'b0;
                for (j = 0; j < 3; j = j + 1) begin
                    tt = (j == 0) ? t1 : (j == 1) ? t2 : t3;
                    ok = (tt[7:4] != 4'd0) && (((vv ^ tt[3:0]) & tt[7:4]) == 4'd0);
                    if (ok) f = 1'b1;
                end
                p2_table[m] = f;
            end
        end
    endfunction
    // p3_table(): 4 NAND gates, gate k input sources 0..3 = A..D, 4.. = G1..; output = G(f8+1)
    function [15:0] p3_table(input [26:0] f);
        integer m, k2; reg [6:0] src; reg [3:0] g; reg a, b;
        begin
            p3_table = 16'd0;
            for (m = 0; m < 16; m = m + 1) begin
                src = {3'b000, m[0], m[1], m[2], m[3]};       // src[0]=A src[1]=B src[2]=C src[3]=D
                g = 4'd0;
                for (k2 = 0; k2 < 4; k2 = k2 + 1) begin
                    a = src[f[3*(2*k2) +: 3]];
                    b = src[f[3*(2*k2+1) +: 3]];
                    g[k2] = ~(a & b);
                    src[4 + k2] = g[k2];
                end
                p3_table[m] = g[f[26:24]];
            end
        end
    endfunction
    function [4:0] popcount16(input [15:0] x);
        integer i; begin popcount16 = 5'd0; for (i = 0; i < 16; i = i + 1) popcount16 = popcount16 + x[i]; end
    endfunction
    function [3:0] popcount8(input [7:0] x);
        integer i; begin popcount8 = 4'd0; for (i = 0; i < 8; i = i + 1) popcount8 = popcount8 + x[i]; end
    endfunction
    function [1:0] pidx(input [2:0] pm, input [1:0] p);   // itertools.permutations([0,1,2])[pm][p]
        reg [5:0] t;
        begin
            case (pm)
                3'd0: t = {2'd2, 2'd1, 2'd0}; 3'd1: t = {2'd1, 2'd2, 2'd0}; 3'd2: t = {2'd2, 2'd0, 2'd1};
                3'd3: t = {2'd0, 2'd2, 2'd1}; 3'd4: t = {2'd1, 2'd0, 2'd2}; default: t = {2'd0, 2'd1, 2'd2};
            endcase
            pidx = (p == 2'd0) ? t[1:0] : (p == 2'd1) ? t[3:2] : t[5:4];
        end
    endfunction

    // ================================================================ state (names follow stage1_demo.py)
    reg        show_help;
    reg [1:0]  state;                 // 0 play 1 over 2 clear
    localparam ST_PLAY = 2'd0, ST_OVER = 2'd1, ST_CLEAR = 2'd2;
    reg        mode_cu;               // 0 map 1 closeup
    reg [2:0]  cur;
    reg [1:0]  page;
    reg [7:0]  cmsg; reg [3:0] cmsg_p;
    reg        lights;
    reg [4:0]  done, right;
    reg [3:0]  ans_a; reg [4:0] ans_b; reg [3:0] ans_c; reg [2:0] ans_v;    // values + valid {C,B,A}
    reg        undo_v; reg [2:0] undo_i; reg [3:0] undo_a; reg [4:0] undo_b; reg [3:0] undo_c;
    reg [2:0]  undo_av; reg undo_done, undo_right;
    reg [7:0]  p2t1, p2t2, p2t3; reg [1:0] p2_cur; reg [23:0] p2_eq;
    reg [26:0] p3;                    // 9 fields x 3 bit
    reg [3:0]  p3_cur;
    reg [4:0]  p5_0, p5_1, p5_2; reg [1:0] p5_cur; reg p5_seen;
    reg [2:0]  note_t [0:7]; reg [23:0] note_v [0:7]; reg [3:0] note_n;
    reg [5:1]  hint_seen; reg [2:0] hint0, hint1, hint2;
    reg [1:0]  form; reg debug;
    reg        door_layer; reg [3:0] dd0, dd1, dd2, dd3, dd4; reg [2:0] door_cur;
    reg [3:1]  r_run, r_done;
    reg [7:0]  toast; reg [7:0] toast_t;
    reg [7:0]  flash; reg [7:0] over_t;
    reg [11:0] px_i, py_i; reg [3:0] px_f, py_f;
    reg [7:0]  cdesc;
    reg        e_u, e_d, e_l, e_r, e_tap, e_back;     // events of the tick being processed

    // ================================================================ shared feature modules
    reg        lf_step, lf_load; reg [15:0] lf_seed;
    wire [15:0] lfsr;
    lfsr16 u_lfsr (.clk(clk), .rst(rst), .load(lf_load), .seed(lf_seed), .step(lf_step), .q(lfsr));

    reg        dk_start, dk_en, dk_clear, dk_setc; reg [1:0] dk_round, dk_setcv; reg [2:0] dk_perm;
    wire       dk_active, dk_face_up, dk_grant, dk_cvalid, dk_rdone;
    wire [1:0] dk_rnd, dk_cursor, dk_face, career; wire [2:0] dk_pm; wire [3:0] dk_item;
    card_deck u_deck (.clk(clk), .rst(rst), .clear(dk_clear), .start(dk_start), .start_round(dk_round),
        .start_perm(dk_perm), .en(dk_en), .ev_l(e_l), .ev_r(e_r), .ev_tap(e_tap),
        .set_career(dk_setc), .set_career_v(dk_setcv),
        .active(dk_active), .round(dk_rnd), .perm(dk_pm), .cursor(dk_cursor), .face_up(dk_face_up),
        .face(dk_face), .grant(dk_grant), .grant_item(dk_item), .career(career), .career_valid(dk_cvalid),
        .round_done(dk_rdone));

    reg        inv_tick, inv_load, inv_restore, inv_add_armor;
    wire [1:0] armor; wire shard, boost, forged; wire [1:0] n_hh, n_hs, n_un, n_fr;
    wire [9:0] slow_f; wire [8:0] freeze_f;
    wire       dmg_armor;
    inventory u_inv (.clk(clk), .rst(rst), .tick(inv_tick), .run(1'b1), .store_mode(1'b0),
        .load(inv_load), .load_armor(in_armor), .load_shard(in_shard), .load_boost(in_boost),
        .restore(inv_restore), .grant(dk_grant), .grant_item(dk_item), .armor_consume(dmg_armor),
        .add_armor(inv_add_armor), .use_hh(1'b0), .use_hs(1'b0), .use_undo(1'b0), .use_freeze(1'b0),
        .boost_consume(1'b0), .armor(armor), .shard(shard), .boost(boost), .n_hh(n_hh), .n_hs(n_hs),
        .n_undo(n_un), .n_freeze(n_fr), .slow_f(slow_f), .freeze_f(freeze_f), .forged(forged));

    reg        hs_clear, hs_set, door_dmg; reg [1:0] hs_setv;
    wire [1:0] hearts; wire hs_hit, hs_blocked, hs_dead;
    heart_system u_hearts (.clk(clk), .rst(rst), .clear(hs_clear), .set_en(hs_set), .set_val(hs_setv),
        .damage(door_dmg), .armor_avail(armor != 2'd0), .armor_consume(dmg_armor), .hearts(hearts),
        .hit(hs_hit), .blocked(hs_blocked), .dead(hs_dead));

    reg        an_upd, an_stop, an_reset, an_moved; reg [1:0] an_dx, an_dy;
    wire [1:0] sdir, spose;
    sprite_anim u_anim (.clk(clk), .rst(rst), .reset_dir(an_reset), .upd(an_upd), .stop(an_stop),
        .dxs(an_dx), .dys(an_dy), .moved(an_moved), .dir(sdir), .pose(spose));

    reg  [11:0] q_x, q_y;
    wire        q_blocked;
    s1_collision u_col (.xi(q_x), .yi(q_y), .blocked(q_blocked));
    reg         blocked_r;                     // registered: keeps the collision maths off the critical path
    always @(posedge clk) blocked_r <= q_blocked;

    // ================================================================ derived values
    wire [3:0]  p1_val = sw[3:0];
    wire [7:0]  p4_val = sw[7:0];
    reg  [15:0] p3_t;                           // registered (p3 only changes on ticks)
    reg         p2_ok;                          // p2_table(T1..T3) == F888 and <= 4 literals, registered
    wire [2:0]  n_done = done[0] + done[1] + done[2] + done[3] + done[4];
    wire [2:0]  door_n = door_layer ? 3'd5 : 3'd2;
    // speed() per tick: 6.0 px, x1.2 with form >= 1, x0.5 while slow
    wire        slow = (slow_f != 10'd0);
    wire [3:0]  sp_i = (form != 2'd0) ? (slow ? 4'd3 : 4'd7) : (slow ? 4'd3 : 4'd6);
    wire [3:0]  sp_f = (form != 2'd0) ? (slow ? 4'd6 : 4'd2) : 4'd0;
    // input direction from button LEVELS (pygame.key.get_pressed)
    wire        k_r = lvl[3], k_l = lvl[2], k_d = lvl[1], k_u = lvl[0];
    wire        dxv = k_r ^ k_l, dyv = k_d ^ k_u;   // dx = r - l, dy = d - u

    // candidate positions px + dx*sp (int + tenths with carry / borrow)
    wire [4:0]  fx_add = px_f + sp_f;
    wire [4:0]  fx_sub = {1'b0, px_f} - {1'b0, sp_f};
    wire [11:0] cx_i = !dxv ? px_i : k_r ? px_i + sp_i + (fx_add >= 5'd10) : px_i - sp_i - fx_sub[4];
    wire [3:0]  cx_f = !dxv ? px_f : k_r ? ((fx_add >= 5'd10) ? fx_add - 5'd10 : fx_add) :
                                            (fx_sub[4] ? fx_sub + 5'd10 : fx_sub);
    wire [4:0]  fy_add = py_f + sp_f;
    wire [4:0]  fy_sub = {1'b0, py_f} - {1'b0, sp_f};
    wire [11:0] cy_i = !dyv ? py_i : k_d ? py_i + sp_i + (fy_add >= 5'd10) : py_i - sp_i - fy_sub[4];
    wire [3:0]  cy_f = !dyv ? py_f : k_d ? ((fy_add >= 5'd10) ? fy_add - 5'd10 : fy_add) :
                                            (fy_sub[4] ? fy_sub + 5'd10 : fy_sub);

    // smart_hint(): P5 while puzzle 5 is not done, then the first not-RIGHT of P3, P2, P1, P4
    wire [2:0]  smart_key = !done[4] ? 3'd5 : !right[2] ? 3'd3 : !right[1] ? 3'd2 :
                            !right[0] ? 3'd1 : !right[3] ? 3'd4 : 3'd0;

    // ================================================================ sequencer
    localparam Q_IDLE = 5'd0, Q_LFSR = 5'd1, Q_TOP = 5'd2, Q_TRIG = 5'd3, Q_SHUF = 5'd4, Q_SHUF2 = 5'd5,
               Q_SHUF3 = 5'd6, Q_DISP = 5'd7, Q_MX = 5'd8, Q_MY = 5'd9, Q_ANIM = 5'd10, Q_NEAR = 5'd11,
               Q_NEAR2 = 5'd12, Q_CU = 5'd13, Q_DEMO = 5'd14, Q_SHUFW = 5'd15, Q_MXW = 5'd16, Q_MYW = 5'd17;
    reg [4:0]  q;
    // recomputed at reset and at the start of every tick (state Q_LFSR = 1): p2/p3 only change in the
    // close-up / demo states, and the results are only used later in a tick (saves simulation time too)
    always @(posedge clk) if (rst || q == 5'd1) begin
        p3_t  <= p3_table(p3);
        p2_ok <= (p2_table(p2t1, p2t2, p2t3) == P2_TRUTH) &&
                 ((popcount8({p2t1[7:4], p2t2[7:4]}) + {3'd0, p2t3[7]} + p2t3[6] + p2t3[5] + p2t3[4]) <= 4'd4);
    end
    reg [2:0]  cnt;
    reg [11:0] ox_i, oy_i; reg [3:0] ox_f, oy_f;
    reg [2:0]  nb_i; reg nb_v; reg [2:0] nb_best; reg [29:0] nb_d2; reg [15:0] nb_r2;
    reg [1:0]  nb_ph;                                   // pipeline phase of the current object
    reg signed [16:0] nb_dx, nb_dy; reg [33:0] nb_d2c, nb_lim; reg [15:0] nb_r2c; reg [49:0] nb_lhs, nb_rhs;
    reg        dm_pend; reg [3:0] dm_op; reg [15:0] dm_arg;

    // find_near() score of object nb_i (tenths): d2 <= (R*10)^2, best = smallest d2/R^2
    wire [7:0]  nr   = obj_r(nb_i) + ((form != 2'd0) ? 8'd30 : 8'd0);
    wire signed [16:0] dxt = $signed({1'b0, px_i} * 17'sd10 + px_f) - $signed({1'b0, obj_ax(nb_i)} * 17'sd10);
    wire signed [16:0] dyt = $signed({1'b0, py_i} * 17'sd10 + py_f) - $signed({1'b0, obj_ay(nb_i)} * 17'sd10);
    // (evaluated over 4 pipelined cycles in Q_NEAR: offsets -> squares -> cross products -> compare)

    // ---------------------------------------------------------------- helper tasks
    // notes.append(...); the notebook shows notes[-8:] from the top -> keep the last 8, oldest first
    task note_push(input [2:0] t, input [23:0] val);
        integer i;
        begin
            if (note_n != 4'd8) begin
                note_t[note_n[2:0]] <= t; note_v[note_n[2:0]] <= val; note_n <= note_n + 4'd1;
            end else begin
                for (i = 0; i < 7; i = i + 1) begin note_t[i] <= note_t[i + 1]; note_v[i] <= note_v[i + 1]; end
                note_t[7] <= t; note_v[7] <= val;
            end
        end
    endtask
    task add_hint(input [2:0] k);       // hints_seen.append(...) if not already there
        begin
            if (!hint_seen[k]) begin
                hint_seen[k] <= 1'b1; hint0 <= hint1; hint1 <= hint2; hint2 <= k;
            end
        end
    endtask
    task say(input [7:0] id);
        begin toast <= id; toast_t <= TOAST_FRAMES; end
    endtask
    // commit(i, correct, msg) - saves the undo record, then logs the answer
    task commit(input [2:0] i, input correct, input [7:0] msg);
        begin
            undo_v <= 1'b1; undo_i <= i; undo_a <= ans_a; undo_b <= ans_b; undo_c <= ans_c; undo_av <= ans_v;
            undo_done <= done[i]; undo_right <= right[i];
            done[i] <= 1'b1; right[i] <= correct;
            cmsg <= msg; say(TOAST_NB);
        end
    endtask
    task reset_stage(input full);       // reset_stage(full): everything back to the stage start
        integer i;
        begin
            if (full) form <= 2'd0;
            px_i <= SPAWN_X; px_f <= 4'd0; py_i <= SPAWN_Y; py_f <= 4'd0;
            mode_cu <= 1'b0; cur <= 3'd0; page <= 2'd0; cmsg <= CMSG_NONE; cmsg_p <= 4'd0;
            state <= ST_PLAY; lights <= 1'b1;
            done <= 5'd0; right <= 5'd0; ans_v <= 3'd0; ans_a <= 4'd0; ans_b <= 5'd0; ans_c <= 4'd0;
            undo_v <= 1'b0;
            p2t1 <= 8'd0; p2t2 <= 8'd0; p2t3 <= 8'd0; p2_cur <= 2'd0; p2_eq <= 24'd0;
            p3 <= 27'd0; p3_cur <= 4'd0;
            p5_0 <= 5'd0; p5_1 <= 5'd0; p5_2 <= 5'd0; p5_cur <= 2'd0; p5_seen <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin note_t[i] <= 3'd0; note_v[i] <= 24'd0; end
            note_n <= 4'd0; hint_seen <= 5'd0; hint0 <= 3'd0; hint1 <= 3'd0; hint2 <= 3'd0;
            door_layer <= 1'b0; {dd0, dd1, dd2, dd3, dd4} <= 20'd0; door_cur <= 3'd0;
            r_run <= 3'b000; r_done <= 3'b000;
            toast <= TOAST_NONE; toast_t <= 8'd0; flash <= 8'd0; over_t <= 8'd0;
            cdesc <= DESC_NONE;
            dk_clear <= 1'b1; hs_clear <= 1'b1; an_reset <= 1'b1;
            if (full) inv_load <= 1'b1; else inv_restore <= 1'b1;
        end
    endtask
    // auto_answer(i): demo helper - fills puzzle i like a perfect player
    task auto_answer(input [2:0] i);
        begin
            case (i)
                3'd0: begin ans_a <= ANS_A; ans_v[0] <= 1'b1; end
                3'd1: begin p2t1 <= 8'b1100_1100; p2t2 <= 8'b0011_0011; p2t3 <= 8'd0;
                            p2_eq <= {8'd0, 8'b0011_0011, 8'b1100_1100}; end
                3'd2: begin p3 <= {3'd2, 3'd0, 3'd0, 3'd5, 3'd4, 3'd3, 3'd2, 3'd1, 3'd0};
                            ans_b <= 5'd7; ans_v[1] <= 1'b1; end
                3'd3: begin ans_c <= 4'd5; ans_v[2] <= 1'b1; end
                default: begin p5_0 <= PW0; p5_1 <= PW1; p5_2 <= PW2; end
            endcase
            done[i] <= 1'b1; right[i] <= 1'b1;
        end
    endtask

    // ---------------------------------------------------------------- main always block
    integer ii;
    always @(posedge clk) begin
        // one-cycle strobes
        lf_step <= 1'b0; lf_load <= 1'b0; dk_start <= 1'b0; dk_en <= 1'b0; dk_clear <= 1'b0; dk_setc <= 1'b0;
        inv_tick <= 1'b0; inv_load <= 1'b0; inv_restore <= 1'b0; inv_add_armor <= 1'b0;
        hs_clear <= 1'b0; hs_set <= 1'b0; door_dmg <= 1'b0;
        an_upd <= 1'b0; an_stop <= 1'b0; an_reset <= 1'b0; exit_req <= 1'b0;
        if (demo_cmd) begin dm_pend <= 1'b1; dm_op <= demo_op; dm_arg <= demo_arg; end

        if (rst) begin
            q <= Q_IDLE; show_help <= 1'b1; debug <= 1'b0; dm_pend <= 1'b0; form <= 2'd0;
            reset_stage(1'b1);
        end else if (enter) begin
            q <= Q_IDLE; show_help <= help_on_entry; reset_stage(1'b1);
        end else begin
            case (q)
            Q_IDLE: begin
                if (gtick) begin
                    {e_u, e_d, e_l, e_r, e_tap, e_back} <= {ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back};
                    cnt <= 3'd0; q <= Q_LFSR;
                end else if (dm_pend) begin
                    dm_pend <= 1'b0; q <= Q_DEMO;
                end
            end
            // ---- for _ in range(7): self.lfsr_step()
            Q_LFSR: begin
                lf_step <= 1'b1; cnt <= cnt + 3'd1;
                if (cnt == 3'd6) q <= Q_TOP;
            end
            Q_TOP: begin
                q <= Q_IDLE;
                if (flash != 8'd0) flash <= flash - 8'd1;
                if (toast_t != 8'd0) toast_t <= toast_t - 8'd1;
                if (show_help) begin
                    if (e_tap || e_back) show_help <= 1'b0;
                end else if (state == ST_CLEAR) begin
                    if (e_tap) exit_req <= 1'b1;
                end else if (state == ST_OVER) begin
                    // time.time() > over_until (= +3 s): true on the 181st update after the hit
                    if (over_t == 8'd0) reset_stage(1'b0);
                    else over_t <= over_t - 8'd1;
                end else begin
                    inv_tick <= 1'b1;              // slow_t / freeze_t -= dt
                    q <= Q_TRIG;
                end
            end
            // ---- card_trigger()
            Q_TRIG: begin
                q <= Q_DISP;
                if (!dk_active) begin
                    if (!r_run[1]) begin dk_round <= 2'd1; q <= Q_SHUF; end
                    else if (r_done[1] && !r_run[2] && n_done >= 3'd3) begin dk_round <= 2'd2; q <= Q_SHUF; end
                    else if (r_done[2] && !r_run[3] && n_done == 3'd5) begin dk_round <= 2'd3; q <= Q_SHUF; end
                end
            end
            Q_SHUF:  begin lf_step <= 1'b1; q <= Q_SHUFW; end           // lfsr_step()
            Q_SHUFW: q <= Q_SHUF2;                                        // (the step lands this cycle)
            Q_SHUF2: begin                                                // v = lfsr & 7; if v < 6: break
                if (lfsr[2:0] < 3'd6) begin
                    dk_perm <= lfsr[2:0]; dk_start <= 1'b1; r_run[dk_round] <= 1'b1; q <= Q_SHUF3;
                end else q <= Q_SHUF;
            end
            Q_SHUF3: q <= Q_DISP;
            // ---- update(): cards | notebook | map | close-up
            Q_DISP: begin
                q <= Q_IDLE;
                if (dk_active) begin an_stop <= 1'b1; dk_en <= 1'b1; end
                else if (sw[14]) an_stop <= 1'b1;
                else if (!mode_cu) begin
                    ox_i <= px_i; ox_f <= px_f; oy_i <= py_i; oy_f <= py_f;
                    q_x <= cx_i; q_y <= py_i; q <= Q_MXW;                // blocked(px + dx*sp, py)
                end else begin
                    an_stop <= 1'b1; q <= Q_CU;
                end
            end
            Q_MXW: q <= Q_MX;                                            // collision result is registered
            Q_MX: begin
                if (dxv && !blocked_r) begin px_i <= cx_i; px_f <= cx_f; q_x <= cx_i; end
                else q_x <= px_i;
                q_y <= cy_i; q <= Q_MYW;                                 // blocked(px, py + dy*sp)
            end
            Q_MYW: q <= Q_MY;
            Q_MY: begin
                if (dyv && !blocked_r) begin py_i <= cy_i; py_f <= cy_f; end
                q <= Q_ANIM;
            end
            Q_ANIM: begin
                an_upd <= 1'b1;
                an_dx <= {dxv, k_r}; an_dy <= {dyv, k_d};
                an_moved <= (px_i != ox_i) || (px_f != ox_f) || (py_i != oy_i) || (py_f != oy_f);
                if (e_tap) begin nb_i <= 3'd0; nb_v <= 1'b0; nb_ph <= 2'd0; q <= Q_NEAR; end
                else q <= Q_IDLE;
            end
            Q_NEAR: begin                                                // find_near(), 4 cycles / object
                nb_ph <= nb_ph + 2'd1;
                case (nb_ph)
                    2'd0: begin nb_dx <= dxt; nb_dy <= dyt; nb_r2c <= nr * nr; end
                    2'd1: begin nb_d2c <= nb_dx * nb_dx + nb_dy * nb_dy; nb_lim <= nb_r2c * 100; end
                    2'd2: begin nb_lhs <= nb_d2c * nb_r2; nb_rhs <= nb_d2 * nb_r2c; end
                    default: begin
                        if (nb_d2c <= nb_lim && (!nb_v || nb_lhs < nb_rhs)) begin
                            nb_v <= 1'b1; nb_best <= nb_i; nb_d2 <= nb_d2c[29:0]; nb_r2 <= nb_r2c;
                        end
                        if (nb_i == 3'd7) q <= Q_NEAR2; else nb_i <= nb_i + 3'd1;
                    end
                endcase
            end
            Q_NEAR2: begin
                q <= Q_IDLE;
                if (nb_v) begin
                    mode_cu <= 1'b1; cur <= nb_best; page <= 2'd0; cmsg <= CMSG_NONE; an_stop <= 1'b1;
                    if (nb_best == O_SCREEN && !lights) p5_seen <= 1'b1;
                end
            end
            // ---- closeup_input()
            Q_CU: begin
                q <= Q_IDLE;
                if (e_back) begin
                    if (page != 2'd0 && paged(cur)) page <= page - 2'd1;
                    else mode_cu <= 1'b0;
                    cmsg <= CMSG_NONE;
                end else case (cur)
                O_WB: if (e_tap) begin                                     // puzzle 1
                    if (page == 2'd0) page <= 2'd1;
                    else begin
                        note_push(3'd1, {20'd0, p1_val});
                        commit(3'd0, p1_val == ANS_A, CMSG_REC);
                        ans_a <= p1_val; ans_v[0] <= 1'b1;
                    end
                end
                O_PAPER: begin                                             // puzzle 2
                    if (page == 2'd0) begin if (e_tap) page <= 2'd1; end
                    else if (e_l) p2_cur <= (p2_cur == 2'd0) ? 2'd2 : p2_cur - 2'd1;
                    else if (e_r) p2_cur <= (p2_cur == 2'd2) ? 2'd0 : p2_cur + 2'd1;
                    else if (e_tap) begin
                        case (p2_cur) 2'd0: p2t1 <= sw[7:0]; 2'd1: p2t2 <= sw[7:0]; default: p2t3 <= sw[7:0]; endcase
                        cmsg <= CMSG_STORED; cmsg_p <= {2'd0, p2_cur} + 4'd1;
                    end else if (e_d) begin
                        case (p2_cur) 2'd0: p2t1 <= 8'd0; 2'd1: p2t2 <= 8'd0; default: p2t3 <= 8'd0; endcase
                        cmsg <= CMSG_CLEARED; cmsg_p <= {2'd0, p2_cur} + 4'd1;
                    end else if (e_u) begin
                        if (p2t1[7:4] == 4'd0 && p2t2[7:4] == 4'd0 && p2t3[7:4] == 4'd0) cmsg <= CMSG_NOTERM;
                        else begin
                            p2_eq <= {p2t3, p2t2, p2t1};
                            note_push(3'd2, {p2t3, p2t2, p2t1});
                            commit(3'd1, p2_ok, CMSG_REC);
                        end
                    end
                end
                O_NAND: begin                                              // puzzle 3
                    if (page == 2'd0) begin if (e_tap) page <= 2'd1; end
                    else if (e_l) p3_cur <= (p3_cur == 4'd0) ? 4'd8 : p3_cur - 4'd1;
                    else if (e_r) p3_cur <= (p3_cur == 4'd8) ? 4'd0 : p3_cur + 4'd1;
                    else if (e_u || e_d) begin
                        // n = 4 if c == 8 else 4 + c // 2 ;  p3[c] = (p3[c] +- 1) % n
                        p3[3*p3_cur +: 3] <= e_u ?
                            ((p3[3*p3_cur +: 3] + 3'd1 >= p3n(p3_cur)) ? 3'd0 : p3[3*p3_cur +: 3] + 3'd1) :
                            ((p3[3*p3_cur +: 3] == 3'd0) ? p3n(p3_cur) - 3'd1 : p3[3*p3_cur +: 3] - 3'd1);
                    end else if (e_tap) begin
                        note_push(3'd3, 24'd0);
                        commit(3'd2, p3_t == P2_TRUTH, CMSG_CIRC);
                        ans_b <= popcount16(p3_t); ans_v[1] <= 1'b1;
                    end
                end
                O_TWOS: if (e_tap) begin                                   // puzzle 4
                    if (page == 2'd0) page <= 2'd1;
                    else begin
                        note_push(3'd4, {16'd0, p4_val});
                        commit(3'd3, p4_val == P4_ANSWER, CMSG_VAL);
                        ans_c <= popcount8(p4_val); ans_v[2] <= 1'b1;
                    end
                end
                O_LIGHTSW: if (e_tap) begin
                    lights <= !lights; say(lights ? TOAST_LOFF : TOAST_LON);
                end
                O_PC: begin                                                // puzzle 5 (login)
                    if (done[4]) begin
                        if (e_d || e_tap) page <= (page == 2'd2) ? 2'd2 : page + 2'd1;
                        else if (e_u) page <= (page == 2'd0) ? 2'd0 : page - 2'd1;
                    end
                    else if (e_u) p5_cur <= (p5_cur == 2'd0) ? 2'd2 : p5_cur - 2'd1;
                    else if (e_d) p5_cur <= (p5_cur == 2'd2) ? 2'd0 : p5_cur + 2'd1;
                    else if (e_l || e_r) begin
                        case (p5_cur)
                            2'd0: p5_0 <= l26(p5_0, e_r);
                            2'd1: p5_1 <= l26(p5_1, e_r);
                            default: p5_2 <= l26(p5_2, e_r);
                        endcase
                    end else if (e_tap) begin
                        note_push(3'd5, {3'd0, p5_2, 3'd0, p5_1, 3'd0, p5_0});
                        if (p5_0 == PW0 && p5_1 == PW1 && p5_2 == PW2) begin
                            commit(3'd4, 1'b1, CMSG_GRANTED); page <= 2'd0;
                        end else cmsg <= CMSG_BADPASS;
                    end
                end
                O_DOOR: begin                                              // door, 2 layers
                    if (e_l) door_cur <= (door_cur == 3'd0) ? door_n - 3'd1 : door_cur - 3'd1;
                    else if (e_r) door_cur <= (door_cur == door_n - 3'd1) ? 3'd0 : door_cur + 3'd1;
                    else if (e_u || e_d) begin
                        case (door_cur)
                            3'd0: dd0 <= d10(dd0, e_u); 3'd1: dd1 <= d10(dd1, e_u); 3'd2: dd2 <= d10(dd2, e_u);
                            3'd3: dd3 <= d10(dd3, e_u); default: dd4 <= d10(dd4, e_u);
                        endcase
                    end else if (e_tap) begin                              // door_confirm()
                        if (door_layer ? ({dd0, dd1, dd2, dd3, dd4} == L2C) : ({dd0, dd1} == L1C)) begin
                            {dd0, dd1, dd2, dd3, dd4} <= 20'd0; door_cur <= 3'd0;
                            if (!door_layer) begin door_layer <= 1'b1; cmsg <= CMSG_LOCK1; end
                            else begin state <= ST_CLEAR; form <= 2'd1; end
                        end else begin
                            cmsg <= CMSG_WRONG; door_dmg <= 1'b1;          // -> heart_system ONLY
                        end
                    end
                end
                default: ;                                                 // projector: look only
                endcase
            end
            // ---- demo hub (jump_to / do_action / set_*), executed between ticks
            Q_DEMO: begin
                q <= Q_IDLE;
                case (dm_op)
                    4'd1, 4'd2, 4'd3, 4'd4, 4'd5: begin        // jump_to start r2 r3 door clear
                        reset_stage(1'b1); form <= form; show_help <= 1'b0;
                        if (dm_op == 4'd5) begin state <= ST_CLEAR; form <= 2'd1; end
                        else if (dm_op != 4'd1) begin
                            for (ii = 0; ii < 5; ii = ii + 1)
                                if (ii < 3 || dm_op != 4'd2) auto_answer(ii[2:0]);
                            dk_setc <= 1'b1; dk_setcv <= 2'd0;
                            hint_seen <= 5'b00100; hint2 <= 3'd3;            // add_hint("P3")
                            r_run[1] <= 1'b1; r_done[1] <= 1'b1;
                            if (dm_op != 4'd2) begin r_run[2] <= 1'b1; r_done[2] <= 1'b1; end
                            if (dm_op == 4'd4) begin r_run[3] <= 1'b1; r_done[3] <= 1'b1; end
                        end
                    end
                    4'd6: begin                                 // door_wrong: at the door, A is wrong
                        reset_stage(1'b1); form <= form; show_help <= 1'b0;
                        for (ii = 0; ii < 5; ii = ii + 1) auto_answer(ii[2:0]);
                        dk_setc <= 1'b1; dk_setcv <= 2'd0; hint_seen <= 5'b00100; hint2 <= 3'd3;
                        r_run <= 3'b111; r_done <= 3'b111;
                        ans_a <= ANS_A + 4'd1; right[0] <= 1'b0;
                    end
                    4'd7: begin inv_add_armor <= 1'b1; say(TOAST_ARMORP); end
                    4'd8: begin hs_set <= 1'b1; hs_setv <= dm_arg[1:0]; if (state == ST_OVER) state <= ST_PLAY; end
                    4'd9: form <= dm_arg[1:0];
                    4'd10: debug <= !debug;
                    4'd11: begin                                // cheat_solve (F5)
                        if (!done[0]) begin auto_answer(3'd0); say(TOAST_DBG1); end
                        else if (!done[1]) begin auto_answer(3'd1); say(TOAST_DBG2); end
                        else if (!done[2]) begin auto_answer(3'd2); say(TOAST_DBG3); end
                        else if (!done[3]) begin auto_answer(3'd3); say(TOAST_DBG4); end
                        else if (!done[4]) begin auto_answer(3'd4); say(TOAST_DBG5); end
                    end
                    4'd12: begin reset_stage(1'b1); show_help <= 1'b0; end     // restart stage
                    4'd13: begin lf_load <= 1'b1; lf_seed <= dm_arg; end       // seed the LFSR (tests)
                    4'd14: show_help <= 1'b0;
                    default: ;
                endcase
            end
            default: q <= Q_IDLE;
            endcase

            // ---- events coming back from the shared modules (any cycle)
            if (dk_rdone) r_done[dk_rnd] <= 1'b1;
            if (dk_grant) begin                                           // grant(item)
                case (dk_item)
                    IT_HINT_HARD:  begin add_hint(3'd3); cdesc <= DESC_H3; end
                    IT_HINT_SMART: begin
                        if (smart_key == 3'd0) cdesc <= DESC_NOHINT;
                        else begin add_hint(smart_key); cdesc <= DESC_NONE + {5'd0, smart_key}; end
                    end
                    IT_UNDO: begin                                        // apply_undo()
                        if (!undo_v) cdesc <= DESC_NOUNDO;
                        else begin
                            ans_a <= undo_a; ans_b <= undo_b; ans_c <= undo_c; ans_v <= undo_av;
                            done[undo_i] <= undo_done; right[undo_i] <= undo_right;
                            if (undo_i == 3'd1 && !undo_done) p2_eq <= 24'd0;
                            undo_v <= 1'b0;
                            cdesc <= DESC_U1 + {5'd0, undo_i};
                        end
                    end
                    IT_SHARD:  cdesc <= shard ? DESC_FORGED : DESC_SHARD1;
                    IT_BOOST:  cdesc <= DESC_BOOST;
                    IT_ARMOR:  cdesc <= DESC_ARMOR;
                    IT_SLOW:   cdesc <= DESC_SLOW;
                    IT_FREEZE: cdesc <= DESC_FREEZE;
                    default:   cdesc <= DESC_NONE;
                endcase
            end
            if (hs_blocked) say(TOAST_ARMOR);
            if (hs_hit) begin
                flash <= FLASH_FRAMES;
                if (!hs_dead) say(TOAST_WRONG);
            end
            if (hs_dead) begin state <= ST_OVER; over_t <= OVER_FRAMES; end
        end
    end

    function [2:0] p3n(input [3:0] c);   // number of choices of field c
        p3n = (c == 4'd8) ? 3'd4 : 3'd4 + {1'b0, c[2:1]};
    endfunction
    function [4:0] l26(input [4:0] x, input up);
        l26 = up ? ((x == 5'd25) ? 5'd0 : x + 5'd1) : ((x == 5'd0) ? 5'd25 : x - 5'd1);
    endfunction
    function [3:0] d10(input [3:0] x, input up);
        d10 = up ? ((x == 4'd9) ? 4'd0 : x + 4'd1) : ((x == 4'd0) ? 4'd9 : x - 4'd1);
    endfunction

    // ================================================================ camera + screen positions
    // camera(): cx = clamp(px - 500, 0, 1000), cy = clamp(py - 60 - 281.25, 0, 553.5); screen = world*0.64
    wire signed [15:0] pxt = $signed({1'b0, px_i} * 16'd10) + $signed({12'd0, px_f});
    wire signed [15:0] pyt = $signed({1'b0, py_i} * 16'd10) + $signed({12'd0, py_f});
    wire signed [15:0] cxr = pxt - 16'sd5000;
    wire [13:0] cx10 = (cxr < 0) ? 14'd0 : (cxr > 16'sd10000) ? 14'd10000 : cxr[13:0];
    wire signed [16:0] cyr = {pyt, 1'b0} - 17'sd6825;                 // in 1/20 px
    wire [13:0] cy20 = (cyr < 0) ? 14'd0 : (cyr > 17'sd11070) ? 14'd11070 : cyr[13:0];
    wire [29:0] camx_m = cx10 * 16'd4194;                              // *0.064
    wire [29:0] camy_m = cy20 * 16'd2097;                              // *0.032
    reg [10:0] cam_x_r; reg [9:0] cam_y_r;
    always @(posedge clk) begin cam_x_r <= camx_m[26:16]; cam_y_r <= camy_m[25:16]; end
    assign cam_x = cam_x_r;
    assign cam_y = cam_y_r;
    wire signed [16:0] fxd = pxt - $signed({3'd0, cx10});
    wire signed [17:0] fyd = $signed({pyt + 16'sd40, 1'b0}) - $signed({4'd0, cy20});
    wire signed [33:0] fxm = fxd * 17'sd4194;
    wire signed [33:0] fym = fyd * 18'sd2097;
    wire [11:0] psx = fxm[27:16];
    wire [11:0] psy = fym[27:16];

    // ================================================================ UI contract
    function [23:0] w24(input [23:0] x); w24 = x; endfunction
    reg [3071:0] F;
    reg [255:0]  C;
    reg [3071:0] F_r;                               // registered at the module boundary: the composer and
    reg [255:0]  C_r;                               // renderer never see a long combinational path
    always @(posedge clk) begin F_r <= F; C_r <= C; end
    assign fields = F_r;
    assign conds  = C_r;
    wire deck_on = dk_active;
    wire [1:0] cimg_idx0 = pidx(dk_pm, 2'd0), cimg_idx1 = pidx(dk_pm, 2'd1), cimg_idx2 = pidx(dk_pm, 2'd2);
    function [5:0] cimg(input [1:0] r, input [1:0] pos, input [1:0] idx, input fu, input [1:0] fc, input [1:0] car);
        cimg = (r == 2'd1) ? ((fu && fc == pos) ? 6'd51 + idx : 6'd48 + idx) : 6'd54 + car * 3 + pos;
    endfunction
    wire [23:0] slow_s   = round_secs(slow_f);
    wire [23:0] freeze_s = round_secs({1'b0, freeze_f});
    function [23:0] round_secs(input [9:0] f);     // '%.0f' % (frames / 60), round half to even
        reg [9:0] qq, rr;
        begin
            qq = f / 60; rr = f - qq * 60;
            round_secs = (rr > 30 || (rr == 30 && qq[0])) ? qq + 1 : qq;
        end
    endfunction
    integer n;
    always @(*) begin
        F = 3072'd0;
        F[24*F_HEARTS +: 24]   = hearts;
        F[24*F_ARMOR +: 24]    = armor;
        F[24*F_SLOW_S +: 24]   = slow_s;
        F[24*F_FREEZE_S +: 24] = freeze_s;
        F[24*F_PSX +: 24]      = {{12{psx[11]}}, psx};
        F[24*F_PSY +: 24]      = {{12{psy[11]}}, psy};
        F[24*F_PFRAME +: 24]   = form * 12 + sdir * 3 + spose;
        F[24*F_CAMXN +: 24]    = -{13'd0, cam_x};
        F[24*F_CAMYN +: 24]    = -{14'd0, cam_y};
        F[24*F_FLASH_A +: 24]  = (flash * 15) >> 5;
        F[24*F_P1VAL +: 24]    = p1_val;
        F[24*F_P4VAL +: 24]    = p4_val;
        F[24*F_ANS_A +: 24]    = ans_a;
        F[24*F_ANS_B +: 24]    = ans_b;
        F[24*F_ANS_C +: 24]    = ans_c;
        F[24*F_P2_T1 +: 24]    = p2t1;
        F[24*F_P2_T2 +: 24]    = p2t2;
        F[24*F_P2_T3 +: 24]    = p2t3;
        F[24*F_P2_SW +: 24]    = sw[7:0];
        F[24*F_P2_EQN +: 24]   = p2_eq;
        F[24*F_P2_CUR +: 24]   = p2_cur;
        for (n = 0; n < 9; n = n + 1) F[24*(F_P3_0 + n) +: 24] = p3[3*n +: 3];
        F[24*F_P3_OUTN +: 24]  = p3[26:24] + 3'd1;
        F[24*F_P3_CUR +: 24]   = p3_cur;
        F[24*F_P3_TAB +: 24]   = p3_t;
        F[24*F_P5_L0 +: 24]    = p5_0;
        F[24*F_P5_L1 +: 24]    = p5_1;
        F[24*F_P5_L2 +: 24]    = p5_2;
        F[24*F_P5_CUR +: 24]   = p5_cur;
        F[24*F_DOOR_D0 +: 24]  = dd0; F[24*F_DOOR_D1 +: 24] = dd1; F[24*F_DOOR_D2 +: 24] = dd2;
        F[24*F_DOOR_D3 +: 24]  = dd3; F[24*F_DOOR_D4 +: 24] = dd4;
        F[24*F_DOOR_CUR +: 24] = door_cur;
        F[24*F_DOOR_LNUM +: 24]= door_layer + 1'b1;
        F[24*F_DOOR_N +: 24]   = door_n;
        F[24*F_CMSG +: 24]     = cmsg;
        F[24*F_CMSG_P +: 24]   = cmsg_p;
        F[24*F_TOAST +: 24]    = toast;
        F[24*F_OBJ +: 24]      = cur;
        F[24*F_PAGE +: 24]     = page;
        F[24*F_CARD_CUR +: 24] = dk_cursor;
        F[24*F_CARD_ROUND +: 24] = dk_rnd;
        F[24*F_CIMG0 +: 24]    = cimg(dk_rnd, 2'd0, cimg_idx0, dk_face_up, dk_face, career);
        F[24*F_CIMG1 +: 24]    = cimg(dk_rnd, 2'd1, cimg_idx1, dk_face_up, dk_face, career);
        F[24*F_CIMG2 +: 24]    = cimg(dk_rnd, 2'd2, cimg_idx2, dk_face_up, dk_face, career);
        F[24*F_CNAME +: 24]    = dk_item;
        F[24*F_CDESC +: 24]    = cdesc;
        F[24*F_CAREER +: 24]   = career;
        F[24*F_CSYM0 +: 24]    = career * 3;
        F[24*F_CSYM1 +: 24]    = career * 3 + 1;
        F[24*F_CSYM2 +: 24]    = career * 3 + 2;
        F[24*F_HINT0 +: 24]    = hint0;
        F[24*F_HINT1 +: 24]    = hint1;
        F[24*F_HINT2 +: 24]    = hint2;
        for (n = 0; n < 8; n = n + 1) begin
            F[24*(F_NOTE_T0 + n) +: 24] = note_t[n];
            F[24*(F_NOTE_V0 + n) +: 24] = note_v[n];
        end
        F[24*F_FORM +: 24]       = form;
        F[24*F_CLEAR_FORM +: 24] = 24'd1;

        C = 256'd0;
        C[0] = 1'b1;
        C[C_HELP]     = show_help;
        C[C_PLAY]     = (state == ST_PLAY);
        C[C_OVER]     = (state == ST_OVER);
        C[C_CLEAR]    = (state == ST_CLEAR);
        C[C_MAP]      = !mode_cu;
        C[C_CLOSEUP]  = mode_cu;
        C[C_DECK]     = deck_on;
        C[C_NOTEBOOK] = sw[14];
        C[C_LIGHTS]   = lights;
        C[C_DEBUG]    = debug;
        C[C_STANDALONE] = !has_next;
        C[C_CU_WB] = mode_cu && cur == O_WB;         C[C_CU_PAPER] = mode_cu && cur == O_PAPER;
        C[C_CU_NAND] = mode_cu && cur == O_NAND;     C[C_CU_TWOS] = mode_cu && cur == O_TWOS;
        C[C_CU_SCREEN] = mode_cu && cur == O_SCREEN; C[C_CU_PC] = mode_cu && cur == O_PC;
        C[C_CU_LIGHTSW] = mode_cu && cur == O_LIGHTSW; C[C_CU_DOOR] = mode_cu && cur == O_DOOR;
        C[C_PAGE0] = page == 2'd0; C[C_PAGE1] = page == 2'd1; C[C_PAGE2] = page == 2'd2;
        C[C_HEART1] = hearts > 2'd0; C[C_HEART2] = hearts > 2'd1; C[C_HEART3] = hearts > 2'd2;
        C[C_ARMOR_ON] = armor != 2'd0;
        C[C_SLOW_ON] = slow_f != 10'd0;
        C[C_FREEZE_ON] = freeze_f != 9'd0;
        C[C_FLASH_ON] = flash != 8'd0;
        C[C_TOAST_ON] = toast_t != 8'd0;
        C[C_DONE1] = done[0]; C[C_DONE2] = done[1]; C[C_DONE3] = done[2]; C[C_DONE4] = done[3]; C[C_DONE5] = done[4];
        C[C_ANSA_V] = ans_v[0]; C[C_ANSB_V] = ans_v[1]; C[C_ANSC_V] = ans_v[2];
        for (n = 0; n < 8; n = n + 1) C[C_SW0 + n] = sw[n];
        for (n = 0; n < 9; n = n + 1) C[C_P3F0 + n] = (p3_cur == n);
        C[C_DOOR_L2] = door_layer;
        C[C_CMSG_ON] = cmsg != CMSG_NONE;
        C[C_CMSG_TN] = (cmsg == CMSG_STORED) || (cmsg == CMSG_CLEARED);
        C[C_CARD_FACEUP] = dk_face_up;
        C[C_CARD_R1] = dk_rnd == 2'd1;
        C[C_CAREER_V] = dk_cvalid;
        C[C_CF0] = dk_face_up && dk_face == 2'd0; C[C_CF1] = dk_face_up && dk_face == 2'd1;
        C[C_CF2] = dk_face_up && dk_face == 2'd2;
        for (n = 0; n < 8; n = n + 1) begin
            C[C_NOTE_V0 + n] = (n < note_n);
            C[C_NOTE_D0 + n] = (n < note_n) && (note_t[n] == 3'd1 || note_t[n] == 3'd4);
            C[C_NOTE_E0 + n] = (n < note_n) && (note_t[n] == 3'd2);
            C[C_NOTE_L0 + n] = (n < note_n) && (note_t[n] == 3'd5);
        end
        C[C_HINT_V0] = hint0 != 3'd0; C[C_HINT_V1] = hint1 != 3'd0; C[C_HINT_V2] = hint2 != 3'd0;
        C[C_STAGE1] = 1'b1;
        for (n = 0; n < 3; n = n + 1) begin
            C[C_P2C0 + n] = (p2_cur == n);
            C[C_P5C0 + n] = (p5_cur == n);
            C[C_CARD_C0 + n] = !dk_face_up && (dk_cursor == n);
        end
        for (n = 0; n < 5; n = n + 1) C[C_DOOR_C0 + n] = (door_cur == n);
    end

    // background: room with camera on the map, plain dark fill in close-ups, green on the clear screen
    assign bg_mode  = (state == ST_CLEAR) ? 2'd0 : mode_cu ? 2'd0 : 2'd1;
    assign bg_color = (state == ST_CLEAR) ? 12'h021 : 12'h112;     // (15,40,25) / (18,20,26)

    // ================================================================ board outputs (draw_panel)
    assign leds = {4'd0, slow, freeze_f != 9'd0, lights, done, armor != 2'd0,
                   hearts > 2'd2, hearts > 2'd1, hearts > 2'd0};
    assign rgb16 = !dk_cvalid ? 3'b000 : (career == 2'd0) ? 3'b010 : (career == 2'd1) ? 3'b110 : 3'b100;
    // RGB LED17 = status at a glance ({R,G,B}), highest priority first:
    //   damage flash / out of hearts -> red   stage clear -> green   Freeze -> cyan
    //   Slow -> yellow   holding armor -> blue   otherwise off
    // (board-only feedback: the VGA picture and the Pygame comparison do not depend on it)
    assign rgb17 = (flash != 8'd0)      ? 3'b100 :
                   (state == ST_OVER)   ? 3'b100 :
                   (state == ST_CLEAR)  ? 3'b010 :
                   (freeze_f != 9'd0)   ? 3'b011 :
                   slow                 ? 3'b110 :
                   (armor != 2'd0)      ? 3'b001 : 3'b000;
    // 7-seg: "H" + hearts + seg_right().rjust(6)
    function [4:0] dg(input [3:0] x); dg = {1'b0, x}; endfunction
    reg [29:0] rj;     // 6 chars, rj[29:25] = leftmost
    reg [7:0]  tmp;
    always @(*) begin
        rj = {6{SG_BLANK}};
        if (state == ST_CLEAR) rj = {SG_BLANK, SG_BLANK, SG_P, SG_A, 5'd5, 5'd5};
        else if (state == ST_OVER) rj = {SG_BLANK, SG_BLANK, SG_D, SG_E, SG_A, SG_D};
        else if (mode_cu && !dk_active) begin
            if (cur == O_WB && page == 2'd1)
                rj = (p1_val >= 4'd10) ? {{4{SG_BLANK}}, 5'd1, dg(p1_val - 4'd10)} : {{5{SG_BLANK}}, dg(p1_val)};
            else if (cur == O_TWOS && page == 2'd1)
                rj = (p4_val >= 8'd100) ? {{3{SG_BLANK}}, dg(p4_val / 100), dg((p4_val / 10) % 10), dg(p4_val % 10)} :
                     (p4_val >= 8'd10)  ? {{4{SG_BLANK}}, dg(p4_val / 10), dg(p4_val % 10)} :
                                          {{5{SG_BLANK}}, dg(p4_val[3:0])};
            else if (cur == O_DOOR)
                rj = door_layer ? {SG_BLANK, dg(dd0), dg(dd1), dg(dd2), dg(dd3), dg(dd4)} :
                                  {{4{SG_BLANK}}, dg(dd0), dg(dd1)};
            else if (cur == O_PC && !done[4])
                rj = join3(p5_0, p5_1, p5_2);
        end
        seg_chars = {SG_H, (hearts == 2'd0) ? 5'd0 : {3'd0, hearts}, rj};
    end
    function [29:0] join3(input [4:0] a, input [4:0] b, input [4:0] c);   // "".join(str(v) for v in p5)
        reg [29:0] s; integer j; reg [4:0] x;
        begin
            s = {6{SG_BLANK}};
            for (j = 0; j < 3; j = j + 1) begin
                x = (j == 0) ? a : (j == 1) ? b : c;
                if (x >= 5'd20) s = {s[19:0], 5'd2, dg(x - 5'd20)};
                else if (x >= 5'd10) s = {s[19:0], 5'd1, dg(x - 5'd10)};
                else s = {s[24:0], dg(x[3:0])};
            end
            join3 = s;
        end
    endfunction

    // ================================================================ handoff + observation
    assign out_armor = armor;
    assign out_shard = shard;
    assign out_boost = boost;
    assign out_form  = form;
    assign dbg_px = px_i; assign dbg_py = py_i; assign dbg_pxf = px_f; assign dbg_pyf = py_f;
    assign dbg_done = done; assign dbg_right = right; assign dbg_hearts = hearts; assign dbg_lfsr = lfsr;
    assign dbg_state = {mode_cu, state == ST_OVER, state == ST_CLEAR};
endmodule
