# Systolic-Array AI Accelerator

A parameterized **TPU-style INT8 matrix-multiply accelerator** in
SystemVerilog, built as the Advanced VLSI final project. Targets the
**Digilent Nexys A7-100T** (Xilinx Artix-7 XC7A100T) and demonstrates
all five required techniques from the course:
**pipelining, parallel processing, retiming, strength reduction,
and algorithm/architecture co-design**.

The accelerator does INT8 × INT8 → INT32 matrix multiply via an
**output-stationary systolic array** with a runtime-programmable tile
controller. A pluggable multiplier block lets the same RTL be built with
exact DSP MACs, exact LUT-only MACs, or four approximate variants
(truncated, Mitchell log-domain, BAM with two truncation strengths).

**Headline result (acc_S8_DSP @ XC7A100T, OOC):**
6.8 GMAC/s peak in 2.3 k LUTs and 64 DSPs at **106 MHz**, with a real
3×3 conv layer running through it bit-exactly against a NumPy reference.

---

## What is implemented

| Layer                   | RTL module                                             | Notes |
|-------------------------|--------------------------------------------------------|-------|
| INT8 PE                 | [`rtl/pe_int8.sv`](rtl/pe_int8.sv)                     | 2-stage pipeline; pluggable multiplier (`MULT_TYPE`) |
| Multiplier variants (5) | [`rtl/multiplier/`](rtl/multiplier/)                   | DSP / LUT / TRUNC / Mitchell / BAM |
| Edge skew buffer        | [`rtl/skew_buffer.sv`](rtl/skew_buffer.sv)             | Triangular shift bank for matrix skewing |
| Systolic array          | [`rtl/systolic_array.sv`](rtl/systolic_array.sv)       | S × S mesh, phantom-edge wiring, column-shift drain |
| Operand BRAM            | [`rtl/bram_2p.sv`](rtl/bram_2p.sv)                     | Dual-port wrapper; supports `$readmemh` init |
| Tile controller         | [`rtl/tile_controller.sv`](rtl/tile_controller.sv)     | Runtime M/N/K; edge-tile handling; raster tile order |
| Integrated accelerator  | [`rtl/accelerator_top.sv`](rtl/accelerator_top.sv)     | 3 BRAMs + controller + array + host I/O |
| UART RX / TX            | [`rtl/uart_rx.sv`](rtl/uart_rx.sv), [`rtl/uart_tx.sv`](rtl/uart_tx.sv) | 8-N-1, configurable baud (Phase 6B; sim-verified) |
| UART command bridge     | [`rtl/host_bridge.sv`](rtl/host_bridge.sv)             | Packet protocol → BRAM ports + start/done (Phase 6B; sim-verified) |
| Bonded top-level        | [`rtl/top.sv`](rtl/top.sv)                             | Pin-bound build for the Nexys A7 (Phase 6B; not deployed) |

The design is fully parameterized: array size **S ∈ {4, 8, 16}**,
data widths, max workload bounds (`MAX_M`, `MAX_N`, `MAX_K`), and
multiplier choice are all build-time knobs.

## What is verified

Every phase ships a self-checking testbench that returns `0` errors on
success — no eyeballing waveforms.

| TB                      | Coverage                                                 | Result |
|-------------------------|----------------------------------------------------------|--------|
| [`tb_pe_int8.sv`](tb/tb_pe_int8.sv)                 | Single PE, 11 directed scenarios                       | 11/11 |
| [`tb_skew_buffer.sv`](tb/tb_skew_buffer.sv)         | Triangular skew correctness                            | pass |
| [`tb_bram_2p.sv`](tb/tb_bram_2p.sv)                 | Dual-port BRAM behavior                                | pass |
| [`tb_systolic_array.sv`](tb/tb_systolic_array.sv)   | Full S×S array vs golden, mixed scenarios at S=8       | 200/200 |
| [`tb_accelerator_top.sv`](tb/tb_accelerator_top.sv) | Tiling + edge-tiles + drain, 6 scenarios incl. M=20/N=15/K=12 partials | 1772/1772 |
| [`tb_uart.sv`](tb/tb_uart.sv)                       | UART TX→RX loopback, 256 random bytes                  | pass |
| [`tb_host_bridge.sv`](tb/tb_host_bridge.sv)         | All 5 protocol opcodes end-to-end through real UART blocks | pass |

