// cr_core.v - Stage 3 "Campus Run" game logic (onlystage_3/game.py) as a sequencer.
// Reference: tools/cr_model.py, bit for bit after every 1/120 s step (tb/cr_tb_cosim.v + tools/cr_cosim.py cmp).
//
// Built so far: player physics, jump / double jump / coyote / buffer, collision against the 250 x 11 tile grid and
// the extra boxes (the stage-2 "?" box), deaths (fall, water, time-out), restart, pause, the commands STAGE and
// PUT (Task 7); the animals - patrol, follower, walk + water, fly, pop - and their contact test (Task 8); the
// reporter (chase, interview, cloak follow, retreat), the skills Cloak and Phase, the lifts, the "?" box and
// the milk tea, the doors, level clear / win, near-finish message, progress, commands SEED / WIN / GOLD (Task 9).
//
// Numbers (cr_model.py): 1 m = Q = 600*4096 units; player x / y / speeds / gravity carry 8 more fraction bits
// ("F units"). The grid is visited in the game's list order - rows top to bottom, columns left to right, then
// the extra boxes - one box per two clocks, because that order decides which surface a fast fall lands on.
//
// Inputs: btn_left/btn_right are levels; ev_jump / ev_skill / ev_menu are one-clock pulses valid with gtick.
// Each gtick runs STEPS_PER_TICK steps (2 on the board: 120 steps/s at the 60 Hz tick); jump and skill count for
// the first of them only. demo_cmd (op, arg) is a command applied between steps:
//   1 STAGE  restart at stage arg (1..3)      2 PUT  player to x = arg[8:0]/2 m, y = arg[13:9]/2 m, standing arg[14]
//   3 SEED   random generator state = arg (0 means 0xACE1)    4 WIN  confirm on the win screen (exit_req)
//   5 GOLD   the milk tea's power without the tea
// enter starts a new game at level 1 and cancels presses arriving with it (a button held into the stage).
// WIN screen (stage3_demo.py poll/update): a jump press, or a menu press made while the WIN screen is already
// up, confirms after the tick's steps -> exit_req.
// A command, enter or gtick arriving while busy is kept and handled when the core is free (commands first),
// so no press is lost; presses that arrive before a waiting tick is handled join that tick.
`timescale 1ns/1ps
module cr_core #(
    parameter MEM_DIR        = "mem/",
    parameter STEPS_PER_TICK = 2,
    parameter TEST_MODE      = 0         // 0 the game; 1 no animals, no lifts (Task 7 stimulus);
                                         // 2 animals but no lifts, a contact starts nothing (Task 8 stimulus)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        gtick,
    input  wire        btn_left,
    input  wire        btn_right,
    input  wire        ev_jump,
    input  wire        ev_skill,
    input  wire        ev_menu,
    input  wire        enter,            // stage entry: a new game from level 1
    input  wire        demo_cmd,
    input  wire [3:0]  demo_op,
    input  wire [15:0] demo_arg,
    output wire        exit_req,
    output reg         step_done,        // one clock after each finished step
    output wire        busy,
    output wire [2:0]  mode,
    output wire [1:0]  level,
    output reg  [12:0] cam_px,
    input  wire [5:0]  q_idx,
    output wire [31:0] q_data
);
`include "cr_consts.vh"

    localparam PLAY = 2'd0, PAUSE = 2'd1, CLEAR = 2'd2, WIN = 2'd3;
    localparam OP_STAGE = 4'd1, OP_PUT = 4'd2, OP_SEED = 4'd3, OP_WIN = 4'd4, OP_GOLD = 4'd5;
    localparam M_MUL = 2'd0, M_DIV = 2'd1, M_SQRT = 2'd2;
    // what the box walker does with each box
    localparam W_XPASS = 4'd0, W_YPASS = 4'd1, W_REACH = 4'd2, W_WATER = 4'd3, W_BLOCK = 4'd4, W_PLACE = 4'd5,
               W_TEA = 4'd6, W_RPUSH = 4'd7, W_RTOPS = 4'd8;

    // ---------------- the level grid: one 11-bit word per column, bit r = world row r ----------------
    reg [10:0] solid_rom [0:767];
    reg [10:0] water_rom [0:767];
    initial begin
        $readmemh({MEM_DIR, "cr_solid.mem"}, solid_rom);
        $readmemh({MEM_DIR, "cr_water.mem"}, water_rom);
    end

    // ---------------- state (names as in cr_model.Model) ----------------
    reg [1:0]  stage;                    // 1..3
    reg [1:0]  mode_r;
    reg signed [47:0] xf, yf, vyf, takeoff, old_xf, old_yf;
    reg signed [47:0] gf;                // always >= 0
    reg signed [47:0] vxf;               // always >= 0
    reg [1:0]  jumps;
    reg [7:0]  elapsed;
    reg        grounded, walking, face_l;
    reg [4:0]  grace, buffer;
    reg signed [47:0] cam;
    reg [47:0] stride;
    reg [13:0] time_left;
    reg        died;
    // ---------------- flow, reporter, skills, objects (Task 9) ----------------
    reg [13:0] now;                      // steps since the restart
    reg [8:0]  notice;
    reg [3:0]  message, rs_msg;
    reg [9:0]  skill, interview;
    reg [6:0]  protection, follow;
    reg [7:0]  retreat, clear_left;
    reg [5:0]  flash;
    reg [8:0]  grow;
    reg        used, chase, near, gold, opened, exit_r, sl, tick_jump, conf_menu;
    reg [3:0]  q0, q1;
    reg [6:0]  prog;
    reg        tea_on;
    reg signed [47:0] tea_x, tea_y, tea_vy, tea_old;       // units
    reg        lifts_on, ld0_dn, ld1_dn;
    reg signed [47:0] lt0, lt1;                            // lift tops, units
    reg signed [47:0] rx, ry, rvy;                         // reporter: x units; y, vy F units
    reg        rdir_l, rvisible, rwalking;
    reg signed [47:0] last_xf;
    // the player's route (newest at head + cnt - 1) and the reporter's trail (newest at tail - 1)
    reg [15:0] rt_step [0:63];
    reg signed [47:0] rt_x [0:63];
    reg signed [47:0] rt_y [0:63];
    reg        rt_walk [0:63];
    reg        rt_gnd [0:63];
    reg [5:0]  rt_head;
    reg [6:0]  rt_cnt;
    reg signed [47:0] tr_x [0:511];
    reg signed [47:0] tr_y [0:511];
    reg        tr_d [0:511];
    reg [8:0]  tr_tail;
    reg [9:0]  tr_cnt;
    // subroutine working values
    reg signed [47:0] bk_x, bk_y, bk_w, bk_h;              // blocked(): the box, units
    reg signed [47:0] pl_tx, pl_ty, best_s, best_x, best_y, prev_s, prev_x, prev_y, c_s, c_x, c_y;
    reg        pl_behind, have_prev, have_best, pl_ok, c_ok, c_far, c_near;
    reg signed [47:0] c_dx, c_dy;
    reg signed [47:0] f_x, f_y;
    reg        f_walk, f_gnd, f_still;
    reg signed [47:0] r_old, r_tgt, r_y0, r_den, r_h, r_prev, rp_y, rt_best;
    reg        r_neg, r_negq, rt_have;
    // boxes outside the grid, in F units: 0 = the stage-2 "?" box (lifts follow in Task 9)
    reg [2:0]  ex_v;
    reg signed [47:0] ex_x [0:2];
    reg signed [47:0] ex_y [0:2];
    reg signed [47:0] ex_w [0:2];
    reg signed [47:0] ex_h [0:2];

    // ---------------- animals ----------------
    localparam PATROL = 2'd0, WALK = 2'd1, FLY = 2'd2, POP = 2'd3;
    localparam SC_PATROL = 2'd0, SC_STEP = 2'd1, SC_FALL = 2'd2, SC_WATER = 2'd3;
    reg [CR_ENT_W-1:0] ent_rom [0:191];       // cr_assets.ENT_FIELDS, level*64 + index
    reg               edge_rom [0:34815];     // cr_assets.edge_bits patterns, pattern*512 + mark
    initial begin
        $readmemh({MEM_DIR, "cr_ent.mem"}, ent_rom);
        $readmemh({MEM_DIR, "cr_edge.mem"}, edge_rom);
    end
    reg [15:0] lfsr;
    reg [6:0]  n_ents;                        // animals of this level (0 in TEST_MODE 1)
    reg [63:0] e_active, e_alive, contacts, contacts_new;
    reg signed [31:0] e_x [0:63];
    reg signed [31:0] e_y [0:63];
    reg signed [31:0] e_vy [0:63];
    reg        e_dl [0:63];                   // 1: moving left (direction -1)
    reg [6:0]  e_exp [0:63];                  // exposure 0..120
    reg [9:0]  e_phase [0:63];
    reg [3:0]  e_wl [0:63];                   // waterline = e_wl * Q, 0 = none
    reg [8:0]  e_marks [0:63];
    reg [2:0]  e_skin [0:63];
    reg [2:0]  e_slot [0:63];                 // follower: which path ring
    reg signed [31:0] p_x [0:511];            // follower paths: slot*64 + entry
    reg signed [31:0] p_y [0:511];
    reg        p_d [0:511];
    reg [5:0]  p_w [0:7];                     // next entry to write
    reg [5:0]  p_cnt [0:7];                   // entries held, saturates at 61
    reg [2:0]  slots;
    reg [6:0]  ai;
    // the animal being processed
    reg signed [31:0] wx, wy, wvy, wold, wseen, wfold, wbest, wbestd;
    reg        wdl, wact, walive, whave;
    reg [6:0]  wexp;
    reg [9:0]  wphase;
    reg [3:0]  wwl, sr;
    reg [8:0]  wmarks;
    reg [1:0]  sc_mode;
    reg signed [47:0] wheight;           // signed: mixed with a negative bottom, unsigned would win
    reg [63:0] wh1;

    assign mode = {1'b0, mode_r};
    assign level = stage;
    assign exit_req = exit_r;
    assign q_data = 32'd0;

    // ---------------- sequencer ----------------
    localparam S_IDLE = 7'd0, S_RESTART = 7'd1, S_STEP = 7'd2, S_MOVE0 = 7'd3, S_M1 = 7'd4, S_M2 = 7'd5,
               S_M3 = 7'd6, S_M4 = 7'd7, S_M5 = 7'd8, S_D0 = 7'd9, S_D1 = 7'd10, S_REST = 7'd11,
               S_END = 7'd12, S_MWAIT = 7'd13, S_W_INIT = 7'd14, S_W_GET = 7'd15, S_W_USE = 7'd16,
               S_TJ = 7'd17, S_TJ_R1 = 7'd18, S_TJ_R2 = 7'd19, S_TJ_R3 = 7'd20, S_TJ_D1 = 7'd21,
               S_TJ_D2 = 7'd22, S_TJ_D3 = 7'd23, S_TJ_D4 = 7'd24, S_TJ_D5 = 7'd25, S_TJ_D6 = 7'd26,
               S_TJ_D7 = 7'd27, S_R_ENT = 7'd28, S_A0 = 7'd29, S_A1 = 7'd30, S_A2 = 7'd31, S_A3 = 7'd32,
               S_A4 = 7'd33, S_SCAN = 7'd34, S_A_FALL = 7'd35, S_A9 = 7'd36, S_AC = 7'd37, S_AC2 = 7'd38,
               S_AW = 7'd39, S_T2 = 7'd40, S_LIFT0 = 7'd41, S_LIFT1 = 7'd42, S_TEA0 = 7'd43, S_TEA1 = 7'd44,
               S_TEA2 = 7'd45, S_ROUTE = 7'd46, S_RPOP = 7'd47, S_REP = 7'd48, S_REP2 = 7'd49, S_REP2B = 7'd50,
               S_REP3 = 7'd51, S_ANIM = 7'd52, S_NEAR = 7'd53, S_DOOR = 7'd54, S_END0 = 7'd55, S_PR0 = 7'd56,
               S_PR1 = 7'd57, S_H0 = 7'd58, S_H1 = 7'd59, S_H2 = 7'd60, S_F0 = 7'd61, S_F1 = 7'd62,
               S_F2 = 7'd63, S_F3 = 7'd64, S_F4 = 7'd65, S_F5 = 7'd66, S_F6 = 7'd67, S_F7 = 7'd68,
               S_RT0 = 7'd69, S_RT1 = 7'd70, S_RT2 = 7'd71, S_RT3 = 7'd72, S_RT4 = 7'd73, S_RT5 = 7'd74,
               S_RT6 = 7'd75, S_RT7 = 7'd76, S_RT8 = 7'd77, S_RT9 = 7'd78, S_PL0 = 7'd79, S_PL1 = 7'd80,
               S_PL2 = 7'd81, S_W_USE2 = 7'd82, S_DRAW = 7'd83, S_R_ENT2 = 7'd84, S_H1A = 7'd85, S_H1B = 7'd86,
               S_W_USE3 = 7'd87, S_W_USE4 = 7'd88, S_ACM = 7'd89;
    reg [6:0] st, tj_ret, w_ret, m_ret, rs_ret, prog_ret, hit_ret, fo_ret, rq_ret, pl_ret, dr_ret;
    reg [3:0] dr_n;                      // draw(): shifts left

    // this tick's input (the levels are sampled when the tick is handled)
    reg signed [1:0] ax;
    reg jl;
    reg [2:0] steps_left;
    // commands waiting for the end of the step
    reg cmd_pend, enter_pend;
    reg [3:0] cmd_op;
    reg [15:0] cmd_arg;
    reg tick_pend, jump_pend, skill_pend, menu_pend;
    assign busy = (st != S_IDLE) || cmd_pend || enter_pend || tick_pend;

    // ---------------- box walker ----------------
    reg signed [47:0] w_lo, w_hi, near_lo, near_hi;
    reg [8:0]  w_first, w_last, w_c;
    reg [3:0]  w_r;
    reg [1:0]  w_x;
    reg        w_cells, found;
    reg [3:0]  w_mode;
    reg signed [47:0] bx, by, bw, bh;
    reg        bval;
    reg        dy_pos;
    reg signed [47:0] reach;

    function [8:0] div75;                // floor(n / 75), exact for n < 2^17
        input [16:0] n;
        reg [34:0] p;
        begin
            p = n * 18'd223697;
            div75 = p[32:24];
        end
    endfunction

    wire [1:0]  lvl = stage - 2'd1;
    wire [10:0] col_word = w_mode == W_WATER ? water_rom[{lvl, w_c[7:0]}] : solid_rom[{lvl, w_c[7:0]}];
    wire signed [47:0] w_hi1 = w_hi - 48'sd1;
    wire [16:0] lo_cells = w_lo[39:23];
    wire [16:0] hi_cells = w_hi1[39:23];
    wire [8:0]  first_c = w_lo[47] ? 9'd0 : div75(lo_cells);
    wire [8:0]  last_raw = w_hi1[47] ? 9'd0 : div75(hi_cells);
    wire [8:0]  last_c = last_raw > 9'd249 ? 9'd249 : last_raw;
    wire        no_cells = w_hi1[47] || first_c > last_c;

    // tests against the current box (cr_model under / touches)
    wire signed [47:0] b_top = by + bh;
    wire under_b = (xf + CR_HALF_F > bx + CR_TIE_X) && (xf - CR_HALF_F < bx + bw - CR_TIE_X);
    wire touch_b = under_b && (yf < b_top - CR_TIE_F) && (yf + CR_PH_F > by + CR_TIE_F);

    // ---------------- animal helpers ----------------
    wire [CR_ENT_W-1:0] ew = ent_rom[{lvl, ai[5:0]}];
    wire signed [31:0] ent_x0   = ew[CR_ENT_X_LSB +: 32];
    wire signed [31:0] ent_y0   = ew[CR_ENT_Y_LSB +: 32];
    wire signed [31:0] ent_base = ew[CR_ENT_BASE_Y_LSB +: 32];
    wire signed [31:0] ent_lo   = ew[CR_ENT_LO_LSB +: 32];
    wire signed [31:0] ent_hi   = ew[CR_ENT_HI_LSB +: 32];
    wire signed [31:0] ent_trig = ew[CR_ENT_TRIGGER_LSB +: 32];
    wire [1:0] ent_species = ew[CR_ENT_SPECIES_LSB +: 2];
    wire [1:0] ent_motion  = ew[CR_ENT_MOTION_LSB +: 2];
    wire [5:0] ent_leader1 = ew[CR_ENT_LEADER1_LSB +: 6];      // leader index + 1, 0 = none
    wire       ent_active0 = ew[CR_ENT_ACTIVE_LSB];
    wire [2:0] ent_nskins  = ew[CR_ENT_NSKINS_LSB +: 3];
    wire [6:0] ent_edge    = ew[CR_ENT_EDGE_LSB +: 7];
    reg edge_q;                                                 // block ROM, one clock late
    always @(posedge clk) edge_q <= edge_rom[{ent_edge, e_marks[ai[5:0]]}];

    // fpga/rtl/common/lfsr16.v, one shift; a draw (S_DRAW) is 16 shifts, one per clock (short timing path)
    wire [15:0] lfsr_sh = {lfsr[14:0], lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3]};
    wire [15:0] lfsr_1 = lfsr_sh == 16'd0 ? 16'hACE1 : lfsr_sh;
    wire [18:0] skin_prod = lfsr * ent_nskins;

    // waking: camera + 20 m (+ 5 m for early walkers / flyers) reaches the trigger
    wire early = (stage == 2'd2 && (ent_motion == WALK || ent_motion == FLY)) || (stage == 2'd3 && ent_motion == FLY);
    wire wakes = cam + (early ? CR_WAKE25 : CR_WAKE20) >= ent_trig;
    // follower ring
    wire [2:0] fslot = e_slot[ai[5:0]];
    wire [5:0] fw = p_w[fslot];
    wire [5:0] fcnt_new = p_cnt[fslot] == 6'd61 ? 6'd61 : p_cnt[fslot] + 6'd1;
    wire [8:0] f_old = {fslot, fw + 6'd4};                     // the entry written 60 appends ago
    wire [5:0] lead = ent_leader1 - 6'd1;
    // ant: up 1 s, stay 2 s, down 1 s of a 6 s cycle
    wire [9:0] ph_next = wphase == 10'd719 ? 10'd0 : wphase + 10'd1;
    wire signed [11:0] ant_t = $signed({2'b0, ph_next}) - 12'sd240;
    wire signed [11:0] ant_m = ant_t < 12'sd480 - ant_t ? ant_t : 12'sd480 - ant_t;
    wire [6:0] ant_exp = ant_m < 0 ? 7'd0 : ant_m > 12'sd120 ? 7'd120 : ant_m[6:0];
    // exactly on a half-metre mark?
    wire [31:0] wabs = wx[31] ? -wx : wx;
    wire [16:0] half_k = wabs[30:14];
    wire [16:0] whole_k = {1'b0, wabs[30:15]};
    wire on_half  = wabs[13:0] == 14'd0 && div75(half_k) * 75 == half_k;
    wire on_whole = wabs[14:0] == 15'd0 && div75(whole_k) * 75 == whole_k;
    // the column of the animal (what the game "sees", seen // Q)
    wire [16:0] seen_k = wseen[31:15];
    wire [8:0]  seen_c = div75(seen_k);
    wire        col_ok = !wseen[31] && seen_c < 9'd250;
    wire [10:0] a_solid = solid_rom[{lvl, seen_c[7:0]}];
    wire [10:0] a_water = water_rom[{lvl, seen_c[7:0]}];
    wire [10:0] a_surf  = a_solid & ~(a_solid >> 1);
    wire signed [31:0] row_top = $signed({28'd0, sr}) * CR_Q + CR_Q;          // (sr + 1) * Q
    wire signed [31:0] row_bot = $signed({28'd0, sr}) * CR_Q;
    wire signed [31:0] dh = row_top - wy;
    wire signed [31:0] adh = dh[31] ? -dh : dh;
    // contact box; the height product needs 55 bits, so it gets 64-bit wires of its own
    wire [63:0] a_h1 = {16'd0, CR_ANIMAL_H} * {57'd0, wexp};
    // contact box
    wire signed [47:0] a_xf = $signed({{16{wx[31]}}, wx}) <<< 8;
    wire signed [47:0] a_half = ent_species == 2'd3 ? CR_HALF_GOOSE_F : CR_HALF_OTHER_F;
    wire signed [31:0] a_bot_u = ent_motion == POP ? ent_base : wy;
    wire signed [47:0] a_bot = $signed({{16{a_bot_u[31]}}, a_bot_u}) <<< 8;

    // ---------------- Task 9 helpers ----------------
    wire signed [47:0] px_u = xf >>> 8;              // player x, units
    wire signed [47:0] py_u = yf >>> 8;
    wire signed [47:0] ux = bx >>> 8, uy = by >>> 8, uw = bw >>> 8, uh = bh >>> 8;   // walker box, units
    wire signed [47:0] level_w = CR_LEVEL_WF >>> 8;
    wire signed [47:0] spawn_u = stage == 2'd1 ? CR_SPAWN_U1 : stage == 2'd2 ? CR_SPAWN_U2 : CR_SPAWN_U3;
    wire signed [47:0] span    = stage == 2'd1 ? CR_SPAN1 : stage == 2'd2 ? CR_SPAN2 : CR_SPAN3;
    wire signed [47:0] door_x  = stage == 2'd1 ? CR_DOOR1_X : stage == 2'd2 ? CR_DOOR2_X : CR_DOOR3_X;
    wire signed [47:0] door_y  = stage == 2'd1 ? CR_DOOR1_Y : stage == 2'd2 ? CR_DOOR2_Y : CR_DOOR3_Y;
    wire signed [47:0] door_w  = stage == 2'd1 ? CR_DOOR1_W : stage == 2'd2 ? CR_DOOR2_W : CR_DOOR3_W;
    wire signed [47:0] door_h  = stage == 2'd1 ? CR_DOOR1_H : stage == 2'd2 ? CR_DOOR2_H : CR_DOOR3_H;
    // touches() of the player against a box given in units
    function touches_u;
        input signed [47:0] x; input signed [47:0] y; input signed [47:0] w; input signed [47:0] h;
        begin
            touches_u = xf + CR_HALF_F > (x <<< 8) + CR_TIE_X && xf - CR_HALF_F < ((x + w) <<< 8) - CR_TIE_X
                     && yf < ((y + h) <<< 8) - CR_TIE_F && yf + CR_PH_F > (y <<< 8) + CR_TIE_F;
        end
    endfunction
    // blocked() test of the walker box
    wire bk_hit = bk_x < ux + uw - CR_TOL_X && bk_x + bk_w > ux + CR_TOL_X
               && bk_y < uy + uh - CR_TOL_Y && bk_y + bk_h > uy + CR_TOL_Y;
    // place_reporter() candidate from the walker box
    wire signed [47:0] pc_lo = ux + CR_HALF_W, pc_hi = ux + uw - CR_HALF_W;
    wire signed [47:0] pc_x1 = pl_tx < pc_lo ? pc_lo : pl_tx;
    wire signed [47:0] pc_x  = pc_x1 > pc_hi ? pc_hi : pc_x1;
    wire signed [47:0] pc_y  = uy + uh;
    wire pc_far = ux > pl_tx + CR_TEN_Q || ux + uw < pl_tx - CR_TEN_Q;     // then 3 more clocks (timing)
    // question pair (random.sample of 2 from 15): q0 = draw * 15 >> 16, then j = draw * 14 >> 16, q1 = j + (j >= q0)
    wire [19:0] qi_p = lfsr * 4'd15;
    wire [19:0] qj_p = lfsr * 4'd14;
    // lifts
    wire signed [47:0] lift_y0 = lt0 <<< 8, lift_y1 = lt1 <<< 8;
    wire ride0 = grounded && sabs(yf - lift_y0) <= CR_TIE_F && xf + CR_HALF_F > CR_LIFT0_BX_F + CR_TIE_X
              && xf - CR_HALF_F < CR_LIFT0_BX_F + 2 * CR_CELL - CR_TIE_X;
    wire ride1 = grounded && sabs(yf - lift_y1) <= CR_TIE_F && xf + CR_HALF_F > CR_LIFT1_BX_F + CR_TIE_X
              && xf - CR_HALF_F < CR_LIFT1_BX_F + 2 * CR_CELL - CR_TIE_X;
    wire dn0 = (lt0 >= CR_LIFT_HIGH || lt0 <= CR_LIFT_LOW) ? lt0 >= CR_LIFT_HIGH : ld0_dn;
    wire signed [47:0] nt0r = dn0 ? lt0 - CR_LIFT_SPEED : lt0 + CR_LIFT_SPEED;
    wire signed [47:0] nt0 = nt0r < CR_LIFT_LOW ? CR_LIFT_LOW : nt0r > CR_LIFT_HIGH ? CR_LIFT_HIGH : nt0r;
    wire signed [47:0] nt1r = ride1 ? lt1 - CR_SINK_SPEED : lt1 + CR_SINK_SPEED;
    wire signed [47:0] nt1 = nt1r < CR_LIFT_LOW ? CR_LIFT_LOW : nt1r > CR_LIFT_HIGH ? CR_LIFT_HIGH : nt1r;
    // route / trail
    wire [5:0] rt_new = rt_head + rt_cnt[5:0];
    wire [5:0] rt_m2 = rt_head + rt_cnt[5:0] - 6'd2;
    wire [5:0] rt_h1 = rt_head + 6'd1;
    wire [8:0] tr_l1 = tr_tail - 9'd1, tr_l2 = tr_tail - 9'd2;
    wire signed [47:0] ry_u = ry >>> 8;
    wire signed [47:0] rem_dx = rx - tr_x[tr_l1];
    wire rem_clear = tr_d[tr_l1] != rdir_l || (rdir_l ? -rem_dx : rem_dx) < -CR_TOL_X
                  || sabs(rem_dx) > CR_TRAIL_DX || sabs(ry_u - tr_y[tr_l1]) > CR_TRAIL_DY;
    // follow_reporter(): where the route says, kept at least GAP behind
    wire signed [47:0] ahead_r = face_l ? rx - px_u : px_u - rx;
    wire signed [47:0] fx1 = (f_still && CR_GAP - CR_TOL_X <= ahead_r && ahead_r <= CR_GAP_STILL) ? rx : f_x;
    wire signed [47:0] fx2 = (face_l ? fx1 - px_u : px_u - fx1) < CR_GAP ? (face_l ? px_u + CR_GAP : px_u - CR_GAP) : fx1;
    wire signed [47:0] prog_num = 100 * (px_u - spawn_u);
    wire signed [47:0] r_tgt_raw = rdir_l ? rx + CR_RETREAT_STEP : rx - CR_RETREAT_STEP;

    // ---------------- arithmetic unit ----------------
    reg m_start; reg [1:0] m_op; reg [79:0] m_a, m_b;
    wire m_busy, m_done; wire [79:0] m_res;
    cr_math u_math (.clk(clk), .rst(rst), .start(m_start), .op(m_op), .a(m_a), .b(m_b), .busy(m_busy),
                    .done(m_done), .result(m_res));

    // double jump working values
    reg [7:0]  dj_n;
    reg [47:0] dj_rise, dj_s, dj_g, dj_t1;
    reg [4:0]  dj_b;
    // products on wires of their own: inside {...} a product keeps only its operands' width
    wire [15:0] dj_nn = dj_n * dj_n;
    wire [9:0]  dj_bb = dj_b * dj_b;
    wire signed [47:0] rise_raw = (takeoff + CR_DH_F - yf) >>> 8;
    wire [47:0] rise_now = rise_raw < CR_MIN_RISE ? CR_MIN_RISE : rise_raw;
    wire signed [47:0] dj_num = CR_DOUBLE_RANGE - CR_RUN * $signed({40'd0, elapsed});

    // movement helpers
    wire signed [47:0] x_moved = ax == 2'sd1 ? xf + vxf : ax == -2'sd1 ? xf - vxf : xf;
    wire signed [47:0] x_lim = CR_LEVEL_WF - CR_HALF_F;
    wire signed [47:0] dy_now = vyf - (gf >>> 1);
    wire signed [47:0] dx_now = xf - old_xf;
    wire [47:0] adx = dx_now[47] ? -dx_now : dx_now;
    wire signed [47:0] cam_raw = (xf >>> 8) - CR_SEVEN_Q;
    wire signed [47:0] put_x = $signed({39'd0, cmd_arg[8:0]}) * CR_HALF_Q;
    wire signed [47:0] put_cam = put_x - CR_SEVEN_Q;

    function signed [47:0] clamp_cam;
        input signed [47:0] v;
        begin
            clamp_cam = v < 0 ? 48'sd0 : v > CR_CAM_MAX ? CR_CAM_MAX : v;
        end
    endfunction

    task start_math;
        input [1:0] op; input [79:0] a; input [79:0] b; input [6:0] next;
        begin
            m_start <= 1'b1; m_op <= op; m_a <= a; m_b <= b; m_ret <= next; st <= S_MWAIT;
        end
    endtask

    task walk;                           // visit the boxes overlapping (lo, hi) in list order, then go to `next`
        input [3:0] mode_w; input signed [47:0] lo; input signed [47:0] hi; input [6:0] next;
        begin
            w_mode <= mode_w; w_lo <= lo; w_hi <= hi; w_ret <= next; st <= S_W_INIT;
        end
    endtask

    task block;                          // found = blocked(x, y, w, h): a box of the level overlaps (units)
        input signed [47:0] x; input signed [47:0] y; input signed [47:0] w; input signed [47:0] h;
        input [6:0] next;
        begin
            bk_x <= x; bk_y <= y; bk_w <= w; bk_h <= h;
            walk(W_BLOCK, (x - CR_Q) <<< 8, (x + w + CR_Q) <<< 8, next);
        end
    endtask

    task place;                          // pl_ok = place_reporter(tx, ty, behind)
        input signed [47:0] tx; input signed [47:0] ty; input behind; input [6:0] next;
        begin
            pl_tx <= tx; pl_ty <= ty; pl_behind <= behind; have_prev <= 1'b0; pl_ret <= next; st <= S_PL0;
        end
    endtask

    task notify;
        input [3:0] msg;
        begin
            message <= msg; notice <= msg != 4'd0 ? CR_T_NOTICE : 9'd0;
        end
    endtask

    function lex_lt;                     // (s1, x1, y1) < (s2, x2, y2), as Python compares tuples
        input signed [47:0] s1; input signed [47:0] x1; input signed [47:0] y1;
        input signed [47:0] s2; input signed [47:0] x2; input signed [47:0] y2;
        begin
            lex_lt = s1 < s2 || (s1 == s2 && (x1 < x2 || (x1 == x2 && y1 < y2)));
        end
    endfunction

    function signed [47:0] sabs;
        input signed [47:0] v;
        begin
            sabs = v < 0 ? -v : v;
        end
    endfunction

    integer k;
    always @(posedge clk) begin
        m_start <= 1'b0;
        step_done <= 1'b0;
        if (demo_cmd) begin cmd_pend <= 1'b1; cmd_op <= demo_op; cmd_arg <= demo_arg; end
        if (enter) enter_pend <= 1'b1;
        if (gtick) tick_pend <= 1'b1;
        if (gtick && ev_jump) jump_pend <= 1'b1;
        if (gtick && ev_skill) skill_pend <= 1'b1;
        if (gtick && ev_menu) menu_pend <= 1'b1;
        if (enter) begin jump_pend <= 1'b0; skill_pend <= 1'b0; menu_pend <= 1'b0; end
        if (rst) begin
            st <= S_RESTART; stage <= 2'd1; cmd_pend <= 1'b0; enter_pend <= 1'b0; cam_px <= 13'd0;
            lfsr <= 16'hACE1; rs_ret <= S_IDLE; rs_msg <= 4'd0;
            tick_pend <= 1'b0; jump_pend <= 1'b0; skill_pend <= 1'b0; menu_pend <= 1'b0; died <= 1'b0;
            m_op <= 2'd0; m_a <= 80'd0; m_b <= 80'd0;
        end else case (st)
        S_IDLE: begin
            if (enter_pend) begin
                enter_pend <= 1'b0; stage <= 2'd1; rs_msg <= CR_MSG_NEW; rs_ret <= S_IDLE; st <= S_RESTART;
            end else if (cmd_pend) begin
                cmd_pend <= 1'b0;
                case (cmd_op)
                    OP_STAGE: if (cmd_arg[1:0] != 2'd0) begin           // there is no stage 0
                        stage <= cmd_arg[1:0]; rs_msg <= 4'd0; rs_ret <= S_IDLE; st <= S_RESTART;
                    end
                    OP_WIN: if (mode_r == WIN) exit_r <= 1'b1;
                    OP_GOLD: gold <= 1'b1;
                    OP_PUT: begin
                        xf <= put_x <<< 8;
                        yf <= ($signed({42'd0, cmd_arg[13:9]}) * CR_HALF_Q) <<< 8;
                        vyf <= 48'sd0; grounded <= cmd_arg[14];
                        cam <= clamp_cam(put_cam);
                    end
                    OP_SEED: lfsr <= cmd_arg == 16'd0 ? 16'hACE1 : cmd_arg;
                    default: ;
                endcase
            end else if (tick_pend) begin
                tick_pend <= gtick;              // presses arriving with enter stay cancelled here too
                jump_pend <= gtick && ev_jump && !enter; skill_pend <= gtick && ev_skill && !enter;
                menu_pend <= gtick && ev_menu && !enter;
                if (menu_pend && (mode_r == PLAY || mode_r == PAUSE))
                    mode_r <= mode_r == PLAY ? PAUSE : PLAY;
                ax <= (btn_right ? 2'sd1 : 2'sd0) - (btn_left ? 2'sd1 : 2'sd0);
                jl <= jump_pend; sl <= skill_pend;
                tick_jump <= jump_pend; conf_menu <= menu_pend && mode_r == WIN;
                steps_left <= STEPS_PER_TICK;
                st <= S_STEP;
            end
        end

        S_RESTART: begin                 // cr_model.restart()
            xf <= (stage == 2'd2 ? CR_SPAWN_X2 : CR_SPAWN_X1) * CR_CELL;
            yf <= CR_SPAWN_Y * CR_CELL;
            vyf <= 0; face_l <= 1'b0; grounded <= 1'b0; walking <= 1'b0;
            jumps <= 2'd0; elapsed <= 8'd0; takeoff <= 0;
            gf <= CR_G_F; vxf <= CR_RUN_F; grace <= 5'd0; buffer <= 5'd0;
            stride <= 48'd0; cam <= 0;
            mode_r <= PLAY; time_left <= CR_T_LIMIT;
            // extra boxes in list order: the "?" box (stage 2), the two lifts (stage 3)
            ex_v <= stage == 2'd2 ? 3'b001 : (stage == 2'd3 && TEST_MODE == 0) ? 3'b011 : 3'b000;
            ex_x[0] <= stage == 2'd2 ? CR_PUZZLE_XF : CR_LIFT0_BX_F;
            ex_y[0] <= stage == 2'd2 ? CR_PUZZLE_YF : (4 * CR_Q - CR_Q) <<< 8;
            ex_w[0] <= stage == 2'd2 ? CR_CELL : 2 * CR_CELL; ex_h[0] <= CR_CELL;
            ex_x[1] <= CR_LIFT1_BX_F; ex_y[1] <= (5 * CR_Q - CR_Q) <<< 8; ex_w[1] <= 2 * CR_CELL; ex_h[1] <= CR_CELL;
            ex_x[2] <= 0; ex_y[2] <= 0; ex_w[2] <= 0; ex_h[2] <= 0;
            lifts_on <= stage == 2'd3 && TEST_MODE == 0;
            lt0 <= 4 * CR_Q; lt1 <= 5 * CR_Q; ld0_dn <= 1'b0; ld1_dn <= 1'b0;
            // flow
            message <= rs_msg; notice <= rs_msg != 4'd0 ? CR_T_NOTICE : 9'd0;
            exit_r <= 1'b0; clear_left <= 8'd0; now <= 14'd0; prog <= 7'd0;
            used <= 1'b0; near <= 1'b0; chase <= 1'b0;
            skill <= 10'd0; interview <= 10'd0; protection <= 7'd0; retreat <= 8'd0; follow <= 7'd0;
            flash <= 6'd0; grow <= 9'd0; q0 <= 4'd0; q1 <= 4'd0;
            gold <= stage == 2'd3; opened <= 1'b0; tea_on <= 1'b0; tea_x <= 0; tea_y <= 0; tea_vy <= 0;
            // reporter, route, trail
            rx <= spawn_u; ry <= (CR_SPAWN_Y * CR_Q) <<< 8; rvy <= 0;
            rdir_l <= 1'b0; rvisible <= 1'b1; rwalking <= 1'b0;
            rt_head <= 6'd0; rt_cnt <= 7'd1;
            rt_step[0] <= 16'd0; rt_x[0] <= spawn_u; rt_y[0] <= CR_SPAWN_Y * CR_Q; rt_walk[0] <= 1'b0;
            rt_gnd[0] <= 1'b0;
            tr_cnt <= 10'd0; tr_tail <= 9'd0;
            ai <= 7'd0; slots <= 3'd0; contacts <= 64'd0;
            n_ents <= TEST_MODE == 1 ? 7'd0 : stage == 2'd1 ? CR_ENT_COUNT1 : stage == 2'd2 ? CR_ENT_COUNT2 : CR_ENT_COUNT3;
            st <= S_R_ENT;
        end
        S_R_ENT: begin                   // new animals, each drawing its skin from the shared generator
            if (ai == (stage == 2'd1 ? CR_ENT_COUNT1 : stage == 2'd2 ? CR_ENT_COUNT2 : CR_ENT_COUNT3)) begin
                st <= rs_ret;
            end else begin dr_ret <= S_R_ENT2; dr_n <= 4'd15; st <= S_DRAW; end
        end
        S_R_ENT2: begin
            begin
                e_skin[ai[5:0]] <= skin_prod[18:16];
                e_x[ai[5:0]] <= ent_x0; e_y[ai[5:0]] <= ent_y0; e_vy[ai[5:0]] <= 0; e_dl[ai[5:0]] <= 1'b1;
                e_active[ai] <= ent_active0; e_alive[ai] <= 1'b1;
                e_exp[ai[5:0]] <= ent_motion == POP ? 7'd0 : 7'd120;
                e_phase[ai[5:0]] <= 10'd0; e_wl[ai[5:0]] <= 4'd0; e_marks[ai[5:0]] <= 9'd0;
                if (ent_leader1 != 6'd0) begin
                    e_slot[ai[5:0]] <= slots; p_w[slots] <= 6'd0; p_cnt[slots] <= 6'd0; slots <= slots + 3'd1;
                end
                ai <= ai + 7'd1;
                st <= S_R_ENT;
            end
        end
        S_DRAW: begin                    // one LFSR shift per clock, 16 in all
            lfsr <= lfsr_1;
            if (dr_n == 4'd0) st <= dr_ret; else dr_n <= dr_n - 4'd1;
        end

        // ---------------- one step (cr_model.step) ----------------
        S_STEP: begin
            died <= 1'b0;
            if (mode_r == CLEAR) begin                       // "STAGE CLEAR": count down, then the next level
                if (clear_left <= 8'd1) begin
                    stage <= stage + 2'd1; rs_msg <= stage == 2'd1 ? CR_MSG_STAGE2 : CR_MSG_STAGE3;
                    rs_ret <= S_END0; st <= S_RESTART;
                end else begin clear_left <= clear_left - 8'd1; st <= S_END0; end
            end else if (mode_r != PLAY) st <= S_END0;
            else begin
                now <= now + 14'd1;
                if (grow != 9'd0) grow <= grow - 9'd1;
                if (time_left <= 14'd1) begin
                    died <= 1'b1; rs_msg <= CR_MSG_TIMEUP; rs_ret <= S_END0; st <= S_RESTART;
                end else begin
                    time_left <= time_left - 14'd1;
                    st <= S_T2;
                end
            end
        end
        S_T2: begin                      // timers; the interview freezes the world; the skill press
            if (notice != 9'd0) notice <= notice - 9'd1;
            flash <= (stage == 2'd3 && skill == 10'd1) ? CR_T_FLASH : flash != 6'd0 ? flash - 6'd1 : 6'd0;
            if (skill != 10'd0) skill <= skill - 10'd1;
            protection <= interview == 10'd1 ? CR_T_PROTECT_AFTER : protection != 7'd0 ? protection - 7'd1 : 7'd0;
            if (interview != 10'd0) begin
                interview <= interview - 10'd1;
                st <= S_END0;
            end else begin
                if (sl && !used) begin                       // cast()
                    if (stage == 2'd3) begin used <= 1'b1; skill <= CR_T_SKILL; flash <= CR_T_FLASH; end
                    else if (!chase) notify(CR_MSG_NEED_CHASE);
                    else begin chase <= 1'b0; follow <= CR_T_FOLLOW; used <= 1'b1; skill <= CR_T_SKILL; end
                end
                last_xf <= xf;
                st <= S_LIFT0;
            end
        end
        S_LIFT0: begin                   // the oscillating lift carries a rider by its own movement
            if (lifts_on) begin
                ld0_dn <= dn0; lt0 <= nt0; ex_y[0] <= (nt0 - CR_Q) <<< 8;
                if (ride0) yf <= yf + ((nt0 - lt0) <<< 8);
            end
            st <= S_LIFT1;
        end
        S_LIFT1: begin                   // the sinking lift goes down while ridden, up otherwise
            if (lifts_on) begin
                ld1_dn <= ride1; lt1 <= nt1; ex_y[1] <= (nt1 - CR_Q) <<< 8;
                if (ride1) yf <= yf + ((nt1 - lt1) <<< 8);
            end
            st <= S_MOVE0;
        end
        S_MOVE0: begin                   // move(): the press is remembered, then try_jump() while it lasts
            if (jl) buffer <= CR_BUFFER;
            if (jl || buffer != 5'd0) begin tj_ret <= S_M1; st <= S_TJ; end
            else st <= S_M1;
        end
        S_M1: begin
            old_xf <= xf; old_yf <= yf;
            if (ax != 2'sd0) face_l <= ax[1];
            xf <= x_moved < CR_HALF_F ? CR_HALF_F : x_moved > x_lim ? x_lim : x_moved;
            st <= S_M2;
        end
        S_M2: begin                      // the "near" window is fixed before the X pass moves the player
            near_lo <= xf - CR_HALF_F - CR_NEAR_F;
            near_hi <= xf + CR_HALF_F + CR_NEAR_F;
            walk(W_XPASS, xf - CR_HALF_F - CR_NEAR_F, xf + CR_HALF_F + CR_NEAR_F, S_M3);
        end
        S_M3: begin                      // exact constant-gravity step, then the Y pass on the same boxes
            dy_pos <= dy_now > 0;
            vyf <= vyf - gf;
            yf <= yf + dy_now;
            grounded <= 1'b0;
            walk(W_YPASS, near_lo, near_hi, S_M4);
        end
        S_M4: begin
            if (grounded) begin
                grace <= CR_COYOTE; jumps <= 2'd0; vxf <= CR_RUN_F; gf <= CR_G_F;
                if (buffer != 5'd0) begin tj_ret <= S_M5; st <= S_TJ; end
                else st <= S_M5;
            end else begin
                if (elapsed != 8'd255) elapsed <= elapsed + 8'd1;
                if (grace != 5'd0) grace <= grace - 5'd1;
                st <= S_M5;
            end
        end
        S_M5: begin
            if (buffer != 5'd0) buffer <= buffer - 5'd1;
            walking <= adx > CR_TIE_X;
            stride <= stride + adx;
            cam <= clamp_cam(cam_raw);
            st <= S_D0;
        end
        S_D0: begin                      // deaths: below the map, or in water after the coyote time
            if (yf < CR_DEATH_YF) begin
                died <= 1'b1; rs_msg <= stage == 2'd3 ? CR_MSG_FELL : CR_MSG_SPLASH; rs_ret <= S_END0; st <= S_RESTART;
            end
            else if (!grounded && grace == 5'd0) walk(W_WATER, xf - CR_HALF_F, xf + CR_HALF_F, S_D1);
            else st <= S_REST;
        end
        S_D1: begin
            if (found) begin
                died <= 1'b1; rs_msg <= stage == 2'd3 ? CR_MSG_FELL : CR_MSG_SPLASH; rs_ret <= S_END0; st <= S_RESTART;
            end
            else st <= S_REST;
        end
        S_REST: st <= tea_on ? S_TEA0 : S_ROUTE;
        S_TEA0: begin                    // the tea slides right and falls onto the blocks
            tea_x <= tea_x + CR_TEA_VX > CR_TEA_STOP ? CR_TEA_STOP : tea_x + CR_TEA_VX;
            tea_old <= tea_y; tea_vy <= tea_vy - CR_TEA_G; tea_y <= tea_y + tea_vy - CR_TEA_G;
            st <= S_TEA1;
        end
        S_TEA1: walk(W_TEA, (tea_x - CR_TWO_Q) <<< 8, (tea_x + CR_TWO_Q) <<< 8, S_TEA2);
        S_TEA2: begin
            if (touches_u(tea_x - CR_TEA_HALF, tea_y, 2 * CR_TEA_HALF, CR_TEA_H)) begin
                gold <= 1'b1; tea_on <= 1'b0; grow <= CR_T_GROW; notify(CR_MSG_TEA);
            end
            st <= S_ROUTE;
        end
        S_ROUTE: begin                   // record_route()
            rt_step[rt_new] <= {2'b00, now}; rt_x[rt_new] <= px_u; rt_y[rt_new] <= py_u;
            rt_walk[rt_new] <= sabs(xf - last_xf) > CR_TIE_X && grounded; rt_gnd[rt_new] <= grounded;
            rt_cnt <= rt_cnt + 7'd1;
            st <= S_RPOP;
        end
        S_RPOP: begin                    // keep one entry at least ROUTE_OLD steps old
            if (rt_cnt > 7'd1 && $signed({2'b00, rt_step[rt_h1]}) <= $signed({4'b0000, now}) - CR_ROUTE_OLD) begin
                rt_head <= rt_h1; rt_cnt <= rt_cnt - 7'd1;
            end else st <= S_REP;
        end
        S_REP: begin
            if (chase || follow != 7'd0) begin fo_ret <= S_REP2; st <= S_F0; end
            else if (retreat != 8'd0) begin rq_ret <= S_REP3; st <= S_RT0; end
            else st <= S_ANIM;
        end
        S_REP2: begin                    // remember_reporter()
            if (tr_cnt != 10'd0 && !rem_clear && sabs(rem_dx) <= CR_TOL_X) begin
                tr_x[tr_l1] <= rx; tr_y[tr_l1] <= ry_u; tr_d[tr_l1] <= rdir_l;
            end else begin
                tr_x[tr_tail] <= rx; tr_y[tr_tail] <= ry_u; tr_d[tr_tail] <= rdir_l; tr_tail <= tr_tail + 9'd1;
                tr_cnt <= (tr_cnt != 10'd0 && rem_clear) ? 10'd1 : tr_cnt == 10'd512 ? 10'd512 : tr_cnt + 10'd1;
            end
            st <= S_REP2B;
        end
        S_REP2B: begin
            if (follow != 7'd0) begin
                if (follow == 7'd1) begin follow <= 7'd0; retreat <= CR_T_RETREAT; end
                else follow <= follow - 7'd1;
            end
            st <= S_ANIM;
        end
        S_REP3: begin
            if (retreat == 8'd1) begin retreat <= 8'd0; rvisible <= 1'b0; end
            else retreat <= retreat - 8'd1;
            st <= S_ANIM;
        end
        S_ANIM: begin
            ai <= 7'd0; contacts_new <= 64'd0; st <= S_A0;
        end
        S_NEAR: begin
            if (prog >= 7'd92 && !near) begin near <= 1'b1; notify(CR_MSG_NEAR1 + {2'b00, stage} - 4'd1); end
            st <= S_DOOR;
        end
        S_DOOR: begin
            if (px_u >= door_x && px_u <= door_x + door_w && touches_u(door_x, door_y, door_w, door_h)) begin
                if (stage != 2'd3 && (stage == 2'd1 || gold)) begin
                    mode_r <= CLEAR; clear_left <= CR_T_CLEAR; notify(4'd0);
                end else if (gold) begin mode_r <= WIN; notify(4'd0); end
                else notify(CR_MSG_NEED_TEA);
            end
            st <= S_END0;
        end
        S_END0: begin prog_ret <= S_END; st <= S_PR0; end
        S_PR0: begin                     // progress = 100 * (x - spawn) // (door - spawn), 0..99
            if (px_u - spawn_u <= 0) begin prog <= 7'd0; st <= prog_ret; end
            else start_math(M_DIV, {32'd0, prog_num}, {32'd0, span}, S_PR1);
        end
        S_PR1: begin prog <= m_res > 80'd99 ? 7'd99 : m_res[6:0]; st <= prog_ret; end

        // ---------------- hit() ----------------
        S_H0: begin
            if (protection != 7'd0 || interview != 10'd0 || retreat != 8'd0 || follow != 7'd0) st <= hit_ret;
            else begin
                protection <= CR_T_PROTECT;
                if (chase) place(face_l ? px_u - CR_HIT_AHEAD : px_u + CR_HIT_AHEAD, py_u, 1'b0, S_H1);
                else begin
                    chase <= 1'b1; retreat <= 8'd0; tr_cnt <= 10'd0; fo_ret <= S_H2; st <= S_F0;
                end
            end
        end
        S_H1: begin                      // the interview: two questions, the world stops for 5 s
            rvisible <= pl_ok; dr_ret <= S_H1A; dr_n <= 4'd15; st <= S_DRAW;
        end
        S_H1A: begin q0 <= qi_p[19:16]; dr_ret <= S_H1B; dr_n <= 4'd15; st <= S_DRAW; end
        S_H1B: begin
            q1 <= qj_p[19:16] + (qj_p[19:16] >= q0 ? 4'd1 : 4'd0);
            chase <= 1'b0; interview <= CR_T_INTERVIEW; notify(4'd0);
            st <= hit_ret;
        end
        S_H2: begin notify(CR_MSG_REPORTER); st <= hit_ret; end

        // ---------------- follow_reporter() ----------------
        S_F0: begin
            f_x <= rt_x[rt_head]; f_y <= rt_y[rt_head]; f_walk <= rt_walk[rt_head]; f_gnd <= rt_gnd[rt_head];
            f_still <= rt_cnt > 7'd1 && sabs(px_u - rt_x[rt_m2]) <= CR_TOL_X;
            st <= S_F1;
        end
        S_F1: begin f_x <= fx2; rvisible <= 1'b1; st <= S_F2; end
        S_F2: if (f_gnd) block(f_x - CR_HALF_W, f_y - CR_FEET, 2 * CR_HALF_W, CR_FEET, S_F3);
              else st <= S_F4;
        S_F3: if (!found) place(f_x, f_y, 1'b1, S_F6);              // nothing under the feet
              else st <= S_F4;
        S_F4: block(f_x - CR_HALF_W, f_y, 2 * CR_HALF_W, CR_PH, S_F5);
        S_F5: if (found) place(f_x, f_y, 1'b1, S_F6);
              else begin rx <= f_x; ry <= f_y <<< 8; st <= S_F7; end
        S_F6: begin rvisible <= pl_ok; st <= S_F7; end
        S_F7: begin rdir_l <= face_l; rwalking <= f_walk && !f_still; st <= fo_ret; end

        // ---------------- retreat_reporter() ----------------
        S_RT0: begin
            r_old <= rx;
            r_tgt <= r_tgt_raw < CR_HALF_W ? CR_HALF_W : r_tgt_raw > level_w - CR_HALF_W ? level_w - CR_HALF_W : r_tgt_raw;
            st <= S_RT1;
        end
        S_RT1: begin                     // drop trail points that are not behind the target
            if (tr_cnt > 10'd1 && (rdir_l ? r_tgt - tr_x[tr_l2] : tr_x[tr_l2] - r_tgt) >= 0) begin
                tr_tail <= tr_l1; tr_cnt <= tr_cnt - 10'd1;
            end else st <= S_RT2;
        end
        S_RT2: begin                     // height on the trail: y0 + (y1 - y0) * (t - x0) // (x1 - x0)
            if (tr_cnt > 10'd1) begin
                r_y0 <= tr_y[tr_l2]; r_den <= tr_x[tr_l1] - tr_x[tr_l2];
                r_neg <= ((tr_y[tr_l1] - tr_y[tr_l2]) < 0) != ((r_tgt - tr_x[tr_l2]) < 0);
                start_math(M_MUL, {32'd0, sabs(tr_y[tr_l1] - tr_y[tr_l2])}, {32'd0, sabs(r_tgt - tr_x[tr_l2])}, S_RT3);
            end else st <= S_RT6;
        end
        S_RT3: begin                     // floor division of signed numbers on the unsigned divider
            r_negq <= r_neg != (r_den < 0);
            if (r_neg != (r_den < 0))
                start_math(M_DIV, m_res + {32'd0, sabs(r_den)} - 80'd1, {32'd0, sabs(r_den)}, S_RT4);
            else start_math(M_DIV, m_res, {32'd0, sabs(r_den)}, S_RT4);
        end
        S_RT4: begin
            r_h <= r_y0 + (r_negq ? -$signed(m_res[47:0]) : $signed(m_res[47:0]));
            block(r_tgt - CR_HALF_W, r_y0 + (r_negq ? -$signed(m_res[47:0]) : $signed(m_res[47:0])),
                  2 * CR_HALF_W, CR_PH, S_RT5);
        end
        S_RT5: begin
            if (!found) begin
                rx <= r_tgt; ry <= r_h <<< 8; rvy <= 0; rwalking <= sabs(r_tgt - r_old) > CR_TOL_X;
                st <= rq_ret;
            end else begin tr_cnt <= 10'd0; st <= S_RT6; end
        end
        S_RT6: begin                     // no trail: back up, stop at walls, fall under gravity
            rx <= r_tgt; rp_y <= ry_u;
            walk(W_RPUSH, (r_tgt - CR_THREE_Q) <<< 8, (r_tgt + CR_THREE_Q) <<< 8, S_RT7);
        end
        S_RT7: begin r_prev <= ry; rvy <= rvy - CR_G_F; ry <= ry + rvy - CR_G_F; st <= S_RT8; end
        S_RT8: begin rt_have <= 1'b0; walk(W_RTOPS, (rx - CR_TWO_Q) <<< 8, (rx + CR_TWO_Q) <<< 8, S_RT9); end
        S_RT9: begin
            if (rt_have) begin ry <= rt_best; rvy <= 0; end
            rwalking <= sabs(rx - r_old) > CR_TOL_X;
            st <= rq_ret;
        end

        // ---------------- place_reporter(): the smallest (score, x, y) that is free ----------------
        S_PL0: begin
            have_best <= 1'b0;
            walk(W_PLACE, (pl_tx - CR_TWELVE_Q) <<< 8, (pl_tx + CR_TWELVE_Q) <<< 8, S_PL1);
        end
        S_PL1: if (!have_best) begin pl_ok <= 1'b0; st <= pl_ret; end
               else block(best_x - CR_HALF_W, best_y, 2 * CR_HALF_W, CR_PH, S_PL2);
        S_PL2: begin
            if (!found) begin
                rx <= best_x; ry <= best_y <<< 8; rvy <= 0; rdir_l <= !(px_u >= best_x); pl_ok <= 1'b1;
                st <= pl_ret;
            end else begin               // taken: look for the next one in sorted order
                prev_s <= best_s; prev_x <= best_x; prev_y <= best_y; have_prev <= 1'b1; st <= S_PL0;
            end
        end

        // ---------------- animals (cr_model.animals / update_animal), one at a time in list order ----------
        S_A0: begin
            if (ai == n_ents) begin
                contacts <= contacts_new;
                prog_ret <= S_NEAR; st <= S_PR0;
            end else if (!e_alive[ai]) ai <= ai + 7'd1;
            else begin
                wx <= e_x[ai[5:0]]; wy <= e_y[ai[5:0]]; wvy <= e_vy[ai[5:0]]; wdl <= e_dl[ai[5:0]];
                wexp <= e_exp[ai[5:0]]; wphase <= e_phase[ai[5:0]]; wwl <= e_wl[ai[5:0]];
                wmarks <= e_marks[ai[5:0]]; walive <= 1'b1;
                wact <= e_active[ai] || wakes;
                st <= (e_active[ai] || wakes) ? S_A1 : S_AW;
            end
        end
        S_A1: begin                      // a follower replays its leader 60 steps late
            if (ent_leader1 != 6'd0) begin
                p_x[{fslot, fw}] <= e_x[lead]; p_y[{fslot, fw}] <= e_y[lead]; p_d[{fslot, fw}] <= e_dl[lead];
                p_w[fslot] <= fw + 6'd1; p_cnt[fslot] <= fcnt_new;
                if (fcnt_new == 6'd61) begin
                    wx <= p_x[f_old]; wy <= p_y[f_old]; wdl <= p_d[f_old];
                    st <= S_AC;
                end else st <= S_A2;
            end else st <= S_A2;
        end
        S_A2: begin
            if (ent_motion == POP) begin
                wphase <= ph_next; wexp <= ant_exp;
                wy <= ent_base - CR_Q + $signed({25'd0, ant_exp}) * CR_ANT_STEP;
                st <= S_AC;
            end else if (wwl != 4'd0) begin          // sinking
                wy <= wy - CR_SINK_WATER;
                walive <= wy - CR_SINK_WATER + CR_ANIMAL_H > $signed({28'd0, wwl}) * CR_Q;
                st <= S_AC;
            end else begin
                wold <= wx;
                wx <= wdl ? wx - CR_ENEMY : wx + CR_ENEMY;
                st <= S_A3;
            end
        end
        S_A3: begin                      // on a mark, take the float game's side of it (cr_assets.edge_bits)
            if (on_half) begin
                wseen <= edge_q ? (on_whole ? wx - 32'sd1 : wdl ? wx - 32'sd1 : wx + 32'sd1) : wx;
                if (wmarks != 9'd511) wmarks <= wmarks + 9'd1;
            end else wseen <= wx;
            st <= S_A4;
        end
        S_A4: begin
            sr <= 4'd10; whave <= 1'b0;
            if (ent_motion == PATROL) begin
                if (wseen < ent_lo) begin wx <= 2 * ent_lo - wx; wdl <= 1'b0; wseen <= 2 * ent_lo - wx; end
                else if (wseen > ent_hi) begin wx <= 2 * ent_hi - wx; wdl <= 1'b1; wseen <= 2 * ent_hi - wx; end
                sc_mode <= SC_PATROL; st <= S_SCAN;
            end else if (ent_motion == WALK) begin
                if (wvy == 0) begin sc_mode <= SC_STEP; st <= S_SCAN; end
                else st <= S_A_FALL;
            end else st <= S_A9;
        end
        S_SCAN: begin                    // rows 10..0 of the animal's column
            case (sc_mode)
                SC_PATROL: if (col_ok && a_surf[sr] && adh <= CR_Q && (!whave || adh < wbestd)) begin
                    wbest <= row_top; wbestd <= adh; whave <= 1'b1;
                end
                SC_STEP: if (col_ok && a_surf[sr] && dh > 0 && dh <= CR_Q) begin
                    wbest <= row_top; whave <= 1'b1;               // the last one found is the lowest
                end
                SC_FALL: if (!whave && col_ok && a_solid[sr] && wfold >= row_top && wy <= row_top) begin
                    wy <= row_top; wvy <= 0; whave <= 1'b1;
                end
                default: if (!whave && col_ok && a_water[sr] && row_bot <= wy && wy < row_top) begin
                    wwl <= sr + 4'd1; whave <= 1'b1;
                end
            endcase
            if (sr != 4'd0) sr <= sr - 4'd1;
            else case (sc_mode)
                SC_PATROL: begin
                    if (whave || (col_ok && a_surf[0] && adh <= CR_Q && (!whave || adh < wbestd)))
                        wy <= (col_ok && a_surf[0] && adh <= CR_Q && (!whave || adh < wbestd)) ? row_top : wbest;
                    else begin wx <= wold; wdl <= !wdl; end
                    st <= S_A9;
                end
                SC_STEP: begin
                    if (col_ok && a_surf[0] && dh > 0 && dh <= CR_Q) wy <= row_top;
                    else if (whave) wy <= wbest;
                    st <= S_A_FALL;
                end
                SC_FALL: begin sr <= 4'd10; whave <= 1'b0; sc_mode <= SC_WATER; end
                default: st <= S_A9;
            endcase
        end
        S_A_FALL: begin                  // fall_item(): gravity, then land on the highest top crossed
            wfold <= wy; wvy <= wvy - CR_WALK_G; wy <= wy + wvy - CR_WALK_G;
            sr <= 4'd10; whave <= 1'b0; sc_mode <= SC_FALL; st <= S_SCAN;
        end
        S_A9: begin
            if (wseen < CR_KILL_X || wy < CR_KILL_Y) walive <= 1'b0;
            st <= S_AC;
        end
        S_AC: begin                      // touched? (game.py:605-617)
            wh1 <= a_h1;
            st <= (walive && wact && wexp != 7'd0 && wwl == 4'd0) ? S_ACM : S_AW;
        end
        S_ACM: begin                     // ANIMAL_H * exposure // 120, the second multiply in its own clock
            wheight <= (wh1 * {16'd0, CR_H120_M}) >> 33;
            st <= S_AC2;
        end
        S_AC2: begin
            if (xf - CR_HALF_F < a_xf + a_half - CR_TIE_X && xf + CR_HALF_F > a_xf - a_half + CR_TIE_X
                    && yf < a_bot + (wheight <<< 8) - CR_TIE_F && yf + CR_PH_F > a_bot + CR_TIE_F
                    && !(stage == 2'd3 && skill != 10'd0)) begin    // Phase: nothing can touch
                contacts_new[ai] <= 1'b1;
                if (!contacts[ai] && TEST_MODE == 0) begin hit_ret <= S_AW; st <= S_H0; end
                else st <= S_AW;
            end else st <= S_AW;
        end
        S_AW: begin
            e_x[ai[5:0]] <= wx; e_y[ai[5:0]] <= wy; e_vy[ai[5:0]] <= wvy; e_dl[ai[5:0]] <= wdl;
            e_exp[ai[5:0]] <= wexp; e_phase[ai[5:0]] <= wphase; e_wl[ai[5:0]] <= wwl;
            e_marks[ai[5:0]] <= wmarks; e_alive[ai] <= walive; e_active[ai] <= wact;
            ai <= ai + 7'd1; st <= S_A0;
        end
        S_END: begin
            step_done <= 1'b1;
            jl <= 1'b0; sl <= 1'b0;          // jump and skill count for the first step of a tick only
            if (steps_left > 3'd1) begin steps_left <= steps_left - 3'd1; st <= S_STEP; end
            else begin
                if (mode_r == WIN && (tick_jump || conf_menu)) exit_r <= 1'b1;
                st <= S_IDLE;
            end
        end

        // ---------------- try_jump() ----------------
        S_TJ: begin
            if (grounded || (jumps == 2'd0 && grace != 5'd0)) begin
                grounded <= 1'b0; grace <= 5'd0; buffer <= 5'd0;
                jumps <= 2'd1; takeoff <= yf; elapsed <= 8'd0;
                gf <= CR_G_F; vyf <= CR_JUMP_VY_F; vxf <= CR_RUN_F;
                st <= tj_ret;
            end else if (jumps == 2'd1 && elapsed <= CR_DOUBLE_LAST) begin
                if (vyf < 0) begin       // about to land: keep the press for the ground jump?
                    dj_b <= buffer == 5'd0 ? 5'd0 : buffer - 5'd1;
                    start_math(M_MUL, {32'd0, -vyf}, {75'd0, buffer == 5'd0 ? 5'd0 : buffer - 5'd1}, S_TJ_R1);
                end else st <= S_TJ_D1;
            end else st <= tj_ret;
        end
        S_TJ_R1: begin
            dj_t1 <= m_res[47:0];
            start_math(M_MUL, {32'd0, gf}, {70'd0, dj_bb}, S_TJ_R2);
        end
        S_TJ_R2: begin
            reach <= $signed(dj_t1) + $signed({1'b0, m_res[47:1]});
            walk(W_REACH, xf - CR_HALF_F, xf + CR_HALF_F, S_TJ_R3);
        end
        S_TJ_R3: st <= found ? tj_ret : S_TJ_D1;
        S_TJ_D1: begin
            dj_n <= CR_DOUBLE_STEPS - elapsed;
            dj_rise <= rise_now;
            start_math(M_SQRT, {16'd0, rise_now, 16'd0}, 80'd0, S_TJ_D2);
        end
        S_TJ_D2: begin
            dj_s <= m_res[47:0] + CR_SQRT_DH;
            start_math(M_MUL, {32'd0, m_res[47:0] + CR_SQRT_DH}, {32'd0, m_res[47:0] + CR_SQRT_DH}, S_TJ_D3);
        end
        S_TJ_D3: start_math(M_DIV, {7'd0, m_res[79:7]}, {64'd0, dj_nn}, S_TJ_D4);
        S_TJ_D4: begin
            dj_g <= m_res[47:0];
            start_math(M_MUL, m_res, {32'd0, dj_rise}, S_TJ_D5);
        end
        S_TJ_D5: start_math(M_SQRT, {m_res[70:0], 9'd0}, 80'd0, S_TJ_D6);
        S_TJ_D6: begin
            gf <= dj_g; vyf <= m_res[47:0]; jumps <= 2'd2; buffer <= 5'd0;
            if (dj_num <= 0) begin vxf <= 0; st <= tj_ret; end
            else start_math(M_DIV, {24'd0, dj_num, 8'd0}, {72'd0, dj_n}, S_TJ_D7);
        end
        S_TJ_D7: begin
            vxf <= m_res > CR_RUN_F ? CR_RUN_F : m_res[47:0];
            st <= tj_ret;
        end

        S_MWAIT: if (m_done) st <= m_ret;

        // ---------------- box walker: grid cells of the window's columns, rows 10..0, then extra boxes ------
        S_W_INIT: begin
            w_first <= first_c; w_last <= last_c; w_c <= first_c;
            w_r <= 4'd10; w_cells <= !no_cells; w_x <= 2'd0; found <= 1'b0;
            st <= S_W_GET;
        end
        S_W_GET: begin
            if (w_cells) begin
                bval <= col_word[w_r];
                bx <= $signed({39'd0, w_c}) * CR_CELL; by <= $signed({44'd0, w_r}) * CR_CELL;
                bw <= CR_CELL; bh <= CR_CELL;
                if (w_c == w_last) begin
                    w_c <= w_first;
                    if (w_r == 4'd0) w_cells <= 1'b0; else w_r <= w_r - 4'd1;
                end else w_c <= w_c + 9'd1;
                st <= S_W_USE;
            end else if (w_mode != W_WATER && w_x != 2'd3) begin
                bval <= ex_v[w_x] && ex_x[w_x] < w_hi && ex_x[w_x] + ex_w[w_x] > w_lo;
                bx <= ex_x[w_x]; by <= ex_y[w_x]; bw <= ex_w[w_x]; bh <= ex_h[w_x];
                w_x <= w_x + 2'd1;
                st <= S_W_USE;
            end else st <= w_ret;
        end
        S_W_USE: begin
            st <= S_W_GET;
            if (bval) case (w_mode)
                W_XPASS: if (ax != 2'sd0 && touch_b) begin
                    if (ax == 2'sd1) begin if (bx - CR_HALF_F < xf) xf <= bx - CR_HALF_F; end
                    else if (bx + bw + CR_HALF_F > xf) xf <= bx + bw + CR_HALF_F;
                end
                W_YPASS: if (under_b) begin
                    if (!dy_pos && old_yf >= b_top - CR_TIE_F && yf <= b_top + CR_TIE_F) begin
                        yf <= b_top; vyf <= 0; grounded <= 1'b1;
                    end
                    if (dy_pos && old_yf + CR_PH_F <= by + CR_TIE_F && yf + CR_PH_F >= by - CR_TIE_F) begin
                        yf <= by - CR_PH_F; vyf <= 0;
                        if (stage == 2'd2 && !opened && bx == CR_PUZZLE_XF && by == CR_PUZZLE_YF
                                && bw == CR_CELL && bh == CR_CELL) begin
                            opened <= 1'b1; tea_on <= 1'b1; tea_x <= CR_TEA_X0; tea_y <= CR_TEA_Y0;
                            tea_vy <= CR_TEA_VY; notify(CR_MSG_PICK_TEA);
                        end
                    end
                end
                W_REACH: if (under_b && yf - b_top >= -CR_TIE_F && yf - b_top <= reach) begin
                    found <= 1'b1; st <= w_ret;
                end
                W_WATER: if (touch_b) begin found <= 1'b1; st <= w_ret; end
                W_BLOCK: if (bk_hit) begin found <= 1'b1; st <= w_ret; end
                W_PLACE: begin
                    c_x <= pc_x; c_y <= pc_y; c_far <= pc_far; st <= S_W_USE2;
                end
                W_TEA: if (ux <= tea_x && tea_x < ux + uw && tea_old >= uy + uh - CR_TOL_Y && tea_y <= uy + uh) begin
                    tea_y <= uy + uh; tea_vy <= 0;
                end
                W_RPUSH: if (rx - CR_HALF_W < ux + uw - CR_TOL_X && rx + CR_HALF_W > ux + CR_TOL_X
                             && rp_y < uy + uh - CR_TOL_Y && rp_y + CR_PH > uy + CR_TOL_Y) begin
                    if (!rdir_l) begin if (ux + uw + CR_HALF_W > rx) rx <= ux + uw + CR_HALF_W; end
                    else if (ux - CR_HALF_W < rx) rx <= ux - CR_HALF_W;
                end
                default: if (rx + CR_HALF_W > ux + CR_TOL_X && rx - CR_HALF_W < ux + uw - CR_TOL_X
                             && ry <= by + bh && by + bh <= r_prev + CR_TIE_F && (!rt_have || by + bh > rt_best)) begin
                    rt_best <= by + bh; rt_have <= 1'b1;      // W_RTOPS: the highest top fallen past
                end
            endcase
        end
        S_W_USE2: begin                  // place: the candidate's score, over three clocks
            c_ok <= !c_far && !(pl_behind && (face_l ? c_x - px_u : px_u - c_x) < CR_GAP - CR_TOL_X);
            c_dx <= sabs(c_x - pl_tx); c_dy <= sabs(c_y - pl_ty);
            c_near <= sabs(c_x - px_u) < CR_NEAR_PLAYER;
            st <= S_W_USE3;
        end
        S_W_USE3: begin
            c_s <= 5 * c_dx + 8 * c_dy + (c_near ? CR_TEN_Q : 48'sd0);
            st <= S_W_USE4;
        end
        S_W_USE4: begin                  // place: keep the smallest candidate above the last one tried
            if (c_ok && (!have_prev || lex_lt(prev_s, prev_x, prev_y, c_s, c_x, c_y))
                     && (!have_best || lex_lt(c_s, c_x, c_y, best_s, best_x, best_y))) begin
                best_s <= c_s; best_x <= c_x; best_y <= c_y; have_best <= 1'b1;
            end
            st <= S_W_GET;
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule
