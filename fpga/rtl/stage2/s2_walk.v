// s2_walk.v - Stage 2 blocked(x, y) of stage2_demo.py (start -> done some cycles later).
//   feet box 20 x 10: l = x-10, r = x+10, t = y-10, b = y, mid = (t+b)//2 = y-5
//   8 sample points (l,t) (r,t) (l,b) (r,b) (x,t) (x,b) (l,mid) (r,mid); blocked if any point is outside
//   the 960 x 540 picture or not walkable in make_walk_mask() (FLOOR minus the SOLIDS polygons).
// The mask is stored run-length coded (s2_mask.mem, see stage2_assets.py): one 120-bit word per row with
// up to 12 x-positions where walkable/blocked toggles -> one ROM read per row, compared in parallel.
`timescale 1ns/1ps
module s2_walk #(parameter MASK_FILE = "mem/s2_mask.mem") (
    input  wire        clk,
    input  wire        start,
    input  wire [11:0] x,          // int(x)
    input  wire [11:0] y,          // int(y)
    output reg         done,
    output reg         blocked
);
    reg  [8:0]   addr;
    wire [119:0] row;
    rom_sync #(.WIDTH(120), .DEPTH(350), .AW(9), .MEM_FILE(MASK_FILE)) u_mask (.clk(clk), .addr(addr), .q(row));

    // walkable(px) on the row in `row`, valid when the row index was inside 176..525
    function walk(input [119:0] r, input signed [12:0] px);
        integer i; reg [3:0] n; reg signed [12:0] rel;
        begin
            rel = px - 13'sd100; n = 4'd0;
            for (i = 0; i < 12; i = i + 1)
                if ($signed({3'b000, r[10*i +: 10]}) <= rel) n = n + 4'd1;
            walk = (px >= 13'sd100) && (px < 13'sd930) && n[0];
        end
    endfunction

    reg  [1:0]  k;              // row being checked: 0 = t, 1 = mid, 2 = b
    reg  [1:0]  ph;
    reg         busy, inrow;
    reg  signed [12:0] xs, ys, ry;
    wire signed [12:0] rowy = (k == 2'd0) ? ys - 13'sd10 : (k == 2'd1) ? ys - 13'sd5 : ys;
    always @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            busy <= 1'b1; k <= 2'd0; ph <= 2'd0; blocked <= 1'b0;
            xs <= $signed({1'b0, x}); ys <= $signed({1'b0, y});
        end else if (busy) begin
            case (ph)
                2'd0: begin                                    // address of this row
                    ry <= rowy;
                    inrow <= (rowy >= 13'sd176) && (rowy <= 13'sd525);
                    addr <= rowy[8:0] - 9'd176;
                    ph <= 2'd1;
                end
                2'd1: ph <= 2'd2;                              // ROM latency
                default: begin
                    if (!inrow || !walk(row, xs - 13'sd10) || !walk(row, xs + 13'sd10) ||
                        (k != 2'd1 && !walk(row, xs)))
                        blocked <= 1'b1;
                    if (k == 2'd2) begin busy <= 1'b0; done <= 1'b1; end
                    else begin k <= k + 2'd1; ph <= 2'd0; end
                end
            endcase
        end
    end
    initial busy = 1'b0;
endmodule
