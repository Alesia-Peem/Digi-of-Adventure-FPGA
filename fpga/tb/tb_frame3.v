// tb_frame3.v - TESTBENCH ONLY (Stage 3 version of tb_frame.v): s3_core -> ui_composer -> line_renderer. Plays a Pygame-generated input script on the real video pipeline
// (s1_core -> ui_composer -> line_renderer -> VGA pins) and, at selected ticks, captures one complete
// VGA frame as a PPM picture plus the UI fields/conditions used to build it.
// fpga/tools/frame_check.py renders the same fields with the Python model of the UI engine and checks
// that both pictures are identical pixel for pixel; it also writes side-by-side PNGs for inspection.
//   plusargs: +STIM=sim/s1_full_stim.mem  +SNAP=sim/frame_ticks.txt (one tick number per line)
//             +OUTDIR=sim/frames/
`timescale 1ns/1ps
module tb_frame3;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        gtick = 0, ev_u = 0, ev_d = 0, ev_tap = 0;
    reg [4:0]  lvl = 0;
    reg        demo_cmd = 0;
    reg [3:0]  demo_op = 0;
    reg [15:0] demo_arg = 0;
    wire [3071:0] fields; wire [255:0] conds0;
    wire [2:0]  bg_mode; wire [12:0] cam_px; wire [7:0] wave_ph; wire [15:0] hill_ph;
    wire [255:0] conds = conds0 | (256'd1 << 252);          // IS_S3 (normally set by the stage manager)
    s3_core core (.clk(clk), .rst(rst), .gtick(gtick), .ev_u(ev_u), .ev_d(ev_d), .ev_l(1'b0), .ev_r(1'b0),
        .ev_tap(ev_tap), .ev_back(1'b0), .lvl(lvl), .enter(1'b0), .exit_req(), .demo_cmd(demo_cmd),
        .demo_op(demo_op), .demo_arg(demo_arg), .fields(fields), .conds(conds0), .bg_mode(bg_mode),
        .cam_px(cam_px), .wave_ph(wave_ph), .hill_ph(hill_ph), .seg_chars(), .leds(), .rgb16(), .rgb17());

    wire        pix_ce, active, hs, vs, line_start, frame_end;
    wire [9:0]  hcount, vcount;
    vga_timing vt (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount), .active(active),
        .hsync(hs), .vsync(vs), .line_start(line_start), .frame_end(frame_end));
    wire        dl_we, tx_we, busy, dl_full, ovf;
    wire [7:0]  dl_waddr; wire [63:0] dl_wdata; wire [11:0] tx_waddr; wire [6:0] tx_wdata;
    ui_composer #(.PROG_FILE("mem/ui_prog.mem"), .STR_FILE("mem/ui_str.mem"), .PTR_FILE("mem/ui_ptr.mem")) comp (
        .clk(clk), .rst(rst), .start(frame_end), .fields(fields), .conds(conds), .busy(busy),
        .dl_we(dl_we), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .tx_we(tx_we), .tx_waddr(tx_waddr),
        .tx_wdata(tx_wdata), .dl_full(dl_full));
    wire [3:0] r, g, b; wire vhs, vvs;
    line_renderer lr (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount), .active(active),
        .hsync(hs), .vsync(vs), .bg_mode(bg_mode), .bg_color(12'h000), .bg_color2(12'h000), .cam_x(11'd0),
        .cam_y(10'd0), .zoom_ox(12'd0), .zoom_oy(12'd0), .zoom_inv(17'd65536), .wire_src(270'd0), .src_val(28'd0),
        .wire_hl(7'd0), .hill_ph(hill_ph), .wave_ph(wave_ph), .s3_cam(cam_px),
        .pic_rgb(12'h000), .pic_w(10'd0), .pic_h(10'd0), .fade(5'd16), .pic_row_req(), .pic_src_row(), .pic_rd_x(),
        .dl_we(dl_we), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .tx_we(tx_we), .tx_waddr(tx_waddr),
        .tx_wdata(tx_wdata), .vga_r(r), .vga_g(g), .vga_b(b), .vga_hs(vhs), .vga_vs(vvs), .overflow(ovf));

    // ---------------------------------------------------------------- frame capture
    // VGA pins change at pix_ce and then show pixel (hcount-1) of that pix_ce; sampled at the NEXT
    // pix_ce edge they still hold it -> two pixel-clock delays between (hcount, vcount) and the pins.
    reg [9:0] ph = 0, pv = 0, ph2 = 0, pv2 = 0; reg pact = 0, pact2 = 0;
    reg       capturing = 0;          // driven only by the initial block below
    integer   fpix, nseen;
    reg [11:0] img [0:640*480-1];
    always @(posedge clk) if (pix_ce) begin
        if (capturing && pact2) img[pv2 * 640 + ph2] <= {r, g, b};
        ph <= hcount; pv <= vcount; pact <= active;
        ph2 <= ph; pv2 <= pv; pact2 <= pact;
    end

    reg [31:0] stim [0:16383];
    integer snaps [0:63];
    integer nsnap, si, n, i, k, fd;
    reg [1023:0] stim_file, snap_file, outdir, fname, pre;

    task dump_state(input integer tickno);
        integer j;
        begin
            $sformat(fname, "%0s/%0s%0d_fields.txt", outdir, pre, tickno);
            fd = $fopen(fname, "w");
            $fdisplay(fd, "bg %0d 0 0 0", bg_mode);
            $fdisplay(fd, "s3 %0d %0d %0d", cam_px, wave_ph, hill_ph);
            for (j = 1; j < 128; j = j + 1) $fdisplay(fd, "f %0d %0d", j, fields[24*j +: 24]);
            for (j = 1; j < 256; j = j + 1) if (conds[j]) $fdisplay(fd, "c %0d", j);
            $fclose(fd);
        end
    endtask
    task dump_ppm(input integer tickno);
        integer j;
        begin
            $sformat(fname, "%0s/%0s%0d.ppm", outdir, pre, tickno);
            fd = $fopen(fname, "w");
            $fdisplay(fd, "P3 640 480 15");
            for (j = 0; j < 640 * 480; j = j + 1) $fdisplay(fd, "%0d %0d %0d", img[j][11:8], img[j][7:4], img[j][3:0]);
            $fclose(fd);
        end
    endtask

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) stim_file = "sim/s3_cp185_stim.mem";
        if (!$value$plusargs("SNAP=%s", snap_file)) snap_file = "sim/frame_ticks3_cp185.txt";
        if (!$value$plusargs("OUTDIR=%s", outdir))  outdir = "sim/frames";
        if (!$value$plusargs("PRE=%s", pre))        pre = "h";
        for (i = 0; i < 16384; i = i + 1) stim[i] = 32'hFFFFFFFF;
        $readmemh(stim_file, stim);
        for (i = 0; i < 64; i = i + 1) snaps[i] = -1;
        $readmemh(snap_file, snaps);   // hex tick numbers
        nsnap = 0; while (nsnap < 64 && snaps[nsnap] != -1) nsnap = nsnap + 1;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (3000) @(posedge clk);
        si = 0;
        for (i = 0; si < nsnap; i = i + 1) begin
            if (stim[i][8]) begin                                  // checkpoint (jump_to)
                @(negedge clk) begin demo_op = 4'd1; demo_arg = stim[i][23:16]; demo_cmd = 1; end
                @(negedge clk) demo_cmd = 0;
                repeat (3000) @(posedge clk);
            end else begin
                @(negedge clk) lvl = {1'b0, stim[i][1], stim[i][0], 2'b00};
                @(negedge clk) begin {ev_tap, ev_d, ev_u} = stim[i][4:2]; gtick = 1; end
                @(negedge clk) begin gtick = 0; {ev_tap, ev_d, ev_u} = 3'd0; end
                repeat (4) @(posedge clk);
                while (core.q != 0) @(posedge clk);
            end
            repeat (3) @(posedge clk);
            if (i == snaps[si]) begin
                @(posedge frame_end); repeat (2) @(posedge clk);
                dump_state(i);
                wait (pix_ce && hcount == 0 && vcount == 0); @(negedge clk); capturing = 1;
                @(posedge frame_end); @(negedge clk); capturing = 0;
                dump_ppm(i);
                $display("tb_frame3: tick %0d captured (dl_full=%0d overflow=%0d)", i, dl_full, ovf);
                si = si + 1;
            end
        end
        $finish;
    end
endmodule
