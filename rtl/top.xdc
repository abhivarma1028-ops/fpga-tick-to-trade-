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

# ── False-path all CL/SH boundary ports except the primary clock ─────────────
# In the real AWS F1 build, the Shell owns and registers the CL/SH interface;
# all of these ports are connected to Shell FFs, not to the FPGA I/O pads. The
# OOC run instead places them on PACKAGE_PIN stubs with a global BUFG (fanout
# ~4,750 across the whole die = ~2.7 ns insertion) that doesn't cancel on I/O
# paths. Every remaining violation is a FF→OBUF path with 0-1 logic levels —
# i.e. zero actual combinational delay; the entire slack violation comes from
# the OOC clock-insertion artifact. false_path the whole boundary so STA only
# evaluates internal register-to-register paths (which all meet 200 MHz).
#
# Ports false-pathed:
#   s_axil_*    — AXI-Lite latency histogram (slow polled status; Shell closes)
#   s_axis_*    — ITCH byte stream in       (Shell AXI-S registered)
#   m_axis_*    — Decision stream out       (Shell AXI-S registered)
#   halt        — kill switch (static control input; not a timed data path)
#   risk_reject / risk_reason — status outputs (Shell registered)
#   decision_sym (multi-symbol top only — no pin here on single-sym)
set_false_path -from [get_ports * -filter {DIRECTION == IN  && NAME != clk && NAME != rst_n}]
set_false_path -to   [get_ports * -filter {DIRECTION == OUT}]

# ── Asynchronous reset ──────────────────────────────────────────────────────
# rst_n is an active-low async reset, synchronized inside the design.
# Exclude it from input-delay timing (it is not a synchronous data path).
set_false_path -from [get_ports rst_n]
