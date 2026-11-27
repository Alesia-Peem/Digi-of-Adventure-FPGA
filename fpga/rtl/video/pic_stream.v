// pic_stream.v - big pictures (rooms, cutscenes, endings) streamed from the QSPI flash, one row per VGA line.
//
// FLASH IMAGE (tools/pic_pack.py, programmed at PIC_BASE; little-endian):
//   +0 "CPEP"  +4 u16 count, u16 version  +8 count x {u32 off, u16 w, u16 h}
//   +off 256 x u16 palette 0x0RGB   +off+512 h rows x w bytes of palette index
//
// INTERFACE
//   * After reset: reads the first 6 bytes. `missing` = 1 when they are not "CPEP" + u16 count = PIC_COUNT
//     (flash not programmed, QUAD bit not set, image from another build, ...). While missing, row_req never
//     touches the flash and rd_rgb shows a diagonal stripe pattern (16 px magenta / black, moving with the
//     row number) so the screen is recognisable without any help from the renderer; a pic_load re-reads
//     those 6 bytes (busy meanwhile) and, if they are good now, clears `missing` and loads the picture.
//   * pic_load pulse (in vblank): reads the header entry of pic_id (off, w, h) and the 256-entry
//     palette into the palette RAM, invalidates the row buffer. ~2.3k clk.
//   * row_req pulse + src_row: ROW BUFFER INVARIANT - after the k-th row_req (k >= 2) the row requested
//     at request k-1 is readable via rd_x for the whole line (from 3 clk after the pulse until the next
//     row_req): one line of latency, like line_renderer painting line N+1 while N is shown.
//     Implementation: ping-pong 2 x 1024 x 8 row buffer with a row tag per half. On a row_req the front
//     (displayed) half becomes the half holding the previous request's row; the new row is fetched into
//     the other half, unless it is already resident in either half (Stage 1 asks for every source row
//     twice in a row -> one fetch per source row). Row length = picture width w <= 768: the line budget
//     (4 clk / byte + ~90 clk overhead < 3200 clk) allows ~777 B; pic_pack.py asserts it. The 1024-byte
//     halves are just the BRAM shape (w is clamped to 1024 so a bad header cannot overrun them).
//     Fetch = one 0x6B burst of w bytes: 640 B ~ 2.65k clk < 3200 clk (one VGA line).
//   * rd_x -> rd_rgb = palette[front_row[rd_x]], 2 clk latency (row RAM, then palette RAM), same as
//     rom_sync + palette in line_renderer.
//   * busy = magic check, pic_load or row fetch in progress (or pending).
// The caller must keep src_row < h (as line_renderer clamps sy) and not request rows faster than one per
// line; a request that arrives while a fetch runs is queued (latest wins).
`timescale 1ns/1ps
module pic_stream #(
    parameter [23:0] PIC_BASE    = 24'h400000,   // = PIC_BASE of pic_map.vh
    parameter integer PIC_COUNT   = 0,            // = PIC_COUNT of pic_map.vh (pass it: 0 never matches)
    parameter integer DUMMY       = 8,
    parameter integer LATE_SAMPLE = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cfg_eos,       // STARTUPE2.EOS via qspi_io (1 in simulation), see qspi_reader
    input  wire [4:0]  pic_id,
    input  wire        pic_load,
    input  wire        row_req,
    input  wire [9:0]  src_row,
    input  wire [9:0]  rd_x,
    output wire [11:0] rd_rgb,
    output wire        busy,
    output reg         missing,
    // QSPI flash (SCK goes through STARTUPE2.USRCCLKO at the top level)
    output wire        qspi_csn,
    output wire        qspi_sck,
    input  wire [3:0]  qspi_dq_i,
    output wire [3:0]  qspi_dq_o,
    output wire [3:0]  qspi_dq_oe
);
    // ------------------------------------------------------------------ flash reader
    reg         qr_start;
    reg  [23:0] qr_addr;
    reg  [15:0] qr_len;
    wire        qr_busy, qr_dv;
    wire [7:0]  qr_data;
    qspi_reader #(.DUMMY(DUMMY), .LATE_SAMPLE(LATE_SAMPLE)) u_qr (
        .clk(clk), .rst(rst), .cfg_eos(cfg_eos), .start(qr_start), .addr(qr_addr), .len(qr_len), .busy(qr_busy),
        .data(qr_data), .data_valid(qr_dv), .qspi_csn(qspi_csn), .qspi_sck(qspi_sck),
        .qspi_dq_i(qspi_dq_i), .qspi_dq_o(qspi_dq_o), .qspi_dq_oe(qspi_dq_oe));
    wire qr_done = !qr_busy && !qr_start;          // burst finished (start is registered: see S_* below)

    // ------------------------------------------------------------------ RAMs
    reg  [7:0]  rowbuf [0:2047];                   // {half, x}: 2 x 1024 x 8 -> 1 BRAM18 (simple dual port)
    reg  [11:0] pal    [0:255];                    // 256 x 12 -> BRAM or LUTRAM
    reg         rb_we;  reg [10:0] rb_wa; reg [7:0]  rb_wd;
    reg         pal_we; reg [7:0]  pal_wa; reg [11:0] pal_wd;
    reg         front;
    reg  [7:0]  rb_q;
    reg  [11:0] pal_q;
    always @(posedge clk) if (rb_we) rowbuf[rb_wa] <= rb_wd;
    always @(posedge clk) rb_q <= rowbuf[{front, rd_x}];
    always @(posedge clk) if (pal_we) pal[pal_wa] <= pal_wd;
    always @(posedge clk) pal_q <= pal[rb_q];

    // stripe pattern while missing (same 2 clk latency)
    reg  [9:0]  last_req, shown_row;
    reg  [11:0] stp1, stp2;
    wire [10:0] stp_s = {1'b0, rd_x} + {1'b0, shown_row};
    always @(posedge clk) begin
        if (rst) begin last_req <= 10'd0; shown_row <= 10'd0; end
        else if (row_req) begin shown_row <= last_req; last_req <= src_row; end
        stp1 <= stp_s[4] ? 12'hF0F : 12'h000;
        stp2 <= stp1;
    end
    assign rd_rgb = missing ? stp2 : pal_q;

    // ------------------------------------------------------------------ control
    localparam [2:0] S_RST = 3'd0, S_MAGIC = 3'd1, S_IDLE = 3'd2, S_HDR = 3'd3, S_PAL = 3'd4,
                     S_RADDR = 3'd5, S_ROW = 3'd6;
    reg [2:0]  st;
    reg [47:0] magic;             // "CPEP" + count (LE), in read order
    reg [63:0] hdr;
    reg [10:0] bcnt;
    reg [7:0]  pal_lo;
    reg [23:0] img_base;          // flash address of row 0
    reg [10:0] wlen;              // row length (bytes) = w (<= 768 by pic_pack; clamped to 1024)
    reg        loaded;
    reg        pend_load, pend_row;
    reg [4:0]  pend_id;
    reg [9:0]  pend_r, prev_r;
    reg        has_prev;
    reg [9:0]  tag0, tag1;
    reg        v0, v1;
    reg        tgt;               // half being filled
    reg [20:0] rowoff;

    wire p0 = has_prev && v0 && (tag0 == prev_r);  // previous request's row is in half 0 / 1
    wire p1 = has_prev && v1 && (tag1 == prev_r);
    wire nf = p1 ? 1'b1 : (p0 ? 1'b0 : front);    // new front half
    wire hit = (v0 && tag0 == pend_r) || (v1 && tag1 == pend_r);
    wire [20:0] mul = pend_r * wlen;               // row * w
    wire [23:0] hoff = hdr[23:0];                  // picture offset (the image is < 16 MiB)

    wire hdr_ok = (magic[47:16] == 32'h43504550) && ({magic[7:0], magic[15:8]} == PIC_COUNT);
    assign busy = (st != S_IDLE) || pend_load || (!missing && pend_row);

    always @(posedge clk) begin
        if (rst) begin
            st <= S_RST; qr_start <= 1'b0; qr_addr <= 24'd0; qr_len <= 16'd0;
            missing <= 1'b0; loaded <= 1'b0; pend_load <= 1'b0; pend_row <= 1'b0; pend_id <= 5'd0;
            pend_r <= 10'd0; prev_r <= 10'd0; has_prev <= 1'b0; v0 <= 1'b0; v1 <= 1'b0;
            tag0 <= 10'd0; tag1 <= 10'd0; front <= 1'b0; tgt <= 1'b0;
            rb_we <= 1'b0; pal_we <= 1'b0; bcnt <= 11'd0; magic <= 48'd0; hdr <= 64'd0;
            img_base <= 24'd0; wlen <= 11'd0; rowoff <= 21'd0;
        end else begin
            qr_start <= 1'b0; rb_we <= 1'b0; pal_we <= 1'b0;
            case (st)
            S_RST: if (!qr_busy) begin                       // reader finished its CS#-high init clocks
                qr_addr <= PIC_BASE; qr_len <= 16'd6; qr_start <= 1'b1; st <= S_MAGIC;
            end
            S_MAGIC: begin
                if (qr_dv) magic <= {magic[39:0], qr_data};
                if (qr_done) begin                           // "CPEP", count low byte, count high byte
                    missing <= !hdr_ok;
                    if (!hdr_ok) pend_load <= 1'b0;          // a good header keeps a pending load
                    st <= S_IDLE;
                end
            end
            S_IDLE: begin
                if (missing) begin                           // rows: ignored; pic_load: check again
                    pend_row <= 1'b0;
                    if (pend_load) st <= S_RST;
                end else if (pend_load) begin
                    pend_load <= 1'b0; loaded <= 1'b0; v0 <= 1'b0; v1 <= 1'b0; has_prev <= 1'b0;
                    qr_addr <= PIC_BASE + 24'd8 + {16'd0, pend_id, 3'd0}; qr_len <= 16'd8;
                    qr_start <= 1'b1; st <= S_HDR;
                end else if (pend_row) begin
                    pend_row <= 1'b0;
                    front <= nf;
                    prev_r <= pend_r; has_prev <= 1'b1;
                    if (loaded && !hit) begin
                        tgt <= ~nf;
                        if (nf) begin tag0 <= pend_r; v0 <= 1'b0; end
                        else    begin tag1 <= pend_r; v1 <= 1'b0; end
                        rowoff <= mul; st <= S_RADDR;
                    end
                end
            end
            S_HDR: begin
                if (qr_dv) hdr <= {qr_data, hdr[63:8]};      // little-endian -> hdr = {h, w, off}
                if (qr_done) begin
                    img_base <= PIC_BASE + hoff + 24'd512;
                    wlen <= (hdr[47:32] > 16'd1024) ? 11'd1024 : hdr[42:32];
                    qr_addr <= PIC_BASE + hoff; qr_len <= 16'd512; qr_start <= 1'b1;
                    bcnt <= 11'd0; st <= S_PAL;
                end
            end
            S_PAL: begin
                if (qr_dv) begin
                    bcnt <= bcnt + 11'd1;
                    if (!bcnt[0]) pal_lo <= qr_data;
                    else begin pal_we <= 1'b1; pal_wa <= bcnt[8:1]; pal_wd <= {qr_data[3:0], pal_lo}; end
                end
                if (qr_done) begin loaded <= 1'b1; st <= S_IDLE; end
            end
            S_RADDR: begin
                qr_addr <= img_base + {3'd0, rowoff}; qr_len <= {5'd0, wlen}; qr_start <= 1'b1;
                bcnt <= 11'd0; st <= S_ROW;
            end
            S_ROW: begin
                if (qr_dv) begin
                    rb_we <= 1'b1; rb_wa <= {tgt, bcnt[9:0]}; rb_wd <= qr_data; bcnt <= bcnt + 11'd1;
                end
                if (qr_done) begin
                    if (tgt) v1 <= 1'b1; else v0 <= 1'b1;
                    st <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
            // requests are latched in any state (a new pulse wins over the clear above)
            if (pic_load) begin pend_load <= 1'b1; pend_id <= pic_id; end
            if (row_req)  begin pend_row <= 1'b1; pend_r <= src_row; end
        end
    end
endmodule
