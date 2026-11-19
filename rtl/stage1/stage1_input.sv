module stage1_input #(
    parameter int CLK_HZ = 100_000_000
)(
    input  logic clk,
    input  logic rst_n,
    input  logic btn_u, btn_d, btn_l, btn_r, btn_c,
    output logic hold_u, hold_d, hold_l, hold_r,     // สำหรับเดินค้างบนแผนที่
    output logic pulse_u, pulse_d, pulse_l, pulse_r, // สำหรับเลื่อนเมนู/กล่องตัวเลข
    output logic tap_c,                              // กดสั้นปล่อย (< 0.8s)
    output logic back_c                              // กดค้าง >= 0.8s
);
    localparam int DB_MAX   = CLK_HZ / 100;          // 10 ms debounce
    localparam int LONG_MAX = (CLK_HZ / 10) * 8;     // 0.8 s long press

    logic [4:0] raw, sync1, sync2, stable, prev_stable;
    int db_cnt [0:4];
    assign raw = {btn_u, btn_d, btn_l, btn_r, btn_c};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync1 <= 5'd0; sync2 <= 5'd0; stable <= 5'd0; prev_stable <= 5'd0;
            for (int i = 0; i < 5; i++) db_cnt[i] <= 0;
        end else begin
            sync1 <= raw;
            sync2 <= sync1;
            prev_stable <= stable;
            for (int i = 0; i < 5; i++) begin
                if (sync2[i] != stable[i]) begin
                    if (db_cnt[i] >= DB_MAX) begin
                        stable[i] <= sync2[i];
                        db_cnt[i] <= 0;
                    end else begin
                        db_cnt[i] <= db_cnt[i] + 1;
                    end
                end else begin
                    db_cnt[i] <= 0;
                end
            end
        end
    end

    assign hold_u  = stable[4];
    assign hold_d  = stable[3];
    assign hold_l  = stable[2];
    assign hold_r  = stable[1];

    assign pulse_u = stable[4] & ~prev_stable[4];
    assign pulse_d = stable[3] & ~prev_stable[3];
    assign pulse_l = stable[2] & ~prev_stable[2];
    assign pulse_r = stable[1] & ~prev_stable[1];

    // BTNC Tap vs Hold (0.8s)
    int c_cnt;
    logic c_long_fired;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_cnt <= 0;
            c_long_fired <= 1'b0;
            tap_c <= 1'b0;
            back_c <= 1'b0;
        end else begin
            tap_c  <= 1'b0;
            back_c <= 1'b0;
            if (stable[0]) begin
                if (!c_long_fired) begin
                    if (c_cnt >= LONG_MAX) begin
                        c_long_fired <= 1'b1;
                        back_c <= 1'b1;
                    end else begin
                        c_cnt <= c_cnt + 1;
                    end
                end
            end else begin
                if (prev_stable[0] && !c_long_fired) begin
                    tap_c <= 1'b1;
                end
                c_cnt <= 0;
                c_long_fired <= 1'b0;
            end
        end
    end
endmodule