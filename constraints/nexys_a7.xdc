# =============================================================================
# nexys_a7.xdc — clock-only constraints for synth/timing analysis
# =============================================================================
#
# Just the clock period for now. Pin assignments are NOT included because we're
# not yet generating a bitstream for the board — Phase 3 only needs Vivado to
# run synth + place + route + report timing.
#
# Once we do go to hardware (later in the project), we'll add:
#   - clock pin assignment (E3 on Nexys A7 = 100 MHz onboard oscillator)
#   - I/O pin assignments for whatever interface we expose
#
# Target: 100 MHz (10 ns period).
# After we see the baseline Fmax we can lower the target if there's slack to
# spare, or raise it (relax) if we have negative slack.
# =============================================================================

create_clock -name clk -period 10.0 [get_ports clk]

# Phase 3 is timing analysis on the bare module (out-of-context mode), so we
# don't need pin-level I/O delays. The main timing path of interest is purely
# internal (PE MAC + skew + drain), which the unconstrained-paths section of
# report_timing_summary captures. We deliberately avoid setting bogus
# input/output delays that would shadow the real critical path.
#
# When we later wrap the array in an FPGA-level top with a UART/AXI bridge,
# we'll add proper set_input_delay / set_output_delay against board timing.