Plus the **Phase 6A layer-level sweep** (the headline integration test):
a real 3×3 conv layer (lowered to matmul `(M,N,K) = (64, 16, 36)` via
im2col), with 5 multiplier variants compared at the layer level against
a NumPy golden:

| Variant   | Layer SQNR (dB) | Max abs err | Exact match |
|-----------|----------------:|------------:|------------:|
| **DSP**   |              ∞  |           0 |       100 % |
| TRUNC_L2  |          58.45  |          63 |         0 % |
| TRUNC_L4  |          42.59  |         347 |         0 % |
| BAM_B2    |          27.89  |       4,333 |         0 % |
| Mitchell  |          26.43  |       5,284 |         0 % |

(See [docs/phase6/01_results_6A.md](docs/phase6/01_results_6A.md) for the
full discussion, including the per-MAC-vs-per-layer SQNR analysis that
explains why Mitchell collapses at the layer level despite looking
competitive in per-MAC tests.)

## What is not done

- **Phase 6B (on-board UART demo):** RTL written, simulation-verified
  end-to-end via [`tb_host_bridge.sv`](tb/tb_host_bridge.sv), but not
  deployed to the physical board. Bitstream-build infrastructure
  (`tcl/synth_top.tcl`, pin-bound XDC) is in place; bring-up is a
  follow-up.

## Tools used

| Stage                 | Tool                                                     |
|-----------------------|----------------------------------------------------------|
| HDL                   | SystemVerilog (IEEE 1800-2017)                           |
| Simulation            | **Verilator 5.x** under WSL Ubuntu                       |
| Waveform viewer       | GTKWave (when needed)                                    |
| Synthesis / impl      | **Vivado 2023.x** (Windows native)                       |
| Target part           | xc7a100tcsg324-1 (Nexys A7-100T)                         |
| Vivado-output parser  | C++17 utility, [`tools/extract_results.cpp`](tools/extract_results.cpp) (CMake build) |
| Workload generation   | Python 3.13 + NumPy (in `.venv/`)                        |
| Host driver (planned) | Python + pyserial                                        |

## Repo layout

```
.
├── rtl/                  SystemVerilog source
│   ├── multiplier/         five MAC-engine variants
│   ├── pe_int8.sv          single PE
│   ├── skew_buffer.sv      input skewing
│   ├── systolic_array.sv   S × S mesh
│   ├── bram_2p.sv          BRAM wrapper
│   ├── tile_controller.sv  matmul orchestration
│   ├── accelerator_top.sv  array + BRAMs + controller
│   ├── uart_rx.sv, uart_tx.sv  Phase 6B UART blocks
│   ├── host_bridge.sv          Phase 6B command FSM
│   └── top.sv                  Phase 6B bonded top
│
├── tb/                   self-checking testbenches (one per module
│                         + integration TBs)
│
├── tcl/                  Vivado batch scripts
│   ├── synth.tcl           bare-array OOC build (Phase 3)
│   ├── synth_acc.tcl       integrated-accelerator OOC build (Phase 5)
│   └── synth_top.tcl       bonded build with UART/LEDs (Phase 6B)
│
├── constraints/          XDC files
│   ├── nexys_a7.xdc        clock-only (used by OOC flows)
│   └── nexys_a7_top.xdc    full pin map for the bonded build
│
├── tools/                C++ utility for parsing Vivado outputs
│   ├── extract_results.cpp
│   └── CMakeLists.txt
│
├── scripts/phase6/       Python harnesses for the layer-level demo
│   ├── gen_layer.py        generate A, B, golden C from an im2col conv
│   ├── run_layer.py        sweep the 5 multiplier variants in sim
│   └── host_demo.py        on-board driver (Phase 6B; needs the board)
│
├── sim/phase6/           generated workload + per-variant results
│
├── build/                Vivado output trees (gitignored)
│
├── docs/                 phase-by-phase design + results documentation
│   ├── 00_project_plan.md   umbrella plan + status table
│   ├── phase0/ … phase6/    per-phase {00_design_decisions, 01_results}
│
└── .venv/                Python 3.13 + NumPy + pyserial
```

