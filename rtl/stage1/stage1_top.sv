import stage1_pkg::*;

module stage1_top #(
    parameter int CLK_HZ = 100_000_000
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] sw,
    input  logic        btn_u, btn_d, btn_l, btn_r, btn_c,
    output logic [15:0] led,
    output logic        vga_hs, vga_vs,
    output logic [3:0]  vga_r, vga_g, vga_b
);
    // Clock Dividers: 25MHz (VGA) & 60Hz (Game Tick)
    logic [1:0]  div25;
    logic [20:0] div60;
    logic        tick_60hz;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin div25 <= 0; div60 <= 0; tick_60hz <= 0; end
        else begin
            div25 <= div25 + 2'd1;
            if (div60 >= (CLK_HZ / 60) - 1) begin div60 <= 0; tick_60hz <= 1'b1; end
            else begin div60 <= div60 + 21'd1; tick_60hz <= 1'b0; end
        end
    end
    wire clk_25m = div25[1];

    logic hold_u, hold_d, hold_l, hold_r, pulse_u, pulse_d, pulse_l, pulse_r, tap_c, back_c;
    stage1_input #(.CLK_HZ(CLK_HZ)) u_in (.*);

    game_state_t state;
    logic in_closeup, lights, card_active, card_flipped, door_layer;
    logic has_A, has_B, has_C;
    obj_id_t cur_obj, near_obj;
    logic [1:0]  page, hearts, armor, form, card_round, card_cursor, career, spr_dir, spr_pose, p2_cur, p5_cur;
    logic [2:0]  door_cur;
    logic [3:0]  ans_A, ans_B, ans_C, p3_cur;
    logic [4:0]  done_mask, right_mask, flash_timer, hints_seen;
    logic [11:0] slow_timer, freeze_timer, px, py;
    logic [15:0] p3_truth_out;
    item_id_t    last_item;
    logic [3:0]  p2_used [0:2], p2_pol [0:2], door_dig [0:4];
    logic [2:0]  p3_cfg  [0:8];
    logic [4:0]  p5_chr  [0:2];

    stage1_core u_core (.*);

    stage1_vga u_vga (
        .clk_25m(clk_25m), .rst_n(rst_n), .state(state), .in_closeup(in_closeup),
        .cur_obj(cur_obj), .lights(lights), .notebook_open(sw[14]),
        .card_active(card_active), .card_cursor(card_cursor), .card_flipped(card_flipped),
        .hearts(hearts), .armor(armor), .slow_timer(slow_timer), .freeze_timer(freeze_timer),
        .flash_timer(flash_timer), .px(px), .py(py), .spr_dir(spr_dir), .spr_pose(spr_pose),
        .vga_hs(vga_hs), .vga_vs(vga_vs), .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b)
    );

    // Physical Board LEDs (ตรงกับ spec ใน stage1(2).py)
    assign led[2:0]   = (hearts == 3) ? 3'b111 : (hearts == 2) ? 3'b011 : (hearts == 1) ? 3'b001 : 3'b000;
    assign led[3]     = (armor > 0);
    assign led[8:4]   = done_mask;
    assign led[9]     = lights;
    assign led[10]    = (freeze_timer > 0);
    assign led[11]    = (slow_timer > 0);
    assign led[15:12] = 4'b0000;
endmodule