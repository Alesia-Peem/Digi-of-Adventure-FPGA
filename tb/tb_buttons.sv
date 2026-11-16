// TESTBENCH ONLY (not synthesizable)
`timescale 1ns/1ps
module tb_buttons;
  logic clk = 0, rst = 1, raw = 0;
  wire  level, press, tap, long_press;
  integer n_press = 0, n_tap = 0, n_long = 0, errors = 0;

  always #5 clk = ~clk;

  button_unit #(.DEBOUNCE_CYCLES(4), .LONG_CYCLES(30)) dut (
    .clk(clk), .rst(rst), .raw(raw), .level(level), .press(press), .tap(tap), .long_press(long_press));

  always @(posedge clk) begin
    if (press)      n_press <= n_press + 1;
    if (tap)        n_tap   <= n_tap   + 1;
    if (long_press) n_long  <= n_long  + 1;
  end

  task automatic hold(input integer cycles, input logic v);
    begin raw = v; repeat (cycles) @(negedge clk); end
  endtask

  task automatic expect_counts(input integer p, input integer t, input integer l,
                               input [8*24-1:0] name);
    begin
      if (n_press !== p || n_tap !== t || n_long !== l) begin
        errors = errors + 1;
        $display("FAIL %0s: press=%0d tap=%0d long=%0d (expected %0d %0d %0d)",
                 name, n_press, n_tap, n_long, p, t, l);
      end
    end
  endtask

  initial begin
    $dumpfile("sim/tb_buttons.vcd"); $dumpvars(0, tb_buttons);
    repeat (4) @(negedge clk); rst = 0; repeat (4) @(negedge clk);

    hold(2, 1);  hold(20, 0);                       expect_counts(0, 0, 0, "glitch rejected");
    hold(12, 1); hold(20, 0);                       expect_counts(1, 1, 0, "short press");
    hold(1, 1); hold(1, 0); hold(1, 1); hold(1, 0); // bounce
    hold(12, 1); hold(20, 0);                       expect_counts(2, 2, 0, "bouncy press");
    hold(70, 1); hold(20, 0);                       expect_counts(3, 2, 1, "long press, no tap");

    if (errors == 0) $display("TB_BUTTONS: PASS"); else $display("TB_BUTTONS: FAIL (%0d)", errors);
    $finish;
  end
endmodule