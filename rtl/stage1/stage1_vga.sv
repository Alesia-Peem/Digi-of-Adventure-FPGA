import stage1_pkg::*;

module stage1_vga (
    input  logic        clk_25m,
    input  logic        rst_n,
    input  game_state_t state,
    input  logic        in_closeup,
    input  obj_id_t     cur_obj,
    input  logic        lights,
    input  logic        notebook_open,
    input  logic        card_active,
    input  logic [1:0]  card_cursor,
    input  logic        card_flipped,
    input  logic [1:0]  hearts, armor,
    input  logic [11:0] slow_timer, freeze_timer,
    input  logic [4:0]  flash_timer,
    input  logic [11:0] px, py,
    input  logic [1:0]  spr_dir, spr_pose,
    output logic        vga_hs, vga_vs,
    output logic [3:0]  vga_r, vga_g, vga_b
);
    // 640x480 @ 60Hz Timing
    logic [9:0] hx, vy;
    always_ff @(posedge clk_25m or negedge rst_n) begin
        if (!rst_n) begin hx <= 0; vy <= 0; end
        else if (hx == 10'd799) begin
            hx <= 0;
            vy <= (vy == 10'd524) ? 10'd0 : vy + 10'd1;
        end else hx <= hx + 10'd1;
    end

    assign vga_hs = ~(hx >= 10'd656 && hx < 10'd752);
    assign vga_vs = ~(vy >= 10'd490 && vy < 10'd492);
    wire active   = (hx < 10'd640 && vy < 10'd480);

    // Camera (maps 640x480 view onto 2000x1116 world at 1:2 scale -> 1280x960 or 1000x750)
    int cam_x, cam_y, wx, wy;
    always_comb begin
        cam_x = int'(px) - 500;
        if (cam_x < 0) cam_x = 0; else if (cam_x > WORLD_W - 1000) cam_x = WORLD_W - 1000;
        cam_y = int'(py) - 435;
        if (cam_y < 0) cam_y = 0; else if (cam_y > WORLD_H - 750)  cam_y = WORLD_H - 750;
        wx = cam_x + ((int'(hx) * 1000) / 640);
        wy = cam_y + ((int'(vy) * 750)  / 480);
    end

    // Optional BRAM ROMs (populated by tools/img_to_mem.py)
    // Background downsampled to 250x140 RGB444 (fits comfortably in FPGA BRAM)
    (* rom_style = "block" *) logic [11:0] bg_rom [0:34999];
    initial $readmemh("assets/finalexam.mem", bg_rom);

    logic [11:0] rgb;
    always_comb begin
        rgb = 12'h121; // dark slate default

        if (state == ST_CLEAR) begin
            rgb = 12'h142; // Green clear screen
        end else if (state == ST_OVER) begin
            rgb = 12'h411; // Red game over screen
        end else if (card_active) begin
            rgb = 12'h112;
            // 3 Cards
            for (int c = 0; c < 3; c++) begin
                int cx0 = 80 + c * 180;
                if (hx >= cx0 && hx < cx0 + 120 && vy >= 120 && vy < 300)
                    rgb = (card_cursor == c && !card_flipped) ? 12'hFF8 : 12'h557;
            end
        end else if (notebook_open) begin
            rgb = (hx >= 60 && hx < 580 && vy >= 50 && vy < 430) ? 12'h223 : 12'h111;
        end else if (in_closeup) begin
            rgb = (hx >= 40 && hx < 600 && vy >= 60 && vy < 420) ?
                  ((cur_obj == OBJ_WHITEBOARD || cur_obj == OBJ_PAPER) ? 12'hEEE : 12'h123) : 12'h223;
        end else begin
            // World View from BG ROM
            int bx = (wx >> 3); // 2000 / 8 = 250
            int by = (wy >> 3); // 1116 / 8 = 139
            if (bx >= 0 && bx < 250 && by >= 0 && by < 140)
                rgb = bg_rom[by * 250 + bx];

            // Player Sprite Box (replace with sprite_rom lookup when .mem is loaded)
            if (wx >= int'(px) - 23 && wx < int'(px) + 23 && wy >= int'(py) - 92 && wy < int'(py) + 4)
                rgb = (spr_pose == 2'd0) ? 12'h37E : 12'h59F;

            // Darkness when lights OFF
            if (!lights) rgb = {1'b0, rgb[11:9], 1'b0, rgb[7:5], 1'b0, rgb[3:1]};
        end

        // HUD: Hearts (top-left) & Armor
        for (int h = 0; h < 3; h++) begin
            if (hx >= 16 + h*24 && hx < 32 + h*24 && vy >= 14 && vy < 30)
                rgb = (h < hearts) ? 12'hE33 : 12'h522;
        end
        if (armor > 0 && hx >= 96 && hx < 114 && vy >= 12 && vy < 32)
            rgb = 12'h4BF;
        if (slow_timer > 0 && hx >= 140 && hx < 200 && vy >= 16 && vy < 26)
            rgb = 12'hFA4;
        if (freeze_timer > 0 && hx >= 210 && hx < 270 && vy >= 16 && vy < 26)
            rgb = 12'h8DF;

        // Red Damage Flash
        if (flash_timer > 0) rgb = 12'hF22;
    end

    assign {vga_r, vga_g, vga_b} = active ? rgb : 12'h000;
endmodule