## How to reproduce

### One-time setup

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
```

### Re-run the layer-level sweep (Phase 6A — the headline result)

This regenerates the workload, builds five Verilator binaries (one per
multiplier variant), runs them, parses the C output of each, and emits
a comparison table. Verilator must be installed in WSL.

```powershell
.venv\Scripts\python.exe scripts\phase6\gen_layer.py
.venv\Scripts\python.exe scripts\phase6\run_layer.py --rebuild
```

Output lands in `sim/phase6/`:
- `c_DSP.memh`, `c_BAM_B2.memh`, ... — DUT C outputs per variant
- `results_6A.csv`, `results_6A.md` — comparison table

### Re-run the synthesis sweep (Phase 5 — PPA numbers)

```powershell
# pick any from docs/phase5/00_design_decisions.md
vivado -mode batch -log build/acc_S8_DSP/vivado.log `
       -source tcl/synth_acc.tcl -tclargs 8 DSP

# parse all build/* runs into a comparison table
cmake -S tools -B tools/build && cmake --build tools/build --config Release
.\tools\build\Release\extract_results.exe build
```

### Run an individual module's TB

```bash
# from WSL, project root
verilator --binary --top-module tb_systolic_array \
    --Mdir obj_dir/tb_systolic_array -O2 \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-INITIALDLY \
    rtl/multiplier/*.sv rtl/pe_int8.sv rtl/skew_buffer.sv \
    rtl/systolic_array.sv tb/tb_systolic_array.sv

./obj_dir/tb_systolic_array/Vtb_systolic_array
```

# Vivado synth comparison

| Run | Fmax (MHz) | Slack (ns) | Period (ns) | LUTs | FFs | DSPs | BRAMs | Levels | Power (W) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| S8 | 140.1 | 2.863 | 7.137 | 2561 | 3271 | 128 | 0 | 3 | 0.270 |
| S8_BAM_B2 | 112.4 | 1.105 | 8.895 | 5873 | 2663 | 0 | 0 | 14 | 0.172 |
| S8_BAM_B4 | 132.2 | 2.437 | 7.563 | 4390 | 2119 | 0 | 0 | 10 | 0.143 |
| S8_DSP | 128.7 | 2.229 | 7.771 | 2049 | 3207 | 64 | 0 | 2 | 0.212 |
| S8_LUT | 103.6 | 0.344 | 9.656 | 7937 | 3207 | 0 | 0 | 15 | 0.207 |
| S8_MITCHELL | 74.7 | -3.393 | 13.393 | 12493 | 3207 | 0 | 0 | 21 | 0.318 |
| S8_TRUNC_L2 | 103.0 | 0.292 | 9.708 | 7689 | 3079 | 0 | 0 | 13 | 0.204 |
| S8_TRUNC_L4 | 103.5 | 0.335 | 9.665 | 7441 | 2951 | 0 | 0 | 14 | 0.202 |
| acc_S16_BAM_B2 | 106.6 | 0.619 | 9.381 | 23836 | 10524 | 0 | 11 | 13 | 0.512 |
| acc_S16_DSP |  |  |  |  |  |  |  |  |  |
| acc_S4_BAM_B2 | 109.3 | 0.848 | 9.152 | 1629 | 752 | 0 | 6 | 9 | 0.141 |
| acc_S4_DSP | 104.9 | 0.466 | 9.534 | 689 | 892 | 16 | 6 | 9 | 0.150 |
| acc_S8_BAM_B2 | 101.3 | 0.132 | 9.868 | 6124 | 2731 | 0 | 6 | 1 | 0.215 |
| acc_S8_DSP | 106.3 | 0.592 | 9.408 | 2282 | 3277 | 64 | 6 | 1 | 0.244 |

