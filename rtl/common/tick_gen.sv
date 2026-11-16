// Synthesizable. 1-cycle pulse once per second (CLK_HZ cycles). Use small CLK_HZ in sim.
module tick_gen #(parameter int CLK_HZ = 100_000_000) (
  input  logic clk,
  input  logic rst,
  output logic tick_1hz
);
  localparam int W = $clog2(CLK_HZ);
  logic [W-1:0] cnt;
  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= '0; tick_1hz <= 1'b0;
    end else if (cnt == CLK_HZ-1) begin
      cnt <= '0; tick_1hz <= 1'b1;
    end else begin
      cnt <= cnt + 1'b1; tick_1hz <= 1'b0;
    end
  end
endmodule