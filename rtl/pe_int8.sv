// =============================================================================
// pe_int8.sv  —  Output-Stationary INT8 Processing Element
// =============================================================================
//
// One MAC + forwarding registers. Built to be tiled into an S x S systolic
// array. The multiplier is now a pluggable sub-module (Phase 4), selected by
// the MULT_TYPE parameter.
//
// PIPELINE (2 stages — restored from Phase 3 Exp B's 3-stage version so all
// Phase 4 multiplier variants compete on the same MAC pipeline):
//
//      cycle t              cycle t+1
//   ┌───────────────┐    ┌──────────────────────────┐
//   │ a_in ──► a_reg│    │ a_out  = a_reg           │  ← 1-cycle hop
//   │ b_in ──► b_reg│    │ b_out  = b_reg           │
//   │               │    │ p   = mult(a_reg, b_reg) │  (combinational)
//   │               │    │ c_reg ← c_reg + p_ext    │  ← 1 more cycle
//   └───────────────┘    └──────────────────────────┘
//
// Inputs presented at cycle t cause the accumulator to update at the end of
// cycle t+1. Forwarding to the right/down neighbor happens during cycle t+1.
//
// PARAMETER MULT_TYPE selects which multiplier variant is wired into the MAC:
//   "DSP"      — exact, Vivado infers DSP48E1
//   "LUT"      — exact, forced into LUT fabric (no DSP)
//   "TRUNC"    — truncated approximate (drops MULT_TRUNC_L lower bits)
//   "MITCHELL" — Mitchell log-domain approximate
//   "BAM"      — broken-array partial-product approximate
//
// CONTROL:
//   rst_n      asynchronous active-low reset
//   en         pipeline enable
//   clear_acc  synchronous clear of c_reg only
//   drain_en   column-shift drain mode
//
// NEXT-STATE PRIORITY for c_reg:
//   !rst_n > clear_acc > drain_en > en > hold
// =============================================================================

