// Synthesizable. Async-assert, sync-release reset. Output rst is ACTIVE-HIGH.
module reset_sync (
  input  logic clk,
  input  logic rst_n_async,   // CPU_RESETN (active low)
  output logic rst
);
  logic [1:0] ff;
  always_ff @(posedge clk or negedge rst_n_async) begin
    if (!rst_n_async) ff <= 2'b00;
    else              ff <= {ff[0], 1'b1};
  end
  assign rst = ~ff[1];
endmodule