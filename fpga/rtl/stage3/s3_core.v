// s3_core.v - STAGE 3 "Graduation obby" (demo_py/stage3_demo.py): complete game logic + display fields.
//
// Bit-exact with fpga/tools/s3_model.py (cosim_s3.py checks every tick). The model is checked against the
// original float Pygame code with the same inputs (positions within 2 mm, same states / hits / skill).
// Number format (see s3_model.py / docs/ARCHITECTURE.md section 8):
//   1 m = Q = 120*65536 units -> every horizontal speed is a whole number of units per 1/120 s step;
//   vertical speeds are stored per step; timers count steps (start values = when the float timer flips).
// The sequencer runs the demo's functions in the demo's order, one solid / animal per clock:
//   frame(): events -> do_jump() / skill() -> 2 x step()   or the dead-screen counter
//   step():  timers -> step_p() (x, solids in x, y, solids in y) -> upd_a() x 23 -> hit test -> upd_rep()
// After every tick the "publish" states compute the screen fields (positions at 32 px per metre, visible
// animal slots, HUD numbers) that tools/ui_screens_s3.py draws.
// Board: BTNL/BTNR run, BTNU or BTNC jump, BTNC starts / restarts (= Enter/Space), BTND skill (= E).
`timescale 1ns/1ps
module s3_core (
    input  wire          clk,
    input  wire          rst,
    input  wire          gtick,
    input  wire          ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back,
    input  wire [4:0]    lvl,
    input  wire          enter,           // stage entry -> menu screen (Game(): reset(), 'menu')
    output wire          exit_req,        // last stage: never leaves (win -> BTNC plays again, like the demo)
    input  wire          demo_cmd,
    input  wire [3:0]    demo_op,
    input  wire [15:0]   demo_arg,
    output wire [3071:0] fields,
    output wire [255:0]  conds,
    output wire [2:0]    bg_mode,
    output reg  [12:0]   cam_px,          // renderer: terrain camera (world px)
    output reg  [7:0]    wave_ph,         // renderer: water phase
    output reg  [15:0]   hill_ph,         // renderer: hills phase
    output reg  [39:0]   seg_chars,
    output wire [15:0]   leds,
    output wire [2:0]    rgb16, rgb17
);
`include "game_defs.vh"
`include "ui_map.vh"
`include "s3_consts.vh"
    localparam [2:0] ST_MENU = 3'd0, ST_PLAY = 3'd1, ST_DEAD = 3'd2, ST_WIN = 3'd3, ST_LOSE = 3'd4;
    localparam integer NA = 23;
    assign exit_req = 1'b0;
    assign bg_mode  = 3'd3;

    // ---------------------------------------------------------------- helpers (= s3_model.py)
    function hitf(input signed [35:0] ax, ay, aw, ah, bx, by, bw, bh);       // hit(), e = 1e-4 m
        hitf = (ax < bx + bw - EPS) && (ax + aw > bx + EPS) && (ay < by + bh - EPS) && (ay + ah > by + EPS);
    endfunction
    function signed [35:0] div24(input signed [35:0] v);
        reg signed [63:0] p; begin p = v * 64'sd11184811; div24 = p >>> 28; end
    endfunction
    function signed [35:0] div10(input signed [35:0] v);
        reg signed [63:0] p; begin p = v * 64'sd26843546; div10 = p >>> 28; end
    endfunction
    function signed [35:0] div120(input signed [35:0] v);
        reg signed [63:0] p; begin p = v * 64'sd2236963; div120 = p >>> 28; end
    endfunction
    function signed [15:0] scr(input signed [35:0] x);                        // metres -> px (32 / m)
        reg signed [39:0] p; begin p = (x >>> 15) * 40'sd8738; scr = p >>> 16; end
    endfunction
    function signed [35:0] plant_r(input [9:0] u);
        if (u < 10'd96)       plant_r = u * 36'sd163840;
        else if (u < 10'd336) plant_r = M2;
        else if (u < 10'd432) plant_r = M2 - (u - 10'd336) * 36'sd163840;
        else                  plant_r = 36'sd0;
    endfunction
    function [7:0] phase14(input [15:0] t);                                    // sin(t * 14 / 120 s)
        reg [39:0] p; begin p = t * 40'd311519; phase14 = p[23:16]; end
    endfunction
    function signed [7:0] swing(input signed [7:0] s);                         // sin * .16 m in px
        reg signed [15:0] p; begin p = s * 16'sd41 + 16'sd512; swing = p >>> 10; end
    endfunction

    // ---------------------------------------------------------------- game state
    reg  [2:0]  st;
    reg  signed [35:0] px, py, vy, g, ly, cam, rx, ry;
    reg  signed [15:0] coy;
    reg  signed [21:0] hc;
    reg  [15:0] gt, run;
    reg  [9:0]  talk; reg [7:0] msg_u; reg [1:0] msg; reg [6:0] dd;
    reg  [1:0]  jumps; reg pf;                                 // pf: facing right (f = +1)
    reg  [2:0]  hits; reg used; reg rep_on, rep_out;
    reg         a_on [0:NA-1], a_dead [0:NA-1], a_fall [0:NA-1], a_dir [0:NA-1];   // a_dir 1 = +1
    reg  signed [35:0] a_x [0:NA-1], a_cy [0:NA-1], a_r [0:NA-1], a_vy [0:NA-1];
    reg  [9:0]  a_ph [0:NA-1];

    // ---------------------------------------------------------------- publish: slots
    localparam integer N_AS = 6, N_FS = 2, N_PS = 3;
    reg  [2:0]  na; reg [1:0] nf, npl; reg pub_hud;
    reg  signed [15:0] as_x [0:N_AS-1], as_y [0:N_AS-1], as_yw [0:N_AS-1];
    reg  [2:0]  as_t [0:N_AS-1]; reg as_v [0:N_AS-1], as_f [0:N_AS-1];
    reg  signed [15:0] fa_x [0:N_FS-1], fa_y [0:N_FS-1]; reg fa_v [0:N_FS-1], fa_t2 [0:N_FS-1], fa_f [0:N_FS-1];
    reg  signed [15:0] pl_x [0:N_PS-1], pl_y [0:N_PS-1]; reg pl_v [0:N_PS-1], pl_o [0:N_PS-1];
    wire signed [7:0]  sg = sin8(phase14(gt));
    wire signed [35:0] wv = sg * 36'sd15481;                         // flyer wing: sin(gt*14) * .25 m
    integer n, m;
    // ---------------------------------------------------------------- sequencer
    localparam [5:0] R_IDLE = 6'd0, R_EV = 6'd1, R_SQRT = 6'd2, R_FRAME = 6'd3, R_STEP = 6'd4, R_TALK2 = 6'd5,
               R_PX = 6'd6, R_XL = 6'd7, R_VY = 6'd8, R_YL = 6'd9, R_GR = 6'd10, R_AN = 6'd11, R_AN3 = 6'd12,
               R_AN4 = 6'd13, R_ANX = 6'd14, R_CO = 6'd15, R_REP = 6'd16, R_REP2 = 6'd17, R_END = 6'd18,
               R_NEXT = 6'd19, R_SURF = 6'd20, R_RESET = 6'd21, R_RES2 = 6'd22, R_RES3 = 6'd23, R_RES4 = 6'd24,
               R_DEMO = 6'd25, R_SQ2 = 6'd26, R_P0 = 6'd27, R_P1 = 6'd28, R_P2 = 6'd29, R_P3 = 6'd30,
               R_PA = 6'd31, R_PEND = 6'd32, R_MENU = 6'd33, R_TALK = 6'd34;
    reg  [5:0]  q, sret, rret, xret;
    reg         e_u, e_d, e_tap, k_l, k_r;
    reg         step_n;                         // which of the 2 physics steps
    reg  [7:0]  i, ii;                          // loop indices (animals / solids)
    reg  signed [35:0] sx, sy, sb; reg sb_v;    // surf() arguments / result
    reg  [59:0] sq_v, sq_r, sq_b; reg sq_ph;    // integer square root
    reg         dm_pend; reg [3:0] dm_op; reg [15:0] dm_arg; reg tele; reg [7:0] tele_m;

    // solid ii (shared by every solid loop), animal i
    wire signed [35:0] s_x = so_x(ii), s_y = so_y(ii), s_w = so_w(ii), s_h = so_h(ii), s_t = so_top(ii);
    wire               s_wl = so_wall(ii);
    wire [2:0]         a_t = an_t(i);
    wire signed [35:0] a_x0 = an_x(i), a_y0 = an_y(i);
    // hit box of animal i (step(): plant / walker / flyer)
    wire signed [35:0] bx = (a_t == 3'd3) ? a_x[i] + M015 : a_x[i] + M01;
    wire signed [35:0] by = (a_t == 3'd3) ? a_cy[i] : a_cy[i] + M005;
    wire signed [35:0] bw = (a_t == 3'd3) ? M07 : M08;
    wire signed [35:0] bh = (a_t == 3'd3) ? Q : (a_t == 3'd4) ? M07 : M09;
    wire signed [35:0] wx = a_x[i] + (a_dir[i] ? 36'sd2 * STEP : -36'sd2 * STEP);     // walker step
    wire signed [35:0] dj = ((jumps == 2'd0) ? py : ly) + M45 - py;                     // double jump height
    wire [9:0]         ph1 = (a_ph[i] == 10'd599) ? 10'd0 : a_ph[i] + 10'd1;
    wire signed [35:0] fvy0 = a_vy[i] - GA;
    wire signed [35:0] fvy = (a_cy[i] < M2 && fvy0 < -VA) ? -VA : fvy0;
    wire signed [35:0] rx_in = rx + div24(px - ((talk != 10'd0) ? M14 : M24) - rx);
    wire signed [15:0] ax_c  = scr(a_x[i] + M05) - $signed({3'd0, cam_px});
    wire signed [15:0] ay_c  = 16'sd360 - scr(a_cy[i]);
    wire signed [15:0] ayw_c = 16'sd360 - scr(a_cy[i] + wv);

    always @(posedge clk) begin
        if (demo_cmd) begin dm_pend <= 1'b1; dm_op <= demo_op; dm_arg <= demo_arg; end
        if (rst || enter) begin
            q <= R_RESET; xret <= R_MENU; tele <= 1'b0; if (rst) dm_pend <= 1'b0;
        end else case (q)
        R_IDLE: begin
            if (gtick) begin
                {e_u, e_d, e_tap} <= {ev_u, ev_d, ev_tap}; k_l <= lvl[2]; k_r <= lvl[3]; q <= R_EV;
            end else if (dm_pend) begin dm_pend <= 1'b0; q <= R_DEMO; end
        end
        // ---- frame(): start / do_jump(), skill(), then 2 steps or the dead counter
        R_EV: begin
            q <= R_FRAME;
            if (e_tap && st != ST_PLAY && st != ST_DEAD) begin q <= R_RESET; xret <= R_FRAME; end
            else if ((e_u || e_tap) && st == ST_PLAY && talk == 10'd0) begin                // do_jump()
                if (coy > 0 && jumps == 2'd0) begin vy <= VJ; g <= G1; jumps <= 2'd1; ly <= py; coy <= 16'sd0; end
                else if (jumps < 2'd2) begin
                    if (jumps == 2'd0) ly <= py;
                    g <= G2; jumps <= 2'd2;
                    sq_v <= 60'd50 * $unsigned((dj < M05) ? M05 : dj) * 60'd7864320;
                    sq_r <= 60'd0; sq_b <= 60'd1 << 58; sq_ph <= 1'b0; q <= R_SQRT;
                end
            end
        end
        R_SQRT: begin                                            // bit-by-bit integer square root
            if (!sq_ph) begin if (sq_b > sq_v) sq_b <= sq_b >> 2; else sq_ph <= 1'b1; end
            else if (sq_b == 60'd0) q <= R_SQ2;
            else begin
                if (sq_v >= sq_r + sq_b) begin sq_v <= sq_v - (sq_r + sq_b); sq_r <= (sq_r >> 1) + sq_b; end
                else sq_r <= sq_r >> 1;
                sq_b <= sq_b >> 2;
            end
        end
        R_SQ2: begin vy <= div120($signed({1'b0, sq_r[34:0]})); q <= R_FRAME; end
        R_FRAME: begin
            if (e_d && st == ST_PLAY && talk == 10'd0 && !used && hits == 3'd1) begin       // skill()
                used <= 1'b1; hits <= 3'd0; rep_out <= 1'b1; msg <= 2'd1; msg_u <= T_MSG;
            end
            step_n <= 1'b0;
            if (st == ST_PLAY) q <= R_STEP;
            else if (st == ST_DEAD) begin
                if (dd <= 7'd1) begin q <= R_RESET; xret <= R_P0; end else begin dd <= dd - 7'd1; q <= R_P0; end
            end else q <= R_P0;
        end
        // ---- step()
        R_STEP: begin
            gt <= gt + 16'd1;
            if (gt + 16'd1 >= T_GAME) begin st <= ST_LOSE; q <= R_NEXT; end
            else begin
                cam <= (px - M6 < 0) ? 36'sd0 : (px - M6 > M230) ? M230 : px - M6;
                if (msg_u != 8'd0) msg_u <= msg_u - 8'd1;
                if (talk != 10'd0) begin q <= R_REP; rret <= R_TALK2; end
                else q <= R_PX;
            end
        end
        R_TALK2: begin
            talk <= talk - 10'd1;
            if (talk == 10'd1) begin hits <= 3'd0; hc <= T_HC; if (rep_on) rep_out <= 1'b1; end
            q <= R_NEXT;
        end
        // ---- step_p()
        R_PX: begin
            if (k_r ^ k_l) begin pf <= k_r; run <= run + 16'd1; end
            px <= (px + ((k_r ^ k_l) ? (k_r ? 36'sd5 * STEP : -36'sd5 * STEP) : 36'sd0) < cam) ? cam :
                  px + ((k_r ^ k_l) ? (k_r ? 36'sd5 * STEP : -36'sd5 * STEP) : 36'sd0);
            ii <= 8'd0; q <= (k_r ^ k_l) ? R_XL : R_VY;
        end
        R_XL: begin
            if (hitf(px, py, PW, PH, s_x, s_y, s_w, s_h)) px <= k_r ? s_x - PW : s_x + s_w;
            if (ii == N_SOLID - 1) q <= R_VY; else ii <= ii + 8'd1;
        end
        R_VY: begin vy <= vy - g; py <= py + vy - g; ii <= 8'd0; sb_v <= 1'b0; q <= R_YL; end
        R_YL: begin                                              // sb_v = landed (gr)
            if (hitf(px, py, PW, PH, s_x, s_y, s_w, s_h)) begin
                if (vy <= 0) begin py <= s_t; sb_v <= 1'b1; end else py <= s_y - PH;
                vy <= 36'sd0;
            end
            if (ii == N_SOLID - 1) q <= R_GR; else ii <= ii + 8'd1;
        end
        R_GR: begin
            if (sb_v) begin jumps <= 2'd0; g <= G1; coy <= T_COY; end else coy <= coy - 16'sd1;
            hc <= hc - 22'sd1; i <= 8'd0; q <= R_AN;
        end
        // ---- upd_a(a) for every animal
        R_AN: begin
            q <= R_ANX;
            if (a_dead[i]) ;
            else if (!a_on[i] && cam + M20 < an_trig(i)) ;
            else begin
                a_on[i] <= 1'b1;
                if (a_t == 3'd3) begin                                   // plant
                    a_ph[i] <= ph1; a_r[i] <= plant_r(ph1); a_cy[i] <= a_y0 + plant_r(ph1);
                end else if (a_t == 3'd4) begin                          // flyer
                    a_x[i] <= a_x[i] - 36'sd2 * STEP;
                    if (a_x[i] - 36'sd2 * STEP < cam - M3) a_dead[i] <= 1'b1;
                end else if (a_fall[i]) begin                            // falling into the water
                    a_vy[i] <= fvy; a_cy[i] <= a_cy[i] + fvy;
                    a_x[i] <= a_x[i] + (a_dir[i] ? STEP : -STEP);
                    if (a_cy[i] + fvy < -M15 || a_x[i] + (a_dir[i] ? STEP : -STEP) < cam - M3) a_dead[i] <= 1'b1;
                end else begin a_x[i] <= wx; q <= R_AN3; end               // walker
            end
        end
        R_AN3: begin                                             // patrol bounds, then surf(x + .5, ya)
            q <= R_SURF; sret <= R_AN4; sy <= a_y0; sb_v <= 1'b0; ii <= 8'd0;
            if (an_patrol(i)) begin
                if (a_x[i] < an_a(i)) begin a_x[i] <= an_a(i); a_dir[i] <= 1'b1; end
                if (((a_x[i] < an_a(i)) ? an_a(i) : a_x[i]) + Q > an_b(i)) begin
                    a_x[i] <= an_b(i) - Q; a_dir[i] <= 1'b0; sx <= an_b(i) - Q + M05;
                end else sx <= ((a_x[i] < an_a(i)) ? an_a(i) : a_x[i]) + M05;
            end else if (a_x[i] < cam - M3) begin a_dead[i] <= 1'b1; q <= R_ANX; end
            else sx <= a_x[i] + M05;
        end
        R_AN4: begin
            if (!sb_v) begin a_fall[i] <= 1'b1; a_vy[i] <= 36'sd0; end else a_cy[i] <= sb;
            q <= R_ANX;
        end
        R_ANX: if (i == NA - 1) begin i <= 8'd0; q <= R_CO; end else begin i <= i + 8'd1; q <= R_AN; end
        // ---- animal hit test: first animal touching the player, only when hc has run out
        R_CO: begin
            if (!a_dead[i] && a_on[i] && !a_fall[i] && !(a_t == 3'd3 && a_r[i] < M06) &&
                hitf(px, py, PW, PH, bx, by, bw, bh) && hc <= 0) begin
                hits <= hits + 3'd1; hc <= T_HC;                     // on_hit()
                if (hits == 3'd0) begin
                    rep_on <= 1'b1; rep_out <= 1'b0; rx <= cam - M2; ry <= py; msg <= 2'd2; msg_u <= T_MSG;
                end else begin talk <= T_TALK; hc <= 22'sd1 << 20; end
                q <= R_REP; rret <= R_END;
            end else if (i == NA - 1) begin q <= R_REP; rret <= R_END; end
            else i <= i + 8'd1;
        end
        // ---- upd_rep()
        R_REP: begin
            if (!rep_on) q <= rret;
            else if (rep_out) begin
                rx <= rx - 36'sd14 * STEP; if (rx - 36'sd14 * STEP < cam - M3) rep_on <= 1'b0;
                q <= rret;
            end else begin
                rx <= rx_in; sx <= rx_in + M045; sy <= py + M06; sb_v <= 1'b0; ii <= 8'd0;
                sret <= R_REP2; q <= R_SURF;
            end
        end
        R_REP2: begin ry <= ry + div10((sb_v ? sb : py) - ry); q <= rret; end
        R_END: begin
            if (py < Q) begin st <= ST_DEAD; dd <= T_DEAD; end
            else if (px + PW >= M249) st <= ST_WIN;
            q <= R_NEXT;
        end
        R_NEXT: if (!step_n && st == ST_PLAY) begin step_n <= 1'b1; q <= R_STEP; end else q <= R_P0;
        // ---- surf(sx, sy): highest top <= sy + 1.01 above x (the invisible end wall excluded)
        R_SURF: begin
            if (!s_wl && s_x <= sx && sx <= s_x + s_w && s_t <= sy + SURF_DY && (!sb_v || s_t > sb)) begin
                sb <= s_t; sb_v <= 1'b1;
            end
            if (ii == N_SOLID - 1) q <= sret; else ii <= ii + 8'd1;
        end
        // ---- reset()
        R_RESET: begin
            px <= 36'sd2 * Q; py <= 36'sd4 * Q; vy <= 36'sd0; g <= G1; jumps <= 2'd0; ly <= 36'sd4 * Q;
            coy <= 16'sd0; pf <= 1'b1; run <= 16'd0; gt <= 16'd0; hits <= 3'd0; hc <= 22'sd0; used <= 1'b0;
            rep_on <= 1'b0; rep_out <= 1'b0; talk <= 10'd0; msg_u <= 8'd0; msg <= 2'd0; cam <= 36'sd0;
            dd <= 7'd0; st <= ST_PLAY; i <= 8'd0; q <= R_RES2;
        end
        R_RES2: begin
            a_on[i] <= an_trig(i) < -36'sd90 * Q; a_dir[i] <= 1'b0; a_dead[i] <= 1'b0; a_fall[i] <= 1'b0;
            a_ph[i] <= an_ph(i); a_r[i] <= 36'sd0; a_x[i] <= a_x0; a_cy[i] <= a_y0; a_vy[i] <= 36'sd0;
            if (a_t < 3'd3) begin sx <= a_x0 + M05; sy <= a_y0; sb_v <= 1'b0; ii <= 8'd0; sret <= R_RES4; q <= R_SURF; end
            else q <= R_RES3;
        end
        R_RES4: begin if (sb_v) a_cy[i] <= sb; q <= R_RES3; end
        R_RES3: begin
            if (i == NA - 1) begin
                i <= 8'd0; q <= xret;
                if (tele) begin px <= {20'd0, tele_m, 8'd0} * 36'sd30720; py <= 36'sd30 * Q; tele <= 1'b0; end
            end else begin i <= i + 8'd1; q <= R_RES2; end
        end
        R_MENU: begin st <= ST_MENU; q <= R_P0; end
        R_DEMO: begin                                            // jump_to(): checkpoints / restart
            q <= R_IDLE;
            case (dm_op)
                4'd1: begin tele <= 1'b1; tele_m <= dm_arg[7:0]; q <= R_RESET; xret <= R_P0; end
                4'd2: begin tele <= 1'b1; tele_m <= 8'd50;  q <= R_RESET; xret <= R_P0; end
                4'd3: begin tele <= 1'b1; tele_m <= 8'd90;  q <= R_RESET; xret <= R_P0; end
                4'd4: begin tele <= 1'b1; tele_m <= 8'd140; q <= R_RESET; xret <= R_P0; end
                4'd5: begin tele <= 1'b1; tele_m <= 8'd185; q <= R_RESET; xret <= R_P0; end
                4'd6: begin tele <= 1'b1; tele_m <= 8'd225; q <= R_RESET; xret <= R_P0; end
                4'd12: begin q <= R_RESET; xret <= R_P0; end
                default: ;
            endcase
        end
        // ---- publish: screen fields of this tick (s3_model.publish)
        R_P0: begin cam_px <= scr(cam); q <= R_P1; end
        R_P1: begin q <= R_P2; end                               // (HUD / player fields: always block below)
        R_P2: begin
            na <= 3'd0; nf <= 2'd0; npl <= 2'd0; i <= 8'd0; q <= R_PA;
            for (m = 0; m < N_AS; m = m + 1) begin as_v[m] <= 1'b0; as_t[m] <= 3'd0; end
            for (m = 0; m < N_FS; m = m + 1) fa_v[m] <= 1'b0;
            for (m = 0; m < N_PS; m = m + 1) pl_v[m] <= 1'b0;
        end
        R_PA: begin                                              // one animal per clock -> visible slots
            if (!a_dead[i] && ax_c >= -16'sd40 && ax_c <= 16'sd680) begin
                if (a_t == 3'd3) begin
                    if (npl < N_PS) begin pl_x[npl] <= ax_c; pl_y[npl] <= ay_c; pl_v[npl] <= 1'b1;
                                          pl_o[npl] <= a_r[i] > M06; npl <= npl + 2'd1; end
                end else if (a_fall[i]) begin
                    if (nf < N_FS) begin fa_x[nf] <= ax_c; fa_y[nf] <= ay_c; fa_v[nf] <= 1'b1;
                                         fa_t2[nf] <= a_t == 3'd2; fa_f[nf] <= a_dir[i]; nf <= nf + 2'd1; end
                end else if (na < N_AS) begin
                    as_x[na] <= ax_c; as_y[na] <= ay_c; as_yw[na] <= ayw_c; as_v[na] <= 1'b1;
                    as_t[na] <= a_t; as_f[na] <= a_dir[i]; na <= na + 3'd1;
                end
            end
            if (i == NA - 1) q <= R_PEND; else i <= i + 8'd1;
        end
        R_PEND: begin pub_hud <= 1'b1; q <= R_IDLE; end
        default: q <= R_IDLE;
        endcase
        if (q != R_PEND) pub_hud <= 1'b0;
    end


    // ---------------------------------------------------------------- publish: player, HUD (after the tick)
    reg  [3071:0] F_r; reg [255:0] C_r;
    wire signed [15:0] cpx = $signed({3'd0, cam_px});
    wire signed [7:0]  swp = swing(sin8(phase14(run))), swr = swing(sg);
    wire signed [15:0] pcx = scr(px + M045) - cpx, rcx = scr(rx + M045) - cpx;
    wire [35:0] shift_p = {16'd0, cam[35:16]} * 36'd3495;
    wire [15:0] shift_c = shift_p[31:16];
    wire [15:0] rem = T_GAME - gt;
    wire [1:0]  tm = (rem >= 16'd14400) ? 2'd2 : (rem >= 16'd7200) ? 2'd1 : 2'd0;
    wire [31:0] secs_p = (rem - tm * 16'd7200) * 32'd34953;
    wire [5:0]  secs = secs_p[27:22];
    wire [15:0] ts1_p = secs * 16'd205;
    wire [3:0]  ts1 = ts1_p[14:11];
    wire [5:0] ts2 = secs - ts1 * 6'd10;
    wire [31:0] gtb3 = gt * 32'd52429, gtb4 = gt * 32'd69906;
    wire [35:0] prog_p = px[35:16] * 36'd437;
    wire [19:0] prog = prog_p[35:16];
    wire [31:0] talkd_p = (talk + 32'd119) * 32'd34953;
    wire [35:0] tt_p = (gt + 36'd6) * 36'd87382;
    wire [15:0] tt = tt_p[35:20];
    wire [31:0] ip_p = tt * 32'd6554;
    wire [15:0] ip = ip_p[31:16];
    wire [35:0] lm_p = px[35:16] * 36'd34953;
    wire [15:0] lm = lm_p[35:22];
    function [11:0] dig3(input [15:0] v);                       // hundreds, tens, ones (v < 1000)
        reg [31:0] h; reg [15:0] r; reg [31:0] t;
        begin
            h = v * 32'd656; r = v - h[31:16] * 16'd100; t = r * 32'd6554;
            dig3 = {h[19:16], t[19:16], r[3:0] - t[19:16] * 4'd10};
        end
    endfunction
    wire [11:0] wd = dig3(ip), ld = dig3(lm);
    function signed [15:0] cloud(input [15:0] base, input [15:0] sh);
        reg [15:0] v; integer k;
        begin
            v = base - sh + 16'd1920;
            for (k = 0; k < 3; k = k + 1) if (v >= 16'd960) v = v - 16'd960;
            cloud = v - 16'd128;
        end
    endfunction
    function [23:0] f24(input signed [15:0] v); f24 = {{8{v[15]}}, v}; endfunction
    always @(posedge clk) if (pub_hud) begin
        wave_ph <= (((cam >>> 13) * 36'sd4450 + gt * 36'sd55629) >>> 16);
        hill_ph <= (((cam >>> 13) * 36'sd91138) >>> 16);
    end
    // condition 0 = constant 1 (ui_composer: instructions without a condition test cond[0])
    always @(posedge clk) if (rst) begin F_r <= 3072'd0; C_r <= 256'd1; end
    else if (pub_hud) begin
        F_r <= 3072'd0; C_r <= 256'd1;
        F_r[F3_CAMPX*24 +: 24] <= {11'd0, cam_px};
        F_r[F3_PCX*24 +: 24] <= f24(pcx);
        F_r[F3_PL1*24 +: 24] <= f24(pcx + swp); F_r[F3_PL2*24 +: 24] <= f24(pcx - swp);
        F_r[F3_PY*24 +: 24]  <= f24(16'sd360 - scr(py));
        C_r[C3_PLAYER] <= st != ST_DEAD; C_r[C3_PF] <= pf;
        C_r[C3_REP] <= rep_on;
        if (rep_on) begin
            F_r[F3_RCX*24 +: 24] <= f24(rcx);
            F_r[F3_RL1*24 +: 24] <= f24(rcx + swr); F_r[F3_RL2*24 +: 24] <= f24(rcx - swr);
            F_r[F3_RY*24 +: 24]  <= f24(16'sd360 - scr(ry));
            C_r[C3_RF] <= !rep_out;
        end
        F_r[F3_FLAGX*24 +: 24] <= f24(16'sd7936 - cpx); C_r[C3_FLAG] <= (16'sd7936 - cpx) < 16'sd700;
        F_r[F3_CL0*24 +: 24] <= f24(cloud(16'd0, shift_c));    F_r[F3_CL1*24 +: 24] <= f24(cloud(16'd234, shift_c));
        F_r[F3_CL2*24 +: 24] <= f24(cloud(16'd467, shift_c));  F_r[F3_CL3*24 +: 24] <= f24(cloud(16'd701, shift_c));
        F_r[F3_CL4*24 +: 24] <= f24(cloud(16'd934, shift_c));  F_r[F3_CL5*24 +: 24] <= f24(cloud(16'd1168, shift_c));
        for (n = 0; n < N_AS; n = n + 1) begin
            F_r[(F3_A0_X + 3 * n) * 24 +: 24] <= as_v[n] ? f24(as_x[n]) : 24'd0;
            F_r[(F3_A0_Y + 3 * n) * 24 +: 24] <= as_v[n] ? f24(as_y[n]) : 24'd0;
            F_r[(F3_A0_YW + 3 * n) * 24 +: 24] <= (as_v[n] && as_t[n] == 3'd4) ? f24(as_yw[n]) : 24'd0;
            C_r[C3_A0_V + 5 * n] <= as_v[n];
            C_r[C3_A0_T1 + 5 * n] <= as_v[n] && as_t[n] == 3'd1;
            C_r[C3_A0_T2 + 5 * n] <= as_v[n] && as_t[n] == 3'd2;
            C_r[C3_A0_T4 + 5 * n] <= as_v[n] && as_t[n] == 3'd4;
            C_r[C3_A0_F + 5 * n] <= as_v[n] && as_f[n];
        end
        for (n = 0; n < N_FS; n = n + 1) begin
            F_r[(F3_F0_X + 2 * n) * 24 +: 24] <= fa_v[n] ? f24(fa_x[n]) : 24'd0;
            F_r[(F3_F0_Y + 2 * n) * 24 +: 24] <= fa_v[n] ? f24(fa_y[n]) : 24'd0;
            C_r[C3_F0_V + 3 * n] <= fa_v[n]; C_r[C3_F0_T2 + 3 * n] <= fa_v[n] && fa_t2[n];
            C_r[C3_F0_F + 3 * n] <= fa_v[n] && fa_f[n];
        end
        for (n = 0; n < N_PS; n = n + 1) begin
            F_r[(F3_P0_X + 2 * n) * 24 +: 24] <= pl_v[n] ? f24(pl_x[n]) : 24'd0;
            F_r[(F3_P0_Y + 2 * n) * 24 +: 24] <= pl_v[n] ? f24(pl_y[n]) : 24'd0;
            C_r[C3_P0_V + 2 * n] <= pl_v[n]; C_r[C3_P0_OPEN + 2 * n] <= pl_v[n] && pl_o[n];
        end
        F_r[F3_TM*24 +: 24] <= {22'd0, tm};
        F_r[F3_TS1*24 +: 24] <= {20'd0, ts1};
        F_r[F3_TS2*24 +: 24] <= {18'd0, ts2};
        C_r[C3_TBLINK] <= rem < 16'd1800 && gtb3[21];
        F_r[F3_PBX1*24 +: 24] <= 24'd220 + ((prog > 20'd200) ? 24'd200 : {4'd0, prog});
        F_r[F3_PBY1*24 +: 24] <= 24'd14;
        C_r[C3_SK_USED] <= used; C_r[C3_SK_READY] <= !used && hits == 3'd1; C_r[C3_SK_BLINK] <= gtb4[21];
        C_r[C3_MSG] <= msg_u != 8'd0; C_r[C3_MSG_SKILL] <= msg == 2'd1;
        C_r[C3_TALK] <= talk != 10'd0; C_r[C3_TALK1] <= talk > T_TALK_HALF;
        F_r[F3_TALKD*24 +: 24] <= {14'd0, talkd_p[31:22]};
        F_r[F3_WT*24 +: 24] <= tt - ip * 16'd10;
        F_r[F3_W1*24 +: 24] <= {20'd0, wd[11:8]}; F_r[F3_W2*24 +: 24] <= {20'd0, wd[7:4]};
        F_r[F3_W3*24 +: 24] <= {20'd0, wd[3:0]};
        C_r[C3_WD1] <= ip < 16'd10; C_r[C3_WD2] <= ip >= 16'd10 && ip < 16'd100; C_r[C3_WD3] <= ip >= 16'd100;
        F_r[F3_L1*24 +: 24] <= {20'd0, ld[11:8]}; F_r[F3_L2*24 +: 24] <= {20'd0, ld[7:4]};
        F_r[F3_L3*24 +: 24] <= {20'd0, ld[3:0]};
        C_r[C3_LD1] <= lm < 16'd10; C_r[C3_LD2] <= lm >= 16'd10 && lm < 16'd100; C_r[C3_LD3] <= lm >= 16'd100;
        C_r[C3_MENU] <= st == ST_MENU; C_r[C3_PLAY] <= st == ST_PLAY; C_r[C3_DEAD] <= st == ST_DEAD;
        C_r[C3_WIN] <= st == ST_WIN; C_r[C3_LOSE] <= st == ST_LOSE;
    end
    assign fields = F_r;
    assign conds  = C_r;

    // ---------------------------------------------------------------- board outputs
    wire [3:0] bar = (lm >= 16'd250) ? 4'd10 : lm / 16'd25;
    assign leds = {2'b00, talk != 10'd0, rep_on && !rep_out, used, !used && hits == 3'd1,
                   bar > 4'd9, bar > 4'd8, bar > 4'd7, bar > 4'd6, bar > 4'd5, bar > 4'd4, bar > 4'd3, bar > 4'd2,
                   bar > 4'd1, bar > 4'd0};
    assign rgb16 = (st == ST_WIN) ? 3'b010 : (st == ST_LOSE) ? 3'b100 : (st == ST_DEAD) ? 3'b001 : 3'b000;
    assign rgb17 = (talk != 10'd0) ? 3'b110 : (hits != 3'd0 && hc > 0) ? 3'b100 : 3'b000;
    // 7-seg: "3-m ss mmm" = stage, time left, metres run
    always @(posedge clk) seg_chars <= {5'd3, SG_DASH, 3'd0, tm, 1'b0, ts1, 1'b0, ts2[3:0],
                                        1'b0, ld[11:8], 1'b0, ld[7:4], 1'b0, ld[3:0]};
endmodule
