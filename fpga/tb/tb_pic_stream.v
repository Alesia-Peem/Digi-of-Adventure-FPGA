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
//   +ZERO run (flash all zeros): missing = 1 within 1 ms of reset, row_req never reads the flash, rd_rgb =
//     stripes; a pic_load while missing re-reads the header (still missing for zeros and for "CPEP" with a
//     wrong picture count); after the real image is written into the model, a pic_load clears `missing`
//     and the picture streams correctly
//   both runs: CS# is 1 from time 0 (initial value, before reset); no SCK edge before the configuration
//     end-of-startup (cfg_eos, held low for the first EOS_LOW clk) and >= 100 clk of cfg_eos = 1 before the
//     first SCK edge; qspi_reader samples DQ through a register (dut.u_qr.dq_iob = dq_i one clk earlier)
// Prints "TB_PIC_STREAM: PASS" or the failing checks.
`timescale 1ns/1ps
module tb_pic_stream #(parameter integer LATE = 1);   // qspi_reader LATE_SAMPLE (run_tests runs both)
`include "pic_map.vh"
    localparam integer LINE = 3200;                  // 800 px x 4 clk at 100 MHz
    localparam integer FLASH_BYTES = PIC_BYTES;      // size of mem/pictures.hex (pic_map.vh)
    localparam integer EOS_LOW = 3000;               // clk after reset release with cfg_eos = 0

    reg clk = 1'b0, rst = 1'b1;
    reg cfg_eos = 1'b0;
    initial begin repeat (5 + EOS_LOW) @(posedge clk); cfg_eos <= 1'b1; end   // STARTUPE2.EOS stand-in
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

    pic_stream #(.PIC_BASE(PIC_BASE), .PIC_COUNT(PIC_COUNT), .LATE_SAMPLE(LATE)) dut (
        .clk(clk), .rst(rst), .cfg_eos(cfg_eos), .pic_id(pic_id), .pic_load(pic_load), .row_req(row_req), .src_row(src_row),
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

    // CS# high from time 0 (FPGA power-up value), before any reset
    initial begin #1; if (qspi_csn !== 1'b1) fail("qspi_csn is not 1 before reset (initial value)"); end
    // start-up clocks only after STARTUPE2.EOS: no SCK edge while cfg_eos = 0, and cfg_eos = 1 for >= 100 clk
    integer t_eos = -1, t_sck1 = -1, n_sck_noeos = 0;
    reg sck_d = 1'b0;
    always @(posedge clk) begin
        sck_d <= qspi_sck;
        if (cfg_eos && t_eos < 0) t_eos = cyc;
        if (qspi_sck !== sck_d) begin
            if (!cfg_eos) n_sck_noeos = n_sck_noeos + 1;
            if (t_sck1 < 0) t_sck1 = cyc;
        end
    end
    // DQ is sampled through a register (IOB flip-flop): dq_iob = dq_i of the previous clk
    reg [3:0] dq_i_d = 4'h0;
    integer n_iob = 0;
    always @(posedge clk) begin
        dq_i_d <= dq_i;
        if (cyc > 2 && dut.u_qr.dq_iob !== dq_i_d) n_iob = n_iob + 1;
    end

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
    // subset: 0 all rows, 1 rows 0..31 + 300..h-1, 2 rows 356, 357, 300 (tag reset after a picture change)
    task stream(input [4:0] id, input [8*16-1:0] name, input integer repeated, input integer subset);
        begin
            w = {fbyte(8 + 8 * id + 5), fbyte(8 + 8 * id + 4)};
            h = {fbyte(8 + 8 * id + 7), fbyte(8 + 8 * id + 6)};
            nrows = 0;
            if (subset == 2) begin          // rows S2_ROOM leaves resident in both halves, then another one
                rows[0] = 356; rows[1] = 357; rows[2] = 300; nrows = 3;
            end else
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

    // expected pixel straight from the flash model (header -> palette -> index)
    function [11:0] exp_rgb(input [4:0] id, input integer row, input integer x);
        integer off, pw, a;
        begin
            off = {fbyte(8 + 8 * id + 3), fbyte(8 + 8 * id + 2), fbyte(8 + 8 * id + 1), fbyte(8 + 8 * id)};
            pw  = {fbyte(8 + 8 * id + 5), fbyte(8 + 8 * id + 4)};
            a   = fbyte(off + 512 + row * pw + x);
            exp_rgb = {fbyte(off + 2 * a + 1), fbyte(off + 2 * a)};
        end
    endfunction
    task pulse_row(input [9:0] r);
        begin @(posedge clk); src_row <= r; row_req <= 1'b1; @(posedge clk); row_req <= 1'b0; end
    endtask
    task pulse_load(input [4:0] id);
        begin @(posedge clk); pic_id <= id; pic_load <= 1'b1; @(posedge clk); pic_load <= 1'b0; end
    endtask
    task expect_row(input [4:0] id, input integer row, input [8*48-1:0] what);
        begin
            for (i = 0; i < 640; i = i + 1)
                if (pix[i] !== exp_rgb(id, row, i)) begin fail(what); i = 640; end
        end
    endtask
    // directed: requests that arrive while a fetch is running are queued, the latest one wins
    task queued_requests;
        begin
            ncmd0 = fm.ncmd;
            pulse_row(10'd10);                      // fetch of 10 starts
            repeat (100) @(posedge clk);
            if (!busy) fail("no fetch running for the queued-request test");
            pulse_row(10'd20);                      // queued ...
            repeat (100) @(posedge clk);
            pulse_row(10'd30);                      // ... and replaced by 30 (latest wins)
            while (busy) @(posedge clk);
            if (fm.ncmd - ncmd0 != 2) fail("queued row_req: expected fetches of rows 10 and 30 only");
            line(10'd30, 640);                      // 30 resident -> no fetch, shown now
            if (fm.ncmd - ncmd0 != 2) fail("queued row_req: row 30 fetched twice");
            expect_row(PIC_TITLE, 30, "queued row_req: row 30 wrong");
            // pic_load during a fetch: queued, runs after it, invalidates the TITLE rows
            ncmd0 = fm.ncmd;
            pulse_row(10'd40);
            repeat (100) @(posedge clk);
            if (!busy) fail("no fetch running for the queued-load test");
            pulse_load(PIC_S2_ROOM);
            while (busy) @(posedge clk);
            if (fm.ncmd - ncmd0 != 3) fail("queued pic_load: expected row 40 + header + palette");
            line(10'd30, 0);                        // 30 was TITLE's: must be fetched again
            line(10'd30, 640);
            if (fm.ncmd - ncmd0 != 4) fail("queued pic_load: row 30 not re-fetched after the load");
            expect_row(PIC_S2_ROOM, 30, "queued pic_load: S2_ROOM row 30 wrong");
            $display("queued requests: row_req during a fetch (latest wins) and pic_load during a fetch checked");
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
            while (busy) @(posedge clk);
            line(10'd5, 0);
            for (r_shown = 7; r_shown < 40; r_shown = r_shown + 11) begin
                line(r_shown[9:0], 0);
                line(10'd0, 700);                    // shows the row of the previous request
                for (i = 0; i < 700; i = i + 1)
                    if (pix[i] !== stripe(i[9:0], r_shown[9:0])) begin fail("stripe pattern wrong"); i = 700; end
            end
            if (busy) fail("busy while missing (row requests)");
            if (fm.ncmd != 1) fail("row_req read the flash while missing");
            // pic_load while missing: header read again, still missing (flash still zero)
            pulse_load(PIC_TITLE);
            repeat (2) @(posedge clk);
            if (!busy) fail("pic_load while missing does not re-check the flash header");
            while (busy) @(posedge clk);
            if (fm.ncmd != 2) fail("pic_load while missing: expected exactly one header read");
            if (!missing) fail("missing cleared with a zero flash");
            // "CPEP" with a wrong picture count: still missing
            fm.mem[0] = "C"; fm.mem[1] = "P"; fm.mem[2] = "E"; fm.mem[3] = "P";
            fm.mem[4] = PIC_COUNT + 1; fm.mem[5] = 8'd0;
            pulse_load(PIC_TITLE);
            repeat (2) @(posedge clk);
            while (busy) @(posedge clk);
            if (fm.ncmd != 3) fail("pic_load while missing (bad count): expected one header read");
            if (!missing) fail("magic CPEP with a wrong picture count accepted");
            // real image now in the flash (e.g. programmed over JTAG while running): pic_load recovers
            $readmemh("mem/pictures.hex", fm.mem);
            pulse_load(PIC_TITLE);
            repeat (2) @(posedge clk);
            while (busy) @(posedge clk);
            if (missing) fail("missing not cleared by pic_load after the flash was programmed");
            line(10'd30, 0);
            line(10'd31, 640);
            expect_row(PIC_TITLE, 30, "after recovery: TITLE row 30 wrong");
            line(10'd31, 640);
            expect_row(PIC_TITLE, 31, "after recovery: TITLE row 31 wrong");
            $display("missing: re-checked on pic_load (zero flash, bad count), recovered after programming");
        end else begin
            // ------------------------------------------------------- programmed flash
            if (PIC_BASE != 24'h400000) fail("PIC_BASE changed");
            for (i = 0; i < 100000 && (busy || i < 4); i = i + 1) @(posedge clk);
            if (busy) fail("magic check not done within 1 ms");
            if (missing) fail("missing with a programmed flash");
            stream(PIC_TITLE, "TITLE", 0, 0);
            stream(PIC_S2_ROOM, "S2_ROOM", 1, 1);
            stream(PIC_TITLE, "TITLE_RELOAD", 0, 2);  // rows 356/357 still hold S2_ROOM data -> must refetch
            queued_requests;
        end
        if (fm.errors != 0) begin errors = errors + 1; $display("FAIL: %0d flash protocol errors", fm.errors); end
        if (n_cont != 0) begin errors = errors + 1; $display("FAIL: DQ bus contention on %0d cycles", n_cont); end
        if (n_sck_noeos != 0) begin errors = errors + 1; $display("FAIL: %0d SCK edges before cfg_eos", n_sck_noeos); end
        if (t_sck1 >= 0 && t_eos >= 0 && t_sck1 - t_eos < 100) begin
            errors = errors + 1; $display("FAIL: first SCK edge only %0d clk after cfg_eos (need >= 100)", t_sck1 - t_eos);
        end
        if (n_iob != 0) begin errors = errors + 1; $display("FAIL: dq_iob != dq_i of the previous clk on %0d clk", n_iob); end
        if (errors == 0) $display("TB_PIC_STREAM: PASS (LATE_SAMPLE=%0d%0s)", LATE, $test$plusargs("ZERO") ? ", flash zero -> missing" : "");
        else $display("TB_PIC_STREAM: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
