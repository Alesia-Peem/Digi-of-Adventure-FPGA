// tb_pic_stream.v - TESTBENCH ONLY. pic_stream + qspi_reader against the behavioural S25FL128S model.
//   normal run (flash = mem/pictures.hex):
//     * magic check after reset -> missing = 0
//     * PIC_TITLE  : pic_load, then ALL rows 0..h-1, one distinct row per VGA line (3200 clk)
//     * PIC_S2_ROOM: pic_load, rows 0..31 and 300..h-1, each requested TWICE (0,0,1,1,..: Stage 1 style)
//       -> only one flash fetch per distinct row (tag compare), both screen lines show the same row
//     * every line: the row of the PREVIOUS row_req is read with rd_x at 4 clk / pixel over the whole
//       line, while the next row is fetched; rd_rgb latency must be exactly 2 clk
//     * line budget: cycles row_req -> busy low < 3200 (prints the measured worst case + margin)
//     * pixels -> sim/frames/pic_<NAME>.ppm (P3, maxval 15, "# rows ..." lists the rows dumped);
//       fpga/tools/pic_check.py compares them with mem/preview/pic_<NAME>.png
//   +ZERO run (flash all zeros): missing = 1 within 1 ms of reset, pic_load ignored, rd_rgb = stripes
// Prints "TB_PIC_STREAM: PASS" or the failing checks.
`timescale 1ns/1ps
module tb_pic_stream #(parameter integer LATE = 1);   // qspi_reader LATE_SAMPLE (run_tests runs both)
`include "pic_map.vh"
    localparam integer LINE = 3200;                  // 800 px x 4 clk at 100 MHz
    localparam integer FLASH_BYTES = 5077760;        // size of mem/pictures.hex

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg  [4:0]  pic_id = 5'd0;
    reg         pic_load = 1'b0, row_req = 1'b0;
    reg  [9:0]  src_row = 10'd0, rd_x = 10'd0;
    wire [11:0] rd_rgb;
    wire        busy, missing;
    wire        qspi_csn, qspi_sck;
    wire [3:0]  dq_o, dq_oe, dq_i;
    wire [3:0]  dq;
    pullup (dq[0]); pullup (dq[1]); pullup (dq[2]); pullup (dq[3]);
    assign dq[0] = dq_oe[0] ? dq_o[0] : 1'bz;
    assign dq[1] = dq_oe[1] ? dq_o[1] : 1'bz;
    assign dq[2] = dq_oe[2] ? dq_o[2] : 1'bz;
    assign dq[3] = dq_oe[3] ? dq_o[3] : 1'bz;
    assign dq_i = dq;

    pic_stream #(.PIC_BASE(PIC_BASE), .LATE_SAMPLE(LATE)) dut (
        .clk(clk), .rst(rst), .pic_id(pic_id), .pic_load(pic_load), .row_req(row_req), .src_row(src_row),
        .rd_x(rd_x), .rd_rgb(rd_rgb), .busy(busy), .missing(missing),
        .qspi_csn(qspi_csn), .qspi_sck(qspi_sck), .qspi_dq_i(dq_i), .qspi_dq_o(dq_o), .qspi_dq_oe(dq_oe));
    flash_model #(.BASE(PIC_BASE), .SIZE(FLASH_BYTES)) fm (.csn(qspi_csn), .sck(qspi_sck), .dq(dq));

    integer errors = 0;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    // bus contention: the FPGA must never drive DQ while the flash does
    integer n_cont = 0;
    always @(posedge clk) if (fm.drive && dq_oe != 4'b0000) n_cont = n_cont + 1;
    // fetch completion time (busy falling edge)
    reg busy_d = 1'b0;
    integer t_done = 0;
    always @(posedge clk) begin
        busy_d <= busy;
        if (busy_d && !busy) t_done = cyc;
    end

    task fail(input [8*80-1:0] msg);
        begin errors = errors + 1; if (errors < 30) $display("FAIL: %0s", msg); end
    endtask

    function [7:0] fbyte(input integer a);   // byte at PIC_BASE + a in the flash model
        fbyte = fm.mem[a];
    endfunction

    // stripe pattern shown while `missing` (must match pic_stream.v)
    function [11:0] stripe(input [9:0] x, input [9:0] r);
        reg [10:0] s;
        begin s = {1'b0, x} + {1'b0, r}; stripe = s[4] ? 12'hF0F : 12'h000; end
    endfunction

    // ---------------------------------------------------------------- one VGA line
    // row_req(req) at t0; read rd_x 0..nx-1 at t0+8+4x, sample 2 clk later (also checks rd_rgb did not
    // change after 1 clk); then wait for the end of the line and check the fetch budget.
    reg [11:0] pix [0:1023];
    integer t0, worst, n_fetch_lines, ncs0;
    integer x;
    reg [11:0] prev;
    task line(input [9:0] req, input integer nx);
        begin
            @(posedge clk);
            src_row <= req; row_req <= 1'b1; t0 = cyc + 1; ncs0 = fm.ncmd;
            @(posedge clk);
            row_req <= 1'b0;
            repeat (6) @(posedge clk);
            prev = 12'h000;
            for (x = 0; x < nx; x = x + 1) begin
                rd_x <= x[9:0];
                @(posedge clk); @(negedge clk);
                if (x > 0 && rd_rgb !== prev) fail("rd_rgb latency is not 2 clk (changed 1 clk after rd_x)");
                @(posedge clk); @(negedge clk);
                pix[x] = rd_rgb; prev = rd_rgb;
                @(posedge clk); @(posedge clk);
            end
            while (cyc < t0 + LINE - 2) @(posedge clk);
            if (busy) fail("fetch not finished before the next row_req (line budget)");
            if (fm.ncmd != ncs0) begin
                n_fetch_lines = n_fetch_lines + 1;
                if (t_done - t0 > worst) worst = t_done - t0;
                if (t_done - t0 >= LINE) fail("fetch longer than one VGA line");
            end
        end
    endtask

    // ---------------------------------------------------------------- stream one picture
    reg [9:0] rows [0:1023];   // distinct rows to show
    integer nrows;
    integer fh;
    integer w, h, i, k, rep, ncmd0, line_i, n_req;
    reg [11:0] first [0:1023];
    reg [8*64-1:0] fname;
    task stream(input [4:0] id, input [8*16-1:0] name, input integer repeated, input integer subset);
        begin
            w = {fbyte(8 + 8 * id + 5), fbyte(8 + 8 * id + 4)};
            h = {fbyte(8 + 8 * id + 7), fbyte(8 + 8 * id + 6)};
            nrows = 0;
            for (i = 0; i < h; i = i + 1)
                if (!subset || i < 32 || i >= 300) begin rows[nrows] = i; nrows = nrows + 1; end
            // pic_load in "vblank", wait for busy low (ruling R-d)
            @(posedge clk); pic_id <= id; pic_load <= 1'b1;
            @(posedge clk); pic_load <= 1'b0;
            @(posedge clk);
            if (!busy) fail("busy not high after pic_load");
            while (busy) @(posedge clk);
            $sformat(fname, "sim/frames/pic_%0s.ppm", name);
            fh = $fopen(fname, "w");
            $fwrite(fh, "P3\n# rows");
            for (i = 0; i < nrows; i = i + 1) $fwrite(fh, " %0d", rows[i]);
            $fwrite(fh, "\n%0d %0d\n15\n", w, nrows);
            ncmd0 = fm.ncmd; worst = 0; n_fetch_lines = 0;
            rep = repeated ? 2 : 1;
            n_req = nrows * rep;
            // line j requests request j (rows[j / rep]); it shows request j-1. One extra line at the end
            // repeats the last row (no fetch) so the last row becomes visible.
            for (line_i = 0; line_i <= n_req; line_i = line_i + 1) begin
                k = (line_i < n_req) ? line_i : n_req - 1;
                line(rows[k / rep], (line_i == 0) ? 0 : w);
                if (line_i > 0) begin
                    k = (line_i - 1) / rep;
                    if (!repeated || (line_i - 1) % 2 == 0) begin
                        for (i = 0; i < w; i = i + 1) begin
                            $fwrite(fh, "%0d %0d %0d\n", pix[i][11:8], pix[i][7:4], pix[i][3:0]);
                            first[i] = pix[i];
                        end
                    end else begin
                        for (i = 0; i < w; i = i + 1)
                            if (pix[i] !== first[i]) begin fail("repeated row differs on its 2nd line"); i = w; end
                    end
                end
            end
            $fclose(fh);
            if (fm.ncmd - ncmd0 != nrows) begin
                errors = errors + 1;
                $display("FAIL: %0s: %0d flash reads for %0d distinct rows", name, fm.ncmd - ncmd0, nrows);
            end
            $display("%0s: %0dx%0d, %0d rows streamed (%0s), %0d reads; worst row fetch %0d clk of %0d -> margin %0d clk (%0d ns)",
                     name, w, h, nrows, repeated ? "each row twice" : "distinct rows", fm.ncmd - ncmd0,
                     worst, LINE, LINE - worst, (LINE - worst) * 10);
        end
    endtask

    integer t_miss, r_shown;
    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        if ($test$plusargs("ZERO")) begin
            // ------------------------------------------------------- flash not programmed
            t_miss = -1;
            for (i = 0; i < 100000 && t_miss < 0; i = i + 1) begin   // 1 ms
                @(posedge clk);
                if (missing) t_miss = i;
            end
            if (t_miss < 0) fail("missing not asserted within 1 ms");
            else $display("missing asserted %0d clk (%0d ns) after reset", t_miss, t_miss * 10);
            @(posedge clk); pic_load <= 1'b1;
            @(posedge clk); pic_load <= 1'b0;
            repeat (3) @(posedge clk);
            if (busy) fail("busy after pic_load while missing");
            line(10'd5, 0);
            for (r_shown = 7; r_shown < 40; r_shown = r_shown + 11) begin
                line(r_shown[9:0], 0);
                line(10'd0, 700);                    // shows the row of the previous request
                for (i = 0; i < 700; i = i + 1)
                    if (pix[i] !== stripe(i[9:0], r_shown[9:0])) begin fail("stripe pattern wrong"); i = 700; end
            end
            if (busy) fail("busy while missing");
            if (fm.ncmd != 1) fail("flash read again after missing");
        end else begin
            // ------------------------------------------------------- programmed flash
            if (PIC_BASE != 24'h400000) fail("PIC_BASE changed");
            for (i = 0; i < 100000 && (busy || i < 4); i = i + 1) @(posedge clk);
            if (busy) fail("magic check not done within 1 ms");
            if (missing) fail("missing with a programmed flash");
            stream(PIC_TITLE, "TITLE", 0, 0);
            stream(PIC_S2_ROOM, "S2_ROOM", 1, 1);
        end
        if (fm.errors != 0) begin errors = errors + 1; $display("FAIL: %0d flash protocol errors", fm.errors); end
        if (n_cont != 0) begin errors = errors + 1; $display("FAIL: DQ bus contention on %0d cycles", n_cont); end
        if (errors == 0) $display("TB_PIC_STREAM: PASS (LATE_SAMPLE=%0d%0s)", LATE, $test$plusargs("ZERO") ? ", flash zero -> missing" : "");
        else $display("TB_PIC_STREAM: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
