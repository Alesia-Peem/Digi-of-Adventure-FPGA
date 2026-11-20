// s2_core.v - STAGE 2 "Internship": complete game logic, a port of class Game in stage2_demo.py.
//
// Once per game tick (60 Hz) a sequencer runs Game._update() in Pygame order:
//   7 x LFSR -> flash/help/clear/over -> timers (slow, skill, zoom) -> SW13 skill edge -> card_trigger
//   -> cards | Boss intro start | npc_update | talk_input | (cut-scene) | play_t | (zoom) | skill
//   -> hint popup | inventory (SW15) | notebook (SW14) | map_update (move with wall slide, find_near) |
//   closeup_input (whiteboard, door, bench: parts tray + breadboard editor)
// Shared modules: lfsr16, card_deck, inventory (Stage-2 "stored" item rules), heart_system, sprite_anim
// (Stage-2 walk cycle). Stage-2 modules: s2_walk (walk mask), s2_circuit (val() of a net).
// Positions are world pixels of the 960x540 room with two decimals (int + hundredths), so the Pygame
// speeds 312 px/s -> 5.20 px per tick, x0.5 slow, wall slide 0.7 x speed are exact.
// The Boss walks along the trajectory that stage2_assets.py recorded from npc_update() (s2_npc.mem).
`timescale 1ns/1ps
module s2_core #(parameter NPC_FILE = "mem/s2_npc.mem", parameter MASK_FILE = "mem/s2_mask.mem") (
    input  wire          clk,
    input  wire          rst,
    input  wire          gtick,
    input  wire          ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back,
    input  wire [4:0]    lvl,
    input  wire [15:0]   sw,
    input  wire          enter,
    input  wire          help_on_entry,
    input  wire          has_next,
    input  wire [1:0]    in_armor,
    input  wire          in_shard,
    input  wire          in_boost,
    output reg           exit_req,
    output wire [1:0]    out_armor,
    output wire          out_shard,
    output wire          out_boost,
    output wire [1:0]    out_form,
    input  wire          demo_cmd,
    input  wire [3:0]    demo_op,
    input  wire [15:0]   demo_arg,
    output wire [3071:0] fields,
    output wire [255:0]  conds,
    output wire [2:0]    bg_mode,
    output wire [11:0]   bg_color,
    output reg  [11:0]   zoom_ox, zoom_oy,
    output reg  [16:0]   zoom_inv,
    output wire [269:0]  wire_src,
    output reg  [27:0]   src_val,
    output wire [6:0]    wire_hl,
    output reg  [39:0]   seg_chars,
    output wire [7:0]    seg_raw_en,
    output wire [55:0]   seg_raw,
    output wire [15:0]   leds,
    output wire [2:0]    rgb16,
    output wire [2:0]    rgb17
);
`include "game_defs.vh"
`include "ui_map.vh"
`include "s2_consts.vh"

    // ================================================================ constants
    localparam [9:0]  SPAWN_X = 10'd682, SPAWN_Y = 10'd300;
    localparam [12:0] SKILL_SECS = 13'd600, SKILL_WAIT = 13'd7200;
    localparam [7:0]  OVER_FRAMES = 8'd180, FLASH_FRAMES = 8'd24;
    localparam [1:0]  ST_PLAY = 2'd0, ST_OVER = 2'd1, ST_CLEAR = 2'd2;
    localparam [2:0]  NPC_OFF = 3'd0, NPC_TOP = 3'd1, NPC_TALK = 3'd2, NPC_TOS = 3'd3, NPC_SIT = 3'd4;
    localparam [2:0]  TK_INTRO = 3'd1, TK_INFO = 3'd2, TK_ASK = 3'd3, TK_VERD = 3'd4;
    localparam [2:0]  HD_TXT = 3'd1, HD_SEG = 3'd2, HD_WIRE = 3'd3;
    localparam [1:0]  O_WB = 2'd0, O_DOOR = 2'd1, O_BENCH = 2'd2;
    localparam [5:0]  CUR_CLEAR = 6'd54;

    // ================================================================ state
    reg        show_help, debug;
    reg [1:0]  state;
    reg        mode_cu; reg [1:0] cur; reg [1:0] page;
    reg [7:0]  cmsg; reg [3:0] cmsg_a;
    reg [2:0]  found [0:8];
    reg [17:0] done_spots; reg [8:0] read_hints;
    reg [1:0]  rnd; reg codes_v; reg [2:0] code0, code1;
    reg        pairs_v; reg [2:0] pair [0:5];
    reg [269:0] w;
    reg [5:0]  wcur; reg wpick; reg [4:0] wprev;
    reg        undo_v; reg [269:0] undo_w;
    reg [7:0]  note [0:7]; reg [3:0] note_n;
    reg [23:0] hist [0:15]; reg [23:0] hn0, hn1;           // hints_seen (history for the de-duplication)
    reg [23:0] hp; reg hp_on;                              // hint popup descriptor {type, a, b, c}
    reg [1:0]  inv_cur;
    reg [7:0]  toast; reg [7:0] toast_t; reg [7:0] toast_a;
    reg [7:0]  flash, over_t;
    reg [12:0] play_t, skill_t; reg skill_used;
    reg        zoom_on; reg [6:0] zt; reg [9:0] zx, zy;
    reg [2:0]  npc; reg [7:0] npc_i;
    reg        intro_started, cutscene;
    reg        talk_on; reg [2:0] talk_k; reg [3:0] talk_i, talk_n; reg talk_var;
    reg        vd_pass, vd_armor; reg [1:0] vd_ok;           // verdict data
    reg [3:1]  r_run, r_done;
    reg [9:0]  px_i, py_i; reg [6:0] px_f, py_f;              // position = int + hundredths
    reg [1:0]  form;
    reg        sw13_d;
    reg        walking;                                       // map_update ran this tick
    reg [5:0]  near_k; reg near_v;                            // find_near() result (for the prompt)
    reg [15:0] tickc;                                         // free-running tick counter (glow, blink)

    // ================================================================ shared modules
    reg        lf_step, lf_load; reg [15:0] lf_seed; wire [15:0] lfsr;
    lfsr16 u_lfsr (.clk(clk), .rst(rst), .load(lf_load), .seed(lf_seed), .step(lf_step), .q(lfsr));

    reg        e_u, e_d, e_l, e_r, e_tap, e_back;
    reg        dk_start, dk_en, dk_clear; reg [1:0] dk_round; reg [2:0] dk_perm;
    wire       dk_active, dk_face_up, dk_grant, dk_cvalid, dk_rdone;
    wire [1:0] dk_rnd, dk_cursor, dk_face, career; wire [2:0] dk_pm; wire [3:0] dk_item;
    card_deck u_deck (.clk(clk), .rst(rst), .clear(dk_clear), .start(dk_start), .start_round(dk_round),
        .start_perm(dk_perm), .en(dk_en), .ev_l(e_l), .ev_r(e_r), .ev_tap(e_tap), .set_career(1'b0),
        .set_career_v(2'd0), .active(dk_active), .round(dk_rnd), .perm(dk_pm), .cursor(dk_cursor),
        .face_up(dk_face_up), .face(dk_face), .grant(dk_grant), .grant_item(dk_item), .career(career),
        .career_valid(dk_cvalid), .round_done(dk_rdone));

    reg        inv_tick, inv_load, inv_restore, inv_add_armor, use_hh, use_hs, use_un;
    wire [1:0] armor, n_hh, n_hs, n_un, n_fr; wire shard, boost, forged; wire [9:0] slow_f; wire [8:0] freeze_f;
    wire       dmg_armor;
    inventory u_inv (.clk(clk), .rst(rst), .tick(inv_tick), .run(1'b1), .store_mode(1'b1),
        .load(inv_load), .load_armor(in_armor), .load_shard(in_shard), .load_boost(in_boost),
        .restore(inv_restore), .grant(dk_grant), .grant_item(dk_item), .armor_consume(dmg_armor),
        .add_armor(inv_add_armor), .use_hh(use_hh), .use_hs(use_hs), .use_undo(use_un), .use_freeze(1'b0),
        .boost_consume(1'b0), .armor(armor), .shard(shard), .boost(boost), .n_hh(n_hh), .n_hs(n_hs),
        .n_undo(n_un), .n_freeze(n_fr), .slow_f(slow_f), .freeze_f(freeze_f), .forged(forged));

    reg        hs_clear, hs_set, qa_dmg; reg [1:0] hs_setv;
    wire [1:0] hearts; wire hs_hit, hs_blocked, hs_dead;
    heart_system u_hearts (.clk(clk), .rst(rst), .clear(hs_clear), .set_en(hs_set), .set_val(hs_setv),
        .damage(qa_dmg), .armor_avail(armor != 2'd0), .armor_consume(dmg_armor), .hearts(hearts),
        .hit(hs_hit), .blocked(hs_blocked), .dead(hs_dead));

    reg        an_upd, an_stop, an_reset, an_moved; reg [1:0] an_dx, an_dy;
    wire [1:0] sdir, spose;
    sprite_anim #(.CYCLE2(1)) u_anim (.clk(clk), .rst(rst), .reset_dir(an_reset), .upd(an_upd), .stop(an_stop),
        .dxs(an_dx), .dys(an_dy), .moved(an_moved), .dir(sdir), .pose(spose));

    reg        wk_start; reg [11:0] wk_x, wk_y; wire wk_done, wk_blk;
    s2_walk #(.MASK_FILE(MASK_FILE)) u_walk (.clk(clk), .start(wk_start), .x(wk_x), .y(wk_y),
        .done(wk_done), .blocked(wk_blk));

    reg        cv_start; reg [4:0] cv_node; reg cv_c, cv_b, cv_a; wire cv_done, cv_val;
    s2_circuit u_circ (.clk(clk), .start(cv_start), .node(cv_node), .lc(cv_c), .lb(cv_b), .la(cv_a), .w(w),
        .done(cv_done), .val(cv_val));

    reg  [7:0] npc_addr; wire [32:0] npc_q;
    rom_sync #(.WIDTH(33), .DEPTH(256), .AW(8), .MEM_FILE(NPC_FILE)) u_npc (.clk(clk), .addr(npc_addr), .q(npc_q));
    always @(posedge clk) npc_addr <= npc_i;

    // ================================================================ helpers
    function [5:0] ws(input [269:0] ww, input [5:0] i); ws = {1'b0, ww[5 * i +: 5]}; endfunction
    wire [4:0] parts_total = found[0] + found[1] + found[2] + found[3] + found[4] + found[5] + found[6]
                           + found[7] + found[8];
    wire       slow = (slow_f != 10'd0);
    // speed() per tick (hundredths): 5.20 px, 2.60 while slow; wall slide = 0.7 x speed
    wire [2:0] sp_i = slow ? 3'd2 : 3'd5;
    wire [6:0] sp_f = slow ? 7'd60 : 7'd20;
    wire [2:0] sl_i = slow ? 3'd1 : 3'd3;
    wire [6:0] sl_f = slow ? 7'd82 : 7'd64;
    function [16:0] padd(input [9:0] i, input [6:0] f, input [2:0] di, input [6:0] df);   // {i, f} + {di, df}
        reg [7:0] s;
        begin s = f + df; padd = (s >= 8'd100) ? {i + di + 10'd1, s[6:0] - 7'd100} : {i + di, s[6:0]}; end
    endfunction
    function [16:0] psub(input [9:0] i, input [6:0] f, input [2:0] di, input [6:0] df);   // {i, f} - {di, df}
        begin psub = (f >= df) ? {i - di, f - df} : {i - di - 10'd1, f + 7'd100 - df}; end
    endfunction
    wire k_r = lvl[3], k_l = lvl[2], k_d = lvl[1], k_u = lvl[0];
    wire dxv = k_r ^ k_l, dyv = k_d ^ k_u;
    wire [16:0] cxp = !dxv ? {px_i, px_f} : k_r ? padd(px_i, px_f, sp_i, sp_f) : psub(px_i, px_f, sp_i, sp_f);
    wire [16:0] cyp = !dyv ? {py_i, py_f} : k_d ? padd(py_i, py_f, sp_i, sp_f) : psub(py_i, py_f, sp_i, sp_f);
    wire [16:0] py_up = padd(py_i, py_f, sl_i, sl_f), py_dn = psub(py_i, py_f, sl_i, sl_f);
    wire [16:0] px_up = padd(px_i, px_f, sl_i, sl_f), px_dn = psub(px_i, px_f, sl_i, sl_f);

    // levels() of the DIP switch for input code k = {C,B,A}
    wire       dip_vcc = (ws(w, SK_DIPVCC) == 6'd1);
    function lv(input on, input [5:0] pd); lv = (on && dip_vcc) ? 1'b1 : (pd == 6'd2) ? 1'b0 : 1'b1; endfunction
    wire [2:0] code3 = sw[2:0];
    // the lit segments of the CURRENT switch code (bench page) and the value of every source (wire colour)
    reg  [6:0] segs_now;

    // ================================================================ sequencer
    localparam Q_IDLE = 6'd0, Q_LFSR = 6'd1, Q_TOP = 6'd2, Q_TRIG = 6'd3, Q_PICK = 6'd4, Q_PICKW = 6'd5,
               Q_PICK2 = 6'd6, Q_AFTERDECK = 6'd7, Q_DECKW = 6'd29, Q_NPC = 6'd8, Q_TALK = 6'd9, Q_MAIN = 6'd10, Q_MX = 6'd11,
               Q_MXW = 6'd12, Q_MY = 6'd13, Q_MYW = 6'd14, Q_ANIM = 6'd15, Q_NEAR = 6'd16, Q_NEAR2 = 6'd17,
               Q_CU = 6'd18, Q_EVAL = 6'd19, Q_EVALW = 6'd20, Q_END = 6'd21, Q_DEMO = 6'd22, Q_JUDGE = 6'd23,
               Q_HINT = 6'd24, Q_HINT2 = 6'd25, Q_SMART = 6'd26, Q_PAIRS = 6'd27, Q_PAIRSW = 6'd28;
    reg [5:0]  q, q_ret;
    reg [2:0]  cnt;
    reg [1:0]  mv_ph;                       // which of the 3 tries of a move
    reg [16:0] cand;
    reg [9:0]  ox_i, oy_i; reg [6:0] ox_f, oy_f;
    // find_near
    reg [5:0]  nk; reg nb_v; reg [5:0] nb_k; reg [47:0] nb_d; reg [12:0] nb_r2; reg [2:0] nph;
    reg [47:0] nd_c; reg signed [17:0] ndx, ndy; reg [12:0] nr2; reg nval; reg near_act;
    // evaluation jobs: bit list of what to evaluate this tick
    reg [5:0]  ev_i;                        // 0..6 segments of code3, 7..33 sources (wire colours)
    reg [5:0]  ev_n;
    reg        ev_job;                      // 0 = display, 1 = judge / hint (k0, k1)
    reg [6:0]  ev_seg0, ev_seg1;            // lit segments for code0 / code1
    reg        hint_exact; reg [2:0] hseg; reg [5:0] href;
    reg [3:0]  pick_n; reg [2:0] pick_v; reg [3:0] pick_why;   // lfsr_pick(n) and what it is for
    reg        sk_press;                    // SW13 rising edge of this tick
    reg [2:0]  pi;                          // make_pairs loop
    reg [2:0]  order [0:5];
    reg        dm_pend; reg [3:0] dm_op; reg [15:0] dm_arg;
    integer    ii;

    // value of node n for code k (used by the evaluation states)
    wire [2:0] ev_code = (ev_job == 1'b0) ? code3 : (ev_i[3] ? code1 : code0);

    // hint descriptor {type, a, b, c}: TXT a = popup text (S2_PTEXT) b = title (S2_PTITLE);
    // SEG a = segment b = {t1, t0} c = {in1, in0}; WIRE a = sink b = source
    function [23:0] hd(input [2:0] t, input [6:0] a, input [6:0] b, input [6:0] c); hd = {t, a, b, c}; endfunction
    wire [6:0] g0 = gold_segs(code0), g1 = gold_segs(code1);
    // missing parts for the smart hint: k-th spot that is not found yet (spot order)
    wire [4:0] n_missing = 5'd18 - (done_spots[0] + done_spots[1] + done_spots[2] + done_spots[3] + done_spots[4]
                         + done_spots[5] + done_spots[6] + done_spots[7] + done_spots[8] + done_spots[9]
                         + done_spots[10] + done_spots[11] + done_spots[12] + done_spots[13] + done_spots[14]
                         + done_spots[15] + done_spots[16] + done_spots[17]);
    function [4:0] kth_missing(input [4:0] k);
        integer i; reg [4:0] c; reg found_k;
        begin
            kth_missing = 5'd0; c = 5'd0; found_k = 1'b0;
            for (i = 0; i < 18; i = i + 1)
                if (!done_spots[i] && !found_k) begin
                    if (c == k) begin kth_missing = i; found_k = 1'b1; end
                    c = c + 5'd1;
                end
        end
    endfunction
    wire [3:0] first_miss = (found[0] < part_qty(0)) ? 4'd0 : (found[1] < part_qty(1)) ? 4'd1 :
                            (found[2] < part_qty(2)) ? 4'd2 : (found[3] < part_qty(3)) ? 4'd3 :
                            (found[4] < part_qty(4)) ? 4'd4 : (found[5] < part_qty(5)) ? 4'd5 :
                            (found[6] < part_qty(6)) ? 4'd6 : (found[7] < part_qty(7)) ? 4'd7 : 4'd8;
    // ---------------------------------------------------------------- tasks
    task say(input [7:0] id, input [7:0] dur);
        begin toast <= id; toast_t <= dur; end
    endtask
    task note_push(input [7:0] v);
        integer i;
        begin
            if (note_n != 4'd8) begin note[note_n[2:0]] <= v; note_n <= note_n + 4'd1; end
            else begin for (i = 0; i < 7; i = i + 1) note[i] <= note[i + 1]; note[7] <= v; end
        end
    endtask
    task show_hint(input [23:0] d);           // hint popup + hints_seen (de-duplicated)
        integer i; reg dup;
        begin
            hp <= d; hp_on <= 1'b1; dup = 1'b0;
            for (i = 0; i < 16; i = i + 1) if (hist[i] == d) dup = 1'b1;
            if (!dup) begin
                for (i = 0; i < 15; i = i + 1) hist[i] <= hist[i + 1];
                hist[15] <= d; hn0 <= hn1; hn1 <= d;
            end
        end
    endtask
    task reset_stage(input full);
        integer i;
        begin
            if (full) form <= 2'd1;
            px_i <= SPAWN_X; px_f <= 7'd0; py_i <= SPAWN_Y; py_f <= 7'd0;
            mode_cu <= 1'b0; cur <= 2'd0; page <= 2'd0; cmsg <= S2_CMSG_NONE; cmsg_a <= 4'd0;
            state <= ST_PLAY;
            for (i = 0; i < 9; i = i + 1) found[i] <= 3'd0;
            done_spots <= 18'd0; read_hints <= 9'd0;
            rnd <= 2'd0; codes_v <= 1'b0; pairs_v <= 1'b0; code0 <= 3'd0; code1 <= 3'd0;
            w <= 270'd0; wcur <= 6'd0; wpick <= 1'b0; wprev <= 5'd0; undo_v <= 1'b0;
            for (i = 0; i < 8; i = i + 1) note[i] <= 8'd0;
            note_n <= 4'd0;
            for (i = 0; i < 16; i = i + 1) hist[i] <= 24'hFFFFFF;
            hn0 <= 24'd0; hn1 <= 24'd0; hp_on <= 1'b0; hp <= 24'd0; inv_cur <= 2'd0; toast_a <= 8'd0;
            for (i = 0; i < 6; i = i + 1) begin pair[i] <= 3'd0; order[i] <= 3'd0; end
            talk_k <= 3'd0; talk_i <= 4'd0; talk_n <= 4'd0; talk_var <= 1'b0;
            vd_pass <= 1'b0; vd_armor <= 1'b0; vd_ok <= 2'd0; near_k <= 6'd0; near_v <= 1'b0;
            r_run <= 3'b000; r_done <= 3'b000;
            toast <= 8'd0; toast_t <= 8'd0; flash <= 8'd0; over_t <= 8'd0;
            play_t <= 13'd0; skill_t <= 13'd0; skill_used <= 1'b0; zoom_on <= 1'b0;
            npc <= NPC_OFF; npc_i <= 8'd0;
            talk_on <= 1'b0; intro_started <= 1'b0; cutscene <= 1'b0;
            dk_clear <= 1'b1; hs_clear <= 1'b1; an_reset <= 1'b1;
            if (full) inv_load <= 1'b1; else inv_restore <= 1'b1;
        end
    endtask
    task open_talk(input [2:0] k, input [3:0] n, input v);
        begin talk_on <= 1'b1; talk_k <= k; talk_i <= 4'd0; talk_n <= n; talk_var <= v; end
    endtask

    // ---------------------------------------------------------------- find_near() candidate data
    //   0..2 work-order board, door, bench (r 70)  3 Boss (r 70, only when seated)
    //   4..21 hidden parts (r 50, not found yet)    22..30 hint notes (r 50, not read yet)
    wire [5:0]  nkk = nk;
    wire        n_ok  = (nkk <= 6'd2) || (nkk == 6'd3 && npc == NPC_SIT) ||
                        (nkk >= 6'd4 && nkk <= 6'd21 && !done_spots[nkk - 6'd4]) ||
                        (nkk >= 6'd22 && nkk <= 6'd30 && !read_hints[nkk - 6'd22]);
    wire [11:0] n_ax  = (nkk <= 6'd3) ? ob_ax(nkk) : (nkk <= 6'd21) ? it_ax(nkk - 6'd4) : hi_ax(nkk - 6'd22);
    wire [11:0] n_ay  = (nkk <= 6'd3) ? ob_ay(nkk) : (nkk <= 6'd21) ? it_ay(nkk - 6'd4) : hi_ay(nkk - 6'd22);
    wire [12:0] n_r2  = (nkk <= 6'd3) ? 13'd4900 : 13'd2500;

    // ---------------------------------------------------------------- main always block
    always @(posedge clk) begin
        lf_step <= 1'b0; lf_load <= 1'b0; dk_start <= 1'b0; dk_en <= 1'b0; dk_clear <= 1'b0;
        inv_tick <= 1'b0; inv_load <= 1'b0; inv_restore <= 1'b0; inv_add_armor <= 1'b0;
        use_hh <= 1'b0; use_hs <= 1'b0; use_un <= 1'b0;
        hs_clear <= 1'b0; hs_set <= 1'b0; qa_dmg <= 1'b0;
        an_upd <= 1'b0; an_stop <= 1'b0; an_reset <= 1'b0; exit_req <= 1'b0;
        wk_start <= 1'b0; cv_start <= 1'b0;
        if (demo_cmd) begin dm_pend <= 1'b1; dm_op <= demo_op; dm_arg <= demo_arg; end

        if (rst) begin
            q <= Q_IDLE; show_help <= 1'b1; debug <= 1'b0; dm_pend <= 1'b0; form <= 2'd1; sw13_d <= 1'b0;
            tickc <= 16'd0; near_v <= 1'b0; segs_now <= 7'd0; src_val <= 28'd0;
            reset_stage(1'b1);
        end else if (enter) begin
            q <= Q_IDLE; show_help <= help_on_entry; reset_stage(1'b1);
        end else begin
            case (q)
            Q_IDLE: begin
                if (gtick) begin
                    {e_u, e_d, e_l, e_r, e_tap, e_back} <= {ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back};
                    cnt <= 3'd0; walking <= 1'b0; tickc <= tickc + 16'd1; q <= Q_LFSR;
                end else if (dm_pend) begin dm_pend <= 1'b0; q <= Q_DEMO; end
            end
            Q_LFSR: begin lf_step <= 1'b1; cnt <= cnt + 3'd1; if (cnt == 3'd6) q <= Q_TOP; end
            // ---- flash, help, clear, over, timers, SW13 edge
            Q_TOP: begin
                q <= Q_END;
                if (flash != 8'd0) flash <= flash - 8'd1;
                if (toast_t != 8'd0) toast_t <= toast_t - 8'd1;
                if (show_help) begin
                    if (e_tap || e_back) show_help <= 1'b0;
                end else if (state == ST_CLEAR) begin
                    if (e_tap) exit_req <= 1'b1;
                end else if (state == ST_OVER) begin
                    if (over_t == 8'd0) reset_stage(1'b0);
                    else over_t <= over_t - 8'd1;
                end else begin
                    inv_tick <= 1'b1;                                         // slow_t -= dt
                    if (skill_t != 13'd0) skill_t <= skill_t - 13'd1;         // skill keeps counting
                    if (zoom_on) begin
                        if (zt == 7'd89) zoom_on <= 1'b0; else zt <= zt + 7'd1;
                    end
                    sk_press <= sw[13] && !sw13_d; sw13_d <= sw[13];
                    q <= Q_TRIG;
                end
            end
            // ---- card_trigger(): round 1 at start, 2 at 9 parts, 3 after 2 QA tests
            Q_TRIG: begin
                q <= Q_AFTERDECK;
                if (!dk_active) begin
                    if (!r_run[1]) begin dk_round <= 2'd1; pick_n <= 4'd6; pick_why <= 4'd0; q <= Q_PICK; end
                    else if (r_done[1] && !r_run[2] && parts_total >= 5'd9) begin
                        dk_round <= 2'd2; pick_n <= 4'd6; pick_why <= 4'd0; q <= Q_PICK; end
                    else if (r_done[2] && !r_run[3] && rnd >= 2'd2) begin
                        dk_round <= 2'd3; pick_n <= 4'd6; pick_why <= 4'd0; q <= Q_PICK; end
                end
            end
            // ---- lfsr_pick(n): step until (lfsr & 7) < n; pick_why says what the value is for
            Q_PICK:  begin lf_step <= 1'b1; q <= Q_PICKW; end
            Q_PICKW: q <= Q_PICK2;
            Q_PICK2: begin
                if ({1'b0, lfsr[2:0]} >= pick_n) q <= Q_PICK;
                else case (pick_why)
                    4'd0: begin dk_perm <= lfsr[2:0]; dk_start <= 1'b1; r_run[dk_round] <= 1'b1; q <= Q_DECKW; end
                    4'd1: begin                                                // make_pairs swap
                        order[pi] <= order[lfsr[2:0]]; order[lfsr[2:0]] <= order[pi];
                        pi <= pi - 3'd1; q <= Q_PAIRS;
                    end
                    default: begin pick_v <= lfsr[2:0]; q <= Q_SMART; end      // smart hint clue
                endcase
            end
            Q_DECKW: q <= Q_AFTERDECK;                                  // deck becomes active
            Q_AFTERDECK: begin
                q <= Q_NPC;
                if (dk_active) begin dk_en <= 1'b1; q <= Q_END; end           // cards_input(); return
                else if (r_done[1] && !intro_started) begin                    // start_intro()
                    intro_started <= 1'b1; cutscene <= 1'b1; npc <= NPC_TOP; npc_i <= 8'hFF;   // -1: first update -> entry 0
                end
            end
            // ---- npc_update(): follow the recorded trajectory
            Q_NPC: begin
                q <= Q_TALK;
                if (npc == NPC_TOP || npc == NPC_TOS) begin              // one recorded update per tick
                    npc_i <= npc_i + 8'd1;
                    if (npc == NPC_TOP && npc_i + 8'd1 == NPC_L1 - 1) begin
                        npc <= NPC_TALK; open_talk(TK_INTRO, 4'd8, 1'b0);       // reached the player
                    end else if (npc == NPC_TOS && npc_i + 8'd1 == NPC_L1 + NPC_L2 - 1) begin
                        npc <= NPC_SIT; cutscene <= 1'b0;
                    end
                end
            end
            // ---- talk_input()
            Q_TALK: begin
                q <= Q_MAIN;
                if (talk_on) begin
                    q <= Q_END;
                    if (e_tap) begin
                        if (talk_i != talk_n - 4'd1) begin
                            talk_i <= talk_i + 4'd1;
                            if (talk_k == TK_INTRO && talk_i == 4'd2) skill_t <= SKILL_SECS;   // line 3: start_skill()
                        end else begin                                         // talk_done(True)
                            talk_on <= 1'b0;
                            case (talk_k)
                                TK_INTRO: begin
                                    npc <= NPC_TOS; npc_i <= NPC_L1 - 1;
                                    note_push(S2_NOTE_N29);
                                end
                                TK_ASK: begin ev_job <= 1'b1; ev_i <= 6'd0; q <= Q_EVAL; q_ret <= Q_JUDGE; end
                                TK_VERD: begin
                                    if (!vd_pass) qa_dmg <= 1'b1;
                                    else begin
                                        rnd <= rnd + 2'd1;
                                        if (rnd == 2'd2) say(S2_TOAST_DOOR, 8'd150);
                                        else begin code0 <= pair[2 * (rnd + 2'd1)]; code1 <= pair[2 * (rnd + 2'd1) + 1];
                                                   undo_v <= 1'b0; end                   // new_round()
                                    end
                                end
                                default: ;
                            endcase
                        end
                    end else if (e_back && talk_k == TK_ASK && talk_i == talk_n - 4'd1) begin
                        talk_on <= 1'b0;                                        // talk_done(False)
                    end
                end
            end
            // ---- the rest of _update()
            Q_MAIN: begin
                q <= Q_END;
                if (cutscene) ;
                else begin
                    if (play_t != 13'h1FFF) play_t <= play_t + 13'd1;
                    if (zoom_on) ;
                    else begin
                        if (sk_press) begin                                     // try_skill()
                            if (skill_t != 13'd0) say(S2_TOAST_SK_ON, 8'd150);
                            else if (skill_used) say(S2_TOAST_SK_USED, 8'd150);
                            else if (play_t < SKILL_WAIT) begin
                                say(S2_TOAST_SK_RECH, 8'd150); toast_a <= (SKILL_WAIT - play_t + 13'd59) / 60;
                            end
                            else if (mode_cu) say(S2_TOAST_SK_MAP, 8'd150);
                            else begin skill_used <= 1'b1; skill_t <= SKILL_SECS; say(S2_TOAST_SK_GO, 8'd150); end
                        end
                        if (hp_on) begin if (e_tap || e_back) hp_on <= 1'b0; end
                        else if (sw[15]) begin                                  // inventory_input()
                            if (e_l) inv_cur <= inv_cur - 2'd1;
                            else if (e_r) inv_cur <= inv_cur + 2'd1;
                            else if (e_tap) begin
                                case (inv_cur)
                                    2'd0: if (n_hh == 2'd0) say(S2_TOAST_NOITEM, 8'd150);
                                          else if (rnd == 2'd3) say(S2_TOAST_NU_VER, 8'd150);
                                          else if (!codes_v) say(S2_TOAST_NU_BENCH, 8'd150);
                                          else begin use_hh <= 1'b1; hint_exact <= 1'b0; ev_job <= 1'b1;
                                                     ev_i <= 6'd0; q <= Q_EVAL; q_ret <= Q_HINT; end
                                    2'd1: if (n_hs == 2'd0) say(S2_TOAST_NOITEM, 8'd150);
                                          else if (done_spots != 18'h3FFFF) begin
                                              pick_n <= 4'd8; pick_why <= 4'd2; q <= Q_PICK;  // lfsr_pick(8)
                                          end else if (rnd == 2'd3) say(S2_TOAST_NU_NOTHING, 8'd150);
                                          else if (!codes_v) begin use_hs <= 1'b1; show_hint(hd(HD_TXT, 7'd27, 7'd9, 7'd0)); end
                                          else begin use_hs <= 1'b1; hint_exact <= 1'b1; ev_job <= 1'b1;
                                                     ev_i <= 6'd0; q <= Q_EVAL; q_ret <= Q_HINT; end
                                    2'd2: if (n_un == 2'd0) say(S2_TOAST_NOITEM, 8'd150);
                                          else if (!undo_v || rnd == 2'd3) say(S2_TOAST_NOUNDO, 8'd150);
                                          else begin use_un <= 1'b1; w <= undo_w; undo_v <= 1'b0; wpick <= 1'b0;
                                                     say(S2_TOAST_UNDONE, 8'd150); end
                                    default: if (n_fr == 2'd0) say(S2_TOAST_NOITEM, 8'd150);
                                             else say(S2_TOAST_FREEZE, 8'd150);
                                endcase
                            end
                        end
                        else if (sw[14]) ;
                        else if (!mode_cu) begin                                // map_update()
                            ox_i <= px_i; ox_f <= px_f; oy_i <= py_i; oy_f <= py_f;
                            cand <= cxp; mv_ph <= 2'd0;
                            if (dxv) begin wk_x <= {2'b0, cxp[16:7]}; wk_y <= {2'b0, py_i}; wk_start <= 1'b1; q <= Q_MXW; end
                            else q <= Q_MY;
                        end else q <= Q_CU;
                    end
                end
            end
            // ---- move X: straight, else slide down, else slide up
            Q_MXW: if (wk_done) q <= Q_MX;
            Q_MX: begin
                if (!wk_blk) begin
                    px_i <= cand[16:7]; px_f <= cand[6:0];
                    if (mv_ph == 2'd1) begin py_i <= py_up[16:7]; py_f <= py_up[6:0]; end
                    if (mv_ph == 2'd2) begin py_i <= py_dn[16:7]; py_f <= py_dn[6:0]; end
                    q <= Q_MY;
                end else if (mv_ph == 2'd2) q <= Q_MY;
                else begin
                    mv_ph <= mv_ph + 2'd1;
                    wk_x <= {2'b0, cand[16:7]};
                    wk_y <= {2'b0, (mv_ph == 2'd0) ? py_up[16:7] : py_dn[16:7]};
                    wk_start <= 1'b1; q <= Q_MXW;
                end
            end
            Q_MY: begin
                mv_ph <= 2'd3;                                                   // marks "y step started"
                if (dyv) begin cand <= cyp; wk_x <= {2'b0, px_i}; wk_y <= {2'b0, cyp[16:7]}; wk_start <= 1'b1;
                               mv_ph <= 2'd0; q <= Q_MYW; end
                else q <= Q_ANIM;
            end
            Q_MYW: if (wk_done) begin
                if (!wk_blk) begin py_i <= cand[16:7]; py_f <= cand[6:0]; q <= Q_ANIM;
                    if (mv_ph == 2'd1) begin px_i <= px_up[16:7]; px_f <= px_up[6:0]; end
                    if (mv_ph == 2'd2) begin px_i <= px_dn[16:7]; px_f <= px_dn[6:0]; end
                end else if (mv_ph == 2'd2) q <= Q_ANIM;
                else begin
                    mv_ph <= mv_ph + 2'd1;
                    wk_x <= {2'b0, (mv_ph == 2'd0) ? px_up[16:7] : px_dn[16:7]};
                    wk_y <= {2'b0, cand[16:7]};
                    wk_start <= 1'b1;
                end
            end
            Q_ANIM: begin
                an_upd <= 1'b1; walking <= 1'b1;
                an_dx <= {dxv, k_r}; an_dy <= {dyv, k_d};
                an_moved <= (px_i != ox_i) || (px_f != ox_f) || (py_i != oy_i) || (py_f != oy_f);
                nk <= 6'd0; nb_v <= 1'b0; nph <= 3'd0; near_act <= e_tap; q <= Q_NEAR;
            end
            // ---- find_near(): best score = dist / r < 1.0001 (exact integer compare, hundredths)
            Q_NEAR: begin
                nph <= nph + 3'd1;
                case (nph)
                    3'd0: begin ndx <= $signed({1'b0, px_i, 7'd0}) - 0; end            // placeholder cycle
                    3'd1: begin
                        ndx <= $signed({1'b0, px_i} * 18'd100 + px_f) - $signed({6'd0, n_ax} * 18'd100);
                        ndy <= $signed({1'b0, py_i} * 18'd100 + py_f) - $signed({6'd0, n_ay} * 18'd100);
                        nr2 <= n_r2; nval <= n_ok;
                    end
                    3'd2: nd_c <= ndx * ndx + ndy * ndy;
                    default: begin
                        if (nval && nd_c * 48'd10000 < {35'd0, nr2} * 48'd100020001 &&
                            (!nb_v || nd_c * nb_r2 < nb_d * nr2)) begin
                            nb_v <= 1'b1; nb_k <= nk; nb_d <= nd_c; nb_r2 <= nr2;
                        end
                        nph <= 3'd0;
                        if (nk == 6'd30) q <= Q_NEAR2; else nk <= nk + 6'd1;
                    end
                endcase
            end
            Q_NEAR2: begin
                q <= Q_END;
                near_v <= nb_v; near_k <= nb_k;
                if (near_act && nb_v) begin
                    near_act <= 1'b0;
                    if (nb_k <= 6'd2) begin mode_cu <= 1'b1; cur <= nb_k[1:0]; page <= 2'd0; cmsg <= S2_CMSG_NONE; end
                    else if (nb_k == 6'd3) begin                                // npc_interact()
                        if (!codes_v) open_talk(TK_INFO, 4'd2, 1'b0);
                        else if (rnd == 2'd3) open_talk(TK_INFO, 4'd1, 1'b1);
                        else open_talk(TK_ASK, 4'd2, 1'b0);
                    end else if (nb_k <= 6'd21) begin                            // pickup()
                        done_spots[nb_k - 6'd4] <= 1'b1;
                        found[it_part(nb_k - 6'd4)] <= found[it_part(nb_k - 6'd4)] + 3'd1;
                        zoom_on <= 1'b1; zt <= 7'd0;
                        zx <= it_ix(nb_k - 6'd4); zy <= it_iy(nb_k - 6'd4);
                        note_push(S2_NOTE_N1 + (nb_k - 6'd4));
                        if (parts_total == 5'd17) say(S2_TOAST_ALLFOUND, 8'd240);
                        else say(s2_toast_found(it_part(nb_k - 6'd4), found[it_part(nb_k - 6'd4)] + 3'd1), 8'd150);
                        // the item disappears: the prompt is recomputed next tick
                        nk <= 6'd0; nb_v <= 1'b0; nph <= 3'd0; q <= Q_NEAR;
                    end else begin                                               // open_hint()
                        read_hints[nb_k - 6'd22] <= 1'b1;
                        show_hint(hd(HD_TXT, {1'b0, nb_k - 6'd22}, {1'b0, nb_k - 6'd22}, 7'd0));
                        note_push(S2_NOTE_N19 + (nb_k - 6'd22));
                        nk <= 6'd0; nb_v <= 1'b0; nph <= 3'd0; q <= Q_NEAR;
                    end
                end
            end
            // ---- closeup_input()
            Q_CU: begin
                q <= Q_END;
                if (e_back) begin
                    if (wpick) begin w[5 * wcur +: 5] <= wprev; wpick <= 1'b0; end
                    else if (page != 2'd0 && cur != O_DOOR) page <= page - 2'd1;
                    else mode_cu <= 1'b0;
                    cmsg <= S2_CMSG_NONE;
                end else case (cur)
                    O_WB:   if (e_tap) page <= (page == 2'd2) ? 2'd0 : page + 2'd1;
                    O_DOOR: if (e_tap) begin
                                if (rnd == 2'd3) begin state <= ST_CLEAR; form <= 2'd2; end
                                else begin cmsg <= S2_CMSG_LOCK; cmsg_a <= {2'd0, rnd}; end
                            end
                    default: begin                                               // decoder bench
                        if (page == 2'd0) begin
                            if (e_tap) begin
                                if (parts_total != 5'd18) cmsg <= S2_CMSG_MISS;
                                else begin
                                    page <= 2'd1;
                                    if (!codes_v && rnd != 2'd3) begin           // new_round()
                                        note_push(S2_NOTE_N28);
                                        undo_v <= 1'b0;
                                        if (!pairs_v) begin                      // make_pairs()
                                            order[0] <= 3'd1; order[1] <= 3'd2; order[2] <= 3'd3;
                                            order[3] <= 3'd4; order[4] <= 3'd5; order[5] <= 3'd6;
                                            pi <= 3'd5; q <= Q_PAIRS;
                                        end else begin
                                            codes_v <= 1'b1; code0 <= pair[2 * rnd]; code1 <= pair[2 * rnd + 1];
                                        end
                                    end
                                end
                            end
                        end else if (rnd == 2'd3) ;
                        else if (wpick) begin                                    // source picker
                            if (e_u || e_d) begin
                                w[5 * wcur +: 5] <= e_u ? ((w[5 * wcur +: 5] == 5'd0) ? 5'd27 : w[5 * wcur +: 5] - 5'd1)
                                                        : ((w[5 * wcur +: 5] == 5'd27) ? 5'd0 : w[5 * wcur +: 5] + 5'd1);
                            end else if (e_tap) wpick <= 1'b0;
                        end
                        else if (e_l) wcur <= (wcur == 6'd0) ? 6'd54 : wcur - 6'd1;
                        else if (e_r) wcur <= (wcur == 6'd54) ? 6'd0 : wcur + 6'd1;
                        else if (e_u) wcur <= (wcur >= 6'd6) ? wcur - 6'd6 : wcur + 6'd49;
                        else if (e_d) wcur <= (wcur <= 6'd48) ? wcur + 6'd6 : wcur - 6'd49;
                        else if (e_tap) begin
                            undo_v <= 1'b1; undo_w <= w;                         // rec_undo()
                            if (wcur == CUR_CLEAR) w <= 270'd0;
                            else begin wprev <= w[5 * wcur +: 5]; wpick <= 1'b1; cmsg <= S2_CMSG_NONE; end
                        end
                    end
                endcase
            end
            // ---- make_pairs(): for i in 5..1: j = lfsr_pick(i+1); swap
            Q_PAIRS: begin
                if (pi == 3'd0) begin
                    pairs_v <= 1'b1; codes_v <= 1'b1;
                    for (ii = 0; ii < 6; ii = ii + 1) pair[ii] <= order[ii];
                    code0 <= order[2 * rnd]; code1 <= order[2 * rnd + 1];
                    q <= Q_END;
                end else begin
                    pick_n <= {1'b0, pi} + 4'd1; pick_why <= 4'd1; q <= Q_PICK;
                end
            end
            // ---- evaluation jobs: ev_job 0 = 7 segments + 27 sources at the switch code (display),
            //                       ev_job 1 = 7 segments at code0 and code1 (judge, hints)
            Q_EVAL: begin
                cv_node <= (ev_job == 1'b0 && ev_i >= 6'd7) ? ev_i[4:0] - 5'd6 : ws(w, SK_D0 + ev_i[2:0]);
                cv_c <= lv(ev_code[2], ws(w, SK_PDC)); cv_b <= lv(ev_code[1], ws(w, SK_PDB));
                cv_a <= lv(ev_code[0], ws(w, SK_PDA));
                cv_start <= 1'b1; q <= Q_EVALW;
            end
            Q_EVALW: if (cv_done) begin
                if (ev_job == 1'b0) begin
                    if (ev_i < 6'd7) segs_now[ev_i[2:0]] <= cv_val && ws(w, SK_SEGCOM) == 6'd2;
                    else src_val[ev_i - 6'd6] <= cv_val;
                    if (ev_i == 6'd33) q <= Q_IDLE; else begin ev_i <= ev_i + 6'd1; q <= Q_EVAL; end
                end else begin
                    if (ev_i[3]) ev_seg1[ev_i[2:0]] <= cv_val && ws(w, SK_SEGCOM) == 6'd2;
                    else ev_seg0[ev_i[2:0]] <= cv_val && ws(w, SK_SEGCOM) == 6'd2;
                    if (ev_i == 6'd14) q <= q_ret;
                    else begin ev_i <= (ev_i == 6'd6) ? 6'd8 : ev_i + 6'd1; q <= Q_EVAL; end
                end
            end
            // ---- judge(): verdict lines, then the result is applied in talk_done()
            Q_JUDGE: begin
                vd_ok <= {ev_seg1 == gold_segs(code1), ev_seg0 == gold_segs(code0)};
                vd_pass <= (ev_seg0 == gold_segs(code0)) && (ev_seg1 == gold_segs(code1));
                vd_armor <= (armor != 2'd0);
                note_push(S2_NOTE_N30 + 3 * rnd + (ev_seg0 == gold_segs(code0)) + (ev_seg1 == gold_segs(code1)));
                open_talk(TK_VERD, 4'd4, 1'b0);
                q <= Q_END;
            end
            // ---- wiring_hint(exact): first segment that is wrong on a QA input
            Q_HINT: begin hseg <= 3'd0; q <= Q_HINT2; end
            Q_HINT2: begin
                if (hseg == 3'd7) begin show_hint(hd(HD_TXT, 7'd28, 7'd9, 7'd0)); q <= Q_END; end
                else if (ev_seg0[hseg] == g0[hseg] && ev_seg1[hseg] == g1[hseg])
                    hseg <= hseg + 3'd1;
                else if (!hint_exact) begin
                    show_hint(hd(HD_SEG, {4'd0, hseg}, {5'd0, g1[hseg], g0[hseg]}, {1'b0, code1, code0}));
                    q <= Q_END;
                end else begin                                                 // first REF wire that differs
                    href <= 6'd0; q <= Q_SMART; pick_why <= 4'd15;
                end
            end
            Q_SMART: begin
                if (pick_why == 4'd15) begin                                    // scan REF
                    if (href == 6'd53) begin hseg <= hseg + 3'd1; q <= Q_HINT2; end
                    else if (ws(w, ref_order(href)) != {1'b0, ref_src(ref_order(href))}) begin
                        show_hint(hd(HD_WIRE, {1'b0, ref_order(href)}, {2'd0, ref_src(ref_order(href))}, 7'd0));
                        q <= Q_END;
                    end else href <= href + 6'd1;
                end else begin                                                  // clue of a missing part
                    use_hs <= 1'b1;
                    show_hint(hd(HD_TXT, 7'd9 + kth_missing({2'd0, pick_v} % n_missing), 7'd9, 7'd0));
                    q <= Q_END;
                end
            end
            // ---- demo hub (state injection, also used by the testbenches)
            Q_DEMO: begin
                q <= Q_IDLE;
                case (dm_op)
                    4'd7:  begin inv_add_armor <= 1'b1; end
                    4'd8:  begin hs_set <= 1'b1; hs_setv <= dm_arg[1:0]; if (state == ST_OVER) state <= ST_PLAY; end
                    4'd9:  form <= dm_arg[1:0];
                    4'd10: debug <= !debug;
                    4'd11: begin                                                 // all parts (F7)
                        for (ii = 0; ii < 9; ii = ii + 1) found[ii] <= part_qty(ii);
                        done_spots <= 18'h3FFFF;
                    end
                    4'd12: begin reset_stage(1'b1); show_help <= 1'b0; end
                    4'd13: begin lf_load <= 1'b1; lf_seed <= dm_arg; end
                    4'd14: show_help <= 1'b0;
                    4'd15: begin                                                 // auto-wire (F8): REF build
                        for (ii = 0; ii < 54; ii = ii + 1) w[5 * ii +: 5] <= ref_src(ii);
                    end
                    4'd6:  play_t <= SKILL_WAIT;                                 // skill ready (F9)
                    default: ;
                endcase
            end
            // ---- end of the tick: sprite.stop() unless map_update ran; refresh evaluations
            Q_END: begin
                if (!walking) an_stop <= 1'b1;
                ev_job <= 1'b0; ev_i <= 6'd0; q <= Q_EVAL;
            end
            default: q <= Q_IDLE;
            endcase


            // ---- events from the shared modules
            if (dk_rdone) r_done[dk_rnd] <= 1'b1;
            if (hs_blocked) say(S2_TOAST_ARMOR, 8'd150);
            if (hs_hit) begin flash <= FLASH_FRAMES; if (!hs_dead) say(S2_TOAST_QAFAIL, 8'd150); end
            if (hs_dead) begin state <= ST_OVER; over_t <= OVER_FRAMES; end
        end
    end


    // ================================================================ zoom window + Boss position
    wire [9:0]  zf_t   = zoom_f(zt);
    wire [16:0] zi_t   = zoom_inv_lut(zt);
    wire [26:0] zw_m   = 27'd640 * zi_t;                  // window width  = 640 / f
    wire [26:0] zh_m   = 27'd360 * zi_t;
    wire [9:0]  zw     = zw_m[25:16], zh = zh_m[25:16];
    wire [10:0] zxg    = (zx * 11'd2) / 3, zyg = (zy * 11'd2) / 3;
    wire signed [12:0] zox_c = $signed({2'b0, zxg}) - $signed({4'b0, zw[9:1]});
    wire signed [12:0] zoy_c = $signed({2'b0, zyg}) - $signed({4'b0, zh[9:1]});
    always @(posedge clk) begin
        zoom_inv <= (zoom_on && !mode_cu) ? zi_t : 17'd65536;
        zoom_ox  <= (!zoom_on || mode_cu) ? 12'd0 : (zox_c < 0) ? 12'd0 :
                    (zox_c > $signed({3'b0, 10'd640 - zw})) ? {2'b0, 10'd640 - zw} : zox_c[11:0];
        zoom_oy  <= (!zoom_on || mode_cu) ? 12'd0 : (zoy_c < 0) ? 12'd0 :
                    (zoy_c > $signed({3'b0, 10'd360 - zh})) ? {2'b0, 10'd360 - zh} : zoy_c[11:0];
    end
    wire [15:0] npc_x64 = npc_q[31:16], npc_y64 = npc_q[15:0];
    wire [15:0] npc_xu  = (npc == NPC_OFF) ? 16'd0 : npc_x64 >> 6;              // UI px
    wire [15:0] npc_yu  = npc_y64 >> 6;
    // ui coordinates -> game area (x 2/3)
    function [11:0] g23(input [11:0] v); g23 = (v * 12'd2) / 3; endfunction

    // hide_legs(): lanes behind the partitions (ROW_LANES) - the room picture covers the legs
    reg        legs; reg [11:0] lx0, lx1, ly0, ly1;
    always @(*) begin
        legs = 1'b0; lx0 = 0; lx1 = 0; ly0 = 0; ly1 = 0;
        if (px_i + 10'd12 >= 10'd322 && px_i <= 10'd648 && py_i + 10'd24 >= 10'd198 && py_i <= 10'd199) begin
            legs = 1'b1; lx0 = (px_i < 10'd346) ? 12'd322 : px_i - 12'd24; lx1 = (px_i + 10'd24 > 10'd636) ? 12'd636 : px_i + 12'd24;
            ly0 = 12'd186; ly1 = py_i + 12'd8;
        end else if (px_i + 10'd12 >= 10'd284 && px_i <= 10'd668 && py_i + 10'd24 >= 10'd288 && py_i <= 10'd289) begin
            legs = 1'b1; lx0 = (px_i < 10'd308) ? 12'd284 : px_i - 12'd24; lx1 = (px_i + 10'd24 > 10'd656) ? 12'd656 : px_i + 12'd24;
            ly0 = 12'd270; ly1 = py_i + 12'd8;
        end else if (px_i + 10'd12 >= 10'd272 && px_i <= 10'd702 && py_i + 10'd24 >= 10'd412 && py_i <= 10'd413) begin
            legs = 1'b1; lx0 = (px_i < 10'd296) ? 12'd272 : px_i - 12'd24; lx1 = (px_i + 10'd24 > 10'd690) ? 12'd690 : px_i + 12'd24;
            ly0 = 12'd413; ly1 = py_i + 12'd8;
        end
    end

    // ================================================================ UI contract (registered)
    reg [3071:0] F; reg [255:0] C;
    reg [3071:0] F_r; reg [255:0] C_r;
    always @(posedge clk) begin F_r <= F; C_r <= C; end
    assign fields = F_r;
    assign conds  = C_r;
    function [5:0] cimg(input [1:0] r, input [1:0] pos, input [1:0] idx, input fu, input [1:0] fc, input [1:0] car);
        cimg = (r == 2'd1) ? ((fu && fc == pos) ? 6'd51 + idx : 6'd48 + idx) : 6'd54 + car * 3 + pos;
    endfunction
    function [1:0] pidx(input [2:0] pm, input [1:0] p);
        reg [5:0] t;
        begin
            case (pm)
                3'd0: t = {2'd2, 2'd1, 2'd0}; 3'd1: t = {2'd1, 2'd2, 2'd0}; 3'd2: t = {2'd2, 2'd0, 2'd1};
                3'd3: t = {2'd0, 2'd2, 2'd1}; 3'd4: t = {2'd1, 2'd0, 2'd2}; default: t = {2'd0, 2'd1, 2'd2};
            endcase
            pidx = (p == 2'd0) ? t[1:0] : (p == 2'd1) ? t[3:2] : t[5:4];
        end
    endfunction
    function [23:0] secs_ceil(input [12:0] t); secs_ceil = (t + 13'd59) / 60; endfunction
    wire [12:0] wait_left = (play_t >= SKILL_WAIT) ? 13'd0 : (SKILL_WAIT - play_t + 13'd59) / 60;   // seconds
    wire        in_board  = mode_cu && cur == O_BENCH && page == 2'd1;
    wire [5:0]  wsrc_now  = (wcur == CUR_CLEAR) ? 6'd0 : ws(w, wcur);
    wire [6:0]  wcount    = count_w(w);
    function [6:0] count_w(input [269:0] ww);
        integer i; begin count_w = 7'd0; for (i = 0; i < 54; i = i + 1) if (ww[5 * i +: 5] != 5'd0) count_w = count_w + 7'd1; end
    endfunction
    integer n;
    always @(*) begin
        F = 3072'd0;
        F[24*F2_HEARTS +: 24] = hearts;  F[24*F2_ARMOR +: 24] = armor;
        F[24*F2_SLOW_S +: 24] = (slow_f + 10'd29) / 60;           // '%.0f' of the seconds left
        F[24*F2_PSX +: 24]    = g23({2'b0, px_i});  F[24*F2_PSY +: 24] = g23({2'b0, py_i});
        F[24*F2_PFRAME +: 24] = form * 12 + sdir * 3 + spose;
        F[24*F2_FLASH_A +: 24]= (flash * 15) >> 5;
        F[24*F2_TOAST +: 24]  = toast;  F[24*F2_TOAST_A +: 24] = toast_a;
        F[24*F2_CMSG +: 24]   = cmsg;   F[24*F2_CMSG_A +: 24] = cmsg_a;
        F[24*F2_OBJ +: 24]    = cur;    F[24*F2_PAGE +: 24] = page;
        F[24*F2_CARD_ROUND +: 24] = dk_rnd;
        F[24*F2_CIMG0 +: 24]  = cimg(dk_rnd, 2'd0, pidx(dk_pm, 2'd0), dk_face_up, dk_face, career);
        F[24*F2_CIMG1 +: 24]  = cimg(dk_rnd, 2'd1, pidx(dk_pm, 2'd1), dk_face_up, dk_face, career);
        F[24*F2_CIMG2 +: 24]  = cimg(dk_rnd, 2'd2, pidx(dk_pm, 2'd2), dk_face_up, dk_face, career);
        F[24*F2_CNAME +: 24]  = dk_item; F[24*F2_CDESC +: 24] = dk_item; F[24*F2_FORM +: 24] = form;
        for (n = 0; n < 8; n = n + 1) F[24*(F2_NOTE0 + n) +: 24] = note[n];
        F[24*F2_HN0_T +: 24] = hn0[23:21]; F[24*F2_HN0_A +: 24] = hn0[20:14]; F[24*F2_HN0_B +: 24] = hn0[13:7];
        F[24*F2_HN0_C +: 24] = hn0[6:0];
        F[24*F2_HN1_T +: 24] = hn1[23:21]; F[24*F2_HN1_A +: 24] = hn1[20:14]; F[24*F2_HN1_B +: 24] = hn1[13:7];
        F[24*F2_HN1_C +: 24] = hn1[6:0];
        F[24*F2_HP_T +: 24] = hp[23:21]; F[24*F2_HP_A +: 24] = hp[20:14]; F[24*F2_HP_B +: 24] = hp[13:7];
        F[24*F2_HP_C +: 24] = hp[6:0];
        for (n = 0; n < 9; n = n + 1) F[24*(F2_PCOUNT0 + n) +: 24] = found[n];
        F[24*F2_PTOTAL +: 24] = parts_total; F[24*F2_QA_RND +: 24] = rnd;
        F[24*F2_QA_K0 +: 24] = code0; F[24*F2_QA_K1 +: 24] = code1;
        for (n = 0; n < 6; n = n + 1) F[24*(F2_QA_P0 + n) +: 24] = pair[n];
        F[24*F2_NPC_X +: 24] = g23(npc_xu[11:0]);
        F[24*F2_NPC_Y +: 24] = g23(npc_yu[11:0]) + ((npc_q[32] && (npc == NPC_TOP || npc == NPC_TOS) && tickc[3]) ? 24'd1 : 24'd0);
        // talk line: static text index or a dynamic line (TL_A/B/C)
        F[24*F2_TLINE +: 24] = (talk_k == TK_INTRO) ? S2_TALK_I0 + talk_i :
                               (talk_k == TK_INFO) ? (talk_var ? S2_TALK_VERIF : S2_TALK_NB1 + talk_i) :
                               (talk_k == TK_ASK) ? S2_TALK_ASK1 :
                               (talk_i == 4'd0) ? S2_TALK_V0 :
                               (talk_i == 4'd3) ? (!vd_pass ? (vd_armor ? S2_TALK_FAILA : S2_TALK_FAIL) : S2_TALK_PASSF) : 8'd0;
        F[24*F2_TL_A +: 24] = (talk_k == TK_ASK) ? rnd + 1 : (talk_i == 4'd1) ? code0 : (talk_i == 4'd2) ? code1 : rnd + 1;
        F[24*F2_TL_B +: 24] = (talk_i == 4'd1) ? code0 : (talk_i == 4'd2) ? code1 : code0;
        F[24*F2_TL_C +: 24] = (talk_i == 4'd3) ? code1 : 2 - rnd;
        F[24*F2_SKILL_S +: 24] = secs_ceil(skill_t);
        F[24*F2_SKILL_M +: 24] = wait_left / 60; F[24*F2_SKILL_SS +: 24] = wait_left % 60;
        F[24*F2_INV_HH +: 24] = n_hh; F[24*F2_INV_HS +: 24] = n_hs; F[24*F2_INV_UN +: 24] = n_un;
        F[24*F2_INV_FR +: 24] = n_fr; F[24*F2_SHARDS +: 24] = shard;
        F[24*F2_ZF +: 24] = (zoom_on && !mode_cu) ? zf_t : 10'd0;
        F[24*F2_ZO +: 24] = {zoom_oy, zoom_ox}; F[24*F2_ZINV +: 24] = zoom_inv;
        F[24*F2_GLOW_R +: 24] = glow_r(tickc % 54);
        F[24*F2_LEG_X0 +: 24] = g23(lx0); F[24*F2_LEG_X1 +: 24] = g23(lx1);
        F[24*F2_LEG_Y0 +: 24] = g23(ly0); F[24*F2_LEG_Y1 +: 24] = g23(ly1);
        F[24*F2_PROMPT +: 24] = (near_k == 6'd3) ? 3 : near_k;
        F[24*F2_WCUR +: 24] = wcur;
        F[24*F2_WCUR_X +: 24] = (wcur == CUR_CLEAR) ? 0 : sink_x(wcur);
        F[24*F2_WCUR_Y +: 24] = (wcur == CUR_CLEAR) ? 0 : sink_y(wcur);
        F[24*F2_WSRC +: 24] = wsrc_now; F[24*F2_WCNT +: 24] = wcount;
        F[24*F2_CODE3 +: 24] = code3; F[24*F2_CODE_C +: 24] = code3;
        F[24*F2_PD_N +: 24] = (ws(w, SK_PDC) == 6'd2) + (ws(w, SK_PDB) == 6'd2) + (ws(w, SK_PDA) == 6'd2);
        F[24*F2_MISSN +: 24] = 0;

        C = 256'd0;
        C[0] = 1'b1;
        C[C2_HELP] = show_help; C[C2_PLAY] = state == ST_PLAY; C[C2_OVER] = state == ST_OVER;
        C[C2_CLEAR] = state == ST_CLEAR; C[C2_MAP] = !mode_cu; C[C2_CLOSEUP] = mode_cu; C[C2_DECK] = dk_active;
        C[C2_NOTEBOOK] = sw[14]; C[C2_INV] = sw[15]; C[C2_HINTP] = hp_on; C[C2_TALK] = talk_on;
        C[C2_TALK_ASKLAST] = talk_k == TK_ASK && talk_i == talk_n - 4'd1;
        C[C2_CU_WB] = mode_cu && cur == O_WB; C[C2_CU_DOOR] = mode_cu && cur == O_DOOR;
        C[C2_CU_BENCH] = mode_cu && cur == O_BENCH && page == 2'd0; C[C2_BOARD] = in_board;
        C[C2_PAGE0] = page == 2'd0; C[C2_PAGE1] = page == 2'd1; C[C2_PAGE2] = page == 2'd2;
        C[C2_HEART1] = hearts > 2'd0; C[C2_HEART2] = hearts > 2'd1; C[C2_HEART3] = hearts > 2'd2;
        C[C2_ARMOR_ON] = armor != 2'd0; C[C2_SLOW_ON] = slow; C[C2_FLASH_ON] = flash != 8'd0;
        C[C2_TOAST_ON] = toast_t != 8'd0; C[C2_TOAST_RECH] = toast == S2_TOAST_SK_RECH;
        C[C2_CMSG_ON] = cmsg != S2_CMSG_NONE; C[C2_CMSG_LOCK] = cmsg == S2_CMSG_LOCK; C[C2_CMSG_MISS] = cmsg == S2_CMSG_MISS;
        C[C2_CARD_FACEUP] = dk_face_up; C[C2_CARD_R1] = dk_rnd == 2'd1;
        C[C2_CF0] = dk_face_up && dk_face == 2'd0; C[C2_CF1] = dk_face_up && dk_face == 2'd1;
        C[C2_CF2] = dk_face_up && dk_face == 2'd2;
        C[C2_CARD_C0] = !dk_face_up && dk_cursor == 2'd0; C[C2_CARD_C1] = !dk_face_up && dk_cursor == 2'd1;
        C[C2_CARD_C2] = !dk_face_up && dk_cursor == 2'd2;
        C[C2_CAREER_V] = dk_cvalid; C[C2_BOOST] = boost;
        for (n = 0; n < 8; n = n + 1) C[C2_NOTE_V0 + n] = (n < note_n);
        C[C2_HN0_V] = hn0[23:21] != 3'd0; C[C2_HN0_SEG] = hn0[23:21] == HD_SEG; C[C2_HN0_WIRE] = hn0[23:21] == HD_WIRE;
        C[C2_HN0_TXT] = hn0[23:21] == HD_TXT;
        C[C2_HN1_V] = hn1[23:21] != 3'd0; C[C2_HN1_SEG] = hn1[23:21] == HD_SEG; C[C2_HN1_WIRE] = hn1[23:21] == HD_WIRE;
        C[C2_HN1_TXT] = hn1[23:21] == HD_TXT;
        C[C2_HP_SEG] = hp[23:21] == HD_SEG; C[C2_HP_WIRE] = hp[23:21] == HD_WIRE; C[C2_HP_TXT] = hp[23:21] == HD_TXT;
        C[C2_NPC_ON] = npc != NPC_OFF; C[C2_NPC_BEHIND] = npc_yu[11:0] <= {2'b0, py_i}; C[C2_NPC_SIT] = npc == NPC_SIT;
        C[C2_SKILLBTN] = intro_started && !mode_cu; C[C2_SKILL_ON] = skill_t != 13'd0; C[C2_SKILL_USED] = skill_used;
        C[C2_SKILL_READY] = play_t >= SKILL_WAIT && !skill_used && skill_t == 13'd0;
        C[C2_BLINK] = tickc[4]; C[C2_ZOOM] = zoom_on && !mode_cu; C[C2_GLOW] = skill_t != 13'd0;
        C[C2_LEGS] = legs && !mode_cu;
        C[C2_PROMPT_ON] = near_v && near_k <= 6'd3 && !talk_on && !cutscene && !mode_cu;
        C[C2_DONE] = rnd == 2'd3; C[C2_CODES] = codes_v;
        C[C2_TL_STATIC] = !(talk_k == TK_ASK && talk_i == 4'd1) && !(talk_k == TK_VERD && (talk_i == 4'd1 || talk_i == 4'd2))
                          && !(talk_k == TK_VERD && talk_i == 4'd3 && vd_pass && rnd != 2'd2);
        C[C2_TL_VIN] = talk_k == TK_VERD && (talk_i == 4'd1 || talk_i == 4'd2);
        C[C2_TL_VOK] = (talk_i == 4'd1) ? vd_ok[0] : vd_ok[1];
        C[C2_TL_PASSMID] = talk_k == TK_VERD && talk_i == 4'd3 && vd_pass && rnd != 2'd2;
        C[C2_TL_ASK2] = talk_k == TK_ASK && talk_i == 4'd1;
        for (n = 0; n < 18; n = n + 1) C[C2_FOUND0 + n] = done_spots[n];
        for (n = 0; n < 9; n = n + 1) C[C2_PARTOK0 + n] = found[n] >= part_qty(n);
        for (n = 0; n < 3; n = n + 1) C[C2_QAPASS0 + n] = rnd > n;
        C[C2_WCLEAR] = wcur == CUR_CLEAR && rnd != 2'd3; C[C2_WPICK] = wpick;
        C[C2_WCURSOR] = wcur != CUR_CLEAR && rnd != 2'd3;
        C[C2_DSW0] = sw[0]; C[C2_DSW1] = sw[1]; C[C2_DSW2] = sw[2];
        C[C2_DIPOK] = dip_vcc; C[C2_COMOK] = ws(w, SK_SEGCOM) == 6'd2;
        C[C2_CODEVALID] = code3 != 3'd0 && code3 != 3'd7;
        for (n = 0; n < 7; n = n + 1) begin
            C[C2_SEG0 + n] = segs_now[n];
            C[C2_T0S0 + n] = gold_segs(code0) >> n;
            C[C2_T1S0 + n] = gold_segs(code1) >> n;
        end
        C[C2_PWR0] = ws(w, SK_U1_VCC) == 6'd1 && ws(w, SK_U1_GND) == 6'd2;
        C[C2_PWR1] = ws(w, SK_U2_VCC) == 6'd1 && ws(w, SK_U2_GND) == 6'd2;
        C[C2_PWR2] = ws(w, SK_U3_VCC) == 6'd1 && ws(w, SK_U3_GND) == 6'd2;
        C[C2_PWR3] = ws(w, SK_U4_VCC) == 6'd1 && ws(w, SK_U4_GND) == 6'd2;
        for (n = 0; n < 9; n = n + 1) begin
            C[C2_MISS0 + n] = found[n] < part_qty(n);
            C[C2_MSEP0 + n] = (found[n] < part_qty(n)) && first_miss != n;
        end
        for (n = 0; n < 4; n = n + 1) C[C2_INVC0 + n] = inv_cur == n;
        C[C2_ALL18] = parts_total == 5'd18;
    end

    assign bg_mode  = (state == ST_CLEAR || (mode_cu && !in_board)) ? 3'd0 : in_board ? 3'd4 : 3'd2;
    assign bg_color = (state == ST_CLEAR) ? 12'h021 : 12'h112;
    assign wire_src = w;
    assign wire_hl  = {wpick && in_board, wcur};

    // ================================================================ board outputs (draw_panel)
    assign leds = {rnd > 2'd2, rnd > 2'd1, rnd > 2'd0,
                   found[8] >= part_qty(8), found[7] >= part_qty(7), found[6] >= part_qty(6), found[5] >= part_qty(5),
                   found[4] >= part_qty(4), found[3] >= part_qty(3), found[2] >= part_qty(2), found[1] >= part_qty(1),
                   found[0] >= part_qty(0), armor != 2'd0, hearts > 2'd2, hearts > 2'd1, hearts > 2'd0};
    assign rgb16 = !dk_cvalid ? 3'b000 : (career == 2'd0) ? 3'b010 : (career == 2'd1) ? 3'b110 : 3'b100;
    assign rgb17 = (flash != 8'd0) ? 3'b100 : (state == ST_OVER) ? 3'b100 : (state == ST_CLEAR) ? 3'b010 :
                   slow ? 3'b110 : (armor != 2'd0) ? 3'b001 : 3'b000;
    // 7-seg: "H3" + at the bench "C B A" + the live decoder output (raw segments) in the last digit
    wire live = in_board && codes_v && !dk_active;
    always @(*) begin
        if (state == ST_CLEAR) seg_chars = {SG_H, 3'b0, hearts, SG_BLANK, SG_BLANK, SG_P, SG_A, 5'd5, 5'd5};
        else if (state == ST_OVER) seg_chars = {SG_H, 5'd0, SG_BLANK, SG_BLANK, SG_D, SG_E, SG_A, SG_D};
        else if (live) seg_chars = {SG_H, 3'b0, hearts, SG_BLANK, SG_BLANK, 4'd0, code3[2], 4'd0, code3[1], 4'd0, code3[0], SG_BLANK};
        else seg_chars = {SG_H, 3'b0, hearts, {6{SG_BLANK}}};
    end
    assign seg_raw_en = {live, 7'd0};                     // digit 7 = rightmost
    assign seg_raw    = {segs_now, 49'd0};

    assign out_armor = armor; assign out_shard = shard; assign out_boost = boost; assign out_form = form;
endmodule
