// s2_circuit.v - logic value of one breadboard net, exactly like val() of stage2_demo.py:
//   '1' -> 1, '0' -> 0, C/B/A -> level on the DIP switch output (computed by the caller),
//   a node already on the current path -> 0 (the `seen` rule: breaks wiring loops the same way),
//   220-ohm resistor R? -> value of what its input end is wired to (0 if nothing),
//   gate -> 0 if its chip has no +5V/GND or an input is unwired, else NOT / AND / OR of its inputs.
// The recursion is done with an explicit stack (max depth 22 = 15 gates + 7 resistors).
// Node numbers = index in [None] + SRC_LIST: 1 '1', 2 '0', 3 C, 4 B, 5 A, 6..8 N1-3, 9..12 A1-4,
// 13..20 O1-8, 21..27 Ra..Rg.
`timescale 1ns/1ps
module s2_circuit (
    input  wire         clk,
    input  wire         start,
    input  wire [4:0]   node,
    input  wire         lc, lb, la,      // switch output levels (levels() of the demo)
    input  wire [269:0] w,               // wiring: sink i -> source w[5i +: 5]
    output reg          done,
    output reg          val
);
`include "s2_consts.vh"
    function [4:0] ws(input [5:0] i); ws = w[5 * i +: 5]; endfunction

    reg  [4:0]  sn  [0:23];               // stack: node
    reg         sph [0:23];               // stack: second input in progress
    reg  [4:0]  sp;                       // stack depth
    reg  [27:0] seen;
    reg  [4:0]  cn;                       // node being called
    reg         rv;                       // value being returned
    reg  [1:0]  st;                       // 0 idle, 1 call, 2 return
    reg  [12:0] steps;

    // gate g = node - 6 (0..14): unit and inputs
    wire [3:0]  g     = cn - 5'd6;
    wire        u_ok  = (g <= 4'd2)  ? (ws(SK_U1_VCC) == 5'd1 && ws(SK_U1_GND) == 5'd2) :
                        (g <= 4'd6)  ? (ws(SK_U2_VCC) == 5'd1 && ws(SK_U2_GND) == 5'd2) :
                        (g <= 4'd10) ? (ws(SK_U3_VCC) == 5'd1 && ws(SK_U3_GND) == 5'd2) :
                                       (ws(SK_U4_VCC) == 5'd1 && ws(SK_U4_GND) == 5'd2);
    wire [4:0]  in_a  = ws(gate_in_a({4'd0, g}));
    wire [4:0]  in_b  = ws(gate_in_b({4'd0, g}));
    wire        two   = (g >= 4'd3);
    wire [4:0]  r_in  = ws(SK_S0 + (cn - 5'd21));
    // top of stack (for the return step)
    wire [4:0]  tn    = sn[sp - 5'd1];
    wire        tph   = sph[sp - 5'd1];
    wire [3:0]  tg    = tn - 5'd6;
    wire [4:0]  tin_b = ws(gate_in_b({4'd0, tg}));

    always @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            sp <= 5'd0; seen <= 28'd0; cn <= node; st <= 2'd1; steps <= 13'd0;
        end else if (st != 2'd0) begin
            steps <= steps + 13'd1;
            if (steps == 13'h1FFF) begin st <= 2'd0; done <= 1'b1; val <= 1'b0; end   // safety cap
            else if (st == 2'd1) begin                                            // ---- call cn
                if (cn == 5'd1)      begin rv <= 1'b1; st <= 2'd2; end
                else if (cn == 5'd2 || cn == 5'd0) begin rv <= 1'b0; st <= 2'd2; end
                else if (cn == 5'd3) begin rv <= lc; st <= 2'd2; end
                else if (cn == 5'd4) begin rv <= lb; st <= 2'd2; end
                else if (cn == 5'd5) begin rv <= la; st <= 2'd2; end
                else if (seen[cn])   begin rv <= 1'b0; st <= 2'd2; end
                else if (cn >= 5'd21) begin                                       // resistor
                    if (r_in == 5'd0) begin rv <= 1'b0; st <= 2'd2; end
                    else begin sn[sp] <= cn; sph[sp] <= 1'b0; sp <= sp + 5'd1; seen[cn] <= 1'b1; cn <= r_in; end
                end else begin                                                    // gate
                    if (!u_ok || in_a == 5'd0 || (two && in_b == 5'd0)) begin rv <= 1'b0; st <= 2'd2; end
                    else begin sn[sp] <= cn; sph[sp] <= 1'b0; sp <= sp + 5'd1; seen[cn] <= 1'b1; cn <= in_a; end
                end
            end else begin                                                        // ---- return rv
                if (sp == 5'd0) begin st <= 2'd0; done <= 1'b1; val <= rv; end
                else if (tn >= 5'd21) begin sp <= sp - 5'd1; seen[tn] <= 1'b0; end          // R: pass through
                else if (tn <= 5'd8) begin sp <= sp - 5'd1; seen[tn] <= 1'b0; rv <= !rv; end // NOT
                else if (!tph && (tn <= 5'd12 ? !rv : rv)) begin                            // AND 0 / OR 1: done
                    sp <= sp - 5'd1; seen[tn] <= 1'b0;
                end else if (!tph) begin sph[sp - 5'd1] <= 1'b1; cn <= tin_b; st <= 2'd1; end // second input
                else begin sp <= sp - 5'd1; seen[tn] <= 1'b0; end                           // AND/OR = rv
            end
        end
    end
    initial st = 2'd0;
endmodule
