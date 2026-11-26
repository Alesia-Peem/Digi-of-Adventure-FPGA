// tb_top_pic.v - TESTBENCH ONLY. Top-level smoke test of the picture path: the WHOLE cpe_escape_top
// (compile with -DSIMULATION: qspi_io.v is behavioural and exposes the flash clock as sim_sck) with the
// S25FL128S model (tb/flash_model.v + mem/pictures.hex) on QSPI_CSN / QSPI_DQ.
//   reset -> BOOT (black) -> first vblank: stage_mgr enters OPEN, pic_load(PIC_TITLE) + bg_mode 5 together
//   -> the next complete VGA frame is captured to sim/frames/top_title.ppm (run_tests.sh section 11 checks
//      it pixel exactly against mem/preview/pic_TITLE.png: empty display list, fade 16)
//   -> BTNC tap -> stage_mgr must enter Stage 1 (s1_enter pulse, screen S1, bg_mode no longer 5).
`timescale 1ns/1ps
module tb_top_pic;
`include "pic_map.vh"
    localparam integer FLASH_BYTES = 5077760;        // size of mem/pictures.hex
    reg clk = 1'b0, rstn = 1'b0;
    always #5 clk = ~clk;
    reg btnc = 1'b0;

    wire [15:0] led; wire [7:0] an; wire [3:0] r, g, b; wire hs, vs;
    wire        qspi_csn; wire [3:0] qspi_dq;
    pullup (qspi_dq[0]); pullup (qspi_dq[1]); pullup (qspi_dq[2]); pullup (qspi_dq[3]);
    cpe_escape_top #(.MEM_DIR("mem/"), .SIM_FAST(1)) dut (
        .CLK100MHZ(clk), .CPU_RESETN(rstn), .BTNC(btnc), .BTNU(1'b0), .BTNL(1'b0), .BTNR(1'b0), .BTND(1'b0),
        .SW(16'd0), .LED(led), .LED16_R(), .LED16_G(), .LED16_B(), .LED17_R(), .LED17_G(), .LED17_B(),
        .CA(), .CB(), .CC(), .CD(), .CE(), .CF(), .CG(), .DP(), .AN(an),
        .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hs), .VGA_VS(vs),
        .QSPI_CSN(qspi_csn), .QSPI_DQ(qspi_dq));
    wire qspi_sck = dut.u_qio.sim_sck;               // SCK leaves through STARTUPE2 on the board
    flash_model #(.BASE(PIC_BASE), .SIZE(FLASH_BYTES)) fm (.csn(qspi_csn), .sck(qspi_sck), .dq(qspi_dq));

    wire       pix_ce = dut.pix_ce, active = dut.active, frame_end = dut.frame_end;
    wire [9:0] hcount = dut.hcount, vcount = dut.vcount;

    // ---------------------------------------------------------------- frame capture (as tb_frame_pic.v)
    reg [9:0] ph = 0, pv = 0, ph2 = 0, pv2 = 0; reg pact = 0, pact2 = 0;
    reg       capturing = 1'b0;
    reg [11:0] img [0:640*480-1];
    always @(posedge clk) if (pix_ce) begin
        if (capturing && pact2) img[pv2 * 640 + ph2] <= {r, g, b};
        ph <= hcount; pv <= vcount; pact <= active;
        ph2 <= ph; pv2 <= pv; pact2 <= pact;
    end

    // monitor at negedge: registered outputs are stable, fe_prev = frame_end as sampled by the last posedge
    integer errors = 0, n_load = 0, n_s1 = 0;
    reg     fe_prev = 1'b0;
    always @(negedge clk) begin
        if (dut.u_sm.pic_load) begin
            n_load = n_load + 1;
            if (!fe_prev) begin errors = errors + 1; $display("FAIL pic_load outside vblank"); end
        end
        if (dut.u_sm.s1_enter) n_s1 = n_s1 + 1;
        fe_prev = frame_end;
    end

    integer i, fd;
    initial begin
        for (i = 0; i < 640 * 480; i = i + 1) img[i] = 12'hABC;
        repeat (20) @(negedge clk); rstn = 1'b1;
        if (pic_wh(PIC_S1_ROOM) != {10'd640, 10'd358} || pic_wh(PIC_TITLE) != {10'd640, 10'd360})
            begin errors = errors + 1; $display("FAIL pic_wh table"); end
        // first vblank: OPEN + pic_load of the title
        wait (n_load == 1); @(negedge clk);
        if (dut.u_sm.screen != 3'd0 || dut.u_sm.pic_id != PIC_TITLE || dut.bg_mode != 3'd5)
            begin errors = errors + 1; $display("FAIL OPEN not entered with the title (screen %0d pic %0d mode %0d)",
                                               dut.u_sm.screen, dut.u_sm.pic_id, dut.bg_mode); end
        if (dut.pic_w != 10'd640 || dut.pic_h != 10'd360) begin errors = errors + 1; $display("FAIL pic_w/h"); end
        wait (pix_ce && hcount == 0 && vcount == 0); @(negedge clk);
        if (dut.ps_busy) $display("tb_top_pic: WARNING pic_load still busy at the start of the frame");
        if (dut.ps_missing) begin errors = errors + 1; $display("FAIL pic_stream: flash magic missing"); end
        capturing = 1'b1;
        @(posedge frame_end); @(negedge clk); capturing = 1'b0;
        fd = $fopen("sim/frames/top_title.ppm", "w");
        $fdisplay(fd, "P3 640 480 15");
        for (i = 0; i < 640 * 480; i = i + 1) $fdisplay(fd, "%0d %0d %0d", img[i][11:8], img[i][7:4], img[i][3:0]);
        $fclose(fd);
        $display("tb_top_pic: top_title captured (flash errors=%0d, overflow=%0d)", fm.errors, dut.lr_ovf);
        if (fm.errors != 0) errors = errors + 1;
        // BTNC tap (SIM_FAST: 4 clk debounce, 2000 clk game tick) -> Stage 1
        btnc = 1'b1; repeat (3000) @(negedge clk); btnc = 1'b0;
        i = 0;
        while (n_s1 == 0 && i < 2000000) begin @(negedge clk); i = i + 1; end
        repeat (10) @(negedge clk);
        if (n_s1 != 1 || dut.u_sm.screen != 3'd1 || !dut.on1 || dut.bg_mode == 3'd5) begin
            errors = errors + 1;
            $display("FAIL Stage 1 not entered after the tap (s1_enter %0d, screen %0d, mode %0d)",
                     n_s1, dut.u_sm.screen, dut.bg_mode);
        end
        // Stage 1 room streamed from the flash: loaded in the same vblank as the entry, size 640x358
        if (n_load != 2 || dut.u_sm.pic_id != PIC_S1_ROOM || dut.pic_h != 10'd358) begin
            errors = errors + 1;
            $display("FAIL Stage 1 entry did not load PIC_S1_ROOM (pic_loads %0d, pic_id %0d, h %0d)",
                     n_load, dut.u_sm.pic_id, dut.pic_h);
        end
        $display("TB_TOP_PIC: %0s (errors=%0d, pic_loads %0d, s1_enter %0d)", errors == 0 ? "PASS" : "FAIL",
                 errors, n_load, n_s1);
        $finish;
    end
endmodule
