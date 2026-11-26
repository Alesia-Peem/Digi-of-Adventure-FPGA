// cr_tb_math.v - TESTBENCH ONLY. cr_math.v against sim/cr_math_vec.mem (written by cr_cosim.py genmath):
// one line per vector {op[7:0], a[79:0], b[79:0], result[79:0]}; op 0 multiply, 1 floor divide, 2 floor sqrt.
`timescale 1ns/1ps
module cr_tb_math;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg start = 0; reg [1:0] op = 0; reg [79:0] a = 0, b = 0;
    wire busy, done; wire [79:0] result;
    cr_math dut (.clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b), .busy(busy), .done(done),
                 .result(result));
    reg [247:0] vec [0:4095];
    integer n, i, bad, longest, t;
    initial begin
        for (i = 0; i < 4096; i = i + 1) vec[i] = {248{1'bx}};
        $readmemh("sim/cr_math_vec.mem", vec);
        n = 0; while (n < 4096 && vec[n][0] !== 1'bx) n = n + 1;
        repeat (3) @(posedge clk); @(negedge clk) rst = 0;
        bad = 0; longest = 0;
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk) begin op = vec[i][241:240]; a = vec[i][239:160]; b = vec[i][159:80]; start = 1; end
            @(negedge clk) start = 0;
            t = 1;
            while (!done) begin @(negedge clk); t = t + 1; if (t > 200) begin $display("FAIL vector %0d: no done", i); $finish; end end
            if (t > longest) longest = t;
            if (result !== vec[i][79:0]) begin
                if (bad < 5) $display("FAIL vector %0d op %0d: a=%h b=%h want %h got %h", i, op, a, b, vec[i][79:0], result);
                bad = bad + 1;
            end
        end
        if (n < 900) begin $display("FAIL only %0d vectors read", n); bad = bad + 1; end
        $display("CR_TB_MATH: %s (%0d vectors, %0d wrong, longest %0d clocks)", bad ? "FAIL" : "PASS", n, bad, longest);
        $finish;
    end
endmodule
