// line_renderer.v - shared display engine for every stage.
//
// HOW IT WORKS (why this architecture: see docs/ARCHITECTURE.md)
//  * The visible game area is 640 x 360 (the Pygame 960x540 UI scaled by 2/3), letter-boxed in
//    the 640 x 480 VGA frame at rows 60..419. Rows 0..59 and 420..479 are black.
//  * Layer 0 = BACKGROUND, read per pixel at scan-out time:
//      bg_mode 0 solid colour | 1 Stage-1 room ROM with camera (2x upscale)
//              2 Stage-2 room ROM, 1:1 or zoomed (src = zoom_o + screen * zoom_inv / 65536)
//              3 Stage-3 sky: vertical gradient SKY0 -> SKY1 kept at 8 bit per channel, 2x2 ordered dither
//                to the 4-bit DAC (the demo's gradient would otherwise show 4-bit bands) | 4 Stage-2 board
//  * Everything else (UI rectangles, circles, text, player sprite, cards, overlays) is a DISPLAY LIST
//    of primitives (written once per frame by ui_composer during vblank). While line N is being
//    shown, the engine walks the list and "paints" line N+1 into a line buffer, in list order, using
//    the same "over" alpha blending as Pygame's blit/fill with set_alpha -> Pygame's draw order
//    (painter's algorithm) is reproduced exactly.
//  * Line-buffer entry = {k[4:0], R[3:0], G[3:0], B[3:0]}: final pixel = bg * k/16 + RGB
//    (premultiplied alpha). Empty entry = {16, 0,0,0} = "show background".
//  * Two line buffers ping-pong on line parity; the scan-out side clears each entry after reading it.
//
// DISPLAY LIST ENTRY (64 bit)          type = [63:61]
//   1 RECT   / 2 CLRBG : x0[60:50] y0[49:40] x1[39:29] y1[28:19] (x1,y1 exclusive) colour[18:7] alpha[6:2]
//   3 CIRCLE           : cx[60:50] cy[49:40] r[39:35] r_inner[34:30] colour[29:18] alpha[17:13]
//   4 TEXT             : x0[60:50] y0[49:40] colour[39:28] scale2[27] ptr[26:15] len[14:8] small[7]
//                        font: 8x16 (scale2 -> 16x32) or small 6x12 (small=1)
//   5 SPRITE           : x0[60:50] y0[49:40] img[39:34] scale_m1[33:32] flipx[31] step[30:22]
//                        step = 0: integer scale 1..4; else fractional: source px per screen px x 256
//   6 WIRES            : draws every wire of the breadboard (Stage 2) from wire_src[] (see below)
//   7 STAGE 3          : sub[60:59] x0[58:48] y0[47:38] id[37:32] colour[31:20]
//                        sub 0 WATER   wavy surface 296 + 2 sin(..), alpha 14/16 (draw() water_layer)
//                        sub 1 TERRAIN every solid of the level from s3_solid.mem, camera s3_cam (draw_terrain)
//                        sub 2 TEXTIMG 1-bit bitmap string id (Thai text rendered by the demo's font) at x0,y0
//                        sub 3 HILLS   y >= 200 - 35 sin(..) in colour (draw() hill polygon)
//   0 END
//   x = signed 11 bit, y = signed 10 bit (game-area pixels). alpha 0..16 (16 = opaque).
//   CLRBG resets pixels to "show background" (used to put scenery back in front of the player).
`timescale 1ns/1ps
module line_renderer #(
    parameter BG1_FILE  = "mem/bg_s1.mem",
    parameter PAL1_FILE = "mem/bg_s1_pal.mem",
    parameter BG2_FILE  = "mem/bg_s2.mem",
    parameter PAL2_FILE = "mem/bg_s2_pal.mem",
    parameter SPR_FILE  = "mem/spr.mem",
    parameter SPAL_FILE = "mem/spr_pal.mem",
    parameter FONT_FILE = "mem/font8x16.mem",
    parameter CIRC_FILE = "mem/circ.mem",
    parameter BT_FILE   = "mem/s2_btile.mem",
    parameter BM_FILE   = "mem/s2_bmap.mem",
    parameter BP_FILE   = "mem/s2_bpal.mem",
    parameter WIRE_FILE = "mem/s2_wire.mem",
    parameter S3S_FILE  = "mem/s3_solid.mem",
    parameter S3T_FILE  = "mem/s3_txt.mem",
    parameter S3I_FILE  = "mem/s3_tidx.mem",
    parameter SIN_FILE  = "mem/sin256.mem",
    parameter [23:0] SKY0 = 24'h58B4EE,       // stage3_demo.py sky: top colour
    parameter [23:0] SKY1 = 24'hD3F0FC        //                     bottom colour
) (
    input  wire        clk,
    input  wire        rst,
    // timing
    input  wire        pix_ce,
    input  wire [9:0]  hcount,
    input  wire [9:0]  vcount,
    input  wire        active,
    input  wire        hsync,
    input  wire        vsync,
    // background control (from the stage manager)
    input  wire [2:0]  bg_mode,
    input  wire [11:0] bg_color,
    input  wire [11:0] bg_color2,
    input  wire [10:0] cam_x,       // Stage-1 camera, screen pixels (0..640)
    input  wire [9:0]  cam_y,       // (0..354)
    input  wire [11:0] zoom_ox,     // bg_mode 2: top-left of the zoomed window (game px)
    input  wire [11:0] zoom_oy,
    input  wire [16:0] zoom_inv,    // 65536 / zoom factor (65536 = no zoom)
    // Stage 2 breadboard (WIRES primitive)
    input  wire [269:0] wire_src,   // 54 sinks x 5 bit: source index 1..27, 0 = no wire
    input  wire [27:0] src_val,     // logic value of every source (dark wire when 0)
    input  wire [6:0]  wire_hl,     // {enable, sink}: wire being edited is drawn yellow
    // Stage 3
    input  wire [15:0] hill_ph,     // hills phase (sine-table units x 256)
    input  wire [7:0]  wave_ph,     // water surface phase
    input  wire [12:0] s3_cam,      // camera, world px (32 px per metre)
    // display list + text RAM write ports (from ui_composer)
    input  wire        dl_we,
    input  wire [7:0]  dl_waddr,
    input  wire [63:0] dl_wdata,
    input  wire        tx_we,
    input  wire [11:0] tx_waddr,
    input  wire [6:0]  tx_wdata,
    // VGA pins (registered)
    output reg  [3:0]  vga_r,
    output reg  [3:0]  vga_g,
    output reg  [3:0]  vga_b,
    output reg         vga_hs,
    output reg         vga_vs,
    output reg         overflow     // sticky: a line had too many primitives (debug LED)
);
    localparam GY0 = 10'd60, GH = 10'd360;
    localparam [16:0] EMPTY = {5'd16, 12'h000};

    // ------------------------------------------------------------------ memories
    reg [63:0] dl_mem [0:255];
    reg [6:0]  tx_mem [0:4095];
    reg [7:0]  dl_raddr;
    reg [11:0] tx_raddr;
    reg [63:0] dl_q;
    reg [6:0]  tx_q;
    always @(posedge clk) begin
        if (dl_we) dl_mem[dl_waddr] <= dl_wdata;
        dl_q <= dl_mem[dl_raddr];
    end
    always @(posedge clk) begin
        if (tx_we) tx_mem[tx_waddr] <= tx_wdata;
        tx_q <= tx_mem[tx_raddr];
    end
    integer ii;
    initial begin
        for (ii = 0; ii < 256; ii = ii + 1) dl_mem[ii] = 64'd0;
        for (ii = 0; ii < 4096; ii = ii + 1) tx_mem[ii] = 7'd32;
    end

    reg  [11:0] font_addr;   wire [7:0]  font_q;
    reg  [9:0]  circ_addr;   wire [7:0]  circ_q;
    reg  [15:0] spr_addr;    wire [6:0]  spr_q;
    wire [11:0] spal_q;
    rom_sync #(.WIDTH(8),  .DEPTH(4096),  .AW(12), .MEM_FILE(FONT_FILE)) u_font (.clk(clk), .addr(font_addr), .q(font_q));
    rom_sync #(.WIDTH(8),  .DEPTH(1024),  .AW(10), .MEM_FILE(CIRC_FILE)) u_circ (.clk(clk), .addr(circ_addr), .q(circ_q));
    rom_sync #(.WIDTH(7),  .DEPTH(65536), .AW(16), .MEM_FILE(SPR_FILE))  u_spr  (.clk(clk), .addr(spr_addr),  .q(spr_q));
    rom_sync #(.WIDTH(12), .DEPTH(128),   .AW(7),  .MEM_FILE(SPAL_FILE)) u_spal (.clk(clk), .addr(spr_q[6:0]), .q(spal_q));

    // line buffers (bank = line parity)
    reg [16:0] lb0 [0:639];
    reg [16:0] lb1 [0:639];
    initial begin
        for (ii = 0; ii < 640; ii = ii + 1) begin lb0[ii] = EMPTY; lb1[ii] = EMPTY; end
    end

    // ------------------------------------------------------------------ draw engine
    localparam S_IDLE = 6'd0, S_FETCH = 6'd1, S_WAIT = 6'd2, S_DECODE = 6'd3, S_SPAN = 6'd4,
               S_CWAIT = 6'd5, S_CWAIT2 = 6'd6, S_CWAIT3 = 6'd7, S_TCHAR = 6'd8, S_TCW1 = 6'd9,
               S_TCW2 = 6'd10, S_TPIX = 6'd11, S_SPIX = 6'd12, S_SW1 = 6'd13, S_SW2 = 6'd14,
               S_DONE = 6'd15, S_WNEXT = 6'd16, S_WRD = 6'd17, S_WRD2 = 6'd18, S_WSEG = 6'd19,
               S_WSPAN = 6'd20, S_WGAP = 6'd21, S_T3 = 6'd22, S_TER = 6'd23, S_TERW = 6'd24, S_TERS = 6'd25,
               S_WAT = 6'd26, S_TI = 6'd27, S_TIW = 6'd28, S_TIB = 6'd29, S_TIBW = 6'd30, S_TIBITS = 6'd31, S_TERP = 6'd32;
    reg  [5:0]  st;
    reg  [9:0]  dgy;            // game-area line being drawn
    reg         dbank;
    reg  [7:0]  idx;
    reg  [2:0]  ptype;
    reg  signed [11:0] px, pxe;  // current x, end x (exclusive)
    reg  signed [11:0] ex0, ex1; // exclusion range for circle rings (inclusive)
    reg         excl;
    reg  [11:0] pcol;
    reg  [4:0]  palpha;
    reg         pclr;
    reg  signed [11:0] tx0;      // text / sprite origin x
    reg  [10:0] tpx, tw;         // pixel counter inside a text / sprite line, total width
    reg         tscale, tsmall;
    reg  [3:0]  tbit;            // pixel inside the current character
    reg  [6:0]  tci;             // character index
    reg  [11:0] tptr;
    reg  [3:0]  trow;
    reg  [7:0]  glyph;
    reg  [5:0]  simg;
    reg  [1:0]  sscm1;
    reg         sflip;
    reg  [4:0]  srow, ssx;
    reg  [2:0]  srep;
    reg  [4:0]  cr, cri;
    reg  signed [11:0] ccx;
    reg  [8:0]  sstep;           // fractional sprite step (0 = integer scale)
    reg  [13:0] sacc;            // fractional sprite source position x 256
    wire [13:0] sacc_n = sacc + {5'd0, sstep};
    // WIRES engine
    reg  [5:0]  wi;              // sink being drawn
    reg  [2:0]  wseg;            // which span of the current wire
    reg  [9:0]  wx1, wx2; reg [8:0] wy1, wy2, wym;
    reg  [4:0]  wsrc_c;

    // pixel request -> blend pipeline
    reg         a_v;  reg [9:0] a_x; reg [11:0] a_c; reg [4:0] a_a; reg a_clr; reg a_bank;
    reg         b_v;  reg [9:0] b_x; reg [11:0] b_c; reg [4:0] b_a; reg b_clr; reg b_bank;
    reg  [16:0] rq0, rq1;

    // scan-out side
    wire        in_game  = active && (vcount >= GY0) && (vcount < GY0 + GH);
    wire [9:0]  sgy      = vcount - GY0;
    wire        sbank    = sgy[0];
    reg  [9:0]  clr_x;   reg clr_v; reg clr_bank;

    // read addresses: draw bank uses pipeline stage A, the other bank is scanned
    wire [9:0]  rd0 = (a_bank == 1'b0 && a_v) ? a_x : hcount;
    wire [9:0]  rd1 = (a_bank == 1'b1 && a_v) ? a_x : hcount;
    always @(posedge clk) begin
        rq0 <= lb0[rd0];
        rq1 <= lb1[rd1];
    end

    // blend (stage B): entry over-composited with colour b_c at alpha b_a
    wire [16:0] bent = b_bank ? rq1 : rq0;
    wire [4:0]  ik   = 5'd16 - b_a;
    wire [8:0]  nk   = bent[16:12] * ik + 9'd8;
    wire [8:0]  nr   = bent[11:8] * ik + b_c[11:8] * b_a + 9'd8;
    wire [8:0]  ng   = bent[7:4]  * ik + b_c[7:4]  * b_a + 9'd8;
    wire [8:0]  nb   = bent[3:0]  * ik + b_c[3:0]  * b_a + 9'd8;
    wire [16:0] blended = b_clr ? EMPTY :
                          (b_a == 5'd16) ? {5'd0, b_c} :
                          {nk[8:4], nr[7:4], ng[7:4], nb[7:4]};
    always @(posedge clk) begin
        if (b_v && b_bank == 1'b0) lb0[b_x] <= blended;
        else if (clr_v && clr_bank == 1'b0) lb0[clr_x] <= EMPTY;
        if (b_v && b_bank == 1'b1) lb1[b_x] <= blended;
        else if (clr_v && clr_bank == 1'b1) lb1[clr_x] <= EMPTY;
    end

    // emit one pixel request (clipped to 0..639)
    reg         e_v; reg signed [11:0] e_x;
    always @(posedge clk) begin
        if (rst) begin a_v <= 1'b0; b_v <= 1'b0; end
        else begin
            a_v <= e_v && (e_x >= 0) && (e_x < 640);
            a_x <= e_x[9:0]; a_c <= pcol; a_a <= palpha; a_clr <= pclr; a_bank <= dbank;
            b_v <= a_v; b_x <= a_x; b_c <= a_c; b_a <= a_a; b_clr <= a_clr; b_bank <= a_bank;
        end
    end

    // ---- Stage 3 helpers (same formulas in tools/ui_compile.py render())
    reg  [1:0]  t3sub; reg signed [11:0] t3x, t3y0; reg [2:0] tk;
    reg  signed [13:0] tt0, tt1, ty0, ty1, tlx;
    wire signed [13:0] gl14 = {4'd0, dgy};
    wire signed [13:0] cam14 = {1'b0, s3_cam};
    reg  [5:0]  s3_addr; wire [48:0] s3_q;
    reg  [5:0]  ti_addr; wire [31:0] ti_q;
    reg  [15:0] tib, txt_a; wire [7:0] txt_q;
    reg  [7:0]  sin_a; wire [7:0] sin_q;
    rom_sync #(.WIDTH(49), .DEPTH(64), .AW(6), .MEM_FILE(S3S_FILE)) u_s3s (.clk(clk), .addr(s3_addr), .q(s3_q));
    rom_sync #(.WIDTH(32), .DEPTH(64), .AW(6), .MEM_FILE(S3I_FILE)) u_s3i (.clk(clk), .addr(ti_addr), .q(ti_q));
    rom_sync #(.WIDTH(8), .DEPTH(12288), .AW(14), .MEM_FILE(S3T_FILE)) u_s3t (.clk(clk), .addr(txt_a[13:0]), .q(txt_q));
    rom_sync #(.WIDTH(8), .DEPTH(256), .AW(8), .MEM_FILE(SIN_FILE)) u_sinw (.clk(clk), .addr(sin_a), .q(sin_q));
    // water: sin((x*2 + cam*64)/40 + gt*2.5) (1280-px demo units) = sin256[x*2.037 + wave_ph]
    function [7:0] wat_idx(input [9:0] x, input [7:0] ph);
        reg [20:0] m; begin m = x * 21'd2086; wat_idx = m[17:10] + ph; end
    endfunction
    // hills: sin((x*2 + cam*64*.3)/150) = sin256[(x*139 + hill_ph) / 256]
    function [7:0] hill_idx(input [9:0] x, input [15:0] ph);
        reg [17:0] m; begin m = x * 18'd139 + {2'd0, ph}; hill_idx = m[15:8]; end
    endfunction
    function signed [11:0] wat_dy(input [7:0] sv);          // 2 sin, rounded
        reg signed [15:0] m; begin m = $signed(sv) * 16'sd2 + 16'sd64; wat_dy = m >>> 7; end
    endfunction
    function signed [11:0] hill_dy(input [7:0] sv);         // 35 sin, rounded
        reg signed [15:0] m; begin m = $signed(sv) * 16'sd35 + 16'sd64; hill_dy = m >>> 7; end
    endfunction
    // draw_terrain() at 32 px per metre: lx = x from the solid's left edge, by = rows above its bottom row
    function ter_on(input [2:0] k, input signed [13:0] lx, input signed [13:0] by);
        reg signed [23:0] dx, dy;                       // 24 bit: dx*dx of a 3 m log does not fit 14
        begin
            dx = lx - 24'sd3; dy = by - 24'sd8;
            ter_on = (lx >= 0) || (k == 3'd5 && dx * dx + dy * dy <= 24'sd64);
        end
    endfunction
    function [11:0] ter_col(input [2:0] k, input signed [13:0] lx, input signed [13:0] w, input signed [13:0] ty,
                            input signed [13:0] by, input signed [13:0] h);
        reg incell, edg; reg signed [23:0] dx, dy;
        begin
            incell = (lx < $signed({w[13:5], 5'd0})) && (by < $signed({h[13:5], 5'd0}));
            edg = (lx[4:0] == 5'd0) || (lx[4:0] == 5'd31) || (by[4:0] == 5'd0) || (by[4:0] == 5'd31);
            dx = lx - 24'sd3; dy = by - 24'sd8;
            case (k)
                3'd1: ter_col = (ty < 14'sd10) ? 12'h4A4 : 12'h853;                                  // ground + grass
                3'd2: ter_col = (incell && edg) ? 12'h666 : 12'h899;                                // stone
                3'd3: ter_col = (incell && edg) ? 12'h654 : (incell && !(lx[5] ^ by[5])) ? 12'h889 : 12'h975;
                3'd4: ter_col = (ty < 14'sd4) ? 12'h753 :                                             // bridge
                                (lx[3:0] == 4'd0 && lx < $signed({w[13:4], 4'd0})) ? 12'h863 : 12'hB85;
                default: ter_col = (ty < 14'sd3) ? 12'h631 :                                          // log
                                   (dx * dx + dy * dy <= 24'sd64) ? 12'hC96 : 12'h742;
            endcase
        end
    endfunction

    // ---- WIRES helpers
    reg  [10:0] wire_addr; wire [46:0] wire_q;
    rom_sync #(.WIDTH(47), .DEPTH(1512), .AW(11), .MEM_FILE(WIRE_FILE)) u_wire (.clk(clk), .addr(wire_addr), .q(wire_q));
    function in_v(input [8:0] a, input [8:0] b);           // line inside the vertical segment a..b
        in_v = ({1'b0, a} <= dgy && dgy <= {1'b0, b}) || ({1'b0, b} <= dgy && dgy <= {1'b0, a});
    endfunction
    function near2(input [8:0] y);                         // |line - y| <= 2
        near2 = (dgy + 10'd2 >= {1'b0, y}) && (dgy <= {1'b0, y} + 10'd2);
    endfunction
    function [11:0] src_col(input [4:0] s);                // src_color() of stage2_demo.py, 12 bit
        if (s == 5'd1)       src_col = 12'hE55;            // +5V rail (235,80,80)
        else if (s == 5'd2)  src_col = 12'h68F;            // GND rail (96,128,255)
        else if (s <= 5'd5)  src_col = 12'hFC4;            // switch C B A (250,196,64)
        else if (s <= 5'd8)  src_col = 12'hB8F;            // NOT outputs (190,130,255)
        else if (s <= 5'd12) src_col = 12'h5CF;            // AND outputs (90,205,255)
        else if (s <= 5'd20) src_col = 12'h7E7;            // OR outputs (120,230,120)
        else                 src_col = 12'hE94;            // 220 ohm outputs (240,150,70)
    endfunction
    function [11:0] src_dim(input [4:0] s);                // colour * 0.5 when the wire carries 0
        reg [11:0] c;
        begin c = src_col(s); src_dim = {1'b0, c[11:9], 1'b0, c[7:5], 1'b0, c[3:1]}; end
    endfunction

    // line start: begin drawing the next game line
    wire        next_in  = (vcount + 10'd1 >= GY0) && (vcount + 10'd1 < GY0 + GH);
    wire [9:0]  next_gy  = vcount + 10'd1 - GY0;
    wire        go       = pix_ce && (hcount == 10'd0) && next_in;

    // decoded fields of the current entry (valid in S_DECODE)
    wire signed [11:0] f_x0 = {dl_q[60], dl_q[60:50]};
    wire signed [11:0] f_y0 = {{2{dl_q[49]}}, dl_q[49:40]};
    wire signed [11:0] f_x1 = {dl_q[39], dl_q[39:29]};
    wire signed [11:0] f_y1 = {{2{dl_q[28]}}, dl_q[28:19]};
    wire signed [11:0] gyl  = {2'b00, dgy};
    wire signed [11:0] dy_t = gyl - f_y0;                  // line - y0
    wire signed [11:0] cdy  = (gyl >= f_y0) ? gyl - f_y0 : f_y0 - gyl;   // |line - cy|
    wire        [11:0] sh   = dl_q[33:32] == 2'd0 ? 12'd32 : dl_q[33:32] == 2'd1 ? 12'd64 :
                              dl_q[33:32] == 2'd2 ? 12'd96 : 12'd128;
    wire        [20:0] fdy  = dy_t[11:0] * dl_q[30:22];        // fractional: source row x 256
    wire [11:0] dy_u = dy_t[11:0];
    // sprite row = (line - y0) / scale   (exact for 0 <= d < 128)
    wire [11:0] srow_c = dl_q[33:32] == 2'd0 ? dy_u : dl_q[33:32] == 2'd1 ? (dy_u >> 1) :
                         dl_q[33:32] == 2'd2 ? ((dy_u * 12'd43) >> 7) : (dy_u >> 2);

    always @(posedge clk) begin
        e_v <= 1'b0;
        if (rst) begin
            st <= S_IDLE; overflow <= 1'b0; dl_raddr <= 8'd0;
        end else if (go) begin
            if (st != S_IDLE && st != S_DONE) overflow <= 1'b1;
            st <= S_FETCH; dgy <= next_gy; dbank <= next_gy[0]; idx <= 8'd0;
        end else begin
            case (st)
            S_FETCH: begin dl_raddr <= idx; st <= S_WAIT; end
            S_WAIT:  st <= S_DECODE;
            S_DECODE: begin
                ptype <= dl_q[63:61];
                idx   <= idx + 8'd1;
                st    <= S_FETCH;                      // default: skip
                excl  <= 1'b0;
                case (dl_q[63:61])
                3'd0: st <= S_DONE;
                3'd1, 3'd2: if (gyl >= f_y0 && gyl < f_y1 && f_x1 > f_x0) begin
                        px <= (f_x0 < 0) ? 12'sd0 : f_x0;
                        pxe <= (f_x1 > 640) ? 12'sd640 : f_x1;
                        pcol <= dl_q[18:7]; palpha <= dl_q[6:2]; pclr <= (dl_q[63:61] == 3'd2);
                        st <= S_SPAN;
                    end
                3'd3: if (cdy <= {7'd0, dl_q[39:35]}) begin
                        cr <= dl_q[39:35]; cri <= dl_q[34:30]; ccx <= f_x0;
                        pcol <= dl_q[29:18]; palpha <= dl_q[17:13]; pclr <= 1'b0;
                        circ_addr <= {dl_q[39:35], cdy[4:0]};
                        trow <= cdy[3:0]; srow <= cdy[4:0];          // keep |dy| for the inner circle
                        st <= S_CWAIT;
                    end
                3'd4: if (dy_t >= 0 && dy_t < (dl_q[27] ? 32 : dl_q[7] ? 12 : 16) && dl_q[14:8] != 7'd0) begin
                        tx0 <= f_x0; tpx <= 11'd0; tscale <= dl_q[27]; tsmall <= dl_q[7];
                        tci <= 7'd0; tw <= {4'd0, dl_q[14:8]};          // tw = number of characters
                        tptr <= dl_q[26:15]; trow <= dl_q[27] ? dy_u[4:1] : dy_u[3:0];
                        pcol <= dl_q[39:28]; palpha <= 5'd16; pclr <= 1'b0;
                        st <= S_TCHAR;
                    end
                3'd5: if (dy_t >= 0 && (dl_q[30:22] == 9'd0 ? dy_u < sh : fdy[20:8] < 13'd32)) begin
                        tx0 <= f_x0; simg <= dl_q[39:34]; sscm1 <= dl_q[33:32]; sflip <= dl_q[31];
                        sstep <= dl_q[30:22]; sacc <= 14'd0;
                        srow <= (dl_q[30:22] == 9'd0) ? srow_c[4:0] : fdy[12:8];
                        ssx <= 5'd0; tpx <= 11'd0; palpha <= 5'd16; pclr <= 1'b0;
                        st <= S_SW1;
                        spr_addr <= {dl_q[39:34], (dl_q[30:22] == 9'd0) ? srow_c[4:0] : fdy[12:8],
                                     dl_q[31] ? 5'd31 : 5'd0};
                    end
                3'd6: begin wi <= 6'd0; st <= S_WNEXT; end
                3'd7: begin
                    t3sub <= dl_q[60:59]; t3x <= {dl_q[58], dl_q[58:48]}; t3y0 <= {{2{dl_q[47]}}, dl_q[47:38]};
                    ti_addr <= dl_q[37:32]; pcol <= dl_q[31:20]; palpha <= 5'd16; pclr <= 1'b0; srep <= 3'd0;
                    st <= S_T3;
                end
                default: ;
                endcase
            end
            // ---- spans (rect, clrbg, circle)
            S_SPAN: begin
                if (px < pxe) begin
                    e_v <= !(excl && px >= ex0 && px <= ex1);
                    e_x <= px;
                    px  <= px + 12'sd1;
                end else st <= S_FETCH;
            end
            // ---- circle: outer half-width, then optional inner half-width
            S_CWAIT:  st <= S_CWAIT2;
            S_CWAIT2: begin
                px  <= ccx - {4'd0, circ_q};
                pxe <= ccx + {4'd0, circ_q} + 12'sd1;
                if (cri != 5'd0 && {1'b0, srow} <= {1'b0, cri}) begin
                    circ_addr <= {cri, srow};
                    st <= S_CWAIT3;
                end else st <= S_SPAN;
            end
            S_CWAIT3: st <= S_TCW2;   // reuse a wait slot, then latch inner range
            // ---- text
            S_TCHAR: begin
                if ({4'd0, tci} >= tw) st <= S_FETCH;
                else begin
                    tx_raddr <= tptr + {5'd0, tci};
                    tbit <= 4'd0;
                    st <= S_TCW1;
                end
            end
            S_TCW1: st <= S_TCW2;
            S_TCW2: begin
                if (ptype == 3'd3) begin              // circle inner range latch (shared slot)
                    ex0 <= ccx - {4'd0, circ_q};
                    ex1 <= ccx + {4'd0, circ_q};
                    excl <= 1'b1;
                    st <= S_SPAN;
                end else begin
                    font_addr <= {tsmall, tx_q, trow};
                    st <= S_TPIX;
                    glyph <= 8'd0;
                    srep <= 3'd0;                     // 1-cycle wait for font data
                end
            end
            S_TPIX: begin
                if (srep == 3'd0) begin srep <= 3'd1; end          // font data arrives
                else if (srep == 3'd1) begin glyph <= font_q; srep <= 3'd2; end
                else begin
                    // emit one pixel of the current character
                    e_v <= tscale ? glyph[3'd7 - tbit[3:1]] : glyph[3'd7 - tbit[2:0]];
                    e_x <= tx0 + {1'b0, tpx};
                    tpx <= tpx + 11'd1;
                    tbit <= tbit + 4'd1;
                    if ((tscale && tbit == 4'd15) || (tsmall && tbit == 4'd5) || (!tscale && !tsmall && tbit == 4'd7)) begin
                        tci <= tci + 7'd1; st <= S_TCHAR;
                    end
                end
            end
            // ---- sprite: per source pixel: ROM index -> palette -> repeat scale times
            S_SW1: st <= S_SW2;                      // spr_q valid next cycle
            S_SW2: begin st <= S_SPIX; srep <= 3'd0; end   // palette (spal_q) valid next cycle
            S_SPIX: begin
                if (spr_q[6:0] != 7'd0) begin
                    e_v <= 1'b1; pcol <= spal_q;
                end
                e_x <= tx0 + $signed({1'b0, tpx});
                tpx <= tpx + 11'd1;
                if (sstep != 9'd0) begin                       // fractional: next screen pixel
                    sacc <= sacc_n;
                    if (sacc_n[13:8] != {1'b0, ssx}) begin
                        if (sacc_n[13:8] >= 6'd32) begin st <= S_FETCH; tpx <= 11'd0; end
                        else begin
                            ssx <= sacc_n[12:8];
                            spr_addr <= {simg, srow, sflip ? ~sacc_n[12:8] : sacc_n[12:8]};
                            st <= S_SW1;
                        end
                    end
                end else if (srep == {1'b0, sscm1}) begin
                    srep <= 3'd0;
                    if (ssx == 5'd31) begin st <= S_FETCH; tpx <= 11'd0; end
                    else begin
                        ssx <= ssx + 5'd1;
                        spr_addr <= {simg, srow, sflip ? ~(ssx + 5'd1) : (ssx + 5'd1)};
                        st <= S_SW1;
                    end
                end else srep <= srep + 3'd1;
            end
            // ---- WIRES: every wired sink -> Manhattan route (source down/up to y_mid, across, to the sink),
            //      2 px wide, 5x5 end blocks, orange dot in the sink pin. One sink after the other.
            S_WNEXT: begin
                if (wi == 6'd54) st <= S_FETCH;
                else if (wire_src[5*wi +: 5] == 5'd0) wi <= wi + 6'd1;
                else begin
                    wsrc_c <= wire_src[5*wi +: 5];
                    wire_addr <= wi * 11'd28 + {6'd0, wire_src[5*wi +: 5]};
                    st <= S_WRD;
                end
            end
            S_WRD:  st <= S_WRD2;                                 // wire ROM latency
            S_WRD2: begin
                {wx1, wy1, wx2, wy2, wym} <= wire_q; srep <= 3'd0;
                pcol <= (wire_hl[6] && wire_hl[5:0] == wi) ? 12'hFF7 :
                        src_val[wsrc_c] ? src_col(wsrc_c) : src_dim(wsrc_c);
                palpha <= 5'd16; pclr <= 1'b0;
                wseg <= 3'd0; st <= S_WSEG;
            end
            S_WSEG: begin                                          // choose the span of segment wseg on this line
                st <= S_WSPAN;
                case (wseg)
                    3'd0: if (in_v(wy1, wym)) begin px <= {2'b0, wx1} - 12'sd1; pxe <= {2'b0, wx1} + 12'sd1; end
                          else st <= S_WGAP;
                    3'd1: if (dgy == {1'b0, wym} || dgy + 10'd1 == {1'b0, wym}) begin
                              px <= {2'b0, (wx1 < wx2) ? wx1 : wx2} - 12'sd1;
                              pxe <= {2'b0, (wx1 < wx2) ? wx2 : wx1} + 12'sd1;
                          end else st <= S_WGAP;
                    3'd2: if (in_v(wym, wy2)) begin px <= {2'b0, wx2} - 12'sd1; pxe <= {2'b0, wx2} + 12'sd1; end
                          else st <= S_WGAP;
                    3'd3: if (near2(wy1)) begin px <= {2'b0, wx1} - 12'sd2; pxe <= {2'b0, wx1} + 12'sd3; end
                          else st <= S_WGAP;
                    3'd4: if (near2(wy2)) begin px <= {2'b0, wx2} - 12'sd2; pxe <= {2'b0, wx2} + 12'sd3; end
                          else st <= S_WGAP;
                    default: if (near2(wy2)) begin                 // wired pin: orange centre
                              pcol <= 12'hFA4; px <= {2'b0, wx2} - 12'sd1; pxe <= {2'b0, wx2} + 12'sd2;
                          end else st <= S_WGAP;
                endcase
            end
            S_WSPAN: begin
                if (px < pxe) begin e_v <= 1'b1; e_x <= px; px <= px + 12'sd1; end
                else st <= S_WGAP;
            end
            S_WGAP: begin                                          // 3-cycle gap: no read-after-write hazard
                srep <= srep + 3'd1;
                if (srep == 3'd2) begin
                    srep <= 3'd0;
                    if (wseg == 3'd5) begin wi <= wi + 6'd1; st <= S_WNEXT; end
                    else begin wseg <= wseg + 3'd1; st <= S_WSEG; end
                end
            end
            // ---- Stage 3 primitives
            S_T3: begin
                px <= 12'sd0;
                case (t3sub)
                2'd0: if (dgy < 10'd294) st <= S_FETCH; else begin pcol <= 12'h28D; palpha <= 5'd14; st <= S_WAT; end
                2'd3: if (dgy < 10'd165) st <= S_FETCH; else begin pcol <= 12'h9D9; st <= S_WAT; end
                2'd1: begin wi <= 6'd0; st <= S_TER; end
                default: st <= S_TIW;                                     // TEXTIMG: index ROM latency
                endcase
            end
            S_WAT: begin                    // one pixel per cycle; sine ROM result belongs to px - 2
                sin_a <= (t3sub == 2'd0) ? wat_idx(px[9:0], wave_ph) : hill_idx(px[9:0], hill_ph);
                if (px >= 12'sd2) begin
                    e_x <= px - 12'sd2;
                    e_v <= (t3sub == 2'd0) ? (dgy >= 10'd299 || $signed({2'b0, dgy}) >= 12'sd296 + wat_dy(sin_q))
                                           : ($signed({2'b0, dgy}) >= 12'sd200 - hill_dy(sin_q));
                end
                if (px == 12'sd641) st <= S_FETCH; else px <= px + 12'sd1;
            end
            S_TER: begin                                                  // next solid of the level
                if (wi == 6'd63) st <= S_FETCH;
                else begin s3_addr <= wi; srep <= 3'd0; st <= S_TERW; end
            end
            S_TERW: begin                                                 // ROM latency, then unpack
                srep <= srep + 3'd1;
                if (srep == 3'd1) begin
                    tk <= s3_q[48:46]; tt0 <= {1'b0, s3_q[45:33]}; tt1 <= {1'b0, s3_q[32:20]};
                    ty0 <= {{4{s3_q[19]}}, s3_q[19:10]}; ty1 <= {{4{s3_q[9]}}, s3_q[9:0]};
                    st <= S_TERS;
                end
            end
            S_TERS: begin                                                 // visible on this line?
                if (tk == 3'd0) st <= S_FETCH;                            // end of the table
                else if (tk == 3'd6 || gl14 < ty0 || gl14 >= ty1 || tt1 <= cam14 || tt0 >= cam14 + 14'sd640) begin
                    wi <= wi + 6'd1; st <= S_TER;
                end else begin
                    // first pixel (a log's end circle reaches 5 px left of the log)
                    tlx <= (tt0 - ((tk == 3'd5) ? 14'sd5 : 14'sd0) < cam14) ? cam14 - tt0
                                                                            : ((tk == 3'd5) ? -14'sd5 : 14'sd0);
                    st <= S_TERP;
                end
            end
            S_TERP: begin                                                 // one pixel per cycle
                if (tt0 + tlx < tt1 && tt0 + tlx - cam14 < 14'sd640) begin
                    e_v <= ter_on(tk, tlx, ty1 - 14'sd1 - gl14);
                    e_x <= tt0[11:0] + tlx[11:0] - cam14[11:0];
                    pcol <= ter_col(tk, tlx, tt1 - tt0, gl14 - ty0, ty1 - 14'sd1 - gl14, ty1 - ty0);
                    tlx <= tlx + 14'sd1;
                end else begin wi <= wi + 6'd1; st <= S_TER; end
            end
            S_TIW: begin srep <= srep + 3'd1; if (srep == 3'd1) begin srep <= 3'd0;
                if ($signed({2'b0, dgy}) < t3y0 || $signed({2'b0, dgy}) >= t3y0 + $signed({6'd0, ti_q[5:0]})) st <= S_FETCH;
                else begin
                    tib <= ti_q[31:16] + ($signed({2'b0, dgy}) - t3y0) * ((ti_q[15:6] + 10'd7) >> 3);
                    tw <= {1'b0, ti_q[15:6]}; tpx <= 11'd0; st <= S_TIB;
                end end end
            S_TIB: begin if (tpx >= tw) st <= S_FETCH; else begin txt_a <= tib + {8'd0, tpx[10:3]}; srep <= 3'd0; st <= S_TIBW; end end
            S_TIBW: begin srep <= srep + 3'd1; if (srep == 3'd1) begin glyph <= txt_q; srep <= 3'd0; st <= S_TIBITS; end end
            S_TIBITS: begin
                e_v <= glyph[3'd7 - tpx[2:0]]; e_x <= t3x + $signed({1'b0, tpx});
                tpx <= tpx + 11'd1;
                if (tpx[2:0] == 3'd7 || tpx + 11'd1 >= tw) st <= S_TIB;
            end
            S_DONE: ;
            default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ background + scan-out
    wire [9:0]  gx  = hcount;
    wire [10:0] ax1 = cam_x + {1'b0, gx};
    wire [9:0]  ay1 = cam_y + sgy;
    // Stage-2 zoom: src = zoom_o + (screen * zoom_inv) >> 16   (zoom_inv = 65536 -> 1:1)
    wire [26:0] zxm = gx * zoom_inv;
    wire [26:0] zym = sgy * zoom_inv;
    wire [11:0] zx  = zoom_ox + zxm[26:16];
    wire [11:0] zy  = zoom_oy + zym[26:16];
    wire [9:0]  sx  = (bg_mode == 3'd1) ? ax1[10:1] : (zx > 12'd639) ? 10'd639 : zx[9:0];
    wire [8:0]  sy  = (bg_mode == 3'd1) ? ay1[9:1] : ((zy > 12'd357) ? 9'd357 : zy[8:0]);
    wire [17:0] bg_addr = {sy, 9'd0} + {2'd0, sy, 7'd0} + {8'd0, sx};   // sy*640 + sx
    wire [5:0]  bq1, bq2;
    wire [11:0] pc1, pc2;
    rom_sync #(.WIDTH(6), .DEPTH(229120), .AW(18), .MEM_FILE(BG1_FILE))  u_bg1 (.clk(clk), .addr(bg_addr), .q(bq1));
    rom_sync #(.WIDTH(6), .DEPTH(229120), .AW(18), .MEM_FILE(BG2_FILE))  u_bg2 (.clk(clk), .addr(bg_addr), .q(bq2));
    rom_sync #(.WIDTH(12), .DEPTH(64), .AW(6), .MEM_FILE(PAL1_FILE)) u_p1 (.clk(clk), .addr(bq1[5:0]), .q(pc1));
    rom_sync #(.WIDTH(12), .DEPTH(64), .AW(6), .MEM_FILE(PAL2_FILE)) u_p2 (.clk(clk), .addr(bq2[5:0]), .q(pc2));

    // gradient colour for this line (Stage 3 sky): t = gy * 45/16 ~ gy/360 * 1024
    wire [15:0] gtw = sgy * 16'd45;
    wire [11:0] gt  = gtw[15:4];
    // 8-bit channel a + (b - a) * t, scaled to 0..240, plus the 2x2 Bayer offset (2, 10, 14, 6), / 16
    function [3:0] sky4(input [7:0] a, input [7:0] b, input [11:0] t, input [1:0] dp);
        reg signed [21:0] d; reg [8:0] c8; reg [16:0] v; reg [8:0] o;
        begin
            d = ($signed({1'b0, b}) - $signed({1'b0, a})) * $signed({1'b0, t});
            c8 = a + (d >>> 10);
            v = c8 * 9'd241;
            o = v[15:8] + ((dp == 2'd0) ? 9'd2 : (dp == 2'd1) ? 9'd10 : (dp == 2'd2) ? 9'd14 : 9'd6);
            sky4 = (o[8:4] > 5'd15) ? 4'd15 : o[7:4];
        end
    endfunction
    wire [1:0]  dpos = {sgy[0], gx[0]};
    wire [11:0] gcol = {sky4(SKY0[23:16], SKY1[23:16], gt, dpos), sky4(SKY0[15:8], SKY1[15:8], gt, dpos),
                        sky4(SKY0[7:0], SKY1[7:0], gt, dpos)};

    // ---- Stage-2 breadboard: 80 x 45 map of 8x8 tiles (64 colours). The 8 pixels of the NEXT tile
    //      are fetched while the current one is shown (map ROM -> tile ROM, 4 cycles).
    wire        blank_h = (hcount >= 10'd640);
    wire [9:0]  trow_y  = blank_h ? (vcount + 10'd1 - GY0) : sgy;         // after the line: next line
    wire [9:0]  tcol_n  = (hcount[9:3] == 7'd99) ? 10'd0 : {3'd0, hcount[9:3]} + 10'd1;
    reg  [11:0] bm_addr; wire [9:0] bm_q;
    reg  [12:0] bt_addr; wire [47:0] bt_q;
    reg  [47:0] cur_row, next_row;
    reg  [2:0]  bf;               // prefetch step
    reg  [2:0]  bty;
    rom_sync #(.WIDTH(10), .DEPTH(3600), .AW(12), .MEM_FILE(BM_FILE)) u_bmap (.clk(clk), .addr(bm_addr), .q(bm_q));
    rom_sync #(.WIDTH(48), .DEPTH(8192), .AW(13), .MEM_FILE(BT_FILE)) u_btile (.clk(clk), .addr(bt_addr), .q(bt_q));
    always @(posedge clk) begin
        if (rst) bf <= 3'd0;
        else begin
            if (pix_ce && hcount[2:0] == 3'd0) begin
                cur_row <= next_row;
                if (tcol_n < 10'd80 && trow_y < 10'd360) begin
                    bm_addr <= {2'd0, trow_y[8:3], 4'd0} * 12'd5 + {2'd0, tcol_n};   // row*80 + col
                    bty <= trow_y[2:0]; bf <= 3'd1;
                end
            end else if (bf == 3'd1) bf <= 3'd2;                  // map ROM samples the address
            else if (bf == 3'd2) begin bt_addr <= {bm_q, bty}; bf <= 3'd3; end
            else if (bf == 3'd3) bf <= 3'd4;                      // tile ROM samples
            else if (bf == 3'd4) begin next_row <= bt_q; bf <= 3'd0; end
        end
    end
    // colour index of this pixel (the row register is swapped at the first pixel of a tile)
    wire [47:0] row_now = (hcount[2:0] == 3'd0) ? next_row : cur_row;
    wire [5:0]  bidx    = row_now[6 * (3'd7 - hcount[2:0]) +: 6];
    reg  [5:0]  bidx_r;  wire [11:0] pc4;
    always @(posedge clk) if (pix_ce) bidx_r <= bidx;
    rom_sync #(.WIDTH(12), .DEPTH(64), .AW(6), .MEM_FILE(BP_FILE)) u_bpal (.clk(clk), .addr(bidx_r), .q(pc4));

    reg sbank_d;
    reg [16:0] ent;
    reg [11:0] bgc;
    wire [8:0] mr = bgc[11:8] * ent[16:12];   // explicit 9-bit products
    wire [8:0] mg = bgc[7:4]  * ent[16:12];
    wire [8:0] mb = bgc[3:0]  * ent[16:12];
    reg [11:0] gcol_d;
    always @(posedge clk) if (pix_ce) begin sbank_d <= sbank; gcol_d <= gcol; end
    // pipeline: c0 = pix_ce cycle (addresses), c1 = ROM/LB data, c2 = palette data, compose
    reg [2:0]  ph;           // cycles since pix_ce
    reg        p_game, p_act, hs_d, vs_d;
    reg [3:0]  cr_o, cg_o, cb_o;
    always @(posedge clk) begin
        if (rst) begin
            ph <= 3'd7; clr_v <= 1'b0;
            vga_r <= 4'd0; vga_g <= 4'd0; vga_b <= 4'd0; vga_hs <= 1'b1; vga_vs <= 1'b1;
            hs_d <= 1'b1; vs_d <= 1'b1; p_game <= 1'b0; p_act <= 1'b0;
        end else begin
            clr_v <= 1'b0;
            if (pix_ce) begin
                ph <= 3'd0;
                // output previous pixel together with its delayed syncs
                vga_r <= p_game ? cr_o : 4'd0; vga_g <= p_game ? cg_o : 4'd0; vga_b <= p_game ? cb_o : 4'd0;
                vga_hs <= hs_d; vga_vs <= vs_d;
                hs_d <= hsync; vs_d <= vsync; p_game <= in_game; p_act <= active;
                clr_x <= hcount; clr_bank <= sbank;
            end else if (ph != 3'd7) ph <= ph + 3'd1;
            if (ph == 3'd0) begin                     // c1: line-buffer + bg index available
                ent <= sbank_d ? rq1 : rq0;
                clr_v <= p_game;                       // clear the entry we just consumed
            end
            if (ph == 3'd1) begin                     // c2: palette available
                case (bg_mode)
                    3'd0: bgc <= bg_color;
                    3'd1: bgc <= pc1;
                    3'd2: bgc <= pc2;
                    3'd4: bgc <= pc4;
                    default: bgc <= gcol_d;
                endcase
            end
            if (ph == 3'd2) begin                     // c3: compose
                cr_o <= sat4(mr, ent[11:8]);
                cg_o <= sat4(mg, ent[7:4]);
                cb_o <= sat4(mb, ent[3:0]);
            end
        end
    end

    function [3:0] sat4(input [8:0] bk, input [3:0] add);
        reg [5:0] s;
        begin
            s = ((bk + 9'd8) >> 4) + add;
            sat4 = (s > 6'd15) ? 4'd15 : s[3:0];
        end
    endfunction
endmodule
