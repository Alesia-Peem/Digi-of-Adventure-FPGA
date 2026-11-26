// stage_mgr.v - the game's screen sequence (main.py of the new Pygame game):
//   BOOT -> OPEN -> S1 -> C12 -> S2 -> C23 -> S3 -> END -> OPEN ...
//   OPEN = title / opening, C12 / C23 = cutscenes, END = ending: PLACEHOLDERS for now (Phase 5 gives them
//   their real behaviour): each shows its first picture full screen (bg_mode 5, streamed by pic_stream)
//   and leaves on a BTNC tap.  S1 / S2 / S3 = the stage cores; they leave with their exit_req
//   (S3: win screen + BTNC, made by the top level from the Stage 3 WIN condition).
//
// RULES
//   * Every screen change is REQUESTED (exit_req, tap, demo jump) and APPLIED on the next `vblank` pulse.
//     In that same cycle: the new screen (-> bg_mode in the top), the stage enter pulse and, for a picture
//     screen, pic_load + pic_id -> entering / leaving bg_mode 5 and loading the picture happen together in
//     vblank (ruling R13); pic_stream loads header + palette (~2.3k clk) long before the first row request.
//   * One request at a time: while a change is pending, further requests are ignored (no skipped screens).
//   * BTNC on a picture screen: the input_hub tap (= release of a short press) acts once. A press that is
//     held across a transition (or released so shortly before it that its tap is still on its way through
//     input_hub) sets `held` when the screen is entered; its tap is swallowed (or, for a long press, `held`
//     is dropped once BTNC is stably released at a game tick with no tap) -> the NEXT tap acts.
//     "stably released" = low for >= 8 clk: button_unit raises tap 2 clk after the level falls and
//     input_hub hands it out with the first gtick >= 3 clk after the fall, so a tick that sees BTNC low for
//     8 clk without ev_tap proves that no tap is pending.
//   * Demo menu (demo_menu.v, SW12): 13 = go to Stage 1, 14 = go to Stage 2 (SW0 off) / Stage 3 (SW0 on).
//     A jump goes straight to the stage (no cutscene), from ANY screen, without help screen, Stage 2 with an
//     empty handoff - the same as the previous 2-bit manager. Other commands belong to the running stage
//     (top_cmd = 0).
//   * Handoff: armor / shard / boost of Stage 1 are latched at the Stage 1 exit (-> Stage 2 inputs), those of
//     Stage 2 at the Stage 2 exit (h3_*, for Stage 3 when it gets handoff inputs).
//   * form never decreases (only reset lowers it): max(form, stage out_form) at each exit, and at least 1
//     on entering C12, 2 on entering C23 (Stage 1 / Stage 2 completion unlock forms 1 / 2).
`timescale 1ns/1ps
module stage_mgr (
    input  wire        clk,
    input  wire        rst,
    input  wire        vblank,          // 1-cycle pulse at the start of vblank (vga_timing frame_end)
    input  wire        gtick,           // game tick (input_hub)
    input  wire        ev_tap,          // BTNC tap, valid with gtick (masked by the top while SW12 demo is on)
    input  wire        btnc_lvl,        // BTNC debounced level (input_hub lvl[4])
    input  wire        s1_exit, s2_exit, s3_exit,
    input  wire [1:0]  s1_armor, s1_form,
    input  wire        s1_shard, s1_boost,
    input  wire [1:0]  s2_armor, s2_form,
    input  wire        s2_shard, s2_boost,
    input  wire        demo_cmd,
    input  wire [3:0]  demo_op,
    input  wire [15:0] demo_arg,
    output wire        top_cmd,         // demo command consumed here (13 / 14): not for the stages
    output reg  [2:0]  screen,
    output wire        on1, on2, on3,   // a stage core runs
    output wire        pic_on,          // a picture screen runs: bg_mode 5, empty display list
    output wire        boot,            // before the first vblank: black screen
    output reg         s1_enter, s2_enter, s3_enter,
    output reg         s1_help, s2_help,
    output reg  [1:0]  h2_armor,
    output reg         h2_shard, h2_boost,
    output reg  [1:0]  h3_armor,
    output reg         h3_shard, h3_boost,
    output reg  [1:0]  form,
    output reg  [4:0]  pic_id,
    output reg         pic_load
);
`include "pic_map.vh"
    localparam [2:0] SC_OPEN = 3'd0, SC_S1 = 3'd1, SC_C12 = 3'd2, SC_S2 = 3'd3, SC_C23 = 3'd4, SC_S3 = 3'd5,
                     SC_END = 3'd6, SC_BOOT = 3'd7;

    assign on1    = (screen == SC_S1);
    assign on2    = (screen == SC_S2);
    assign on3    = (screen == SC_S3);
    assign boot   = (screen == SC_BOOT);
    assign pic_on = (screen == SC_OPEN) || (screen == SC_C12) || (screen == SC_C23) || (screen == SC_END);
    assign top_cmd = demo_cmd && (demo_op == 4'd13 || demo_op == 4'd14);

    function [4:0] first_pic(input [2:0] s);
        case (s)
            SC_C12:  first_pic = PIC_CUT12;
            SC_C23:  first_pic = PIC_CUT23_1;
            SC_END:  first_pic = PIC_END1;
            default: first_pic = PIC_TITLE;
        endcase
    endfunction
    function is_pic(input [2:0] s);
        is_pic = (s == SC_OPEN) || (s == SC_C12) || (s == SC_C23) || (s == SC_END);
    endfunction
    function [2:0] after_tap(input [2:0] s);          // picture screen -> next screen
        case (s)
            SC_OPEN: after_tap = SC_S1;
            SC_C12:  after_tap = SC_S2;
            SC_C23:  after_tap = SC_S3;
            default: after_tap = SC_OPEN;              // END
        endcase
    endfunction
    function [1:0] max2(input [1:0] a, input [1:0] b);
        max2 = (a > b) ? a : b;
    endfunction

    reg       pend, pdemo, held;
    reg [6:0] lo_sr;                                 // BTNC low history (1 = low), newest in [0]
    wire      low8 = &{lo_sr, !btnc_lvl};
    reg [2:0] nxt;
    always @(posedge clk) begin
        if (rst) begin
            screen <= SC_BOOT; pend <= 1'b1; nxt <= SC_OPEN; pdemo <= 1'b0; held <= 1'b1; lo_sr <= 7'd0;
            s1_enter <= 1'b0; s2_enter <= 1'b0; s3_enter <= 1'b0; s1_help <= 1'b1; s2_help <= 1'b1;
            h2_armor <= 2'd0; h2_shard <= 1'b0; h2_boost <= 1'b0;
            h3_armor <= 2'd0; h3_shard <= 1'b0; h3_boost <= 1'b0;
            form <= 2'd0; pic_id <= PIC_TITLE; pic_load <= 1'b0;
        end else begin
            s1_enter <= 1'b0; s2_enter <= 1'b0; s3_enter <= 1'b0; pic_load <= 1'b0;
            lo_sr <= {lo_sr[5:0], !btnc_lvl};
            if (gtick && (ev_tap || low8)) held <= 1'b0;   // the held press's tap swallowed / BTNC released
            // ---- requests
            if (!pend) begin
                if (screen == SC_S1 && s1_exit) begin
                    pend <= 1'b1; nxt <= SC_C12; pdemo <= 1'b0;
                    h2_armor <= s1_armor; h2_shard <= s1_shard; h2_boost <= s1_boost;
                    form <= max2(form, s1_form);
                end else if (screen == SC_S2 && s2_exit) begin
                    pend <= 1'b1; nxt <= SC_C23; pdemo <= 1'b0;
                    h3_armor <= s2_armor; h3_shard <= s2_shard; h3_boost <= s2_boost;
                    form <= max2(form, s2_form);
                end else if (screen == SC_S3 && s3_exit) begin
                    pend <= 1'b1; nxt <= SC_END; pdemo <= 1'b0;
                end else if (pic_on && gtick && ev_tap && !held) begin
                    pend <= 1'b1; nxt <= after_tap(screen); pdemo <= 1'b0;
                end else if (top_cmd) begin
                    pend <= 1'b1; pdemo <= 1'b1;
                    nxt <= (demo_op == 4'd13) ? SC_S1 : demo_arg[0] ? SC_S3 : SC_S2;
                end
            end
            // ---- apply in vblank
            if (pend && vblank) begin
                pend <= 1'b0; screen <= nxt; held <= !low8;
                case (nxt)
                    SC_S1: begin s1_enter <= 1'b1; s1_help <= !pdemo; end
                    SC_S2: begin
                        s2_enter <= 1'b1; s2_help <= !pdemo;
                        if (pdemo) begin h2_armor <= 2'd0; h2_shard <= 1'b0; h2_boost <= 1'b0; end
                    end
                    SC_S3: s3_enter <= 1'b1;
                    default: ;
                endcase
                if (is_pic(nxt)) begin pic_load <= 1'b1; pic_id <= first_pic(nxt); end
                if (nxt == SC_C12) form <= max2(form, 2'd1);
                if (nxt == SC_C23) form <= max2(form, 2'd2);
            end
        end
    end
endmodule
