// Synthesizable. Conditions the 5 push buttons + 16 switches.
// btn_raw order: [0]=BTNU [1]=BTND [2]=BTNL [3]=BTNR [4]=BTNC
// State-dependent mapping is done by each consumer's "en" input (see the table in the design notes).
module input_hub #(
  parameter int DEBOUNCE_CYCLES = 1_000_000,
  parameter int LONG_CYCLES     = 80_000_000
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [4:0]  btn_raw,
  input  logic [15:0] sw_raw,
  output logic [4:0]  lvl,      // debounced levels
  output logic [4:0]  press,    // 1-cycle press pulses
  output logic        tap_c,    // BTNC short tap (on release)
  output logic        long_c,   // BTNC long press
  output logic [15:0] sw        // synchronized switches
);
  genvar i;
  generate
    for (i = 0; i < 5; i = i + 1) begin : g_btn
      logic tap_i, long_i;
      button_unit #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .LONG_CYCLES(LONG_CYCLES)) u_btn (
        .clk(clk), .rst(rst), .raw(btn_raw[i]),
        .level(lvl[i]), .press(press[i]), .tap(tap_i), .long_press(long_i));
    end
  endgenerate
  assign tap_c  = g_btn[4].tap_i;
  assign long_c = g_btn[4].long_i;

  logic [15:0] sw_m;
  always_ff @(posedge clk) begin
    if (rst) begin sw_m <= '0; sw <= '0; end
    else     begin sw_m <= sw_raw; sw <= sw_m; end
  end
endmodule