`timescale 1ns/1ps

module pe_int8 #(
    parameter int    DATA_W       = 8,
    parameter int    ACC_W        = 32,
    parameter string MULT_TYPE    = "DSP",
    parameter int    MULT_TRUNC_L = 0,
    parameter int    MULT_BAM_B   = 0
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       en,
    input  logic                       clear_acc,
    input  logic                       drain_en,

    input  logic signed [DATA_W-1:0]   a_in,
    input  logic signed [DATA_W-1:0]   b_in,
    input  logic signed [ACC_W-1:0]    c_drain_in,

    output logic signed [DATA_W-1:0]   a_out,
    output logic signed [DATA_W-1:0]   b_out,
    output logic signed [ACC_W-1:0]    c_out,
    output logic signed [ACC_W-1:0]    c_drain_out
);

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    // Stage-1 registers (also serve as the forwarding latches).
    logic signed [DATA_W-1:0]    a_reg;
    logic signed [DATA_W-1:0]    b_reg;

    // Module-scope wire that holds whichever generate branch's c_reg.
    // The branches drive this; the module outputs are fed from it.
    logic signed [ACC_W-1:0]     c_reg_view;

    // -------------------------------------------------------------------------
    // Stage 1 — input / forwarding registers (shared by all variants)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_reg <= '0;
            b_reg <= '0;
        end
        else if (en) begin
            a_reg <= a_in;
            b_reg <= b_in;
        end
    end

    // -------------------------------------------------------------------------
    // Stages 2 (multiplier) + 3 (accumulator) — selected by MULT_TYPE
    //
    // Each branch fully owns its own multiplier sub-module AND its own c_reg
    // declaration. This lets us put a per-variant `(* use_dsp = ... *)`
    // attribute on c_reg, which is essential because:
    //   - DSP variant: we want use_dsp = "yes" so Vivado absorbs the MAC
    //     pattern (mul + add) into a single DSP48E1.
    //   - All other variants: we want use_dsp = "no" so the accumulator add
    //     stays in fabric. Otherwise Vivado would still use a DSP for just
    //     the add (taking the fabric multiplier's output as the C input),
    //     which is a hybrid that defeats the strength-reduction comparison.
    //
    // The accumulator next-state logic is otherwise identical across variants.
    // -------------------------------------------------------------------------
    generate
        // ---------------- DSP — full MAC absorbed into one DSP48 ------------
        if (MULT_TYPE == "DSP") begin : gen_dsp

            logic signed [2*DATA_W-1:0] p_narrow;
            logic signed [ACC_W-1:0]    prod;

            mult_dsp #(.DATA_W(DATA_W)) u_mult (
                .a (a_reg),
                .b (b_reg),
                .p (p_narrow)
            );

            assign prod = {{(ACC_W - 2*DATA_W){p_narrow[2*DATA_W-1]}}, p_narrow};

            (* use_dsp = "yes" *)
            logic signed [ACC_W-1:0] c_reg;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)         c_reg <= '0;
                else if (clear_acc) c_reg <= '0;
                else if (drain_en)  c_reg <= c_drain_in;
                else if (en)        c_reg <= c_reg + prod;
            end

            assign c_reg_view = c_reg;

        end
        // ---------------- LUT — exact, forced into fabric ------------------
        else if (MULT_TYPE == "LUT") begin : gen_lut

            logic signed [2*DATA_W-1:0] p_narrow;
            logic signed [ACC_W-1:0]    prod;

            mult_lut #(.DATA_W(DATA_W)) u_mult (
                .a (a_reg),
                .b (b_reg),
                .p (p_narrow)
            );

            assign prod = {{(ACC_W - 2*DATA_W){p_narrow[2*DATA_W-1]}}, p_narrow};

            (* use_dsp = "no" *)
            logic signed [ACC_W-1:0] c_reg;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)         c_reg <= '0;
                else if (clear_acc) c_reg <= '0;
                else if (drain_en)  c_reg <= c_drain_in;
                else if (en)        c_reg <= c_reg + prod;
            end

            assign c_reg_view = c_reg;

        end
        // ---------------- TRUNC — fabric truncated approximate -------------
        else if (MULT_TYPE == "TRUNC") begin : gen_trunc

            logic signed [2*DATA_W-1:0] p_narrow;
            logic signed [ACC_W-1:0]    prod;

            mult_truncated #(
                .DATA_W(DATA_W),
                .L     (MULT_TRUNC_L)
            ) u_mult (
                .a (a_reg),
                .b (b_reg),
                .p (p_narrow)
            );

            assign prod = {{(ACC_W - 2*DATA_W){p_narrow[2*DATA_W-1]}}, p_narrow};

            (* use_dsp = "no" *)
            logic signed [ACC_W-1:0] c_reg;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)         c_reg <= '0;
                else if (clear_acc) c_reg <= '0;
                else if (drain_en)  c_reg <= c_drain_in;
                else if (en)        c_reg <= c_reg + prod;
            end

            assign c_reg_view = c_reg;

        end
        // ---------------- MITCHELL — log-domain approximate ----------------
        else if (MULT_TYPE == "MITCHELL") begin : gen_mitchell

            logic signed [2*DATA_W-1:0] p_narrow;
            logic signed [ACC_W-1:0]    prod;

            mult_mitchell #(.DATA_W(DATA_W)) u_mult (
                .a (a_reg),
                .b (b_reg),
                .p (p_narrow)
            );

            assign prod = {{(ACC_W - 2*DATA_W){p_narrow[2*DATA_W-1]}}, p_narrow};

            (* use_dsp = "no" *)
            logic signed [ACC_W-1:0] c_reg;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)         c_reg <= '0;
                else if (clear_acc) c_reg <= '0;
                else if (drain_en)  c_reg <= c_drain_in;
                else if (en)        c_reg <= c_reg + prod;
            end

            assign c_reg_view = c_reg;

        end
        // ---------------- BAM — broken-array multiplier --------------------
        else if (MULT_TYPE == "BAM") begin : gen_bam

            logic signed [2*DATA_W-1:0] p_narrow;
            logic signed [ACC_W-1:0]    prod;

            mult_bam #(
                .DATA_W(DATA_W),
                .B     (MULT_BAM_B)
            ) u_mult (
                .a (a_reg),
                .b (b_reg),
                .p (p_narrow)
            );

            assign prod = {{(ACC_W - 2*DATA_W){p_narrow[2*DATA_W-1]}}, p_narrow};

            (* use_dsp = "no" *)
            logic signed [ACC_W-1:0] c_reg;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)         c_reg <= '0;
                else if (clear_acc) c_reg <= '0;
                else if (drain_en)  c_reg <= c_drain_in;
                else if (en)        c_reg <= c_reg + prod;
            end

            assign c_reg_view = c_reg;

        end
        else begin : gen_unimpl
            initial $fatal(1, "pe_int8: unsupported MULT_TYPE '%s'", MULT_TYPE);
            assign c_reg_view = '0;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign a_out       = a_reg;
    assign b_out       = b_reg;
    assign c_out       = c_reg_view;
    assign c_drain_out = c_reg_view;

endmodule
