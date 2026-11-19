import stage1_pkg::*;

module stage1_world (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        reset_pos,
    input  logic        tick_60hz,
    input  logic        can_move,      // 1 เมื่ออยู่โหมด map, ไม่เปิดสมุด, ไม่เปิดการ์ด
    input  logic        hold_u, hold_d, hold_l, hold_r,
    input  logic [1:0]  form,
    input  logic        is_slow,
    input  logic        is_freeze,
    output logic [11:0] px,
    output logic [11:0] py,
    output logic [1:0]  spr_dir,       // 0:front, 1:back, 2:left, 3:right
    output logic [1:0]  spr_pose,      // 0:stand, 1:stepl, 2:stepr
    output obj_id_t     near_obj
);
    // Floor boundary: left = 600 - 0.76*(y-355), right = 1440 + 0.714*(y-350)
    function automatic logic point_outside_floor(input int x, input int y);
        int fl, fr;
        fl = 600  - ((195 * (y - 355)) >>> 8);
        fr = 1440 + ((183 * (y - 350)) >>> 8);
        return (y < FLOOR_TOP || y > FLOOR_BOT || x < fl || x > fr);
    endfunction

    function automatic logic rect_overlap(
        input int ax, ay, aw, ah,
        input int bx, by, bw, bh
    );
        return (ax < bx + bw) && (ax + aw > bx) && (ay < by + bh) && (ay + ah > by);
    endfunction

    function automatic logic is_blocked(input int x, input int y);
        int rx, ry, rw, rh;
        rx = x - FEET_HW;
        ry = y - FEET_H;
        rw = FEET_HW * 2;
        rh = FEET_H;
        if (point_outside_floor(rx, ry) ||
            point_outside_floor(rx + rw, ry) ||
            point_outside_floor(rx, ry + rh) ||
            point_outside_floor(rx + rw, ry + rh))
            return 1'b1;

        // 8 Blockers from stage1(2).py
        if (rect_overlap(rx, ry, rw, rh,  620, 300,  200,  70)) return 1'b1; // grey cabinet
        if (rect_overlap(rx, ry, rw, rh,  815, 250,  140, 120)) return 1'b1; // shelf
        if (rect_overlap(rx, ry, rw, rh,  450, 440,  125, 120)) return 1'b1; // lockers
        if (rect_overlap(rx, ry, rw, rh,  100, 880,  200, 125)) return 1'b1; // low cabinet
        if (rect_overlap(rx, ry, rw, rh,  640, 435,  710, 150)) return 1'b1; // table row 1
        if (rect_overlap(rx, ry, rw, rh,  520, 615,  885, 170)) return 1'b1; // table row 2
        if (rect_overlap(rx, ry, rw, rh,  345, 860, 1125, 170)) return 1'b1; // table row 3
        if (rect_overlap(rx, ry, rw, rh, 1490, 525,  225, 250)) return 1'b1; // teacher desk
        return 1'b0;
    endfunction

    // Speed per 60Hz frame (BASE_SPEED = 360 px/s -> 6 px/frame)
    int step_px;
    always_comb begin
        if (is_freeze)       step_px = 0;
        else if (is_slow)    step_px = (form >= 2'd1) ? 4 : 3;
        else                 step_px = (form >= 2'd1) ? 7 : 6;
    end

    // Walk animation state (player_sprite.py: STEP_TIME = 0.14s ≈ 8 frames)
    logic       moving;
    logic [3:0] anim_cnt;
    logic [1:0] walk_idx; // 0:stepl, 1:stand, 2:stepr, 3:stand

    always_comb begin
        if (!moving) spr_pose = 2'd0;
        else begin
            case (walk_idx)
                2'd0: spr_pose = 2'd1; // stepl
                2'd2: spr_pose = 2'd2; // stepr
                default: spr_pose = 2'd0; // stand
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || reset_pos) begin
            px       <= SPAWN_X[11:0];
            py       <= SPAWN_Y[11:0];
            spr_dir  <= 2'd0; // front
            moving   <= 1'b0;
            anim_cnt <= 4'd0;
            walk_idx <= 2'd0;
        end else if (tick_60hz) begin
            if (!can_move) begin
                moving   <= 1'b0;
                anim_cnt <= 4'd0;
                walk_idx <= 2'd0;
            end else begin
                int dx, dy, nx, ny;
                logic did_move;
                dx = (hold_r ? 1 : 0) - (hold_l ? 1 : 0);
                dy = (hold_d ? 1 : 0) - (hold_u ? 1 : 0);
                nx = int'(px) + dx * step_px;
                ny = int'(py) + dy * step_px;

                did_move = 1'b0;
                if (dx != 0 && !is_blocked(nx, int'(py))) begin
                    px <= nx[11:0];
                    did_move = 1'b1;
                end
                if (dy != 0 && !is_blocked(int'(px), ny)) begin
                    py <= ny[11:0];
                    did_move = 1'b1;
                end

                // Facing direction (Left/Right wins over Up/Down)
                if (dx > 0)      spr_dir <= 2'd3; // right
                else if (dx < 0) spr_dir <= 2'd2; // left
                else if (dy > 0) spr_dir <= 2'd0; // front
                else if (dy < 0) spr_dir <= 2'd1; // back

                if (did_move) begin
                    if (!moving) begin
                        moving   <= 1'b1;
                        anim_cnt <= 4'd0;
                        walk_idx <= 2'd0; // always start with left leg
                    end else if (anim_cnt >= 4'd7) begin
                        anim_cnt <= 4'd0;
                        walk_idx <= walk_idx + 2'd1;
                    end else begin
                        anim_cnt <= anim_cnt + 4'd1;
                    end
                end else begin
                    moving   <= 1'b0;
                    anim_cnt <= 4'd0;
                    walk_idx <= 2'd0;
                end
            end
        end
    end

    // Proximity Check (find_near)
    localparam int OBJ_AX [1:8] = '{300, 700, 1370, 570, 1560, 1540, 1150, 1340};
    localparam int OBJ_AY [1:8] = '{580, 400,  920, 690,  400,  620,  310,  300};
    localparam int OBJ_R  [1:8] = '{180, 130,  190, 150,  120,  120,  100,  120};

    always_comb begin
        int bonus, d2, r2, best_d2;
        bonus   = (form >= 2'd1) ? 30 : 0;
        near_obj = OBJ_NONE;
        best_d2  = 32'h7FFF_FFFF;

        for (int i = 1; i <= 8; i++) begin
            int dx, dy, rad;
            dx  = int'(px) - OBJ_AX[i];
            dy  = int'(py) - OBJ_AY[i];
            rad = OBJ_R[i] + bonus;
            d2  = dx * dx + dy * dy;
            r2  = rad * rad;
            if (d2 <= r2 && d2 < best_d2) begin
                best_d2  = d2;
                near_obj = obj_id_t'(i);
            end
        end
    end
endmodule