// tb_frame_pic.v - TESTBENCH ONLY. bg_mode 5 (full-screen picture streamed from the QSPI flash) through the
// WHOLE chain: flash_model (mem/pictures.hex) -> qspi_reader -> pic_stream -> line_renderer -> VGA pins.
// One VGA frame is captured as a PPM; tools/frame_check.py piccmp renders the same scene with the Python
// model (preview PNG colours + fade rule + display list) and checks it pixel for pixel.
//   python3 -I tools/frame_check.py picgen      -> sim/pic_dl.mem, sim/pic_tx.mem, sim/pic_scenes.txt
//   vvp tb_frame_pic.vvp +NAME=pic_title +PICID=2 +PICW=640 +PICH=360 +FADE=16 +BGC=291 [+ZERO]
//        -> sim/frames/<NAME>.ppm       (+ZERO = erased flash: pic_stream `missing` stripes)
//   room scenes (bg_mode 1 / 2): +MODE=1|2 +CAMX +CAMY +ZOX +ZOY +ZINV, and +CAMX2 .. +ZINV2 = values written at
//   VGA line 200 of the captured frame (the renderer must keep the values latched for the frame)
// Sequence: reset, magic check, display list + text RAM written through the renderer's write ports,
// pic_load in vblank (frame_end), then the NEXT complete frame is captured.
`timescale 1ns/1ps
module tb_frame_pic;
`include "pic_map.vh"
    localparam integer FLASH_BYTES = PIC_BYTES;      // size of mem/pictures.hex (pic_map.vh)
    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    // scene parameters (plusargs)
    integer     a_id, a_w, a_h, a_fade, a_bgc, a_mode;
    integer     a_cx, a_cy, a_ox, a_oy, a_zi, a_cx2, a_cy2, a_ox2, a_oy2, a_zi2;
    reg  [10:0] cam_x = 11'd0;  reg [9:0] cam_y = 10'd0;
    reg  [11:0] zoom_ox = 12'd0, zoom_oy = 12'd0; reg [16:0] zoom_inv = 17'd65536;
    reg  [4:0]  pic_id = 5'd0;
    reg  [9:0]  pic_w = 10'd640, pic_h = 10'd360;
    reg  [4:0]  fade = 5'd16;
    reg  [11:0] bg_color = 12'h000;
    reg  [2:0]  bg_mode = 3'd0;
    reg         pic_load = 1'b0;

    wire        pix_ce, active, hs, vs, line_start, frame_end;
    wire [9:0]  hcount, vcount;
    vga_timing vt (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount), .active(active),
        .hsync(hs), .vsync(vs), .line_start(line_start), .frame_end(frame_end));

    // flash + streamer
    wire        qspi_csn, qspi_sck;
    wire [3:0]  dq_o, dq_oe, dq_i, dq;
    pullup (dq[0]); pullup (dq[1]); pullup (dq[2]); pullup (dq[3]);
    assign dq[0] = dq_oe[0] ? dq_o[0] : 1'bz;
    assign dq[1] = dq_oe[1] ? dq_o[1] : 1'bz;
    assign dq[2] = dq_oe[2] ? dq_o[2] : 1'bz;
    assign dq[3] = dq_oe[3] ? dq_o[3] : 1'bz;
    assign dq_i = dq;
    wire        row_req, ps_busy, missing;
    wire [9:0]  src_row, rd_x;
    wire [11:0] rd_rgb;
    pic_stream #(.PIC_BASE(PIC_BASE), .PIC_COUNT(PIC_COUNT)) ps (
        .clk(clk), .rst(rst), .cfg_eos(1'b1), .pic_id(pic_id), .pic_load(pic_load), .row_req(row_req), .src_row(src_row),
        .rd_x(rd_x), .rd_rgb(rd_rgb), .busy(ps_busy), .missing(missing),
        .qspi_csn(qspi_csn), .qspi_sck(qspi_sck), .qspi_dq_i(dq_i), .qspi_dq_o(dq_o), .qspi_dq_oe(dq_oe));
    flash_model #(.BASE(PIC_BASE), .SIZE(FLASH_BYTES)) fm (.csn(qspi_csn), .sck(qspi_sck), .dq(dq));

    // renderer (display list written by this testbench instead of ui_composer)
    reg         dl_we = 1'b0, tx_we = 1'b0;
    reg  [7:0]  dl_waddr = 8'd0;  reg [63:0] dl_wdata = 64'd0;
    reg  [11:0] tx_waddr = 12'd0; reg [6:0]  tx_wdata = 7'd0;
    wire [3:0]  r, g, b; wire vhs, vvs, ovf;
    line_renderer lr (.clk(clk), .rst(rst), .pix_ce(pix_ce), .hcount(hcount), .vcount(vcount), .active(active),
        .hsync(hs), .vsync(vs), .bg_mode(bg_mode), .bg_color(bg_color), .bg_color2(12'h000), .cam_x(cam_x),
        .cam_y(cam_y), .zoom_ox(zoom_ox), .zoom_oy(zoom_oy), .zoom_inv(zoom_inv), .wire_src(270'd0), .src_val(28'd0),
        .wire_hl(7'd0), .hill_ph(16'd0), .wave_ph(8'd0), .s3_cam(13'd0),
        .pic_rgb(rd_rgb), .pic_w(pic_w), .pic_h(pic_h), .fade(fade),
        .pic_row_req(row_req), .pic_src_row(src_row), .pic_rd_x(rd_x),
        .dl_we(dl_we), .dl_waddr(dl_waddr), .dl_wdata(dl_wdata), .tx_we(tx_we), .tx_waddr(tx_waddr),
        .tx_wdata(tx_wdata), .vga_r(r), .vga_g(g), .vga_b(b), .vga_hs(vhs), .vga_vs(vvs), .overflow(ovf));

    // row requests of the captured frame: count, rows in order, every request must be < h
    integer nreq = 0, bad_req = 0, req_v0 = -1, req_v1 = -1;
    reg     counting = 1'b0;
    always @(posedge clk) if (counting && row_req) begin
        if (nreq == 0) req_v0 = vcount;
        req_v1 = vcount;
        if (src_row >= pic_h) bad_req = bad_req + 1;
        nreq = nreq + 1;
    end

    // ---------------------------------------------------------------- frame capture (as tb_frame.v)
    reg [9:0] ph = 0, pv = 0, ph2 = 0, pv2 = 0; reg pact = 0, pact2 = 0;
    reg       capturing = 1'b0;
    reg [11:0] img [0:640*480-1];
    always @(posedge clk) if (pix_ce) begin
        if (capturing && pact2) img[pv2 * 640 + ph2] <= {r, g, b};
        ph <= hcount; pv <= vcount; pact <= active;
        ph2 <= ph; pv2 <= pv; pact2 <= pact;
    end

    reg [63:0] dlm [0:255];
    reg [7:0]  txm [0:4095];
    reg [1023:0] name, fname;
    integer i, fd, ndl;
    initial begin
        if (!$value$plusargs("NAME=%s", name)) name = "pic_title";
        if (!$value$plusargs("PICID=%d", a_id)) a_id = PIC_TITLE;
        if (!$value$plusargs("PICW=%d", a_w)) a_w = 640;
        if (!$value$plusargs("PICH=%d", a_h)) a_h = 360;
        if (!$value$plusargs("FADE=%d", a_fade)) a_fade = 16;
        if (!$value$plusargs("BGC=%d", a_bgc)) a_bgc = 0;
        if (!$value$plusargs("MODE=%d", a_mode)) a_mode = 5;
        if (!$value$plusargs("CAMX=%d", a_cx)) a_cx = 0;
        if (!$value$plusargs("CAMY=%d", a_cy)) a_cy = 0;
        if (!$value$plusargs("ZOX=%d", a_ox)) a_ox = 0;
        if (!$value$plusargs("ZOY=%d", a_oy)) a_oy = 0;
        if (!$value$plusargs("ZINV=%d", a_zi)) a_zi = 65536;
        if (!$value$plusargs("CAMX2=%d", a_cx2)) a_cx2 = a_cx;
        if (!$value$plusargs("CAMY2=%d", a_cy2)) a_cy2 = a_cy;
        if (!$value$plusargs("ZOX2=%d", a_ox2)) a_ox2 = a_ox;
        if (!$value$plusargs("ZOY2=%d", a_oy2)) a_oy2 = a_oy;
        if (!$value$plusargs("ZINV2=%d", a_zi2)) a_zi2 = a_zi;
        for (i = 0; i < 256; i = i + 1) dlm[i] = 64'd0;
        for (i = 0; i < 4096; i = i + 1) txm[i] = 8'd32;
        $readmemh("sim/pic_dl.mem", dlm);
        $readmemh("sim/pic_tx.mem", txm);
        ndl = 0; while (ndl < 255 && dlm[ndl][63:61] != 3'd0) ndl = ndl + 1;
        pic_id = a_id; pic_w = a_w; pic_h = a_h; fade = a_fade; bg_color = a_bgc; bg_mode = a_mode;
        cam_x = a_cx; cam_y = a_cy; zoom_ox = a_ox; zoom_oy = a_oy; zoom_inv = a_zi;

        repeat (5) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        // display list + text RAM
        for (i = 0; i <= ndl; i = i + 1) begin
            @(negedge clk); dl_we = 1'b1; dl_waddr = i; dl_wdata = dlm[i];
        end
        @(negedge clk); dl_we = 1'b0;
        for (i = 0; i < 4096; i = i + 1) begin
            @(negedge clk); tx_we = 1'b1; tx_waddr = i; tx_wdata = txm[i][6:0];
        end
        @(negedge clk); tx_we = 1'b0;
        wait (!ps_busy);                                    // magic check done
        @(posedge frame_end); @(negedge clk);               // vblank: load the picture
        pic_load = 1'b1; @(negedge clk); pic_load = 1'b0;
        wait (pix_ce && hcount == 0 && vcount == 0); @(negedge clk);
        if (ps_busy) $display("tb_frame_pic: WARNING pic_load still busy at the start of the frame");
        capturing = 1'b1; counting = 1'b1;
        wait (vcount == 10'd200); @(negedge clk);          // camera / zoom change in the middle of the frame
        cam_x = a_cx2; cam_y = a_cy2; zoom_ox = a_ox2; zoom_oy = a_oy2; zoom_inv = a_zi2;
        @(posedge frame_end); @(negedge clk); capturing = 1'b0; counting = 1'b0;
        $sformat(fname, "sim/frames/%0s.ppm", name);
        fd = $fopen(fname, "w");
        $fdisplay(fd, "P3 640 480 15");
        for (i = 0; i < 640 * 480; i = i + 1) $fdisplay(fd, "%0d %0d %0d", img[i][11:8], img[i][7:4], img[i][3:0]);
        $fclose(fd);
        $display("tb_frame_pic: %0s captured (missing=%0d row_req=%0d at vcount %0d..%0d, out of range=%0d, overflow=%0d)",
                 name, missing, nreq, req_v0, req_v1, bad_req, ovf);
        $finish;
    end
endmodule
