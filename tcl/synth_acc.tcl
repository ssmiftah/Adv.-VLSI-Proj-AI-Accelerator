# =============================================================================
# synth_acc.tcl  —  Synthesis + impl for accelerator_top (Phase 5)
# =============================================================================
#
# Same flow as synth.tcl but synthesizes the integrated accelerator (BRAMs +
# tile_controller + systolic_array) rather than the bare array.
#
# This script is what we use for the Phase 5 algo/arch sweep:
#   - S ∈ {4, 8, 16}
#   - MULT_TYPE ∈ {DSP, BAM B=2}
#
# RUN FROM THE PROJECT ROOT (PowerShell):
#   vivado -mode batch -log build/acc_S8_DSP/vivado.log `
#          -source tcl/synth_acc.tcl -tclargs 8 DSP
#
# Args:
#   1. array size S          (default 8)
#   2. multiplier variant    (default "DSP")
#   3. truncation L          (default 0)
#   4. BAM break point B     (default 0)
#
# Outputs land in build/acc_<run_tag>/.
# =============================================================================

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
set S            8
set MULT_TYPE    "DSP"
set MULT_TRUNC_L 0
set MULT_BAM_B   0
if {[llength $argv] >= 1} { set S            [lindex $argv 0] }
if {[llength $argv] >= 2} { set MULT_TYPE    [lindex $argv 1] }
if {[llength $argv] >= 3} { set MULT_TRUNC_L [lindex $argv 2] }
if {[llength $argv] >= 4} { set MULT_BAM_B   [lindex $argv 3] }
puts "INFO: Building accelerator_top with S=$S MULT_TYPE=$MULT_TYPE MULT_TRUNC_L=$MULT_TRUNC_L MULT_BAM_B=$MULT_BAM_B"

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
set tcl_dir   [file dirname [file normalize [info script]]]
set proj_root [file normalize [file join $tcl_dir ..]]

set rtl_dir         [file join $proj_root rtl]
set xdc_dir         [file join $proj_root constraints]

set run_tag         "acc_S${S}_${MULT_TYPE}"
if {$MULT_TYPE eq "TRUNC"} { append run_tag "_L${MULT_TRUNC_L}" }
if {$MULT_TYPE eq "BAM"}   { append run_tag "_B${MULT_BAM_B}" }

set build_dir       [file join $proj_root build $run_tag]
file mkdir $build_dir
puts "INFO: build_dir = $build_dir"

# -----------------------------------------------------------------------------
# Target device — Nexys A7-100T
# -----------------------------------------------------------------------------
set part xc7a100tcsg324-1

# -----------------------------------------------------------------------------
# Read RTL  (multiplier variants + PE + array + BRAM + controller + top)
# -----------------------------------------------------------------------------
set rtl_files [list \
    [file join $rtl_dir multiplier mult_dsp.sv] \
    [file join $rtl_dir multiplier mult_lut.sv] \
    [file join $rtl_dir multiplier mult_truncated.sv] \
    [file join $rtl_dir multiplier mult_mitchell.sv] \
    [file join $rtl_dir multiplier mult_bam.sv] \
    [file join $rtl_dir pe_int8.sv] \
    [file join $rtl_dir skew_buffer.sv] \
    [file join $rtl_dir systolic_array.sv] \
    [file join $rtl_dir bram_2p.sv] \
    [file join $rtl_dir tile_controller.sv] \
    [file join $rtl_dir accelerator_top.sv] \
]

foreach f $rtl_files {
    puts "INFO: reading $f"
    read_verilog -sv $f
}

# -----------------------------------------------------------------------------
# Read constraints
# -----------------------------------------------------------------------------
set xdc_file [file join $xdc_dir nexys_a7.xdc]
puts "INFO: reading $xdc_file"
read_xdc $xdc_file

# -----------------------------------------------------------------------------
# Synthesis  (out-of-context — port count exceeds package pins)
# -----------------------------------------------------------------------------
puts "INFO: ===== synth_design ====="
synth_design -top accelerator_top \
             -part $part \
             -mode out_of_context \
             -generic S=$S \
             -generic DATA_W=8 \
             -generic ACC_W=32 \
             -generic MAX_M=64 \
             -generic MAX_N=64 \
             -generic MAX_K=64 \
             -generic MULT_TYPE=$MULT_TYPE \
             -generic MULT_TRUNC_L=$MULT_TRUNC_L \
             -generic MULT_BAM_B=$MULT_BAM_B

write_checkpoint -force [file join $build_dir post_synth.dcp]
report_timing_summary -file [file join $build_dir post_synth_timing.rpt]
report_utilization   -file [file join $build_dir post_synth_util.rpt]

# -----------------------------------------------------------------------------
# Implementation
# -----------------------------------------------------------------------------
puts "INFO: ===== opt_design ====="
opt_design

puts "INFO: ===== place_design ====="
place_design

puts "INFO: ===== route_design ====="
route_design

write_checkpoint -force [file join $build_dir post_route.dcp]

# -----------------------------------------------------------------------------
# Reports
# -----------------------------------------------------------------------------
puts "INFO: ===== reports ====="
report_timing_summary -file [file join $build_dir timing_summary.rpt] \
                      -delay_type min_max -report_unconstrained \
                      -check_timing_verbose -max_paths 10
report_utilization   -file [file join $build_dir utilization.rpt]
report_power         -file [file join $build_dir power.rpt]
report_drc           -file [file join $build_dir drc.rpt]
report_timing -file [file join $build_dir worst_path.rpt] \
              -max_paths 5 -nworst 5 -delay_type max -path_type full

# -----------------------------------------------------------------------------
# Headline
# -----------------------------------------------------------------------------
set xdc_period_ns 10.0
set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
if {$wns ne ""} {
    set achieved_period [expr {$xdc_period_ns - $wns}]
    set fmax_mhz [expr {1000.0 / $achieved_period}]
} else {
    set achieved_period "n/a"
    set fmax_mhz "n/a"
}

puts ""
puts "================================================================"
puts " HEADLINE  accelerator_top  S=$S  MULT_TYPE=$MULT_TYPE"
puts "----------------------------------------------------------------"
puts "  Target period  : ${xdc_period_ns} ns  (100 MHz)"
puts "  Worst slack    : $wns ns"
puts "  Achieved period: $achieved_period ns"
puts "  Fmax           : $fmax_mhz MHz"
puts "  Reports        : $build_dir/"
puts "================================================================"
puts ""

puts "INFO: done"
