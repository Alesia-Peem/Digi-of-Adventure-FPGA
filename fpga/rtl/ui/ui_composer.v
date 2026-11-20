// ui_composer.v - "UI virtual machine": rebuilds the display list once per frame (during vblank).
//
// Each Pygame draw_* function (HUD, close-ups, cards, notebook, help ...) is described once in
// fpga/tools/ui_screens.py and compiled by fpga/tools/ui_compile.py into
//   ui_prog.mem (96-bit instructions)  ui_str.mem (8-bit chars)  ui_ptr.mem (12-bit string pointers)
// The game logic only exposes FIELDS (numbers) and CONDITIONS (booleans) -> rendering is fully
// separated from game logic, and the same engine serves all three stages.
//
// INSTRUCTION (96 bit)
//   [95:91] op  [90:83] cond index  [82] negate  [81:71] x0 (s11)  [70:61] y0 (s10)
//   [60:40] A (op specific)  [39:28] colour (12-bit RGB)  [27:0] B (op specific)
//   An instruction runs only if cond[idx] ^ negate (cond 0 = constant 1). Positions get the OFS offset.
//   0 END
//   1 RECT, 2 CLRBG  A={x1 s11 [60:50], y1 s10 [49:40]} (exclusive)  B[27:23] alpha  B[22:16] alpha-field
//            B[15] = 1: emit the WIRES primitive instead
//            B[14] = 1: x1 / y1 are the (absolute) values of fields A[60:54] / A[53:47]
//   3 CIRC   A[60:56] r  A[55:51] inner r (0 = filled)  B[27:23] alpha
//   4 TEXT   A[60] scale2 A[59] xcont A[58] ycont A[57:43] string addr  B[27:24] line height-8 (32 if scale2)
//            B[23] small font
//   5 NUM    A[60] scale2 A[59] xcont A[58] ycont A[57:51] field A[50:47] fmt A[46:43] width A[42] small A[41] center
//   6 TEXTT  A[60] scale2 A[59] xcont A[58] ycont A[57:49] pointer-table base  A[48:42] field A[41] small
//            A[40] center (each line centred on x0)  B[27:22] line h
//   7 SPR    A[60:55] image base  A[54:48] field (added)  A[47:46] scale-1  A[45] flip-x
//            A[44:36] step (0 = integer scale, else source px per screen px x 256)
//   8 OFS    A[60:54] fx  A[53:47] fy  B[27:20] sx  B[19:12] sy :  off = (field*s + (x0,y0))
//   9 SKIP   A[60:51] n : if the condition is TRUE skip the next n instructions
//  10 ZOOM   A[46]=0: A[60:54] field zf (x256, 0 = zoom off)  A[53:47] field origin {y[23:12], x[11:0]}
//            A[46]=1: A[60:54] field zinv (65536/zoom).  While on, positions p -> (p - origin) * zf / 256,
//            circle radii * zf / 256 (max 31) and fractional sprite steps * zinv / 65536 (world zoom).
//   TEXTT B[21] = box: a black box 8 px wider on each side, 23 px high, is drawn behind the text
//   xcont: text starts where the previous text ended, on the same line   (label + number)
//   ycont: text starts at x0 on the line below the previous text, + y0    (flowing paragraphs)
//   NUM formats: 0 decimal (at least `width` digits)  1 binary (`width` bits, MSB first)
//     2 letter 'A'+v  3 signed 8-bit decimal  4 bits16() of the Pygame demo (LSB-first nibbles)
//     5 product term {usedABCD, plainABCD} (width 1 -> "(empty)", 2 -> "(nothing)" when empty)
//     6 equation of 3 terms (T1 = v[7:0] ..) joined with " + "   7 three letters v[4:0],v[12:8],v[20:16]
`timescale 1ns/1ps
module ui_composer #(
    parameter PROG_FILE = "mem/ui_prog.mem",
    parameter STR_FILE  = "mem/ui_str.mem",
    parameter PTR_FILE  = "mem/ui_ptr.mem"
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,            // pulse at the beginning of vblank
    input  wire [3071:0] fields,           // 128 x 24 bit, field k = fields[24k +: 24]; field 0 = 0
    input  wire [255:0]  conds,            // cond 0 must be 1
    output reg           busy,
    output reg           dl_we,
    output reg  [7:0]    dl_waddr,
    output reg  [63:0]   dl_wdata,
    output reg           tx_we,
    output reg  [11:0]   tx_waddr,
    output reg  [6:0]    tx_wdata,
    output reg           dl_full           // sticky debug flag: display list overflow
);
    // ------------------------------------------------------------ ROMs
    reg  [10:0] pc;
    wire [95:0] ins;
    reg  [14:0] s_addr;  wire [7:0]  s_q;
    reg  [8:0]  p_addr;  wire [14:0] p_q;
    rom_sync #(.WIDTH(96), .DEPTH(2048),  .AW(11), .MEM_FILE(PROG_FILE)) u_prog (.clk(clk), .addr(pc), .q(ins));
    rom_sync #(.WIDTH(8),  .DEPTH(32768), .AW(15), .MEM_FILE(STR_FILE))  u_str  (.clk(clk), .addr(s_addr), .q(s_q));
    rom_sync #(.WIDTH(15), .DEPTH(512),   .AW(9),  .MEM_FILE(PTR_FILE))  u_ptr  (.clk(clk), .addr(p_addr), .q(p_q));

    // ------------------------------------------------------------ decode
    localparam OP_END = 5'd0, OP_RECT = 5'd1, OP_CLRBG = 5'd2, OP_CIRC = 5'd3, OP_TEXT = 5'd4,
               OP_NUM = 5'd5, OP_TEXTT = 5'd6, OP_SPR = 5'd7, OP_OFS = 5'd8, OP_SKIP = 5'd9, OP_ZOOM = 5'd10,
               OP_S3 = 5'd11;
    wire [4:0]  op      = ins[95:91];
    wire        cond_ok = conds[ins[90:83]] ^ ins[82];
    wire signed [11:0] i_x0 = {ins[81], ins[81:71]};
    wire signed [11:0] i_y0 = {{2{ins[70]}}, ins[70:61]};
    wire signed [11:0] i_x1 = {ins[60], ins[60:50]};
    wire signed [11:0] i_y1 = {{2{ins[49]}}, ins[49:40]};
    wire [11:0] i_col = ins[39:28];
    wire        i_sc2 = ins[60];
    wire        i_xc  = ins[59];
    wire        i_yc  = ins[58];

    // two field read ports (one generic, one for the OFS y field)
    wire [6:0]  fid_a = (op == OP_OFS || op == OP_ZOOM || ((op == OP_RECT || op == OP_CLRBG) && ins[14])) ? ins[60:54] :
                        (op == OP_SPR)   ? ins[54:48] :
                        (op == OP_NUM)   ? ins[57:51] :
                        (op == OP_TEXTT) ? ins[48:42] :
                        (op == OP_S3)    ? ins[52:46] : ins[22:16];
    // field taps are registered (one extra cycle per instruction) to keep the 128:1 mux off the
    // multiply in OFS / the formatters
    reg  [23:0] fa, fb;
    always @(posedge clk) begin fa <= fields[fid_a*24 +: 24]; fb <= fields[ins[53:47]*24 +: 24]; end

    reg  signed [11:0] offx, offy;      // OFS offsets
    reg  signed [11:0] lastx, lasty, nexty;
    // world zoom (Stage 2 pickup animation)
    reg         zon;
    reg  [8:0]  zf;
    reg  [11:0] zox, zoy;
    reg  [16:0] zinv;
    // all inputs are arguments: a continuous assign only re-evaluates when its arguments change
    function signed [11:0] zt(input signed [11:0] p, input [11:0] o, input on, input [8:0] f);
        reg signed [23:0] m;
        begin m = (p - $signed({1'b0, o[10:0]})) * $signed({1'b0, f}); zt = on ? m[19:8] : p; end
    endfunction
    wire signed [11:0] px0 = i_x0 + offx;
    wire signed [11:0] py0 = i_y0 + offy;
    wire signed [11:0] px1 = ins[14] ? fa[11:0] : i_x1 + offx;
    wire signed [11:0] py1 = ins[14] ? fb[11:0] : i_y1 + offy;
    wire signed [11:0] ax0 = zt(px0, zox, zon, zf);
    wire signed [11:0] ay0 = zt(py0, zoy, zon, zf);
    wire signed [11:0] ax1 = zt(px1, zox, zon, zf);
    wire signed [11:0] ay1 = zt(py1, zoy, zon, zf);
    wire [13:0] zr  = ins[60:56] * zf;
    wire [4:0]  cr_z = !zon ? ins[60:56] : (zr[13:8] > 6'd31) ? 5'd31 : zr[12:8];
    wire [25:0] zs  = ins[44:36] * zinv;
    wire [8:0]  step_z = (!zon || ins[44:36] == 9'd0) ? ins[44:36] : (zs[24:16] == 9'd0) ? 9'd1 : zs[24:16];
    reg         box_on; reg [7:0] box_slot;
    wire signed [11:0] tx_xs = i_xc ? lastx : ax0;
    wire signed [11:0] tx_ys = i_xc ? lasty : (i_yc ? nexty + i_y0 : ay0);

    // ------------------------------------------------------------ text / number emitter state
    reg  signed [11:0] tx_x, tx_y, tx_x0;
    reg  [11:0] tx_start;
    reg  [6:0]  tx_len;
    reg  [11:0] tx_ptr;
    reg  [11:0] tcol;
    reg         tsc2, tsml, tcen;
    reg  [5:0]  tlh;
    reg  [23:0] v;
    reg  [3:0]  fmt, width;
    reg  [3:0]  k;
    reg  [3:0]  dgt;
    reg         started, sp_done;
    reg  [1:0]  term_i;
    reg         any_term;
    reg  [2:0]  ti;
    reg  [1:0]  sepk;
    reg  [7:0]  dl_n;                   // next free display-list slot

    localparam C_IDLE = 5'd0, C_FETCH = 5'd1, C_WAIT = 5'd2, C_EXEC = 5'd3, C_SWAIT = 5'd4, C_SCHAR = 5'd5,
               C_PWAIT = 5'd6, C_PWAIT2 = 5'd7, C_DEC = 5'd8, C_DECSUB = 5'd9, C_BIN = 5'd10, C_B16 = 5'd11,
               C_TERM = 5'd12, C_TERMP = 5'd13, C_SEP = 5'd14, C_SEPL = 5'd15, C_PHW = 5'd16, C_PHC = 5'd17,
               C_LET3 = 5'd18, C_NUMEND = 5'd19, C_END = 5'd20, C_WAIT2 = 5'd21, C_BOX = 5'd22;
    // box geometry (lastx / lasty were just updated by flush_text, so use the text start + width)
    reg signed [11:0] bx0, by0, bx1, by1;
    reg  [4:0]  st;

    function [23:0] pow10(input [3:0] i);
        case (i)
            4'd0: pow10 = 24'd100000; 4'd1: pow10 = 24'd10000; 4'd2: pow10 = 24'd1000;
            4'd3: pow10 = 24'd100;    4'd4: pow10 = 24'd10;    default: pow10 = 24'd1;
        endcase
    endfunction
    function [2:0] first_used(input [3:0] u);
        first_used = u[3] ? 3'd0 : u[2] ? 3'd1 : u[1] ? 3'd2 : 3'd3;
    endfunction

    // term byte being printed: {used A,B,C,D, plain A,B,C,D}
    wire [7:0] term_b = (fmt == 4'd6) ? (term_i == 2'd0 ? v[7:0] : term_i == 2'd1 ? v[15:8] : v[23:16]) : v[7:0];
    wire [3:0] t_used = term_b[7:4];

    task put(input [6:0] ch);
        begin
            tx_we <= 1'b1; tx_waddr <= tx_ptr; tx_wdata <= ch;
            tx_ptr <= tx_ptr + 12'd1; tx_len <= tx_len + 7'd1;
        end
    endtask

    // width of the collected text and its x (moved left by half the width when centred)
    wire [11:0] twid = tsc2 ? {1'b0, tx_len, 4'd0} : tsml ? ({2'b0, tx_len, 3'd0} - {4'b0, tx_len, 1'b0}) : {2'b0, tx_len, 3'd0};
    wire signed [11:0] tx_xe = tcen ? tx_x - $signed({1'b0, twid[11:1]}) : tx_x;
    task flush_text;   // write the display-list entry for the characters collected so far
        begin
            if (tx_len != 7'd0) begin
                dl_we <= 1'b1; dl_waddr <= dl_n; dl_n <= dl_n + 8'd1;
                dl_wdata <= {3'd4, tx_xe[10:0], tx_y[9:0], tcol, tsc2, tx_start, tx_len, tsml, 7'd0};
                if (dl_n >= 8'd254) dl_full <= 1'b1;
            end
            lastx <= tx_xe + twid;
            lasty <= tx_y;
            bx0 <= tx_xe - 12'sd8; bx1 <= tx_xe + twid + 12'sd8; by0 <= tx_y - 12'sd5; by1 <= tx_y + 12'sd18;
            nexty <= tx_y + {6'd0, tlh};
        end
    endtask

    task prim(input [63:0] d);
        begin
            dl_we <= 1'b1; dl_waddr <= dl_n; dl_wdata <= d; dl_n <= dl_n + 8'd1;
            if (dl_n >= 8'd254) dl_full <= 1'b1;
        end
    endtask

    always @(posedge clk) begin
        dl_we <= 1'b0;
        tx_we <= 1'b0;
        if (rst) begin
            st <= C_IDLE; busy <= 1'b0; pc <= 11'd0; dl_full <= 1'b0; dl_n <= 8'd0;
            offx <= 12'sd0; offy <= 12'sd0; lastx <= 12'sd0; lasty <= 12'sd0; nexty <= 12'sd0;
            tx_ptr <= 12'd0;
        end else begin
            case (st)
            C_IDLE: if (start) begin
                busy <= 1'b1; pc <= 11'd0; dl_n <= 8'd0; tx_ptr <= 12'd0;
                offx <= 12'sd0; offy <= 12'sd0; lastx <= 12'sd0; lasty <= 12'sd0; nexty <= 12'sd0;
                zon <= 1'b0; zinv <= 17'd65536; box_on <= 1'b0;
                st <= C_FETCH;
            end
            C_FETCH: st <= C_WAIT;            // ROM samples pc
            C_WAIT:  st <= C_WAIT2;           // instruction valid
            C_WAIT2: st <= C_EXEC;            // field taps valid
            C_EXEC: begin
                st <= C_FETCH; pc <= pc + 11'd1;
                if (op == OP_END) st <= C_END;
                else if (op == OP_SKIP) begin
                    if (cond_ok) pc <= pc + 11'd1 + {1'b0, ins[60:51]};
                end else if (cond_ok) begin
                    case (op)
                    OP_RECT, OP_CLRBG:
                        if (ins[15]) prim({3'd6, 61'd0});                    // WIRES (Stage 2 breadboard)
                        else prim({(op == OP_CLRBG) ? 3'd2 : 3'd1, ax0[10:0], ay0[9:0], ax1[10:0], ay1[9:0], i_col,
                              (ins[22:16] != 7'd0 && !ins[14]) ? fa[4:0] : ins[27:23], 2'd0});
                    OP_CIRC:
                        prim({3'd3, ax0[10:0], ay0[9:0], cr_z, zon ? 5'd0 : ins[55:51], i_col, ins[27:23], 13'd0});
                    OP_SPR:
                        prim({3'd5, ax0[10:0], ay0[9:0], ins[60:55] + fa[5:0], ins[47:46], ins[45], step_z, 22'd0});
                    OP_S3:                                                 // Stage 3: sub, id (+ field)
                        prim({3'd7, ins[60:59], ax0[10:0], ay0[9:0],
                              ins[58:53] + ((ins[52:46] != 7'd0) ? fa[5:0] : 6'd0), i_col, 20'd0});
                    OP_ZOOM:
                        if (ins[46]) zinv <= fa[16:0];
                        else begin zon <= (fa[8:0] != 9'd0); zf <= fa[8:0]; zox <= fb[11:0]; zoy <= fb[23:12]; end
                    OP_OFS: begin
                        offx <= $signed(fa[11:0]) * $signed({4'd0, ins[27:20]}) + i_x0;
                        offy <= $signed(fb[11:0]) * $signed({4'd0, ins[19:12]}) + i_y0;
                    end
                    OP_TEXT, OP_NUM, OP_TEXTT: begin
                        tx_x <= tx_xs; tx_x0 <= tx_xs; tx_y <= tx_ys;
                        tx_start <= tx_ptr; tx_len <= 7'd0; tcol <= i_col; tsc2 <= i_sc2;
                        if (op == OP_TEXT) begin
                            s_addr <= ins[57:43]; tlh <= i_sc2 ? 6'd32 : {2'b0, ins[27:24]} + 6'd8; tsml <= ins[23]; tcen <= 1'b0;
                            st <= C_SWAIT;
                        end else if (op == OP_TEXTT) begin
                            p_addr <= ins[57:49] + fa[8:0]; tlh <= ins[27:22]; tsml <= ins[41]; tcen <= ins[40];
                            st <= C_PWAIT;
                            if (ins[21]) begin box_on <= 1'b1; box_slot <= dl_n; dl_n <= dl_n + 8'd1; end
                        end else begin
                            tlh <= i_sc2 ? 6'd32 : ins[42] ? 6'd12 : 6'd16; tsml <= ins[42]; tcen <= ins[41];
                            v <= fa; fmt <= ins[50:47]; width <= ins[46:43];
                            k <= 4'd0; started <= 1'b0; sp_done <= 1'b0;
                            term_i <= 2'd0; any_term <= 1'b0; ti <= 3'd0;
                            case (ins[50:47])
                                4'd0: st <= C_DEC;
                                4'd1: begin k <= ins[46:43]; st <= C_BIN; end
                                4'd2: begin                                 // single letter
                                    tx_we <= 1'b1; tx_waddr <= tx_ptr; tx_wdata <= 7'd65 + fa[6:0];
                                    tx_ptr <= tx_ptr + 12'd1; tx_len <= 7'd1; st <= C_NUMEND;
                                end
                                4'd3: begin
                                    st <= C_DEC;
                                    if (fa[7]) begin                         // negative 8-bit value
                                        tx_we <= 1'b1; tx_waddr <= tx_ptr; tx_wdata <= 7'd45;
                                        tx_ptr <= tx_ptr + 12'd1; tx_len <= 7'd1;
                                        v <= {16'd0, 8'd0 - fa[7:0]};
                                    end else v <= {16'd0, fa[7:0]};
                                end
                                4'd4: st <= C_B16;
                                4'd5, 4'd6: st <= C_TERM;
                                4'd7: st <= C_LET3;
                                default: st <= C_NUMEND;
                            endcase
                        end
                    end
                    default: ;
                    endcase
                end
            end
            // ---- strings (TEXT) and table strings (TEXTT)
            C_PWAIT:  st <= C_PWAIT2;
            C_PWAIT2: begin s_addr <= p_q; st <= C_SWAIT; end
            C_SWAIT:  st <= C_SCHAR;
            C_SCHAR: begin
                if (s_q == 8'd0) begin
                    flush_text; st <= box_on ? C_BOX : C_FETCH;
                end else if (s_q == 8'd10) begin           // newline: close this line, open the next
                    flush_text;
                    tx_y <= tx_y + {6'd0, tlh}; tx_x <= tx_x0; tx_start <= tx_ptr; tx_len <= 7'd0;
                    s_addr <= s_addr + 15'd1; st <= C_SWAIT;
                end else begin
                    put(s_q[6:0]); s_addr <= s_addr + 15'd1; st <= C_SWAIT;
                end
            end
            // ---- decimal: 6 digits by repeated subtraction, leading zeros suppressed
            C_DEC: begin dgt <= 4'd0; st <= C_DECSUB; end
            C_DECSUB: begin
                if (v >= pow10(k)) begin v <= v - pow10(k); dgt <= dgt + 4'd1; end
                else begin
                    if (dgt != 4'd0 || started || k == 4'd5 || (4'd6 - k) <= width) begin
                        put(7'd48 + {3'd0, dgt}); started <= 1'b1;
                    end
                    if (k == 4'd5) st <= C_NUMEND;
                    else begin k <= k + 4'd1; st <= C_DEC; end
                end
            end
            C_BIN: begin
                if (k == 4'd0) st <= C_NUMEND;
                else begin put(v[k - 4'd1] ? 7'd49 : 7'd48); k <= k - 4'd1; end
            end
            C_B16: begin                                     // nibble groups separated by spaces
                if (k[1:0] == 2'd0 && k != 4'd0 && !sp_done) begin put(7'd32); sp_done <= 1'b1; end
                else begin
                    put(v[k] ? 7'd49 : 7'd48); sp_done <= 1'b0;
                    if (k == 4'd15) st <= C_NUMEND; else k <= k + 4'd1;
                end
            end
            C_LET3: begin
                put(7'd65 + (k == 4'd0 ? {2'd0, v[4:0]} : k == 4'd1 ? {2'd0, v[12:8]} : {2'd0, v[20:16]}));
                if (k == 4'd2) st <= C_NUMEND; else k <= k + 4'd1;
            end
            // ---- product terms / equations
            C_TERM: begin
                if (ti == 3'd4) begin
                    if (fmt == 4'd6) begin
                        if (term_i == 2'd2) st <= C_NUMEND;
                        else begin term_i <= term_i + 2'd1; ti <= 3'd0; end
                    end else if (t_used == 4'd0 && width == 4'd1) begin s_addr <= 15'd1; st <= C_PHW; end  // "(empty)"
                    else if (t_used == 4'd0 && width == 4'd2) begin s_addr <= 15'd9; st <= C_PHW; end  // "(nothing)"
                    else st <= C_NUMEND;
                end else if (term_b[3'd7 - ti]) begin
                    if (fmt == 4'd6 && ti == first_used(t_used) && any_term) begin
                        sepk <= 2'd0; st <= C_SEP;                         // " + " between terms
                    end else st <= C_SEPL;
                end else ti <= ti + 3'd1;
            end
            C_SEP: begin
                put(sepk == 2'd1 ? 7'd43 : 7'd32);
                if (sepk == 2'd2) st <= C_SEPL; else sepk <= sepk + 2'd1;
            end
            C_SEPL: begin                                      // the variable letter
                put(7'd65 + {4'd0, ti});
                any_term <= 1'b1;
                st <= term_b[3'd3 - ti] ? C_TERM : C_TERMP;
                ti <= ti + 3'd1;
            end
            C_TERMP: begin put(7'd39); st <= C_TERM; end       // apostrophe = inverted
            C_PHW: st <= C_PHC;
            C_PHC: begin
                if (s_q == 8'd0) st <= C_NUMEND;
                else begin put(s_q[6:0]); s_addr <= s_addr + 15'd1; st <= C_PHW; end
            end
            C_NUMEND: begin flush_text; st <= C_FETCH; end
            C_BOX: begin                                         // box behind the text (reserved slot)
                dl_we <= 1'b1; dl_waddr <= box_slot; box_on <= 1'b0; st <= C_FETCH;
                dl_wdata <= {3'd1, bx0[10:0], by0[9:0], bx1[10:0], by1[9:0], 12'h000, 5'd16, 2'd0};
            end
            C_END: begin
                prim(64'd0);                                     // END marker
                busy <= 1'b0; st <= C_IDLE;
            end
            default: st <= C_IDLE;
            endcase
        end
    end
endmodule
