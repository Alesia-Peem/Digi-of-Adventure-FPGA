// flash_model.v - TESTBENCH ONLY. Behavioural subset of the Spansion/Cypress S25FL128S on the Nexys A7:
//   * 0x6B Quad Output Read: command (8 bit) + 24-bit address on DQ0, MSB first, sampled on SCK rising;
//     DUMMY dummy clocks; then data on DQ[3:0], high nibble first, driven after every SCK falling edge
//     (old data held TH ns, new data valid TV ns after the edge), address increments until CS# goes high.
//   * memory: SIZE bytes starting at flash byte address BASE, loaded with $readmemh from +HEX=<file>
//     (default mem/pictures.hex, one byte per line); +ZERO fills it with zeros instead ("not programmed"
//     case for the `missing` test). Addresses outside [BASE, BASE+SIZE) read 0xFF (erased flash).
//   * protocol checks counted in `errors` (printed by the testbench):
//       - fewer than 8 SCK cycles with CS# high before the first command (STARTUPE2 quirk, see qspi_reader)
//       - command other than 0x6B
//       - DQ2/DQ3 (WP#/HOLD#) not high while command/address bits are clocked in
//       - the hex file is shorter than SIZE (stale mem/pictures.hex; SIZE = PIC_BYTES of pic_map.vh)
//   `drive` is 1 while the model drives DQ (the testbench uses it to detect bus contention).
`timescale 1ns/1ps
module flash_model #(
    parameter [23:0] BASE  = 24'h400000,
    parameter integer SIZE = 5077760,
    parameter integer DUMMY = 8,
    parameter real TV = 8.0,      // clock-to-output (S25FL128S tV at 50 MHz: 8 ns max)
    parameter real TH = 2.0       // output hold after SCK falling (tHO)
) (
    input  wire       csn,
    input  wire       sck,
    inout  wire [3:0] dq
);
    reg [7:0] mem [0:SIZE-1];
    reg [8*256-1:0] fname;
    integer i;
    initial begin
        if ($test$plusargs("ZERO")) begin
            for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'h00;
        end else begin
            if (!$value$plusargs("HEX=%s", fname)) fname = "mem/pictures.hex";
            $readmemh(fname, mem);
        end
    end

    integer errors = 0;
    // a hex file shorter than SIZE leaves the tail undefined (stale mem/pictures.hex vs pic_map.vh)
    initial begin
        #1;
        if (^mem[SIZE-1] === 1'bx) begin
            errors = errors + 1;
            $display("FLASH: %0s has fewer than SIZE = %0d bytes (stale? rerun tools/pic_pack.py)", fname, SIZE);
        end
    end
    integer pre_rise = 0;         // SCK rising edges with CS# high before the first command
    integer nrise = 0;            // SCK rising edges since CS# went low
    integer ncmd = 0;
    reg     seen_cs = 1'b0;
    reg [7:0]  cmd;
    reg [23:0] addr;
    reg [3:0]  dq_r = 4'hz;
    reg        drive = 1'b0;
    assign dq = drive ? dq_r : 4'bzzzz;

    function [7:0] rd(input [23:0] a);
        begin
            if (a >= BASE && a < BASE + SIZE) rd = mem[a - BASE];
            else rd = 8'hFF;
        end
    endfunction

    always @(negedge csn) begin
        if (!seen_cs && pre_rise < 8) begin
            errors = errors + 1;
            $display("FLASH: first command after only %0d SCK cycles with CS# high (need >= 8)", pre_rise);
        end
        seen_cs = 1'b1;
        nrise = 0; cmd = 8'h00; addr = 24'h0;
        ncmd = ncmd + 1;
    end
    always @(posedge csn) begin
        #1 drive = 1'b0;          // tDIS
        dq_r = 4'hz;
    end

    always @(posedge sck) begin
        if (csn) pre_rise = pre_rise + 1;
        else begin
            nrise = nrise + 1;
            if (nrise <= 8) begin
                cmd = {cmd[6:0], dq[0]};
                if (nrise == 8 && cmd != 8'h6B) begin
                    errors = errors + 1;
                    $display("FLASH: unsupported command %02h", cmd);
                end
            end else if (nrise <= 32) addr = {addr[22:0], dq[0]};
            if (nrise <= 32 && dq[3:2] !== 2'b11) begin
                errors = errors + 1;
                $display("FLASH: WP#/HOLD# (DQ2/DQ3) = %b during command bit %0d", dq[3:2], nrise);
            end
        end
    end

    // data phase: nibble n (0 = high nibble of the first byte) after the falling edge that follows
    // rising edge 8 + 24 + DUMMY + n
    integer nib;
    reg [7:0] b;
    always @(negedge sck) begin
        if (!csn && cmd == 8'h6B && nrise >= 32 + DUMMY) begin
            nib = nrise - (32 + DUMMY);
            b = rd(addr + (nib >> 1));
            #(TH);
            if (!csn) begin
                drive = 1'b1; dq_r = 4'bxxxx;
                #(TV - TH);
                if (!csn) dq_r = nib[0] ? b[3:0] : b[7:4];
            end
        end
    end
endmodule
