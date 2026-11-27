// cr_core.v - Stage 3 "Campus Run" game logic (onlystage_3/game.py) as a sequencer.
// Reference: tools/cr_model.py, bit for bit after every 1/120 s step (tb/cr_tb_cosim.v + tools/cr_cosim.py cmp).
//
// Built so far: player physics, jump / double jump / coyote / buffer, collision against the 250 x 11 tile grid and
// the extra boxes (the stage-2 "?" box), deaths (fall, water, time-out), restart, pause, the commands STAGE and
// PUT (Task 7); the animals - patrol, follower, walk + water, fly, pop - and their contact test (Task 8).
// Reporter / skills / lifts / tea / doors (Task 9) are not built yet: a new contact does nothing so far.
//
// Numbers (cr_model.py): 1 m = Q = 600*4096 units; player x / y / speeds / gravity carry 8 more fraction bits
// ("F units"). The grid is visited in the game's list order - rows top to bottom, columns left to right, then
// the extra boxes - one box per two clocks, because that order decides which surface a fast fall lands on.
//
// Inputs: btn_left/btn_right are levels; ev_jump / ev_skill / ev_menu are one-clock pulses valid with gtick.
// Each gtick runs STEPS_PER_TICK steps (2 on the board: 120 steps/s at the 60 Hz tick); jump and skill count for
// the first of them only. demo_cmd (op, arg) is a command applied between steps:
//   1 STAGE  restart at stage arg (1..3)      2 PUT  player to x = arg[8:0]/2 m, y = arg[13:9]/2 m, standing arg[14]
//   3 SEED   random generator state = arg (0 means 0xACE1)
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
    localparam OP_STAGE = 4'd1, OP_PUT = 4'd2, OP_SEED = 4'd3;
    localparam M_MUL = 2'd0, M_DIV = 2'd1, M_SQRT = 2'd2;
    // what the box walker does with each box
    localparam W_XPASS = 2'd0, W_YPASS = 2'd1, W_REACH = 2'd2, W_WATER = 2'd3;

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

    assign mode = {1'b0, mode_r};
    assign level = stage;
    assign exit_req = 1'b0;
    assign q_data = 32'd0;

    // ---------------- sequencer ----------------
    localparam S_IDLE = 6'd0, S_RESTART = 6'd1, S_STEP = 6'd2, S_MOVE0 = 6'd3, S_M1 = 6'd4, S_M2 = 6'd5,
               S_M3 = 6'd6, S_M4 = 6'd7, S_M5 = 6'd8, S_D0 = 6'd9, S_D1 = 6'd10, S_REST = 6'd11,
               S_END = 6'd12, S_MWAIT = 6'd13, S_W_INIT = 6'd14, S_W_GET = 6'd15, S_W_USE = 6'd16,
               S_TJ = 6'd17, S_TJ_R1 = 6'd18, S_TJ_R2 = 6'd19, S_TJ_R3 = 6'd20, S_TJ_D1 = 6'd21,
               S_TJ_D2 = 6'd22, S_TJ_D3 = 6'd23, S_TJ_D4 = 6'd24, S_TJ_D5 = 6'd25, S_TJ_D6 = 6'd26,
               S_TJ_D7 = 6'd27, S_R_ENT = 6'd28, S_A0 = 6'd29, S_A1 = 6'd30, S_A2 = 6'd31, S_A3 = 6'd32,
               S_A4 = 6'd33, S_SCAN = 6'd34, S_A_FALL = 6'd35, S_A9 = 6'd36, S_AC = 6'd37, S_AC2 = 6'd38,
               S_AW = 6'd39;
    reg [5:0] st, tj_ret, w_ret, m_ret;

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
    reg [1:0]  w_mode;
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

    function [15:0] lfsr16;                                     // 16 steps of fpga/rtl/common/lfsr16.v
        input [15:0] q0;
        integer t; reg [15:0] q;
        begin
            q = q0;
            for (t = 0; t < 16; t = t + 1) begin
                q = {q[14:0], q[15] ^ q[14] ^ q[12] ^ q[3]};
                if (q == 16'd0) q = 16'hACE1;
            end
            lfsr16 = q;
        end
    endfunction
    wire [15:0] lfsr_next = lfsr16(lfsr);
    wire [18:0] skin_prod = lfsr_next * ent_nskins;

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
    wire [63:0] a_h2 = a_h1 * {16'd0, CR_H120_M};
    // contact box
    wire signed [47:0] a_xf = $signed({{16{wx[31]}}, wx}) <<< 8;
    wire signed [47:0] a_half = ent_species == 2'd3 ? CR_HALF_GOOSE_F : CR_HALF_OTHER_F;
    wire signed [31:0] a_bot_u = ent_motion == POP ? ent_base : wy;
    wire signed [47:0] a_bot = $signed({{16{a_bot_u[31]}}, a_bot_u}) <<< 8;

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
        input [1:0] op; input [79:0] a; input [79:0] b; input [5:0] next;
        begin
            m_start <= 1'b1; m_op <= op; m_a <= a; m_b <= b; m_ret <= next; st <= S_MWAIT;
        end
    endtask

    task walk;                           // visit the boxes overlapping (lo, hi) in list order, then go to `next`
        input [1:0] mode_w; input signed [47:0] lo; input signed [47:0] hi; input [5:0] next;
        begin
            w_mode <= mode_w; w_lo <= lo; w_hi <= hi; w_ret <= next; st <= S_W_INIT;
        end
    endtask

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
        if (rst) begin
            st <= S_RESTART; stage <= 2'd1; cmd_pend <= 1'b0; enter_pend <= 1'b0; cam_px <= 13'd0;
            lfsr <= 16'hACE1;
            tick_pend <= 1'b0; jump_pend <= 1'b0; skill_pend <= 1'b0; menu_pend <= 1'b0; died <= 1'b0;
            m_op <= 2'd0; m_a <= 80'd0; m_b <= 80'd0;
        end else case (st)
        S_IDLE: begin
            if (enter_pend) begin
                enter_pend <= 1'b0; stage <= 2'd1; st <= S_RESTART;
            end else if (cmd_pend) begin
                cmd_pend <= 1'b0;
                case (cmd_op)
                    OP_STAGE: begin stage <= cmd_arg[1:0]; st <= S_RESTART; end
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
                tick_pend <= gtick; jump_pend <= gtick && ev_jump; skill_pend <= gtick && ev_skill;
                menu_pend <= gtick && ev_menu;
                if (menu_pend && (mode_r == PLAY || mode_r == PAUSE))
                    mode_r <= mode_r == PLAY ? PAUSE : PLAY;
                ax <= (btn_right ? 2'sd1 : 2'sd0) - (btn_left ? 2'sd1 : 2'sd0);
                jl <= jump_pend;
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
            ex_v <= {2'b00, stage == 2'd2};
            ex_x[0] <= CR_PUZZLE_XF; ex_y[0] <= CR_PUZZLE_YF; ex_w[0] <= CR_CELL; ex_h[0] <= CR_CELL;
            for (k = 1; k < 3; k = k + 1) begin
                ex_x[k] <= 0; ex_y[k] <= 0; ex_w[k] <= 0; ex_h[k] <= 0;
            end
            ai <= 7'd0; slots <= 3'd0; contacts <= 64'd0;
            n_ents <= TEST_MODE == 1 ? 7'd0 : stage == 2'd1 ? CR_ENT_COUNT1 : stage == 2'd2 ? CR_ENT_COUNT2 : CR_ENT_COUNT3;
            st <= S_R_ENT;
        end
        S_R_ENT: begin                   // new animals, each drawing its skin from the shared generator
            if (ai == (stage == 2'd1 ? CR_ENT_COUNT1 : stage == 2'd2 ? CR_ENT_COUNT2 : CR_ENT_COUNT3)) begin
                st <= died ? S_END : S_IDLE;
            end else begin
                lfsr <= lfsr_next;
                e_skin[ai[5:0]] <= skin_prod[18:16];
                e_x[ai[5:0]] <= ent_x0; e_y[ai[5:0]] <= ent_y0; e_vy[ai[5:0]] <= 0; e_dl[ai[5:0]] <= 1'b1;
                e_active[ai] <= ent_active0; e_alive[ai] <= 1'b1;
                e_exp[ai[5:0]] <= ent_motion == POP ? 7'd0 : 7'd120;
                e_phase[ai[5:0]] <= 10'd0; e_wl[ai[5:0]] <= 4'd0; e_marks[ai[5:0]] <= 9'd0;
                if (ent_leader1 != 6'd0) begin
                    e_slot[ai[5:0]] <= slots; p_w[slots] <= 6'd0; p_cnt[slots] <= 6'd0; slots <= slots + 3'd1;
                end
                ai <= ai + 7'd1;
            end
        end

        // ---------------- one step (cr_model.step) ----------------
        S_STEP: begin
            died <= 1'b0;
            if (mode_r != PLAY) st <= S_END;
            else if (time_left <= 14'd1) begin
                died <= 1'b1; st <= S_RESTART;
            end else begin
                time_left <= time_left - 14'd1;
                st <= S_MOVE0;
            end
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
            if (yf < CR_DEATH_YF) begin died <= 1'b1; st <= S_RESTART; end
            else if (!grounded && grace == 5'd0) walk(W_WATER, xf - CR_HALF_F, xf + CR_HALF_F, S_D1);
            else st <= S_REST;
        end
        S_D1: begin
            if (found) begin died <= 1'b1; st <= S_RESTART; end
            else st <= S_REST;
        end
        S_REST: begin                    // reporter, objects: Task 9. Then the animals.
            ai <= 7'd0; contacts_new <= 64'd0; st <= S_A0;
        end

        // ---------------- animals (cr_model.animals / update_animal), one at a time in list order ----------
        S_A0: begin
            if (ai == n_ents) begin
                contacts <= contacts_new;
                st <= S_END;             // near-finish and door checks: Task 9
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
            wheight <= a_h2[63:33];      // ANIMAL_H * exposure // 120
            st <= (walive && wact && wexp != 7'd0 && wwl == 4'd0) ? S_AC2 : S_AW;
        end
        S_AC2: begin
            if (xf - CR_HALF_F < a_xf + a_half - CR_TIE_X && xf + CR_HALF_F > a_xf - a_half + CR_TIE_X
                    && yf < a_bot + (wheight <<< 8) - CR_TIE_F && yf + CR_PH_F > a_bot + CR_TIE_F)
                contacts_new[ai] <= 1'b1;            // a new contact calls hit(): Task 9
            st <= S_AW;
        end
        S_AW: begin
            e_x[ai[5:0]] <= wx; e_y[ai[5:0]] <= wy; e_vy[ai[5:0]] <= wvy; e_dl[ai[5:0]] <= wdl;
            e_exp[ai[5:0]] <= wexp; e_phase[ai[5:0]] <= wphase; e_wl[ai[5:0]] <= wwl;
            e_marks[ai[5:0]] <= wmarks; e_alive[ai] <= walive; e_active[ai] <= wact;
            ai <= ai + 7'd1; st <= S_A0;
        end
        S_END: begin
            step_done <= 1'b1;
            jl <= 1'b0;
            if (steps_left > 3'd1) begin steps_left <= steps_left - 3'd1; st <= S_STEP; end
            else st <= S_IDLE;
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
                    end
                end
                W_REACH: if (under_b && yf - b_top >= -CR_TIE_F && yf - b_top <= reach) begin
                    found <= 1'b1; st <= w_ret;
                end
                default: if (touch_b) begin found <= 1'b1; st <= w_ret; end
            endcase
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule
