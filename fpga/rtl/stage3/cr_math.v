// cr_math.v - shared sequential arithmetic for cr_core.v, 80-bit unsigned, one bit per clock.
//   op 0: result = a * b       (low 80 bits; cr_core only asks for products that fit)
//   op 1: result = a / b       floor; b = 0 gives all ones (never asked); rem = a % b
//   op 2: result = isqrt(a)    floor square root (b ignored)
// `start` for one clock; `done` pulses for one clock when `result` is valid; it stays valid until the next start.
// At most 81 clocks. Python reference: a * b, a // b, math.isqrt(a) (tools/cr_cosim.py genmath).
`timescale 1ns/1ps
module cr_math (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  op,
    input  wire [79:0] a,
    input  wire [79:0] b,
    output reg         busy,
    output reg         done,
    output reg  [79:0] result,
    output wire [79:0] rem
);
    reg [1:0]  o;
    reg [6:0]  n;           // bits left
    reg [79:0] x, y;        // mul: shifted a / remaining b; div: dividend bits / divisor; sqrt: remainder / -
    reg [80:0] r;           // mul: product; div: partial remainder; sqrt: root
    reg [79:0] bit2;        // sqrt: the current power of four

    wire [80:0] trial_div = {r[79:0], x[79]};               // remainder with the next dividend bit
    wire [80:0] trial_sq  = r + {1'b0, bit2};               // root + bit

    wire [80:0] mul_next = y[0] ? r + {1'b0, x} : r;
    wire        sq_take  = {1'b0, x} >= trial_sq;
    wire [80:0] sq_next  = sq_take ? (r >> 1) + {1'b0, bit2} : (r >> 1);
    wire        div_take = y != 80'd0 && trial_div >= {1'b0, y};
    assign rem = r[79:0];                // after a division: the remainder (valid with done)

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; result <= 80'd0;
        end else if (start) begin
            busy <= 1'b1; o <= op; x <= a; y <= b; r <= 81'd0;
            bit2 <= 80'd1 << 78;
            n <= (op == 2'd2) ? 7'd40 : 7'd80;
        end else if (busy) begin
            case (o)
                2'd0: begin                               // shift-and-add
                    r <= mul_next; x <= x << 1; y <= y >> 1;
                    if (n == 7'd1) result <= mul_next[79:0];
                end
                2'd1: begin                               // restoring division, quotient shifts into result
                    x <= x << 1;
                    r <= div_take ? trial_div - {1'b0, y} : trial_div;
                    result <= {result[78:0], div_take | (y == 80'd0)};
                end
                default: begin                            // digit-by-digit square root
                    if (sq_take) x <= x - trial_sq[79:0];
                    r <= sq_next; bit2 <= bit2 >> 2;
                    if (n == 7'd1) result <= sq_next[79:0];
                end
            endcase
            n <= n - 7'd1;
            if (n == 7'd1) begin
                busy <= 1'b0; done <= 1'b1;
            end
        end
    end
endmodule
