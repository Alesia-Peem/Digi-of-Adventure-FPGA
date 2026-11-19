import stage1_pkg::*;

module stage1_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        tick_60hz,
    input  logic [15:0] sw,
    input  logic        hold_u, hold_d, hold_l, hold_r,
    input  logic        pulse_u, pulse_d, pulse_l, pulse_r,
    input  logic        tap_c, back_c,

    // Outputs for VGA & Board Peripherals
    output game_state_t state,
    output logic        in_closeup,
    output obj_id_t     cur_obj,
    output logic [1:0]  page,
    output logic        lights,
    output logic [1:0]  hearts,
    output logic [1:0]  armor,
    output logic [1:0]  form,
    output logic [4:0]  done_mask,
    output logic [4:0]  right_mask,
    output logic        card_active,
    output logic [1:0]  card_round,     // 1..3
    output logic [1:0]  card_cursor,    // 0..2
    output logic        card_flipped,
    output logic [1:0]  career,         // 0:AIR, 1:EARTH, 2:WATER
    output item_id_t    last_item,
    output logic [11:0] slow_timer,
    output logic [11:0] freeze_timer,
    output logic [4:0]  flash_timer,

    // World & Puzzle Live State for VGA / 7-Seg
    output logic [11:0] px, py,
    output logic [1:0]  spr_dir, spr_pose,
    output obj_id_t     near_obj,
    output logic [3:0]  ans_A, ans_B, ans_C,
    output logic        has_A, has_B, has_C,
    output logic [1:0]  p2_cur,
    output logic [3:0]  p2_used [0:2],
    output logic [3:0]  p2_pol  [0:2],
    output logic [3:0]  p3_cur,
    output logic [2:0]  p3_cfg  [0:8],
    output logic [15:0] p3_truth_out,
    output logic [1:0]  p5_cur,
    output logic [4:0]  p5_chr  [0:2],
    output logic        door_layer,
    output logic [2:0]  door_cur,
    output logic [3:0]  door_dig [0:4],
    output logic [4:0]  hints_seen      // bit 0..4 = P1..P5
);
    // ---- 16-bit LFSR (taps 15,14,12,3) ----
    logic [15:0] lfsr;
    wire lfsr_fb = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= ({lfsr[14:0], lfsr_fb} == 16'd0) ? 16'hACE1 : {lfsr[14:0], lfsr_fb};
    end

    // ---- 6 Permutations of {0,1,2} ----
    localparam logic [1:0] PERMS [0:5][0:2] = '{
        '{2'd0, 2'd1, 2'd2}, '{2'd0, 2'd2, 2'd1},
        '{2'd1, 2'd0, 2'd2}, '{2'd1, 2'd2, 2'd0},
        '{2'd2, 2'd0, 2'd1}, '{2'd2, 2'd1, 2'd0}
    };

    // ---- Card Items per Round ----
    function automatic item_id_t get_card_item(input logic [1:0] rnd, input logic [1:0] col_idx);
        case (rnd)
            2'd1: return (col_idx == 2'd2) ? ITEM_ARMOR : ITEM_HINT_HARD;
            2'd2: return (col_idx == 2'd0) ? ITEM_SHARD : (col_idx == 2'd1) ? ITEM_SLOW : ITEM_HINT_SMART;
            2'd3: return (col_idx == 2'd0) ? ITEM_FREEZE : (col_idx == 2'd1) ? ITEM_UNDO : ITEM_SHARD;
            default: return ITEM_NONE;
        endcase
    endfunction

    // ---- Combinational Truth Tables for P2 and P3 ----
    logic [15:0] p2_truth_comb;
    logic [3:0]  p2_lits_comb;
    always_comb begin
        p2_truth_comb = 16'd0;
        p2_lits_comb  = 4'd0;
        for (int s = 0; s < 3; s++)
            for (int b = 0; b < 4; b++)
                p2_lits_comb = p2_lits_comb + p2_used[s][b];

        for (int m = 0; m < 16; m++) begin
            logic [3:0] v;
            logic f_val;
            v = {m[3], m[2], m[1], m[0]}; // A=m[3], B=m[2], C=m[1], D=m[0]
            f_val = 1'b0;
            for (int s = 0; s < 3; s++) begin
                if (p2_used[s] != 4'd0) begin
                    logic match;
                    match = 1'b1;
                    for (int i = 0; i < 4; i++) begin
                        if (p2_used[s][3-i] && (v[3-i] != p2_pol[s][3-i])) match = 1'b0;
                    end
                    if (match) f_val = 1'b1;
                end
            end
            p2_truth_comb[m] = f_val;
        end
    end

    always_comb begin
        p3_truth_out = 16'd0;
        for (int m = 0; m < 16; m++) begin
            logic [6:0] src; // [0]=A, [1]=B, [2]=C, [3]=D, [4]=G1, [5]=G2, [6]=G3
            logic [3:0] g;
            src[0] = m[3]; src[1] = m[2]; src[2] = m[1]; src[3] = m[0];
            g[0] = ~(src[p3_cfg[0]] & src[p3_cfg[1]]); src[4] = g[0];
            g[1] = ~(src[p3_cfg[2]] & src[p3_cfg[3]]); src[5] = g[1];
            g[2] = ~(src[p3_cfg[4]] & src[p3_cfg[5]]); src[6] = g[2];
            g[3] = ~(src[p3_cfg[6]] & src[p3_cfg[7]]);
            p3_truth_out[m] = g[p3_cfg[8][1:0]];
        end
    end

    // ---- World & Movement Instance ----
    logic reset_stage_pulse;
    wire can_move = (state == ST_PLAY) && !in_closeup && !card_active && !sw[14];

    stage1_world u_world (
        .clk(clk), .rst_n(rst_n), .reset_pos(reset_stage_pulse),
        .tick_60hz(tick_60hz), .can_move(can_move),
        .hold_u(hold_u), .hold_d(hold_d), .hold_l(hold_l), .hold_r(hold_r),
        .form(form), .is_slow(slow_timer != 0), .is_freeze(freeze_timer != 0),
        .px(px), .py(py), .spr_dir(spr_dir), .spr_pose(spr_pose), .near_obj(near_obj)
    );

    // ---- Internal Registers ----
    logic [2:0] r_run, r_done;
    logic [2:0] perm_idx;
    logic [1:0] shard_cnt;
    logic [7:0] over_timer;

    // Undo Snapshot
    logic       undo_valid;
    logic [2:0] undo_idx;
    logic [3:0] undo_A, undo_B, undo_C;
    logic       undo_has_A, undo_has_B, undo_has_C;
    logic       undo_done_bit, undo_right_bit;

    wire [2:0] done_count = done_mask[0] + done_mask[1] + done_mask[2] + done_mask[3] + done_mask[4];

    // ---- Main Game FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_PLAY; in_closeup <= 1'b0; cur_obj <= OBJ_NONE; page <= 2'd0;
            lights <= 1'b1; hearts <= 2'd3; armor <= 2'd0; form <= 2'd0;
            done_mask <= 5'd0; right_mask <= 5'd0;
            card_active <= 1'b0; card_round <= 2'd1; card_cursor <= 2'd1; card_flipped <= 1'b0;
            career <= 2'd0; last_item <= ITEM_NONE; r_run <= 3'd0; r_done <= 3'd0; perm_idx <= 3'd0;
            slow_timer <= 12'd0; freeze_timer <= 12'd0; flash_timer <= 5'd0; over_timer <= 8'd0;
            ans_A <= 4'd0; ans_B <= 4'd0; ans_C <= 4'd0; has_A <= 1'b0; has_B <= 1'b0; has_C <= 1'b0;
            p2_cur <= 2'd0; for (int i=0;i<3;i++) begin p2_used[i]<=0; p2_pol[i]<=0; end
            p3_cur <= 4'd0; for (int i=0;i<9;i++) p3_cfg[i] <= 3'd0;
            p5_cur <= 2'd0; for (int i=0;i<3;i++) p5_chr[i] <= 5'd0;
            door_layer <= 1'b0; door_cur <= 3'd0; for (int i=0;i<5;i++) door_dig[i] <= 4'd0;
            hints_seen <= 5'd0; shard_cnt <= 2'd0; undo_valid <= 1'b0; reset_stage_pulse <= 1'b0;
        end else begin
            reset_stage_pulse <= 1'b0;

            // 60Hz Timers
            if (tick_60hz) begin
                if (flash_timer  != 0) flash_timer  <= flash_timer  - 5'd1;
                if (state == ST_PLAY) begin
                    if (slow_timer   != 0) slow_timer   <= slow_timer   - 12'd1;
                    if (freeze_timer != 0) freeze_timer <= freeze_timer - 12'd1;
                end else if (state == ST_OVER) begin
                    if (over_timer != 0) over_timer <= over_timer - 8'd1;
                    else begin
                        // Auto-restart Stage 1
                        state <= ST_PLAY; in_closeup <= 1'b0; hearts <= 2'd3; armor <= 2'd0;
                        done_mask <= 5'd0; right_mask <= 5'd0; r_run <= 3'd0; r_done <= 3'd0;
                        slow_timer <= 0; freeze_timer <= 0; door_layer <= 0; door_cur <= 0;
                        has_A <= 0; has_B <= 0; has_C <= 0; hints_seen <= 0; undo_valid <= 0;
                        reset_stage_pulse <= 1'b1;
                    end
                end
            end

            // Stage Clear -> Tap to restart
            if (state == ST_CLEAR) begin
                if (tap_c) begin
                    state <= ST_PLAY; form <= 2'd0; hearts <= 2'd3; armor <= 2'd0;
                    done_mask <= 5'd0; right_mask <= 5'd0; r_run <= 3'd0; r_done <= 3'd0;
                    in_closeup <= 1'b0; door_layer <= 0; reset_stage_pulse <= 1'b1;
                end
            end
            // Play State
            else if (state == ST_PLAY) begin
                // 1. Card Trigger Check
                if (!card_active) begin
                    if (!r_run[0]) begin
                        card_active <= 1'b1; card_round <= 2'd1; card_cursor <= 2'd1; card_flipped <= 1'b0;
                        r_run[0] <= 1'b1; perm_idx <= (lfsr[2:0] < 3'd6) ? lfsr[2:0] : (lfsr[2:0] - 3'd2);
                    end else if (r_done[0] && !r_run[1] && done_count >= 3'd3) begin
                        card_active <= 1'b1; card_round <= 2'd2; card_cursor <= 2'd1; card_flipped <= 1'b0;
                        r_run[1] <= 1'b1; perm_idx <= (lfsr[2:0] < 3'd6) ? lfsr[2:0] : (lfsr[2:0] - 3'd2);
                    end else if (r_done[1] && !r_run[2] && done_count == 3'd5) begin
                        card_active <= 1'b1; card_round <= 2'd3; card_cursor <= 2'd1; card_flipped <= 1'b0;
                        r_run[2] <= 1'b1; perm_idx <= (lfsr[2:0] < 3'd6) ? lfsr[2:0] : (lfsr[2:0] - 3'd2);
                    end
                end

                // 2. Card Selection Input
                if (card_active) begin
                    if (!card_flipped) begin
                        if (pulse_l) card_cursor <= (card_cursor == 2'd0) ? 2'd2 : card_cursor - 2'd1;
                        if (pulse_r) card_cursor <= (card_cursor == 2'd2) ? 2'd0 : card_cursor + 2'd1;
                        if (tap_c) begin
                            logic [1:0] c_idx;
                            item_id_t it;
                            card_flipped <= 1'b1;
                            c_idx = PERMS[perm_idx][card_cursor];
                            if (card_round == 2'd1) career <= c_idx;
                            it = get_card_item(card_round, c_idx);
                            last_item <= it;

                            // Apply Item Effect Immediately
                            case (it)
                                ITEM_HINT_HARD: hints_seen[2] <= 1'b1; // P3 hint
                                ITEM_ARMOR:     if (armor < 2'd3) armor <= armor + 2'd1;
                                ITEM_SLOW:      slow_timer   <= SLOW_FRAMES[11:0];
                                ITEM_FREEZE:    freeze_timer <= FREEZE_FRAMES[11:0];
                                ITEM_SHARD: begin
                                    if (shard_cnt >= 2'd1) begin
                                        shard_cnt <= 2'd0;
                                        if (armor < 2'd3) armor <= armor + 2'd1;
                                    end else shard_cnt <= shard_cnt + 2'd1;
                                end
                                ITEM_HINT_SMART: begin
                                    if (!done_mask[4])       hints_seen[4] <= 1'b1; // P5
                                    else if (!right_mask[2]) hints_seen[2] <= 1'b1; // P3
                                    else if (!right_mask[1]) hints_seen[1] <= 1'b1; // P2
                                    else if (!right_mask[0]) hints_seen[0] <= 1'b1; // P1
                                    else if (!right_mask[3]) hints_seen[3] <= 1'b1; // P4
                                end
                                ITEM_UNDO: begin
                                    if (undo_valid) begin
                                        ans_A <= undo_A; ans_B <= undo_B; ans_C <= undo_C;
                                        has_A <= undo_has_A; has_B <= undo_has_B; has_C <= undo_has_C;
                                        done_mask[undo_idx]  <= undo_done_bit;
                                        right_mask[undo_idx] <= undo_right_bit;
                                        undo_valid <= 1'b0;
                                    end
                                end
                                default: ;
                            endcase
                        end
                    end else if (tap_c) begin
                        card_active <= 1'b0;
                        r_done[card_round - 2'd1] <= 1'b1;
                    end
                end
                // 3. Map Mode -> Open Close-up
                else if (!sw[14] && !in_closeup) begin
                    if (tap_c && near_obj != OBJ_NONE) begin
                        in_closeup <= 1'b1;
                        cur_obj    <= near_obj;
                        page       <= 2'd0;
                    end
                end
                // 4. Close-up Mode Input
                else if (!sw[14] && in_closeup) begin
                    if (back_c) begin
                        if (page > 0 && (cur_obj == OBJ_WHITEBOARD || cur_obj == OBJ_PAPER ||
                                         cur_obj == OBJ_LAPTOP3    || cur_obj == OBJ_LAPTOP4 ||
                                         cur_obj == OBJ_PC))
                            page <= page - 2'd1;
                        else
                            in_closeup <= 1'b0;
                    end else begin
                        case (cur_obj)
                            // ---- P1: Whiteboard ----
                            OBJ_WHITEBOARD: begin
                                if (tap_c) begin
                                    if (page == 2'd0) page <= 2'd1;
                                    else begin
                                        undo_valid <= 1'b1; undo_idx <= 3'd0;
                                        undo_A <= ans_A; undo_B <= ans_B; undo_C <= ans_C;
                                        undo_has_A <= has_A; undo_has_B <= has_B; undo_has_C <= has_C;
                                        undo_done_bit <= done_mask[0]; undo_right_bit <= right_mask[0];
                                        ans_A <= sw[3:0]; has_A <= 1'b1;
                                        done_mask[0] <= 1'b1; right_mask[0] <= (sw[3:0] == ANS_A);
                                    end
                                end
                            end
                            // ---- P2: Paper K-Map ----
                            OBJ_PAPER: begin
                                if (page == 2'd0) begin
                                    if (tap_c) page <= 2'd1;
                                end else begin
                                    if (pulse_l) p2_cur <= (p2_cur == 2'd0) ? 2'd2 : p2_cur - 2'd1;
                                    if (pulse_r) p2_cur <= (p2_cur == 2'd2) ? 2'd0 : p2_cur + 2'd1;
                                    if (tap_c)   begin p2_used[p2_cur] <= sw[7:4]; p2_pol[p2_cur] <= sw[3:0]; end
                                    if (pulse_d) begin p2_used[p2_cur] <= 4'd0;    p2_pol[p2_cur] <= 4'd0;    end
                                    if (pulse_u && (p2_used[0] != 0 || p2_used[1] != 0 || p2_used[2] != 0)) begin
                                        undo_valid <= 1'b1; undo_idx <= 3'd1;
                                        undo_A <= ans_A; undo_B <= ans_B; undo_C <= ans_C;
                                        undo_has_A <= has_A; undo_has_B <= has_B; undo_has_C <= has_C;
                                        undo_done_bit <= done_mask[1]; undo_right_bit <= right_mask[1];
                                        done_mask[1]  <= 1'b1;
                                        right_mask[1] <= (p2_truth_comb == P2_TRUTH) && (p2_lits_comb <= 4'd4);
                                    end
                                end
                            end
                            // ---- P3: Laptop 3 (Quad NAND) ----
                            OBJ_LAPTOP3: begin
                                if (page == 2'd0) begin
                                    if (tap_c) page <= 2'd1;
                                end else begin
                                    logic [2:0] max_src;
                                    max_src = (p3_cur == 4'd8) ? 3'd3 : (3'd3 + p3_cur[3:1]);
                                    if (pulse_l) p3_cur <= (p3_cur == 4'd0) ? 4'd8 : p3_cur - 4'd1;
                                    if (pulse_r) p3_cur <= (p3_cur == 4'd8) ? 4'd0 : p3_cur + 4'd1;
                                    if (pulse_u) p3_cfg[p3_cur] <= (p3_cfg[p3_cur] >= max_src) ? 3'd0 : p3_cfg[p3_cur] + 3'd1;
                                    if (pulse_d) p3_cfg[p3_cur] <= (p3_cfg[p3_cur] == 3'd0) ? max_src : p3_cfg[p3_cur] - 3'd1;
                                    if (tap_c) begin
                                        undo_valid <= 1'b1; undo_idx <= 3'd2;
                                        undo_A <= ans_A; undo_B <= ans_B; undo_C <= ans_C;
                                        undo_has_A <= has_A; undo_has_B <= has_B; undo_has_C <= has_C;
                                        undo_done_bit <= done_mask[2]; undo_right_bit <= right_mask[2];
                                        ans_B <= popcount16(p3_truth_out)[3:0]; has_B <= 1'b1;
                                        done_mask[2]  <= 1'b1;
                                        right_mask[2] <= (p3_truth_out == P2_TRUTH);
                                    end
                                end
                            end
                            // ---- P4: Laptop 4 (Two's Complement) ----
                            OBJ_LAPTOP4: begin
                                if (tap_c) begin
                                    if (page == 2'd0) page <= 2'd1;
                                    else begin
                                        undo_valid <= 1'b1; undo_idx <= 3'd3;
                                        undo_A <= ans_A; undo_B <= ans_B; undo_C <= ans_C;
                                        undo_has_A <= has_A; undo_has_B <= has_B; undo_has_C <= has_C;
                                        undo_done_bit <= done_mask[3]; undo_right_bit <= right_mask[3];
                                        ans_C <= popcount8(sw[7:0]); has_C <= 1'b1;
                                        done_mask[3]  <= 1'b1;
                                        right_mask[3] <= (sw[7:0] == P4_ANSWER);
                                    end
                                end
                            end
                            // ---- Light Switch ----
                            OBJ_LIGHTSW: begin
                                if (tap_c) lights <= ~lights;
                            end
                            // ---- P5: Teacher PC ----
                            OBJ_PC: begin
                                if (!done_mask[4]) begin
                                    if (pulse_u) p5_cur <= (p5_cur == 2'd0) ? 2'd2 : p5_cur - 2'd1;
                                    if (pulse_d) p5_cur <= (p5_cur == 2'd2) ? 2'd0 : p5_cur + 2'd1;
                                    if (pulse_l) p5_chr[p5_cur] <= (p5_chr[p5_cur] == 5'd0)  ? 5'd25 : p5_chr[p5_cur] - 5'd1;
                                    if (pulse_r) p5_chr[p5_cur] <= (p5_chr[p5_cur] == 5'd25) ? 5'd0  : p5_chr[p5_cur] + 5'd1;
                                    if (tap_c) begin
                                        if (p5_chr[0] == PC_PASS_0 && p5_chr[1] == PC_PASS_1 && p5_chr[2] == PC_PASS_2) begin
                                            undo_valid <= 1'b1; undo_idx <= 3'd4;
                                            undo_A <= ans_A; undo_B <= ans_B; undo_C <= ans_C;
                                            undo_has_A <= has_A; undo_has_B <= has_B; undo_has_C <= has_C;
                                            undo_done_bit <= done_mask[4]; undo_right_bit <= right_mask[4];
                                            done_mask[4] <= 1'b1; right_mask[4] <= 1'b1;
                                            page <= 2'd0;
                                        end
                                    end
                                end else begin
                                    if ((pulse_d || tap_c) && page < 2'd2) page <= page + 2'd1;
                                    if (pulse_u && page > 2'd0)            page <= page - 2'd1;
                                end
                            end
                            // ---- Exit Door (2 Layers) ----
                            OBJ_DOOR: begin
                                logic [2:0] max_d;
                                max_d = door_layer ? 3'd4 : 3'd1;
                                if (pulse_l) door_cur <= (door_cur == 3'd0) ? max_d : door_cur - 3'd1;
                                if (pulse_r) door_cur <= (door_cur >= max_d) ? 3'd0 : door_cur + 3'd1;
                                if (pulse_u) door_dig[door_cur] <= (door_dig[door_cur] == 4'd9) ? 4'd0 : door_dig[door_cur] + 4'd1;
                                if (pulse_d) door_dig[door_cur] <= (door_dig[door_cur] == 4'd0) ? 4'd9 : door_dig[door_cur] - 4'd1;
                                if (tap_c) begin
                                    logic ok;
                                    if (!door_layer)
                                        ok = (door_dig[0] == L1_D0 && door_dig[1] == L1_D1);
                                    else
                                        ok = (door_dig[0] == L2_D0 && door_dig[1] == L2_D1 &&
                                              door_dig[2] == L2_D2 && door_dig[3] == L2_D3 && door_dig[4] == L2_D4);

                                    if (ok) begin
                                        for (int i=0;i<5;i++) door_dig[i] <= 4'd0;
                                        door_cur <= 3'd0;
                                        if (!door_layer) door_layer <= 1'b1;
                                        else begin state <= ST_CLEAR; form <= 2'd1; in_closeup <= 1'b0; end
                                    end else begin
                                        if (armor > 2'd0) armor <= armor - 2'd1;
                                        else begin
                                            flash_timer <= FLASH_FRAMES[4:0];
                                            if (hearts <= 2'd1) begin
                                                hearts <= 2'd0; state <= ST_OVER; over_timer <= OVER_FRAMES[7:0];
                                            end else hearts <= hearts - 2'd1;
                                        end
                                    end
                                end
                            end
                            default: ;
                        endcase
                    end
                end
            end
        end
    end
endmodule