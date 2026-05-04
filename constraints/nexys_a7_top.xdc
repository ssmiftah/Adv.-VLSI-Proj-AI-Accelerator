# =============================================================================
# nexys_a7_top.xdc — bonded constraints for the Phase 6B bitstream
# =============================================================================
#
# Pin / I/O assignments for the on-board UART demo (top.sv).
#
# This file is consumed by tcl/synth_top.tcl. The OOC Phase 3-5 flow continues
# to use constraints/nexys_a7.xdc (clock-only).
#
# Pin numbers come from the Digilent Nexys A7-100T master XDC:
#   https://digilent.com/reference/programmable-logic/nexys-a7/start
# =============================================================================

# -----------------------------------------------------------------------------
# Clock — 100 MHz onboard oscillator (E3)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN E3 [get_ports clk_100]
set_property IOSTANDARD LVCMOS33 [get_ports clk_100]

create_clock -name clk_100 -period 10.0 [get_ports clk_100]

# -----------------------------------------------------------------------------
# UART (FTDI USB-to-serial bridge)
#   uart_rx_pin: data into FPGA  (FPGA pin C4 = USB-UART TXD from the host)
#   uart_tx_pin: data out of FPGA (FPGA pin D4 = USB-UART RXD to the host)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN C4 [get_ports uart_rx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_pin]

set_property PACKAGE_PIN D4 [get_ports uart_tx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_pin]

# -----------------------------------------------------------------------------
# Center pushbutton (BTNC) — active-high
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN N17 [get_ports btn_rst]
set_property IOSTANDARD LVCMOS33 [get_ports btn_rst]

# -----------------------------------------------------------------------------
# LEDs
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN H17 [get_ports {led[0]}]
set_property PACKAGE_PIN K15 [get_ports {led[1]}]
set_property PACKAGE_PIN J13 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# -----------------------------------------------------------------------------
# I/O timing
#   UART is so slow vs the 100 MHz clock that exact set_input/output_delay
#   numbers don't matter for closure. Any value <= 1 cycle is fine; we keep
#   the timer happy and the false_path on btn_rst lets the synchronizer do
#   its job.
# -----------------------------------------------------------------------------
set_input_delay  -clock clk_100 -max 1.0 [get_ports uart_rx_pin]
set_input_delay  -clock clk_100 -min 0.5 [get_ports uart_rx_pin]
set_output_delay -clock clk_100 -max 1.0 [get_ports uart_tx_pin]
set_output_delay -clock clk_100 -min 0.5 [get_ports uart_tx_pin]

set_false_path -from [get_ports btn_rst]   -to [all_registers]
set_false_path -from [get_ports uart_rx_pin] -to [all_registers]
set_false_path -to   [get_ports {led[*]}]