## Critical paths

| Run | Source | Destination |
|---|---|---|
| S8 | `gen_row[4].gen_col[6].u_pe/mul_reg0/CLK` | `gen_row[4].gen_col[6].u_pe/c_reg_reg[18]/D` |
| S8_BAM_B2 | `gen_row[0].gen_col[5].u_pe/b_reg_reg[3]/C` | `gen_row[0].gen_col[5].u_pe/gen_bam.c_reg_reg[31]/D` |
| S8_BAM_B4 | `gen_row[7].gen_col[4].u_pe/a_reg_reg[5]/C` | `gen_row[7].gen_col[4].u_pe/gen_bam.c_reg_reg[30]/D` |
| S8_DSP | `gen_row[3].gen_col[7].u_pe/a_reg_reg[7]/C` | `gen_row[3].gen_col[7].u_pe/gen_dsp.c_reg_reg[19]/D` |
| S8_LUT | `gen_row[0].gen_col[5].u_pe/a_reg_reg[2]/C` | `gen_row[0].gen_col[5].u_pe/gen_lut.c_reg_reg[30]/D` |
| S8_MITCHELL | `gen_row[7].gen_col[7].u_pe/a_reg_reg[1]/C` | `gen_row[7].gen_col[7].u_pe/gen_mitchell.c_reg_reg[27]/D` |
| S8_TRUNC_L2 | `gen_row[0].gen_col[6].u_pe/a_reg_reg[3]/C` | `gen_row[0].gen_col[6].u_pe/gen_trunc.c_reg_reg[24]/D` |
| S8_TRUNC_L4 | `gen_row[0].gen_col[6].u_pe/a_reg_reg[2]/C` | `gen_row[0].gen_col[6].u_pe/gen_trunc.c_reg_reg[28]/D` |
| acc_S16_BAM_B2 | `u_array/gen_row[0].gen_col[4].u_pe/b_reg_reg[2]/C` | `u_array/gen_row[0].gen_col[4].u_pe/gen_bam.c_reg_reg[29]/D` |
| acc_S16_DSP | `` | `` |
| acc_S4_BAM_B2 | `u_ctrl/M_reg_reg[0]/C` | `u_a_bram/mem_reg/ADDRBWRADDR[14]` |
| acc_S4_DSP | `u_ctrl/N_reg_reg[0]/C` | `u_c_bram/mem_reg_0/ADDRARDADDR[14]` |
| acc_S8_BAM_B2 | `u_ctrl/FSM_onehot_state_reg[4]/C` | `u_array/gen_row[3].gen_col[3].u_pe/gen_bam.c_reg_reg[8]/D` |
| acc_S8_DSP | `u_ctrl/FSM_onehot_state_reg[4]/C` | `u_array/gen_row[4].gen_col[0].u_pe/gen_dsp.c_reg_reg[30]/D` |

The umbrella plan with the full status table is at
[docs/00_project_plan.md](docs/00_project_plan.md). For a narrative
walk-through of the architecture, findings, and lessons across all
phases, see [docs/project_summary.md](docs/project_summary.md).

## The five techniques, mapped

| Technique             | Where it shows up                                                |
|-----------------------|------------------------------------------------------------------|
| Pipelining            | 2-stage PE; skew buffers; phantom-edge mesh                      |
| Parallel processing   | S² PEs operate concurrently; column-shift drain in S parallel paths |
| Retiming              | `c_reg` placement inside per-`MULT_TYPE` `generate-if` keeps the MAC stage |
| Strength reduction    | TRUNC, BAM, Mitchell variants — the multiplier replaced with cheaper operators |
| Algo / arch co-design | Tile sizes vs multiplier-variant sweep; DSP-budget cliff at S=16 |

## Disclosure

This Project was built using the help of Claude Code.


