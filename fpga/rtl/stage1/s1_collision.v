// s1_collision.v - Stage 1 blocked(x, y), combinational, bit-exact with stage1_demo.py:
//
//   r = Rect(int(x)-18, int(y)-22, 36, 22)            (feet box, FEET_HW=18, FEET_H=22)
//   corners (left,top) (right,top) (left,bottom) (right,bottom) with right = left+36, bottom = top+22
//   a corner is outside when  y < 360  or  y > 1085  or  x < 600 - 0.76*(y-355)  or  x > 1440 + 0.714*(y-350)
//   -> compared exactly in integers:  100*x < 60000 - 76*(y-355)   /   1000*x > 1440000 + 714*(y-350)
//   plus r.colliderect(b) for every BLOCKER (strict overlap, pygame semantics).
// Collision never looks at the background picture (it is pure geometry).
`timescale 1ns/1ps
module s1_collision (
    input  wire [11:0] xi,     // int(x) world pixels
    input  wire [11:0] yi,     // int(y)
    output wire        blocked
);
    wire signed [13:0] l = $signed({2'b00, xi}) - 14'sd18;
    wire signed [13:0] r = $signed({2'b00, xi}) + 14'sd18;
    wire signed [13:0] t = $signed({2'b00, yi}) - 14'sd22;
    wire signed [13:0] b = $signed({2'b00, yi});

    function out_floor(input signed [13:0] cx, input signed [13:0] cy);
        reg signed [31:0] lhs_l, rhs_l, lhs_r, rhs_r;
        begin
            lhs_l = 100 * cx;
            rhs_l = 60000 - 76 * (cy - 355);
            lhs_r = 1000 * cx;
            rhs_r = 1440000 + 714 * (cy - 350);
            out_floor = (cy < 360) || (cy > 1085) || (lhs_l < rhs_l) || (lhs_r > rhs_r);
        end
    endfunction

    // pygame Rect.colliderect: a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top
    // (the feet box is passed as arguments: a continuous assign only re-evaluates on argument changes)
    function hit(input signed [13:0] al, input signed [13:0] ar, input signed [13:0] at, input signed [13:0] ab,
                 input signed [13:0] bx, input signed [13:0] by, input signed [13:0] bw, input signed [13:0] bh);
        hit = (al < bx + bw) && (ar > bx) && (at < by + bh) && (ab > by);
    endfunction

    wire floor_out = out_floor(l, t) || out_floor(r, t) || out_floor(l, b) || out_floor(r, b);
    wire blk = hit(l, r, t, b, 620, 300, 200, 70)      // grey cabinet
            || hit(l, r, t, b, 815, 250, 140, 120)     // shelf
            || hit(l, r, t, b, 450, 440, 125, 120)     // lockers (left wall)
            || hit(l, r, t, b, 100, 880, 200, 125)     // low cabinet (bottom-left)
            || hit(l, r, t, b, 660, 420, 650, 120)     // table row 1 (back)
            || hit(l, r, t, b, 520, 615, 850, 150)     // table row 2
            || hit(l, r, t, b, 380, 860, 1080, 170)    // table row 3 (front)
            || hit(l, r, t, b, 1490, 525, 225, 250);   // teacher desk
    assign blocked = floor_out || blk;
endmodule
