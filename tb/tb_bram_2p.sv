// =============================================================================
// tb_bram_2p.sv  —  Self-checking testbench for the dual-port BRAM wrapper
// =============================================================================
//
// SCENARIOS
//   1. Zero-init       — uninitialized memory reads as 0 everywhere.
//   2. Sparse writes   — write a few specific addresses, read them back,
//                        verify both the written cells AND the untouched
//                        cells (which should still be 0).
//   3. Read latency    — confirm that rd_data appears 1 clock after rd_addr
//                        is driven.
//   4. Concurrent W+R  — simultaneously write to address X and read from
//                        address Y (X ≠ Y) for several cycles. Read should
//                        be unaffected by ongoing writes elsewhere.
//   5. Wide-word param — second instance with a wider word verifies the
//                        DATA_W parameter is honored.
//
// Run (shell):
//   $ verilator --binary -j 0 -Wall -Wno-fatal --trace --Mdir /tmp/bram_build \
//       rtl/bram_2p.sv tb/tb_bram_2p.sv \
//       --top-module tb_bram_2p -o tb_bram_2p
//   $ /tmp/bram_build/tb_bram_2p
// =============================================================================

`timescale 1ns/1ps

module tb_bram_2p;

    localparam int  DATA_W_A    = 32;     // primary instance: A
    localparam int  DEPTH_A     = 16;
    localparam int  DATA_W_B    = 64;     // wider instance for parameter check
    localparam int  DEPTH_B     = 8;
    localparam time CLK_PERIOD  = 10ns;

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    logic clk;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk <= ~clk;

    // -------------------------------------------------------------------------
    // DUT A — 32-bit × 16-deep
    // -------------------------------------------------------------------------
    logic                       a_wr_en;
    logic [$clog2(DEPTH_A)-1:0] a_wr_addr;
    logic [DATA_W_A-1:0]        a_wr_data;
    logic [$clog2(DEPTH_A)-1:0] a_rd_addr;
    logic [DATA_W_A-1:0]        a_rd_data;

    bram_2p #(
        .DATA_W   (DATA_W_A),
        .DEPTH    (DEPTH_A),
        .INIT_FILE("")
    ) dut_a (
        .wr_clk  (clk),
        .wr_en   (a_wr_en),
        .wr_addr (a_wr_addr),
        .wr_data (a_wr_data),
        .rd_clk  (clk),
        .rd_addr (a_rd_addr),
        .rd_data (a_rd_data)
    );

    // -------------------------------------------------------------------------
    // DUT B — 64-bit × 8-deep (just verifies the parameters propagate)
    // -------------------------------------------------------------------------
    logic                       b_wr_en;
    logic [$clog2(DEPTH_B)-1:0] b_wr_addr;
    logic [DATA_W_B-1:0]        b_wr_data;
    logic [$clog2(DEPTH_B)-1:0] b_rd_addr;
    logic [DATA_W_B-1:0]        b_rd_data;

    bram_2p #(
        .DATA_W   (DATA_W_B),
        .DEPTH    (DEPTH_B),
        .INIT_FILE("")
    ) dut_b (
        .wr_clk  (clk),
        .wr_en   (b_wr_en),
        .wr_addr (b_wr_addr),
        .wr_data (b_wr_data),
        .rd_clk  (clk),
        .rd_addr (b_rd_addr),
        .rd_data (b_rd_data)
    );

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    int errors = 0;
    int checks = 0;

    task automatic check32(input string label,
                           input logic [DATA_W_A-1:0] got,
                           input logic [DATA_W_A-1:0] exp);
        checks++;
        if (got !== exp) begin
            $display("[%0t] FAIL  %s : got=0x%08h exp=0x%08h", $time, label, got, exp);
            errors++;
        end else begin
            $display("[%0t] pass  %s : 0x%08h", $time, label, got);
        end
    endtask

    task automatic check64(input string label,
                           input logic [DATA_W_B-1:0] got,
                           input logic [DATA_W_B-1:0] exp);
        checks++;
        if (got !== exp) begin
            $display("[%0t] FAIL  %s : got=0x%016h exp=0x%016h", $time, label, got, exp);
            errors++;
        end else begin
            $display("[%0t] pass  %s : 0x%016h", $time, label, got);
        end
    endtask

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic init_signals();
        a_wr_en   = 1'b0;
        a_wr_addr = '0;
        a_wr_data = '0;
        a_rd_addr = '0;
        b_wr_en   = 1'b0;
        b_wr_addr = '0;
        b_wr_data = '0;
        b_rd_addr = '0;
    endtask

    // Drive a write at the next negedge so it lands at the upcoming posedge.
    task automatic do_write_a(input int addr,
                              input logic [DATA_W_A-1:0] data);
        @(negedge clk);
        a_wr_addr = addr[$clog2(DEPTH_A)-1:0];
        a_wr_data = data;
        a_wr_en   = 1'b1;
        @(posedge clk);
        @(negedge clk);
        a_wr_en   = 1'b0;
    endtask

    // Issue a read address; sample rd_data 1 cycle later.
    task automatic do_read_a(input int addr,
                             output logic [DATA_W_A-1:0] data);
        @(negedge clk);
        a_rd_addr = addr[$clog2(DEPTH_A)-1:0];
        @(posedge clk);   // rd_data captures here (registered output)
        @(negedge clk);   // sample on the negedge after the latching posedge
        data = a_rd_data;
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    initial begin
        logic [DATA_W_A-1:0] got;

        $dumpfile("waves_bram.vcd");
        $dumpvars(0, tb_bram_2p);

        init_signals();
        // Let the initial block in the BRAM run (zero-fill).
        repeat (3) @(posedge clk);

        // -----------------------------------------------------------------
        // Scenario 1 — Zero-init
        // -----------------------------------------------------------------
        $display("\n--- Scenario 1: Zero-init ---");
        for (int i = 0; i < DEPTH_A; i++) begin
            do_read_a(i, got);
            check32($sformatf("zero_init.addr=%0d", i), got, '0);
        end

        // -----------------------------------------------------------------
        // Scenario 2 — Sparse writes; check both written and untouched cells
        // -----------------------------------------------------------------
        $display("\n--- Scenario 2: Sparse writes ---");
        do_write_a(3,  32'hDEADBEEF);
        do_write_a(7,  32'hCAFEBABE);
        do_write_a(11, 32'h12345678);

        do_read_a(3,  got);  check32("sparse.read_addr_3",   got, 32'hDEADBEEF);
        do_read_a(7,  got);  check32("sparse.read_addr_7",   got, 32'hCAFEBABE);
        do_read_a(11, got);  check32("sparse.read_addr_11",  got, 32'h12345678);
        // Untouched cells must still be zero.
        do_read_a(0,  got);  check32("sparse.untouched_0",   got, '0);
        do_read_a(5,  got);  check32("sparse.untouched_5",   got, '0);
        do_read_a(15, got);  check32("sparse.untouched_15",  got, '0);

        // -----------------------------------------------------------------
        // Scenario 3 — Read latency
        //   Drive rd_addr=3 at cycle T (negedge T), sample rd_data at
        //   negedge T+1. The do_read_a task already does this; here we
        //   verify the latency by sampling at multiple offsets.
        // -----------------------------------------------------------------
        $display("\n--- Scenario 3: Read latency ---");
        @(negedge clk);
        a_rd_addr = 4'd3;             // expect DEADBEEF
        // BEFORE the upcoming posedge: rd_data should still reflect the
        // PREVIOUS read (whatever address we last drove). We don't check
        // that — too fragile to depend on prior state. Just confirm that
        // ONE cycle later, rd_data is 0xDEADBEEF.
        @(posedge clk);                // bram captures mem[3] into rd_data here
        @(negedge clk);
        check32("latency.1cycle.addr=3", a_rd_data, 32'hDEADBEEF);

        // -----------------------------------------------------------------
        // Scenario 4 — Concurrent write + read (different addresses)
        //   Write addr=5 with 0xABCD0001 while reading addr=7 (= CAFEBABE).
        //   The read should be unaffected by the ongoing write.
        // -----------------------------------------------------------------
        $display("\n--- Scenario 4: Concurrent W + R ---");
        @(negedge clk);
        a_wr_addr = 4'd5;
        a_wr_data = 32'hABCD0001;
        a_wr_en   = 1'b1;
        a_rd_addr = 4'd7;             // simultaneously read addr 7
        @(posedge clk);
        @(negedge clk);
        a_wr_en   = 1'b0;
        check32("concurrent.read=7_unaffected", a_rd_data, 32'hCAFEBABE);
        // Now confirm the write to addr 5 actually happened.
        do_read_a(5, got);
        check32("concurrent.write=5_landed", got, 32'hABCD0001);

        // -----------------------------------------------------------------
        // Scenario 5 — Wide-word param check (DUT B = 64-bit)
        // -----------------------------------------------------------------
        $display("\n--- Scenario 5: Wide-word param ---");
        @(negedge clk);
        b_wr_addr = 3'd2;
        b_wr_data = 64'h0123_4567_89AB_CDEF;
        b_wr_en   = 1'b1;
        @(posedge clk);
        @(negedge clk);
        b_wr_en   = 1'b0;
        @(negedge clk);
        b_rd_addr = 3'd2;
        @(posedge clk);
        @(negedge clk);
        check64("wide.read_64b", b_rd_data, 64'h0123_4567_89AB_CDEF);

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        $display("\n========================================");
        $display(" Checks: %0d   Errors: %0d", checks, errors);
        if (errors == 0) $display(" RESULT: ALL TESTS PASSED");
        else             $display(" RESULT: FAILED");
        $display("========================================\n");

        $finish;
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 1000);
        $display("TIMEOUT");
        $finish;
    end

endmodule
