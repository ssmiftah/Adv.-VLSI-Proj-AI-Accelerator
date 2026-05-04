# Project Summary — Systolic-Array AI Accelerator

This is the umbrella project document. It walks through what was built,
how it fits together, what we found out along the way, and what those
findings mean. For decision-by-decision design rationale and for raw
numbers, follow the per-phase links in
[00_project_plan.md](00_project_plan.md).

The companion [README](../README.md) is a higher-level entry point;
this document goes a level deeper.

The host-facing UART bridge (Phase 6B) lives on top of the accelerator
but is not part of its core narrative. It is documented separately in
[host_uart_bridge.md](host_uart_bridge.md).

---

## 1. Problem and goals

The project goal was to build a **TPU-style INT8 matrix-multiply
accelerator** in SystemVerilog, push it through Vivado on a Nexys A7,
and use it to demonstrate the five techniques that anchor the course:
**pipelining, parallel processing, retiming, strength reduction, and
algorithm/architecture co-design**.

We deliberately scoped the work as a *learning project* — staged in
seven phases, each with a "concept-first" design-decisions doc locked
before any RTL was written, and a results doc at the end. Every
testbench is self-checking; every phase ends with measured numbers, not
waveform inspection.

The chosen platform constraints fixed two important things up front:

- **DSP budget = 240** (XC7A100T's DSP48E1 count). Any S ≥ 16 with a
  DSP-backed MAC is going to overflow — and it does (Phase 5).
- **INT8 inputs / INT32 accumulators.** INT8 maps cleanly onto a
  single DSP48E1; INT32 accumulation is enough for K ≤ 64
  (theoretical max product is 127 × 128 ≈ 2¹⁵, summed 64 times stays
  comfortably inside ±2³¹).

---

## 2. Overall design

```
┌──────────────────────────────────────────────────────────────────────┐
│                       accelerator_top  (Phase 5)                     │
│                                                                      │
│   Host write port ─►  A_BRAM ──┐                                     │
│   Host write port ─►  B_BRAM ──┤                                     │
│   Host read  port ◄── C_BRAM ◄─┤                                     │
│                                │                                     │
│                                ▼                                     │
│                       ┌─────────────────┐                            │
│                       │ tile_controller │  runtime M, N, K           │
│                       │   (FSM)         │  edge-tile handling        │
│                       │                 │  raster tile order         │
│                       └────────┬────────┘                            │
│                                │ a_col, b_row, drain, clear_col      │
│                                ▼                                     │
│                       ┌─────────────────┐                            │
│                       │  systolic_array │  S × S mesh of pe_int8     │
│                       │    + skew_buf   │  phantom-edge wiring       │
│                       │                 │  column-shift drain        │
│                       │                 │      ┌────────────┐        │
│                       │                 │ ───► │  pe_int8   │        │
│                       │                 │      │  └─►mult_* │        │
│                       │                 │      └────────────┘        │
│                       └─────────────────┘                            │
│                                                                      │
│   start, M_in, N_in, K_in ────►                                      │
│   busy, done              ◄────                                      │
└──────────────────────────────────────────────────────────────────────┘
```

The layering is intentional. Each box is independently testable, has a
self-checking TB, and was completed/verified before the box that
contains it was started. The block-diagram boundaries are also the
boundaries between the phases.

The accelerator's external interface is deliberately **just BRAM ports
plus a start/done handshake**. Anything that drives those ports — a
testbench, a UART bridge, an AXI master — is out of scope for the
accelerator design itself.

### Dataflow

The accelerator is **output-stationary (OS)**. Each PE owns one cell of
the output matrix; A walks across rows, B walks down columns, partial
products accumulate in the PE's `c_reg`, and at the end of a tile the
column-shift drain shifts every column out, S cells per cycle, into the
C_BRAM.

For workloads larger than S × S, the **tile controller** chops the
matmul into S × S output tiles in raster order (vary tile_r fastest,
then tile_p) and streams the inner-K loop through the array for each
tile. Workload dimensions M, N, K are runtime inputs latched at
`start`, so the same bitstream can run any matmul up to
`MAX_M × MAX_N × MAX_K` (= 64 × 64 × 64).

### Key parameters (build-time)

| Parameter      | Default | Range tested      | What it controls |
|----------------|---------|-------------------|------------------|
| `S`            | 8       | {4, 8, 16}        | Array side length (S × S PEs total) |
| `DATA_W`       | 8       | 8                 | A/B element width (INT8) |
| `ACC_W`        | 32      | 32                | Accumulator width (INT32) |
| `MAX_M/N/K`    | 64      | 64                | BRAM-imposed maximum runtime workload dims |
| `MULT_TYPE`    | "DSP"   | DSP/LUT/TRUNC/MITCHELL/BAM | Which multiplier each PE uses |
| `MULT_TRUNC_L` | 0       | 0/2/4             | Bits zeroed by TRUNC variant |
| `MULT_BAM_B`   | 0       | 0/2/4             | BAM input-truncation strength |

### Key conventions

A few conventions are worth pulling out because they shaped the
codebase:

1. **Packed 2D ports.** Module boundaries crossing more than one bit of
   payload always use `logic [N-1:0][W-1:0]` (packed) — never
   `logic [W-1:0] x [N-1:0]` (unpacked). This dodges a Verilator
   quirk where unpacked array ports occasionally don't propagate, and
   keeps everything portable across simulators.
2. **No `\`default_nettype none\`.** Vivado parses RTL slightly
   stricter than Verilator and complained about port-type qualifiers
   under `default_nettype none`. We dropped the directive globally
   rather than fight it, accepting the small loss in lint strictness.
3. **One self-checking TB per module, plus integration TBs.** Every
   leaf module has its own pass/fail TB; integration TBs (array,
   accelerator, layer) feed real workloads and check against
   software-computed golden references.
4. **BRAMs use flat words, controller and array use packed-2D.** A
   tiny `assign struct = flat` dance at the accelerator boundary
   bridges the two, so neither side has to compromise its preferred
   interface.

---

## 3. Phase-by-phase findings

### Phase 0 — Foundations

Locked the dataflow (output-stationary), the array size baseline (S=8),
and the drain mechanism (TPU-style column shift). Hand-traced a
2×2 × 2×2 matmul and derived the cycle count for a generic M × N × K:

> cycles ≈ 2·S − 1 (skew) + K − 1 (compute) + S (drain) + 1 (flush)

The hand trace showed why systolic arrays are *rhythmic*: data and
results all move synchronously per cycle, with no asynchronous
handshakes inside the mesh. That insight set up everything that came
later. No RTL.

### Phase 1 — Single PE

Built `pe_int8` with a 2-stage pipeline (input registers → MAC) and
a `clear_acc` priority over `en` so a tile boundary deterministically
zeroes `c_reg`. The 32-bit accumulator was sized so that K=64
INT8×INT8 MACs cannot overflow.

Self-checking TB exercised 11 directed scenarios (zero, max-positive,
max-negative, mixed signs, boundary cases). 11/11 passed.

Phase 1 is also where we settled on **DSP inference via `(* use_dsp =
"yes" *)`** rather than instantiating the DSP48E1 macro by hand. The
attribute is portable, lets Vivado make placement decisions, and Phase
3 confirmed it produces single-DSP cells per MAC.

### Phase 2 — Systolic array

The most subtle phase. Two design wins worth noting:

**Phantom-edge wiring.** Rather than special-casing the top row and
left column ("if `i == 0`, take input from the top edge; else take
from PE above"), the array declares one extra row and one extra
column of wires:

```sv
logic signed [S-1:0][S:0][DATA_W-1:0]  a_wire;   // [row][col=0..S]
logic signed [S:0][S-1:0][DATA_W-1:0]  b_wire;   // [row=0..S][col]
```

The actual mesh seeds the `[*][0]` row and `[0][*]` column from outside
the generate, and every PE in the generate is then identical:
`a_wire[i][j+1] <= a_wire[i][j];`. Cleaner code, identical synthesis.

**Column-shift drain.** Instead of a separate readout network, the
drain reuses the same PE chain. After compute, `drain_en` shifts
`c_reg` values down the column, S cycles to drain, exposing one row of
S values per cycle on the bottom edge. This matches TPU v1's
documented mechanism and reuses ~all the existing infrastructure.

200/200 scenarios passed at S=8.

### Phase 3 — Retiming and Fmax

Three controlled experiments, each isolated to one change:

| Experiment                              | Fmax    |
|-----------------------------------------|--------:|
| A. baseline (no retiming hints)         |  104    |
| B. `(* use_dsp = "yes" *)` on the MAC   |  129    |
| C. + `(* keep = "true" *)` on `c_reg`   |  140    |

The result: **+35 % Fmax from two attribute changes**, no logic
restructuring. The lesson — retiming on FPGAs is mostly about telling
the synthesizer where to put registers it's already going to create
anyway, not about adding new pipeline stages.

The critical path before and after retiming was the same edge:
`a_reg → multiplier → c_reg.D`. Retiming *moved* `c_reg` so that the
adder absorbed into the DSP block's M-stage, dropping the post-DSP
combinational logic to nearly zero.

### Phase 4 — Strength reduction

Five non-DSP multiplier variants compared. PPA + accuracy on the bare
S=8 array:

| Variant     | Fmax  | LUTs   | DSPs | SQNR (K=8) |
|-------------|------:|-------:|-----:|-----------:|
| **DSP**     | 128.7 |  2,049 |   64 |     ∞      |
| LUT (exact) | 103.6 |  7,937 |    0 |     ∞      |
| TRUNC L=2   | 103.0 |  7,689 |    0 |    66 dB   |
| TRUNC L=4   | 103.5 |  7,441 |    0 |    49 dB   |
| Mitchell    |  74.7 | 12,493 |    0 |    55 dB   |
| BAM B=2     | 112.4 |  5,873 |    0 |    47 dB   |
| BAM B=4     | 132.2 |  4,390 |    0 |    29 dB   |

Two findings stood out:

**Mitchell is uncompetitive on FPGAs.** Mitchell's log-domain
multiplier looks compelling in ASIC literature: a few adders and a
shifter replace a full multiplier. But on Artix-7 the variable-amount
shifter is a barrel network, and barrel shifters are LUT-expensive.
Result: **57 % more LUTs and 28 % less Fmax than the LUT exact
multiplier**, with worse accuracy than even TRUNC L=2. A clean
demonstration that "fewer arithmetic operations" ≠ "less area" when
the arithmetic includes barrel shifts on a substrate without dedicated
shifter hardware.

**BAM B=4 is the LUT-only sweet spot.** It hits **132 MHz, 4.4 k
LUTs, 0 DSPs** — actually *faster than the DSP variant* — at the cost
of ~6 dB accuracy. For applications that have any tolerance for
quantization noise (e.g. a NN that's already 8-bit-quantized), this is
genuinely interesting.

### Phase 5 — Tiling and algo/arch co-design

Wrapped the array with `tile_controller` (runtime-programmable matmul
dimensions, edge-tile handling, raster tile order) and ran a six-point
sweep across S × MULT_TYPE.

The headline finding: **the DSP budget is a hard cliff at S=16**.

```
S=16 DSP variant needs 256 DSPs
XC7A100T provides       240 DSPs
                        ──── 16 short — synth completes, place_design dies at DRC.
```

The variant does fit if we drop to a LUT-only multiplier:
`acc_S16_BAM_B2` builds at 23,836 LUTs (37.6 % of the part) and 106 MHz.
But this is the kind of constraint that simple per-MAC analysis
completely misses — at the algorithm level, S=16 might look like a free
4× throughput improvement; at the architecture level, it forces a
multiplier-topology change.

A second, less obvious finding: **system Fmax saturates near 105 MHz
at the accelerator level**, regardless of S. The bare-array Phase 4
runs hit 128–140 MHz; integration loses 20+ MHz to the controller.
Three distinct critical-path regimes show up depending on S:

| S  | Critical path                                              |
|----|------------------------------------------------------------|
|  4 | `tile_controller`'s address arithmetic → BRAM read addr   |
|  8 | FSM state register (one-hot) → PE c_reg (S² fanout)       |
| 16 | PE-to-PE inside the array itself (back to Phase 4 regime) |

So the integration penalty isn't a single fixed cost — it's a
path-dependent effect that shifts with array size.

The `acc_S8_DSP` point dominated the throughput-per-LUT chart and is
what ended up on the README's headline.

### Phase 6A — Layer-level demo

A real 3×3 conv layer (C_in=4, C_out=16, H=W=8, padding=1) lowered to
matmul `(M, N, K) = (64, 16, 36)` via im2col. The layer fits in one
invocation (no host-side tiling), so the demo exercises the
end-to-end path: BRAM load via host write port → `start` → tile
controller orchestration over 8 M-tiles × 2 N-tiles × 36 K-steps →
drain → C readback via host read port.

**The DSP variant is bit-exact against NumPy.** That validated the
entire RTL stack and the harness in one shot.

The interesting result was the per-MAC vs per-layer SQNR comparison:

| Variant   | Phase 4 SQNR (K=8) | Phase 6A SQNR (K=36) | Δ (dB) |
|-----------|-------------------:|---------------------:|-------:|
| TRUNC_L2  |               66   |                58.45 |  −7.6  |
| TRUNC_L4  |               49   |                42.59 |  −6.4  |
| BAM_B2    |               47   |                27.89 | −19.1  |
| Mitchell  |               55   |                26.43 | −28.6  |

The K=8 → K=36 deltas reveal **error structure**:

- For independent zero-mean errors, SQNR is K-invariant. Δ ≈ 0.
- For consistently biased errors, SQNR drops by 10·log₁₀(K₂/K₁) ≈ −6.5 dB.
- For errors that are *correlated with the signal* (multiplicative),
  there is no simple bound — the error and signal accumulate together.

TRUNC sits near the biased-error prediction (truncation always shaves
off positive amounts → bias dominates). BAM and Mitchell are far worse
than that, because their per-MAC error is proportional to the input
magnitude itself.

The headline: **per-MAC SQNR is not a sufficient statistic for
layer-level accuracy**. Two variants 11 dB apart at K=8 (Mitchell vs
TRUNC_L2) become **32 dB apart at K=36**. A strength-reduction
designer who optimizes on per-MAC numbers alone will get burned at the
network level.

---

## 4. Cross-cutting discussions

### 4.1 The five techniques, where they actually helped

| Technique             | Phase  | Where it earned its keep |
|-----------------------|--------|--------------------------|
| Pipelining            |  1, 2  | 2-stage PE; skew buffers; phantom-edge mesh |
| Parallel processing   |  2     | S² PEs concurrently; column-shift drain in S parallel paths |
| Retiming              |  3     | `(* use_dsp *)` + `(* keep *)` → +35 % Fmax with zero logic changes |
| Strength reduction    |  4     | Five MAC variants compared; BAM B=4 = LUT-only sweet spot |
| Algo / arch co-design |  5, 6A | DSP-budget cliff at S=16; per-MAC ≠ per-layer accuracy |

The mapping is uncontrived — each phase exists because the technique
was the motivating question. A "clean" demo of pipelining wouldn't
have been worth its own phase; we did pipelining because we needed it
to close timing on a real array.

### 4.2 Things that surprised us

1. **Mitchell's FPGA cost.** ASIC literature praises Mitchell as a
   simple log-domain multiplier — a few adders, no array of partial
   products. On Xilinx the implicit barrel shifter dominates, and the
   final LUT count is 57 % *higher* than the exact LUT multiplier. The
   substrate matters.

2. **System Fmax doesn't track bare-array Fmax.** Phase 4 had 7
   variants in the 100–140 MHz range; Phase 5 wrapped them in
   accelerator_top and they all bunched up at 101–110 MHz. The
   controller adds a separate critical path that the bare array
   doesn't have. Lesson: PPA at the leaf module is necessary but not
   sufficient.

3. **BAM B=4 *faster* than DSP at S=8.** 132 vs 129 MHz. The DSP
   variant's critical path was the routing into the DSP block;
   BAM B=4 stays in fabric where the router has more options.

4. **The DSP-budget cliff was clean and unambiguous**: 256 needed,
   240 available, place_design refuses. There was no gradual fallback
   to LUT-based MACs — it was a hard error. This is exactly the kind
   of qualitative effect that motivates the algo/arch co-design
   technique in the first place.

5. **Per-MAC SQNR mispredicts layer SQNR by 30 dB for some variants.**
   The K-dependence is the publishable insight from Phase 6A.

### 4.3 Things that didn't work

- **Trying to silence Verilator's metacomment detector.** Any comment
  starting with the word "verilator" (case-insensitive) gets parsed
  as a directive. We rewrote a couple of comment blocks (and
  eventually saved the rule to project memory).

- **`default_nettype none`.** Vivado's stricter parsing made the SV
  port qualifiers tip-toey; we dropped the directive everywhere.

- **The first version of the C-readback in `tb_layer.sv`.** A
  pipelined idiom relied on Active-region scheduling that varies
  across simulators. Rewrote as the boring two-cycle-per-word pattern
  — slower but unambiguous. The whole readback is 256 cycles either
  way; it doesn't matter.

### 4.4 The C++ extractor and the workflow win

Phase 5 produced 6 (planned) + 8 (Phase 4 carryover) = 14 build
directories under `build/`. Hand-collecting Fmax, LUTs, DSPs, BRAM,
power numbers from each `vivado.log` / `utilization.rpt` / etc. is a
classic source of typos.

[`tools/extract_results.cpp`](../tools/extract_results.cpp) (C++17,
CMake build) parses all of that automatically into one CSV plus a
Markdown table, and was rewritten twice during the project to handle
new fields. The investment paid off: the Phase 5 results table in
`docs/phase5/01_results.md` is generated from the extractor output;
the comparison rows are in their natural order; nothing was
typed by hand.

The lesson: spending a couple of hours on tooling *before* the data
deluge is consistently worth it.

### 4.5 The phased delivery worked

No phase started until the previous one had a passing TB and a
results doc. This sounds bureaucratic but in practice it caught two
classes of bug we'd otherwise have spent days on:

- **Layer integration discovered no bugs in the systolic array.** All
  the bugs we hit at the integration level were in the integration
  itself (controller addressing, drain timing). The array could be
  trusted because we'd already verified it.

- **The Phase 6A bit-exact match validated 6 levels of stack at once.**
  When DSP-variant C_dut == C_ref to the bit, you know the BRAM
  packing is right, the address layout is right, the controller's
  edge-tile handling is right (even though this workload had no
  partial tiles), the drain timing is right, the host readback is
  right. One pass condition, six things checked.

---

## 5. What we'd do differently

- **Add more aggressive retiming experiments earlier.** Phase 3 stopped
  at +35 %; we could plausibly close at higher Fmax with deeper
  pipeline staging in the controller's address generator. We didn't,
  because by Phase 5 the system Fmax was bounded by integration paths
  the bare-array experiments didn't expose.

- **Sweep S=12 or S=14 in Phase 5.** The DSP cliff at S=16 is sharp;
  S=12 (144 DSPs) would fit and might Pareto-dominate S=8 + smaller
  multipliers. The sweep was scoped to powers of 2; the actual design
  is parameterized to allow non-power-of-2.

- **Run a multi-layer Phase 6A.** A single conv layer's accuracy
  result is suggestive; a 3-4-layer mini-network would tell us
  whether layer-level error compounds or saturates across the stack.
  This is the most natural follow-up.

- **Quant-aware training.** Phase 6A used uniform random INT8 inputs.
  Real networks have non-uniform, magnitude-skewed activations, which
  hits BAM and Mitchell harder than uniform inputs do. Real numbers
  could be substantially worse than ours.

---

## 6. Status snapshot

| Phase | Title                          | Status   | Headline number / finding                              |
|-------|--------------------------------|----------|--------------------------------------------------------|
| 0     | Foundations                    | ✅ done  | OS dataflow + column-shift drain locked                |
| 1     | Single PE                      | ✅ done  | 11/11 TB pass; 2-stage pipeline                        |
| 2     | Systolic array                 | ✅ done  | 200/200 TB pass; phantom-edge wiring                   |
| 3     | Retiming / Fmax                | ✅ done  | 104 → 140 MHz from `use_dsp` + `keep`                  |
| 4     | Strength reduction             | ✅ done  | 7 variants; BAM B=4 hits 132 MHz with 0 DSPs           |
| 5     | Tiling / algo-arch co-design   | ✅ done  | DSP cliff at S=16; sweet spot acc_S8_DSP @ 106 MHz     |
| 6A    | Layer demo (sim)               | ✅ done  | DSP bit-exact; per-MAC ≠ per-layer SQNR (Δ up to 29 dB)|

For the full plan, see [00_project_plan.md](00_project_plan.md). The
host-facing UART bridge built on top of this accelerator is documented
in [host_uart_bridge.md](host_uart_bridge.md).
