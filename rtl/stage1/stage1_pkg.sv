package stage1_pkg;
    // ---- Puzzle Constants ----
    localparam logic [3:0]  ANS_A      = 4'd6;          // 0x2A - 0b10011 - 0o21 = 6
    localparam logic [15:0] P2_TRUTH   = 16'hF888;      // F = AB + CD
    localparam logic [3:0]  ANS_B      = 4'd7;          // popcount(16'hF888) = 7
    localparam logic [7:0]  P4_ANSWER  = 8'b1111_0100;  // -12 in 8-bit two's complement
    localparam logic [3:0]  ANS_C      = 4'd5;          // popcount(8'b11110100) = 5

    // PC Passcode "CPE" -> (2, 15, 4)
    localparam logic [4:0]  PC_PASS_0  = 5'd2;
    localparam logic [4:0]  PC_PASS_1  = 5'd15;
    localparam logic [4:0]  PC_PASS_2  = 5'd4;

    // Door Lock Codes: Layer 1 = 69, Layer 2 = 17865
    localparam logic [3:0]  L1_D0 = 4'd6, L1_D1 = 4'd9;
    localparam logic [3:0]  L2_D0 = 4'd1, L2_D1 = 4'd7, L2_D2 = 4'd8, L2_D3 = 4'd6, L2_D4 = 4'd5;

    // ---- World & Physics (60 Hz tick) ----
    localparam int WORLD_W   = 2000;
    localparam int WORLD_H   = 1116;
    localparam int SPAWN_X   = 1300;
    localparam int SPAWN_Y   = 405;
    localparam int FEET_HW   = 18;
    localparam int FEET_H    = 22;
    localparam int FLOOR_TOP = 360;
    localparam int FLOOR_BOT = 1085;

    // Timers (in 60Hz frames)
    localparam int SLOW_FRAMES   = 30 * 60;  // 30 seconds = 1800 frames
    localparam int FREEZE_FRAMES = 15 * 60;  // 15 seconds = 900 frames
    localparam int OVER_FRAMES   = 3  * 60;  // 3 seconds Game Over delay
    localparam int FLASH_FRAMES  = 24;       // 0.4 seconds red flash

    // ---- Object IDs ----
    typedef enum logic [3:0] {
        OBJ_NONE       = 4'd0,
        OBJ_WHITEBOARD = 4'd1,
        OBJ_PAPER      = 4'd2,
        OBJ_LAPTOP3    = 4'd3,
        OBJ_LAPTOP4    = 4'd4,
        OBJ_PROJECTOR  = 4'd5,
        OBJ_PC         = 4'd6,
        OBJ_LIGHTSW    = 4'd7,
        OBJ_DOOR       = 4'd8
    } obj_id_t;

    // ---- Game States ----
    typedef enum logic [1:0] {
        ST_PLAY  = 2'd0,
        ST_OVER  = 2'd1,
        ST_CLEAR = 2'd2
    } game_state_t;

    // ---- Card Items ----
    typedef enum logic [3:0] {
        ITEM_NONE       = 4'd0,
        ITEM_HINT_HARD  = 4'd1,
        ITEM_ARMOR      = 4'd2,
        ITEM_SHARD      = 4'd3,
        ITEM_SLOW       = 4'd4,
        ITEM_HINT_SMART = 4'd5,
        ITEM_FREEZE     = 4'd6,
        ITEM_UNDO       = 4'd7
    } item_id_t;

    // Helper: 16-bit popcount
    function automatic logic [4:0] popcount16(input logic [15:0] v);
        int i;
        logic [4:0] c;
        c = 0;
        for (i = 0; i < 16; i++) c = c + v[i];
        return c;
    endfunction

    // Helper: 8-bit popcount
    function automatic logic [3:0] popcount8(input logic [7:0] v);
        int i;
        logic [3:0] c;
        c = 0;
        for (i = 0; i < 8; i++) c = c + v[i];
        return c;
    endfunction
endpackage