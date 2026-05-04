# =============================================================================
# synth.tcl  —  Headless Vivado synthesis + implementation for systolic_array
# =============================================================================
#
# Targets the Nexys A7-100T board (XC7A100T, package CSG324, speed grade -1).
# Runs in batch mode (no GUI), produces timing / utilization / power reports.
#
# RUN FROM THE PROJECT ROOT:
#
#   Windows (Vivado bin in PATH):
#     vivado -mode batch -source tcl/synth.tcl -tclargs 8
#
#   Or absolute path:
#     "C:/Xilinx/Vivado/2023.1/bin/vivado.bat" -mode batch -source tcl/synth.tcl -tclargs 8
#
# The single tclarg is the array size S (default 8 if omitted).
#
# OUTPUTS land in build/<run_name>/ :
#   - timing_summary.rpt
#   - utilization.rpt
#   - power.rpt
#   - drc.rpt
#   - synth_checkpoint.dcp / impl_checkpoint.dcp  (reload in GUI for inspection)
# =============================================================================

# -----------------------------------------------------------------------------
# Arguments:
#   1. array size S          (default 8)
#   2. multiplier variant    (default "DSP")
#   3. truncation L          (default 0)
#   4. BAM break point B     (default 0)
# -----------------------------------------------------------------------------
set S            8
set MULT_TYPE    "DSP"
set MULT_TRUNC_L 0
set MULT_BAM_B   0
if {[llength $argv] >= 1} { set S            [lindex $argv 0] }
if {[llength $argv] >= 2} { set MULT_TYPE    [lindex $argv 1] }
if {[llength $argv] >= 3} { set MULT_TRUNC_L [lindex $argv 2] }
if {[llength $argv] >= 4} { set MULT_BAM_B   [lindex $argv 3] }
puts "INFO: Building systolic_array with S=$S MULT_TYPE=$MULT_TYPE MULT_TRUNC_L=$MULT_TRUNC_L MULT_BAM_B=$MULT_BAM_B"

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
# Resolve project root from this script's location (works regardless of cwd).
set tcl_dir   [file dirname [file normalize [info script]]]
set proj_root [file normalize [file join $tcl_dir ..]]

set rtl_dir         [file join $proj_root rtl]
set xdc_dir         [file join $proj_root constraints]
set run_tag         "S${S}_${MULT_TYPE}"
if {$MULT_TYPE eq "TRUNC"}    { append run_tag "_L${MULT_TRUNC_L}" }
if {$MULT_TYPE eq "BAM"}      { append run_tag "_B${MULT_BAM_B}"  }
set build_dir       [file join $proj_root build $run_tag]
file mkdir $build_dir
puts "INFO: build_dir = $build_dir"

# -----------------------------------------------------------------------------
# Target device — Nexys A7-100T
# -----------------------------------------------------------------------------
set part xc7a100tcsg324-1

# -----------------------------------------------------------------------------
# Read RTL
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
# Synthesis
# -----------------------------------------------------------------------------
puts "INFO: ===== synth_design ====="
synth_design -top systolic_array \
             -part $part \
             -mode out_of_context \
             -generic S=$S \
             -generic DATA_W=8 \
             -generic ACC_W=32 \
             -generic MULT_TYPE=$MULT_TYPE \
             -generic MULT_TRUNC_L=$MULT_TRUNC_L \
             -generic MULT_BAM_B=$MULT_BAM_B

write_checkpoint -force [file join $build_dir post_synth.dcp]
report_timing_summary -file [file join $build_dir post_synth_timing.rpt]
report_utilization   -file [file join $build_dir post_synth_util.rpt]

# -----------------------------------------------------------------------------
# Implementation: opt → place → route
# -----------------------------------------------------------------------------
puts "INFO: ===== opt_design ====="
opt_design

puts "INFO: ===== place_design ====="
place_design

puts "INFO: ===== route_design ====="
route_design

write_checkpoint -force [file join $build_dir post_route.dcp]

# -----------------------------------------------------------------------------
# Reports — these are the outputs we actually care about for the project report
# -----------------------------------------------------------------------------
puts "INFO: ===== reports ====="
report_timing_summary -file [file join $build_dir timing_summary.rpt] \
                      -delay_type min_max -report_unconstrained \
                      -check_timing_verbose -max_paths 10
report_utilization   -file [file join $build_dir utilization.rpt]
report_power         -file [file join $build_dir power.rpt]
report_drc           -file [file join $build_dir drc.rpt]

# A second timing pass that explicitly shows the worst critical path with
# levels of logic — most useful for retiming decisions.
report_timing -file [file join $build_dir worst_path.rpt] \
              -max_paths 5 -nworst 5 -delay_type max -path_type full

# -----------------------------------------------------------------------------
# Headline numbers to the console (so you don't have to open the .rpt files
# just to see Fmax)
# -----------------------------------------------------------------------------
set ts_obj [get_property STATUS [current_design]]
set wns    [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]

# Compute achievable period: target_period - WNS = achieved_period
set xdc_period_ns 10.0
if {$wns ne ""} {
    set achieved_period [expr {$xdc_period_ns - $wns}]
    set fmax_mhz [expr {1000.0 / $achieved_period}]
} else {
    set achieved_period "n/a"
    set fmax_mhz "n/a"
}

puts ""
puts "================================================================"
puts " HEADLINE  S=$S"
puts "----------------------------------------------------------------"
puts "  Target period  : ${xdc_period_ns} ns  (100 MHz)"
puts "  Worst slack    : $wns ns"
puts "  Achieved period: $achieved_period ns"
puts "  Fmax           : $fmax_mhz MHz"
puts "  Reports        : $build_dir/"
puts "================================================================"
puts ""

puts "INFO: done"
