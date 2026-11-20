// tb_units.v - TESTBENCH ONLY. Self-checking unit tests of the shared modules.
//   vga_timing  : 800 x 525 totals, hsync 96 px, vsync 2 lines, 640x480 active, polarity
//   button_unit : debounce, press, tap (short), long press (no tap after it), bounce rejection
//   card_deck   : all 6 shuffles, each slot holds a different item, career from round 1, wrap-around
//   inventory   : armor cap 3, shard merge, slow / freeze timers, restore, stored mode counters
//   heart_system: armor absorbs, hearts down, dead pulse at 0, set_hearts clamp
//   sprite_anim : left-leg-first walk cycle with 0.14 s frames, facing priority, stop
//   lfsr16      : same sequence as the Python lfsr_step() (first values checked)
// Prints "TB_UNITS: PASS" or the failing checks.
`timescale 1ns/1ps
module tb_units;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    integer errors = 0;
    task check(input cond, input [8*64-1:0] msg);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", msg); end end
    endtask

    // ------------------------------------------------------------ vga_timing
    wire pce, act, hs, vs, ls, fe; wire [9:0] hc, vc;
    vga_timing vt (.clk(clk), .rst(rst), .pix_ce(pce), .hcount(hc), .vcount(vc), .active(act), .hsync(hs),
                   .vsync(vs), .line_start(ls), .frame_end(fe));
    integer n_ce, n_act, n_hs_line, n_vs_lines, max_h, max_v;

    // ------------------------------------------------------------ button
    reg braw = 0;
    wire blvl, bpress, btap, blong;
    button_unit #(.DEBOUNCE_CYCLES(4), .LONG_CYCLES(100), .DW(4), .LW(8)) bu (.clk(clk), .rst(rst), .raw(braw),
        .level(blvl), .press(bpress), .tap(btap), .long_press(blong));
    integer n_press, n_tap, n_long;
    always @(posedge clk) begin
        if (bpress) n_press = n_press + 1;
        if (btap) n_tap = n_tap + 1;
        if (blong) n_long = n_long + 1;
    end

    // ------------------------------------------------------------ card deck
    reg dstart = 0, den = 0, dl = 0, dr = 0, dtap = 0, dclr = 0; reg [1:0] dround = 1; reg [2:0] dperm = 0;
    wire dact, dface_up, dgrant, dcv, drdone; wire [1:0] drnd, dcur, dface, dcar; wire [2:0] dpm; wire [3:0] ditem;
    card_deck cd (.clk(clk), .rst(rst), .clear(dclr), .start(dstart), .start_round(dround), .start_perm(dperm),
        .en(den), .ev_l(dl), .ev_r(dr), .ev_tap(dtap), .set_career(1'b0), .set_career_v(2'd0),
        .active(dact), .round(drnd), .perm(dpm), .cursor(dcur), .face_up(dface_up), .face(dface), .grant(dgrant),
        .grant_item(ditem), .career(dcar), .career_valid(dcv), .round_done(drdone));
    reg [3:0] got_item;
    always @(posedge clk) if (dgrant) got_item <= ditem;

    // ------------------------------------------------------------ inventory + hearts
    reg itick = 0, iload = 0, irest = 0, igrant = 0, idmg = 0, iadd = 0, ismode = 0; reg [3:0] iitem = 0;
    wire [1:0] armor, nhh, nhs, nun, nfr; wire shard, boost, forged; wire [9:0] slow_f; wire [8:0] frz_f;
    wire acons; wire [1:0] hearts; wire hit, blk, dead;
    reg hclr = 0, hset = 0; reg [1:0] hsetv = 0;
    inventory inv (.clk(clk), .rst(rst), .tick(itick), .run(1'b1), .store_mode(ismode), .load(iload),
        .load_armor(2'd0), .load_shard(1'b0), .load_boost(1'b0), .restore(irest), .grant(igrant), .grant_item(iitem),
        .armor_consume(acons), .add_armor(iadd), .use_hh(1'b0), .use_hs(1'b0), .use_undo(1'b0), .use_freeze(1'b0),
        .boost_consume(1'b0), .armor(armor), .shard(shard), .boost(boost), .n_hh(nhh), .n_hs(nhs), .n_undo(nun),
        .n_freeze(nfr), .slow_f(slow_f), .freeze_f(frz_f), .forged(forged));
    heart_system hsys (.clk(clk), .rst(rst), .clear(hclr), .set_en(hset), .set_val(hsetv), .damage(idmg),
        .armor_avail(armor != 0), .armor_consume(acons), .hearts(hearts), .hit(hit), .blocked(blk), .dead(dead));
    integer n_dead, n_hit, n_blk;
    always @(posedge clk) begin
        if (dead) n_dead = n_dead + 1;
        if (hit) n_hit = n_hit + 1;
        if (blk) n_blk = n_blk + 1;
    end

    // ------------------------------------------------------------ sprite anim + lfsr
    reg aupd = 0, astop = 0, ares = 0, amoved = 0; reg [1:0] adx = 0, ady = 0;
    wire [1:0] adir, apose;
    sprite_anim sa (.clk(clk), .rst(rst), .reset_dir(ares), .upd(aupd), .stop(astop), .dxs(adx), .dys(ady),
        .moved(amoved), .dir(adir), .pose(apose));
    reg lstep = 0, lload = 0; reg [15:0] lseed = 16'h1D2C; wire [15:0] lq;
    lfsr16 lf (.clk(clk), .rst(rst), .load(lload), .seed(lseed), .step(lstep), .q(lq));

    task pulse_tick_anim(input [1:0] dx, input [1:0] dy, input mv);
        begin
            @(negedge clk); adx = dx; ady = dy; amoved = mv; aupd = 1; @(negedge clk); aupd = 0;
        end
    endtask

    function [15:0] py_lfsr(input [15:0] x);          // the Pygame lfsr_step()
        reg fb; reg [15:0] y;
        begin fb = x[15] ^ x[14] ^ x[12] ^ x[3]; y = {x[14:0], fb}; py_lfsr = (y == 0) ? 16'hACE1 : y; end
    endfunction

    integer i, p, k; reg [15:0] ref; reg [2:0] seen_items; reg [8:0] poses;
    initial begin
        n_press = 0; n_tap = 0; n_long = 0; n_dead = 0; n_hit = 0; n_blk = 0;
        repeat (4) @(posedge clk); @(negedge clk); rst = 0;

    end
    // ---- VGA: count one full frame (sampled on falling edges, from one frame_end to the next)
    reg vga_checked = 0;
    initial begin : vga_chk
        wait (!rst);
        @(negedge clk); while (!fe) @(negedge clk);
        n_ce = 0; n_act = 0; n_hs_line = 0; n_vs_lines = 0; max_h = 0; max_v = 0;
        forever begin
            if (pce) begin
                n_ce = n_ce + 1;
                if (act) n_act = n_act + 1;
                if (vc == 10 && !hs) n_hs_line = n_hs_line + 1;
                if (hc == 0 && !vs) n_vs_lines = n_vs_lines + 1;
                if (hc > max_h) max_h = hc;
                if (vc > max_v) max_v = vc;
            end
            @(negedge clk);
            if (fe) begin
                check(n_ce == 800 * 525, "vga: 800 x 525 pixel clocks per frame");
                check(n_act == 640 * 480, "vga: 640 x 480 active pixels");
                check(n_hs_line == 96, "vga: hsync 96 pixels, active low");
                check(n_vs_lines == 2, "vga: vsync 2 lines, active low");
                check(max_h == 799 && max_v == 524, "vga: counter ranges");
                vga_checked = 1;
                disable vga_chk;
            end
        end
    end

    initial begin
        #200;
        // ---- buttons: short tap, bounce, long press
        @(negedge clk); braw = 1; @(negedge clk); braw = 0; @(negedge clk); braw = 1; // bounce
        repeat (20) @(negedge clk); braw = 0; repeat (20) @(negedge clk);
        check(n_press == 1 && n_tap == 1 && n_long == 0, "button: bounce -> one press, one tap");
        braw = 1; repeat (150) @(negedge clk); braw = 0; repeat (20) @(negedge clk);
        check(n_press == 2 && n_tap == 1 && n_long == 1, "button: long press -> long, no tap");

        // ---- cards: every permutation, every slot -> three different items, cursor wraps
        for (p = 0; p < 6; p = p + 1) begin
            seen_items = 0;
            for (k = 0; k < 3; k = k + 1) begin
                @(negedge clk); dperm = p; dround = 2; dstart = 1; @(negedge clk); dstart = 0;
                // move from slot 1 to slot k
                den = 1;
                if (k == 0) begin dl = 1; @(negedge clk); dl = 0; end
                if (k == 2) begin dr = 1; @(negedge clk); dr = 0; end
                dtap = 1; @(negedge clk); dtap = 0; @(negedge clk);
                check(dface_up && dface == k, "cards: reveal the chosen slot");
                seen_items[got_item == 4 ? 0 : got_item == 5 ? 1 : 2] = 1;
                dtap = 1; @(negedge clk); dtap = 0; den = 0; @(negedge clk);
                check(!dact, "cards: second tap closes the round");
            end
            check(seen_items == 3'b111, "cards: 3 slots = 3 different items (no duplicate, none lost)");
        end
        @(negedge clk); dperm = 3; dround = 1; dstart = 1; @(negedge clk); dstart = 0; den = 1;
        dl = 1; @(negedge clk); dl = 0; dl = 1; @(negedge clk); dl = 0;          // 1 -> 0 -> 2 (wrap)
        check(dcur == 2, "cards: cursor wraps left");
        dtap = 1; @(negedge clk); dtap = 0; @(negedge clk);
        check(dcv && dcar == 0, "cards: round 1 slot 2 of perm (1,2,0) -> career 0 (air)");
        dtap = 1; @(negedge clk); dtap = 0; den = 0;

        // ---- inventory: armor cap, shard merge, timers
        for (i = 0; i < 4; i = i + 1) begin @(negedge clk); iitem = 3; igrant = 1; @(negedge clk); igrant = 0; end
        check(armor == 3, "inventory: armor saturates at 3");
        @(negedge clk); irest = 1; @(negedge clk); irest = 0;
        check(armor == 0, "inventory: restore -> values at stage entry");
        @(negedge clk); iitem = 4; igrant = 1; @(negedge clk); igrant = 0;
        check(shard && armor == 0, "inventory: first shard kept");
        @(negedge clk); iitem = 4; igrant = 1; @(negedge clk); igrant = 0;
        check(!shard && armor == 1, "inventory: 2 shards forge 1 armor");
        @(negedge clk); iitem = 5; igrant = 1; @(negedge clk); igrant = 0;
        check(slow_f == 600, "inventory: slow = 10 s");
        for (i = 0; i < 600; i = i + 1) begin @(negedge clk); itick = 1; @(negedge clk); itick = 0; end
        check(slow_f == 0, "inventory: slow ends after 600 ticks");
        @(negedge clk); ismode = 1; iitem = 7; igrant = 1; @(negedge clk); igrant = 0; ismode = 0;
        check(nfr == 1 && frz_f == 0, "inventory: stored mode keeps freeze in the bag");

        // ---- hearts: armor absorbs, then 3 hits -> dead
        @(negedge clk); idmg = 1; @(negedge clk); idmg = 0; @(negedge clk);
        check(hearts == 3 && armor == 0 && n_blk == 1, "hearts: armor absorbs one hit");
        for (i = 0; i < 3; i = i + 1) begin @(negedge clk); idmg = 1; @(negedge clk); idmg = 0; end
        @(negedge clk);
        check(hearts == 0 && n_hit == 3 && n_dead == 1, "hearts: 3 hits -> 0 hearts, one dead pulse");
        @(negedge clk); hset = 1; hsetv = 0; @(negedge clk); hset = 0;
        check(hearts == 1, "hearts: set_hearts(0) clamps to 1");

        // ---- sprite: first walking frame = left leg, 0.14 s frames, cycle stepl stand stepr stand
        poses = 0;
        pulse_tick_anim(2'b11, 2'b00, 1);
        check(adir == 3 && apose == 1, "sprite: start walking right with the left leg");
        for (i = 1; i < 9; i = i + 1) pulse_tick_anim(2'b11, 2'b00, 1);      // t = 8/60 s < 0.14 s
        check(apose == 1, "sprite: still the left leg at t = 0.133 s");
        pulse_tick_anim(2'b11, 2'b00, 1);                                     // t = 9/60 s >= 0.14 s
        check(apose == 0, "sprite: stand frame from t = 0.15 s");
        for (i = 0; i < 9; i = i + 1) pulse_tick_anim(2'b11, 2'b10, 1);
        check(adir == 3 && apose == 2, "sprite: left/right wins over up/down; then right leg");
        pulse_tick_anim(2'b00, 2'b10, 0);
        check(adir == 1 && apose == 0, "sprite: stop -> stand, facing back");

        // ---- lfsr matches the Python formula
        @(negedge clk); lload = 1; @(negedge clk); lload = 0;
        ref = 16'h1D2C;
        for (i = 0; i < 1000; i = i + 1) begin
            @(negedge clk); lstep = 1; @(negedge clk); lstep = 0; ref = py_lfsr(ref);
            if (lq !== ref) begin errors = errors + 1; $display("FAIL: lfsr step %0d", i); i = 1000; end
        end

        wait (vga_checked);
        $display("TB_UNITS: %0s (%0d errors)", errors == 0 ? "PASS" : "FAIL", errors);
        $finish;
    end
endmodule
