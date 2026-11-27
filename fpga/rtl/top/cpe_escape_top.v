// cpe_escape_top.v - TOP MODULE for the Digilent Nexys A7 (XC7A100T-1CSG324C).
// Port names = the Digilent master XDC (constraints/nexys_a7.xdc).
//
//   100 MHz ──┬─ reset_sync ─ rst
//             ├─ tick_gen (60 Hz game tick) ─ input_hub (debounce, tap / long press, per-tick events)
//             ├─ s1_core (Stage 1 game logic + shared FEATURE modules) ─ fields / conds / camera
//             ├─ ui_composer (once per frame in vblank: screen program -> display list)
//             ├─ vga_timing + line_renderer (display list + background -> VGA pins)
//             ├─ seven_seg (8 digits)        └─ LEDs / RGB LEDs
//             ├─ s2_core (Stage 2 game logic)
//             ├─ s3_core (Stage 3 graduation obby)
//             ├─ stage_mgr (screen sequence OPEN -> S1 -> C12 -> S2 -> C23 -> S3 -> END, one stage at a time)
//             ├─ pic_stream + qspi_io (pictures + Stage 1/2 rooms from the QSPI flash -> line_renderer)
//             └─ demo_menu (SW12 = on-board version of demo_hub.py: jump to checkpoints, actions)
// Only one clock domain (100 MHz); the 25 MHz pixel rate is a clock ENABLE.
`timescale 1ns/1ps
module cpe_escape_top #(
    parameter MEM_DIR    = "",          // simulation: "mem/" ; Vivado: "" (files added to the project)
    parameter SIM_FAST   = 0,           // 1 = short debounce / long-press / tick (simulation only)
    parameter TICK_PERIOD = 1666667
) (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        BTNC, BTNU, BTNL, BTNR, BTND,
    input  wire [15:0] SW,
    output wire [15:0] LED,
    output wire        LED16_R, LED16_G, LED16_B,
    output wire        LED17_R, LED17_G, LED17_B,
    output wire        CA, CB, CC, CD, CE, CF, CG, DP,
    output wire [7:0]  AN,
    output wire [3:0]  VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS,
    output wire        QSPI_CSN,        // S25FL128S configuration flash (pictures at PIC_BASE)
    inout  wire [3:0]  QSPI_DQ          // (its SCK pin is reached through STARTUPE2 in qspi_io.v)
);
`include "pic_map.vh"
`include "ui_map.vh"
    wire clk = CLK100MHZ;
    wire rst;
    reset_sync u_rst (.clk(clk), .rst_n_async(CPU_RESETN), .rst(rst));

    // ------------------------------------------------------------ input
    wire tick;
    tick_gen #(.PERIOD(SIM_FAST ? 2000 : TICK_PERIOD), .W(21)) u_tick (.clk(clk), .rst(rst), .tick(tick));
    wire [4:0]  lvl;
    wire        ev_u, ev_d, ev_l, ev_r, ev_tap, ev_back, gtick;
    wire [15:0] sw;
    input_hub #(.DEBOUNCE_CYCLES(SIM_FAST ? 4 : 1000000), .LONG_CYCLES(SIM_FAST ? 4000 : 80000000)) u_in (
        .clk(clk), .rst(rst), .tick(tick), .btn_raw({BTNC, BTNR, BTNL, BTND, BTNU}), .sw_raw(SW),
        .lvl(lvl), .ev_u(ev_u), .ev_d(ev_d), .ev_l(ev_l), .ev_r(ev_r), .ev_tap(ev_tap), .ev_back(ev_back),
        .gtick(gtick), .sw(sw));

    // demo menu owns the buttons while SW12 is on
    wire demo_on = sw[12];
    wire        dm_cmd; wire [3:0] dm_op; wire [15:0] dm_arg; wire [39:0] dm_seg;
    demo_menu u_demo (.clk(clk), .rst(rst), .on(demo_on), .gtick(gtick), .ev_u(ev_u), .ev_d(ev_d),
        .ev_tap(ev_tap), .sw(sw), .cmd(dm_cmd), .op(dm_op), .arg(dm_arg), .seg_chars(dm_seg));

    // ------------------------------------------------------------ stage manager (stage_mgr.v)
    // OPEN (title) -> S1 -> C12 -> S2 -> C23 -> S3 -> END -> OPEN. Picture screens (placeholders until
    // Phase 5) show their first picture via bg_mode 5 and leave on a BTNC tap; stages leave with exit_req
    // (Stage 3: BTNC on its WIN screen; on the LOSE screen BTNC still plays it again). Screen changes are
    // applied in vblank. Demo menu: 13 = go to Stage 1, 14 = go to Stage 2 (SW0 off) / Stage 3 (SW0 on),
    // straight to the stage; other commands go to the running stage.
    wire       frame_end;
    wire       s1_exit, s2_exit, s3_exit;
    wire [1:0] h_armor, h_form, h2o_armor, h2o_form; wire h_shard, h_boost, h2o_shard, h2o_boost;
    wire [2:0] screen; wire on1, on2, on3, pic_on, boot, top_cmd;
    wire       s1_enter, s2_enter, s3_enter, s1_help, s2_help, sm_pic_load;
    wire [1:0] h2_armor, h3_armor, form; wire h2_shard, h2_boost, h3_shard, h3_boost;
    wire [4:0] sm_pic_id;
    wire [255:0] c3;
    stage_mgr u_sm (
        .clk(clk), .rst(rst), .vblank(frame_end), .gtick(gtick), .ev_tap(ev_tap & !demo_on), .btnc_lvl(lvl[4]),
        .s1_exit(s1_exit), .s2_exit(s2_exit), .s3_exit(s3_exit),
        .s1_armor(h_armor), .s1_shard(h_shard), .s1_boost(h_boost), .s1_form(h_form),
        .s2_armor(h2o_armor), .s2_shard(h2o_shard), .s2_boost(h2o_boost), .s2_form(h2o_form),
        .demo_cmd(dm_cmd), .demo_op(dm_op), .demo_arg(dm_arg), .top_cmd(top_cmd),
        .screen(screen), .on1(on1), .on2(on2), .on3(on3), .pic_on(pic_on), .boot(boot),
        .s1_enter(s1_enter), .s2_enter(s2_enter), .s3_enter(s3_enter), .s1_help(s1_help), .s2_help(s2_help),
        .h2_armor(h2_armor), .h2_shard(h2_shard), .h2_boost(h2_boost),
        .h3_armor(h3_armor), .h3_shard(h3_shard), .h3_boost(h3_boost), .form(form),
        .pic_id(sm_pic_id), .pic_load(sm_pic_load));
    // Stage 3 exit = BTNC tap on its WIN screen (s3_core's own exit_req is still 0: on WIN it restarts
    // itself on the same tap, harmless because the manager leaves Stage 3 in the next vblank).
    assign s3_exit = on3 && gtick && ev_tap && !demo_on && c3[C3_WIN];
    wire [4:0] lvl_g = demo_on ? 5'd0 : lvl;
    wire ok_ev = !demo_on;

    wire [3071:0] f1, f2, f3; wire [255:0] c1, c2;
    wire [2:0]  bg3; wire [12:0] s3_cam; wire [7:0] s3_wave; wire [15:0] s3_hill; wire [39:0] s3_seg;
    wire [15:0] s3_led; wire [2:0] rgb16_3, rgb17_3;
    wire [1:0]  bg1; wire [2:0] bg2; wire [11:0] bgc1, bgc2; wire [10:0] cam_x; wire [9:0] cam_y;
    wire [39:0] s1_seg, s2_seg; wire [7:0] s2_raw_en; wire [55:0] s2_raw;
    wire [15:0] s1_led, s2_led; wire [2:0] rgb16_1, rgb17_1, rgb16_2, rgb17_2;
    wire [11:0] zox, zoy; wire [16:0] zinv; wire [269:0] wsrc; wire [27:0] sval; wire [6:0] whl;

    s1_core u_s1 (
        .clk(clk), .rst(rst), .gtick(gtick & on1),
        .ev_u(ev_u & ok_ev), .ev_d(ev_d & ok_ev), .ev_l(ev_l & ok_ev), .ev_r(ev_r & ok_ev),
        .ev_tap(ev_tap & ok_ev), .ev_back(ev_back & ok_ev), .lvl(lvl_g), .sw(sw),
        .enter(s1_enter), .help_on_entry(s1_help), .has_next(1'b1),
        .in_armor(2'd0), .in_shard(1'b0), .in_boost(1'b0),
        .exit_req(s1_exit), .out_armor(h_armor), .out_shard(h_shard), .out_boost(h_boost), .out_form(h_form),
        .demo_cmd(dm_cmd & on1 & !top_cmd), .demo_op(dm_op), .demo_arg(dm_arg),
        .fields(f1), .conds(c1), .bg_mode(bg1), .bg_color(bgc1), .cam_x(cam_x), .cam_y(cam_y),
        .seg_chars(s1_seg), .leds(s1_led), .rgb16(rgb16_1), .rgb17(rgb17_1),
        .dbg_px(), .dbg_py(), .dbg_pxf(), .dbg_pyf(), .dbg_done(), .dbg_right(), .dbg_hearts(), .dbg_lfsr(),
        .dbg_state());
    s2_core #(.NPC_FILE({MEM_DIR, "s2_npc.mem"}), .MASK_FILE({MEM_DIR, "s2_mask.mem"})) u_s2 (
        .clk(clk), .rst(rst), .gtick(gtick & on2),
        .ev_u(ev_u & ok_ev), .ev_d(ev_d & ok_ev), .ev_l(ev_l & ok_ev), .ev_r(ev_r & ok_ev),
        .ev_tap(ev_tap & ok_ev), .ev_back(ev_back & ok_ev), .lvl(lvl_g), .sw(sw),
        .enter(s2_enter), .help_on_entry(s2_help), .has_next(1'b0),
        .in_armor(h2_armor), .in_shard(h2_shard), .in_boost(h2_boost),
        .exit_req(s2_exit), .out_armor(h2o_armor), .out_shard(h2o_shard), .out_boost(h2o_boost), .out_form(h2o_form),
        .demo_cmd(dm_cmd & on2 & !top_cmd), .demo_op(dm_op), .demo_arg(dm_arg),
        .fields(f2), .conds(c2), .bg_mode(bg2), .bg_color(bgc2), .zoom_ox(zox), .zoom_oy(zoy), .zoom_inv(zinv),
        .wire_src(wsrc), .src_val(sval), .wire_hl(whl), .seg_chars(s2_seg), .seg_raw_en(s2_raw_en),
        .seg_raw(s2_raw), .leds(s2_led), .rgb16(rgb16_2), .rgb17(rgb17_2));

    s3_core u_s3 (
        .clk(clk), .rst(rst), .gtick(gtick & on3),
        .ev_u(ev_u & ok_ev), .ev_d(ev_d & ok_ev), .ev_l(ev_l & ok_ev), .ev_r(ev_r & ok_ev),
        .ev_tap(ev_tap & ok_ev), .ev_back(ev_back & ok_ev), .lvl(lvl_g), .enter(s3_enter), .exit_req(),
        .demo_cmd(dm_cmd & on3 & !top_cmd), .demo_op(dm_op), .demo_arg(dm_arg),
        .fields(f3), .conds(c3), .bg_mode(bg3), .cam_px(s3_cam), .wave_ph(s3_wave), .hill_ph(s3_hill),
        .seg_chars(s3_seg), .leds(s3_led), .rgb16(rgb16_3), .rgb17(rgb17_3));

    // the UI program needs to know which stage runs: conditions 252..254 (ui_spec.RESERVED)
    reg  [3071:0] fields; reg [255:0] conds;
    // Picture screens / boot: conds = cond 0 only -> no IS_S1/2/3 block of the UI program runs -> the
    // composer writes an empty display list (just END) -> the picture is shown alone.
    wire stg = on1 || on2 || on3;
    always @(posedge clk) begin
        fields <= on1 ? f1 : on2 ? f2 : f3;
        conds  <= stg ? ((on1 ? c1 : on2 ? c2 : c3) | {1'b0, on1, on2, on3, 252'd0}) : {255'd0, 1'b1};
    end
    // picture screens: bg_mode 5 (fade 16, black outside the picture); boot: bg_mode 0 in black
    wire [2:0]  bg_mode  = pic_on ? 3'd5 : boot ? 3'd0 : on1 ? {1'b0, bg1} : on2 ? bg2 : bg3;
    wire [11:0] bg_color = !stg ? 12'h000 : on1 ? bgc1 : bgc2;
    wire [39:0] seg_ch   = !stg ? {8{5'd12}} : on1 ? s1_seg : on2 ? s2_seg : s3_seg;   // 12 = blank digit
    wire [15:0] st_led   = !stg ? 16'd0 : on1 ? s1_led : on2 ? s2_led : s3_led;
    wire [2:0]  rgb16    = !stg ? 3'd0 : on1 ? rgb16_1 : on2 ? rgb16_2 : rgb16_3;
    wire [2:0]  rgb17    = !stg ? 3'd0 : on1 ? rgb17_1 : on2 ? rgb17_2 : rgb17_3;

    // ------------------------------------------------------------ video
    wire        pix_ce, active, hs, vs, line_start;
    wire [9:0]  hcount, vcount;
    vga_timing u_vt (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount), .active(active),
        .hsync(hs), .vsync(vs), .line_start(line_start), .frame_end(frame_end));

    // ---- pictures from the QSPI flash (pic_stream.v): stage_mgr loads them in vblank (picture screens and the
    //      Stage 1 / Stage 2 rooms on stage entry), the renderer asks for one row per game line (bg_mode 1/2/5);
    //      picture size from pic_map.vh (generated by pic_pack.py)
    wire        pic_row_req, ps_busy, ps_missing;
    wire [9:0]  pic_src_row, pic_rd_x;
    wire [11:0] pic_rgb;
    wire [9:0]  pic_w, pic_h;
    assign {pic_w, pic_h} = pic_wh(sm_pic_id);
    //      ps_missing (flash image not found) -> LED16 red; ps_busy is not needed (stage_mgr issues pic_load
    //      in vblank only, the renderer requests one row per line) and stays unconnected
    wire        qspi_sck, qspi_eos; wire [3:0] qspi_dq_o, qspi_dq_oe, qspi_dq_i;
    pic_stream #(.PIC_BASE(PIC_BASE), .PIC_COUNT(PIC_COUNT)) u_ps (
        .clk(clk), .rst(rst), .cfg_eos(qspi_eos), .pic_id(sm_pic_id), .pic_load(sm_pic_load), .row_req(pic_row_req),
        .src_row(pic_src_row), .rd_x(pic_rd_x), .rd_rgb(pic_rgb), .busy(ps_busy), .missing(ps_missing),
        .qspi_csn(QSPI_CSN), .qspi_sck(qspi_sck), .qspi_dq_i(qspi_dq_i), .qspi_dq_o(qspi_dq_o),
        .qspi_dq_oe(qspi_dq_oe));
    qspi_io u_qio (.sck(qspi_sck), .dq_o(qspi_dq_o), .dq_oe(qspi_dq_oe), .dq_i(qspi_dq_i), .dq(QSPI_DQ),
        .eos(qspi_eos), .sim_sck());   // simulation-only clock tap (testbenches read u_qio.sim_sck), unconnected here

    wire        dl_we, tx_we, cp_busy, dl_full, lr_ovf;
    wire [7:0]  dl_waddr; wire [63:0] dl_wdata; wire [11:0] tx_waddr; wire [6:0] tx_wdata;
    ui_composer #(.PROG_FILE({MEM_DIR, "ui_prog.mem"}), .STR_FILE({MEM_DIR, "ui_str.mem"}),
                  .PTR_FILE({MEM_DIR, "ui_ptr.mem"})) u_comp (
        .clk(clk), .rst(rst), .start(frame_end), .fields(fields), .conds(conds), .busy(cp_busy),
        .dl_we(dl_we), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .tx_we(tx_we), .tx_waddr(tx_waddr),
        .tx_wdata(tx_wdata), .dl_full(dl_full));

    line_renderer #(.SPR_FILE({MEM_DIR, "spr.mem"}), .SPAL_FILE({MEM_DIR, "spr_pal.mem"}),
                    .FONT_FILE({MEM_DIR, "font8x16.mem"}), .CIRC_FILE({MEM_DIR, "circ.mem"}),
                    .BT_FILE({MEM_DIR, "s2_btile.mem"}), .BM_FILE({MEM_DIR, "s2_bmap.mem"}),
                    .BP_FILE({MEM_DIR, "s2_bpal.mem"}), .WIRE_FILE({MEM_DIR, "s2_wire.mem"}),
                    .S3S_FILE({MEM_DIR, "s3_solid.mem"}), .S3T_FILE({MEM_DIR, "s3_txt.mem"}),
                    .S3I_FILE({MEM_DIR, "s3_tidx.mem"}), .SIN_FILE({MEM_DIR, "sin256.mem"})) u_lr (
        .clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount), .active(active),
        .hsync(hs), .vsync(vs), .bg_mode(bg_mode), .bg_color(bg_color), .bg_color2(12'h000),
        .cam_x(cam_x), .cam_y(cam_y), .zoom_ox(on2 ? zox : 12'd0), .zoom_oy(on2 ? zoy : 12'd0),
        .zoom_inv(on2 ? zinv : 17'd65536), .wire_src(on2 ? wsrc : 270'd0), .src_val(sval), .wire_hl(on2 ? whl : 7'd0),
        .hill_ph(s3_hill), .wave_ph(s3_wave), .s3_cam(s3_cam),
        // bg_mode 1 / 2 (Stage 1 / 2 rooms) and 5 (picture screens): streamed by pic_stream
        // (fade 16 = full brightness: identity in the stage modes; Phase 5 fades the picture screens)
        .pic_rgb(pic_rgb), .pic_w(pic_w), .pic_h(pic_h), .fade(5'd16), .pic_row_req(pic_row_req),
        .pic_src_row(pic_src_row), .pic_rd_x(pic_rd_x),
        .dl_we(dl_we), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata),
        .tx_we(tx_we), .tx_waddr(tx_waddr), .tx_wdata(tx_wdata),
        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B), .vga_hs(VGA_HS), .vga_vs(VGA_VS), .overflow(lr_ovf));

    // ------------------------------------------------------------ 7-seg, LEDs
    wire [6:0] seg;
    seven_seg u_seg (.clk(clk), .rst(rst), .chars(demo_on ? dm_seg : seg_ch),
        .raw_en((on2 && !demo_on) ? s2_raw_en : 8'd0), .raw_seg(s2_raw),
        .an(AN), .seg(seg), .dp(DP));
    assign {CG, CF, CE, CD, CC, CB, CA} = seg;
    // LED15 = demo menu on, LED14 = render/compose overflow (should never light), LED0..11 = stage 1 panel
    // LED15 = demo menu (stage 1 also), LED14 = render overflow in stage 1; stage 2 uses LED13-15 for QA tests
    // stage 3: LED0-9 distance bar, LED10 skill ready, LED11 skill used, LED12 reporter, LED13 interview
    // picture screens: only LED15 (demo) / LED14 (overflow)
    assign LED = on2 ? st_led : {demo_on, lr_ovf | dl_full, st_led[13:0]};
    // RGB LEDs are very bright: drive them only 1/16 of the time
    reg [3:0] pwm = 4'd0; always @(posedge clk) pwm <= pwm + 4'd1;   // initial value: also defined in simulation
    wire dim = (pwm == 4'd0);
    // LED16 = solid red while pic_stream reports `missing` (no valid picture image in the flash: see the
    // README troubleshooting table); otherwise the running stage's colour
    assign {LED16_R, LED16_G, LED16_B} = (ps_missing ? 3'b100 : rgb16) & {3{dim}};
    assign {LED17_R, LED17_G, LED17_B} = rgb17 & {3{dim}};
endmodule
