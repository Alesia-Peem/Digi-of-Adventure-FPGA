// game_defs.vh - constants shared by all stages (include inside a module body).
// Item IDs = the strings of CARD_ITEMS / ITEM_TEXT in the Pygame demos.
localparam [3:0] IT_NONE = 4'd0, IT_HINT_HARD = 4'd1, IT_BOOST = 4'd2, IT_ARMOR = 4'd3, IT_SHARD = 4'd4,
                 IT_SLOW = 4'd5, IT_HINT_SMART = 4'd6, IT_FREEZE = 4'd7, IT_UNDO = 4'd8;
// 7-segment character codes (seven_seg.v), the SEG_MAP keys of the Pygame demos
localparam [4:0] SG_H = 5'd10, SG_DASH = 5'd11, SG_BLANK = 5'd12, SG_E = 5'd13, SG_P = 5'd14, SG_C = 5'd15,
                 SG_A = 5'd16, SG_F = 5'd17, SG_L = 5'd18, SG_O = 5'd19, SG_U = 5'd20, SG_D = 5'd21,
                 SG_S = 5'd22;
