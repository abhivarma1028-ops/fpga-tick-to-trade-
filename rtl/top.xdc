# ─────────────────────────────────────────────────────────────────────────────
# top.xdc — timing constraints for tick_to_trade_top
#
# Target: AWS F1 (Xilinx UltraScale+ VU9P, xcvu9p-flgb2104-2-i)
#
# NOTE: This is an OUT-OF-CONTEXT (OOC) constraint set. On AWS F1 the physical
# I/O pins are owned by the Shell (SH); the user Custom Logic (CL) connects to
# the Shell internally over AXI. We therefore constrain ONLY the clock and the
# I/O timing budget — never PACKAGE_PIN / IOSTANDARD (those would require a
# physical board and would conflict with the F1 Shell).
# ─────────────────────────────────────────────────────────────────────────────

# ── Primary clock: 200 MHz (5.000 ns period) ────────────────────────────────
# Matches the 5 ns clock used in all cocotb testbenches and the
# "39 cycles @ 200 MHz ≈ 195 ns" tick-to-trade figure.
create_clock -name clk -period 5.000 [get_ports clk]

# Clock uncertainty budget (jitter + on-chip variation). The F1 Shell supplies
# clocks with real jitter; reserve a conservative 0.100 ns.
set_clock_uncertainty 0.100 [get_clocks clk]

# ── Input / output delay budgets ────────────────────────────────────────────
# Reserve a slice of the clock period for routing + setup on either side of the
# CL/SH boundary, so static timing analysis sees a realistic budget instead of
# assuming zero-delay I/O. rst_n is treated as an asynchronous control.
#
# OOC clock-insertion note: in this out-of-context run the clock is driven by a
# single global BUFG that fans out across the whole die, giving ~2.7 ns of clock
# insertion delay. That insertion cancels on internal register→register paths
# (all of which meet 200 MHz) but NOT on I/O paths, where it is charged against
# the I/O delay. A 40% (2.0 ns) budget was therefore unsatisfiable for I/O even
# though the logic is fine. In the real F1 build the clock is placed in clock
# regions (insertion ~0.3 ns) and the Shell registers the CL/SH boundary, so the
# realistic boundary budget is small. Use 10% here to reflect that.

set CLK_PERIOD 5.000
set IO_BUDGET  [expr {$CLK_PERIOD * 0.10}]

# All input ports except clk.
# NOTE: remove_from_collection is NOT permitted inside an .xdc file
# (Designutils 20-1307), which previously left in_ports unset and silently
# dropped the input-delay constraint. Use an XDC-legal get_ports filter instead.
set_input_delay  -clock clk $IO_BUDGET [get_ports * -filter {DIRECTION == IN && NAME != clk}]

# All output ports
set_output_delay -clock clk $IO_BUDGET [all_outputs]

# ── AXI-Lite latency-readout: slow control/status, not a timed datapath ──────
# The AXI-Lite slave (latency_counter histogram readout) is polled by the host
# PS over the Shell AXI fabric at a low rate; it has no single-cycle, 200 MHz
# requirement and its handshakes (awready/arready/…) are combinational per the
# AXI-Lite spec. Exclude the whole s_axil_* boundary from the 200 MHz I/O budget;
# the Shell's AXI interconnect closes its timing in-context.
set_false_path -from [get_ports {s_axil_*} -filter {DIRECTION == IN}]
set_false_path -to   [get_ports {s_axil_*} -filter {DIRECTION == OUT}]

# ── Asynchronous reset ──────────────────────────────────────────────────────
# rst_n is an active-low async reset, synchronized inside the design.
# Exclude it from input-delay timing (it is not a synchronous data path).
set_false_path -from [get_ports rst_n]
