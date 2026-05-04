# =============================================================================
# synth_top.tcl  —  Bonded synth + impl + bitstream for top.sv (Phase 6B)
# =============================================================================
#
# This is the FIRST bonded (non-OOC) build of the project. The Phase 5 sweep
# (synth_acc.tcl) used out-of-context mode because accelerator_top has 396
# I/O bits — well above the 210 pin budget. top.sv reduces that to just
# clk + UART + button + 3 LEDs, so the design fits the package and we can
# write_bitstream.
#
# Output: build/top/top.bit  (ready to load via Vivado Hardware Manager).
#
# RUN FROM PROJECT ROOT:
#   vivado -mode batch -log build/top/vivado.log -source tcl/synth_top.tcl
# =============================================================================

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
set tcl_dir   [file dirname [file normalize [info script]]]
set proj_root [file normalize [file join $tcl_dir ..]]

set rtl_dir   [file join $proj_root rtl]
set xdc_dir   [file join $proj_root constraints]

set build_dir [file join $proj_root build top]
file mkdir $build_dir
puts "INFO: build_dir = $build_dir"

# -----------------------------------------------------------------------------
# Target device — Nexys A7-100T
# -----------------------------------------------------------------------------
set part xc7a100tcsg324-1

# -----------------------------------------------------------------------------
# Read RTL  (everything from accelerator + new bridge / UART / top)
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
    [file join $rtl_dir uart_rx.sv] \
    [file join $rtl_dir uart_tx.sv] \
    [file join $rtl_dir host_bridge.sv] \
    [file join $rtl_dir top.sv] \
]

foreach f $rtl_files {
    puts "INFO: reading $f"
    read_verilog -sv $f
}

# -----------------------------------------------------------------------------
# Read constraints (bonded version — pins + clock + I/O delays)
# -----------------------------------------------------------------------------
set xdc_file [file join $xdc_dir nexys_a7_top.xdc]
puts "INFO: reading $xdc_file"
read_xdc $xdc_file

# -----------------------------------------------------------------------------
# Synthesis  (BONDED — not OOC; top.sv fits the package)
# -----------------------------------------------------------------------------
puts "INFO: ===== synth_design ====="
synth_design -top top -part $part

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
# Bitstream
# -----------------------------------------------------------------------------
puts "INFO: ===== write_bitstream ====="
write_bitstream -force [file join $build_dir top.bit]

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
puts " HEADLINE  top  (bonded, Phase 6B)"
puts "----------------------------------------------------------------"
puts "  Target period  : ${xdc_period_ns} ns  (100 MHz)"
puts "  Worst slack    : $wns ns"
puts "  Achieved period: $achieved_period ns"
puts "  Fmax           : $fmax_mhz MHz"
puts "  Bitstream      : $build_dir/top.bit"
puts "  Reports        : $build_dir/"
puts "================================================================"
puts ""

puts "INFO: done"
