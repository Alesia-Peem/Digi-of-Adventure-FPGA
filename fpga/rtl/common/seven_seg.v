// seven_seg.v - drives the 8-digit common-anode display of the Nexys A7 (AN and CA..CG active LOW).
// chars[5*i +: 5] = character of digit i, i = 0 is the LEFTMOST digit (AN[7]) - same order as the
// text string drawn by draw_panel() in Pygame ("H3" + right-justified live value).
// raw_en[i] = 1 -> digit i shows raw_seg[7*i +: 7] ({g,f,e,d,c,b,a}, 1 = lit) instead (Stage 2 decoder).
// Each digit is lit for 2^17 cycles = 1.3 ms -> ~95 Hz refresh, no flicker.
`timescale 1ns/1ps
module seven_seg (
    input  wire        clk,
    input  wire        rst,
    input  wire [39:0] chars,
    input  wire [7:0]  raw_en,
    input  wire [55:0] raw_seg,
    output reg  [7:0]  an,
    output reg  [6:0]  seg,      // {CG,CF,CE,CD,CC,CB,CA} active low
    output wire        dp
);
    reg [19:0] cnt;
    always @(posedge clk) cnt <= rst ? 20'd0 : cnt + 20'd1;
    wire [2:0] d = cnt[19:17];
    wire [4:0] ch = chars[5*d +: 5];
    reg  [6:0] on;     // {g,f,e,d,c,b,a}
    always @(*) begin
        case (ch)
            5'd0: on = 7'b0111111;  5'd1: on = 7'b0000110;  5'd2: on = 7'b1011011;  5'd3: on = 7'b1001111;
            5'd4: on = 7'b1100110;  5'd5: on = 7'b1101101;  5'd6: on = 7'b1111101;  5'd7: on = 7'b0000111;
            5'd8: on = 7'b1111111;  5'd9: on = 7'b1101111;
            5'd10: on = 7'b1110110; // H  bcefg
            5'd11: on = 7'b1000000; // -  g
            5'd12: on = 7'b0000000; // blank
            5'd13: on = 7'b1111001; // E  adefg
            5'd14: on = 7'b1110011; // P  abefg
            5'd15: on = 7'b0111001; // C  adef
            5'd16: on = 7'b1110111; // A  abcefg
            5'd17: on = 7'b1110001; // F  aefg
            5'd18: on = 7'b0111000; // L  def
            5'd19: on = 7'b0111111; // O  abcdef
            5'd20: on = 7'b0111110; // U  bcdef
            5'd21: on = 7'b1011110; // d  bcdeg
            5'd22: on = 7'b1101101; // S  acdfg
            default: on = 7'b1000000;   // unknown -> "g" like SEG_MAP.get(ch, "g")
        endcase
    end
    always @(posedge clk) begin
        an  <= ~(8'b1000_0000 >> d);           // digit 0 = AN[7] (leftmost)
        seg <= ~(raw_en[d] ? raw_seg[7*d +: 7] : on);
    end
    assign dp = 1'b1;
endmodule
