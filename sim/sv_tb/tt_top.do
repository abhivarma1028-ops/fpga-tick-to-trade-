# =============================================================================
# QuestaSim run script -- full tick-to-trade pipeline waveform
# Usage (GUI):    cd sim/sv_tb && vsim -do tt_top.do
#       (batch):  vsim -c -do tt_top.do
# After it loads, the Wave window is populated; click Zoom Full (or run `wave zoom full`).
# =============================================================================

vlib work
vmap work work

vlog -sv +acc \
    ../../rtl/itch_parser.sv \
    ../../rtl/order_book_m2.sv \
    ../../rtl/strategy_imbalance.sv \
    ../../rtl/risk_check.sv \
    ../../rtl/latency_counter.sv \
    ../../rtl/tick_to_trade_top.sv \
    tb_tick_to_trade_top.sv

vsim -voptargs=+acc work.tb_tick_to_trade_top

set tb /tb_tick_to_trade_top

add wave -divider "Clock / Reset"
add wave $tb/clk $tb/rst_n

add wave -divider "ITCH input (AXI-Stream)"
add wave $tb/s_axis_tvalid $tb/s_axis_tready $tb/s_axis_tlast
add wave -radix hexadecimal $tb/s_axis_tdata

add wave -divider "Parser decode"
add wave $tb/dut/u_parser/byte_cnt $tb/dut/u_parser/m_valid
add wave -radix hexadecimal $tb/dut/u_parser/msg_type
add wave -radix unsigned $tb/dut/u_parser/order_ref $tb/dut/u_parser/shares $tb/dut/u_parser/price
add wave $tb/dut/u_parser/side

add wave -divider "Order book (top-of-book)"
add wave $tb/dut/u_book/state $tb/dut/u_book/book_valid $tb/dut/u_book/msg_ready
add wave -radix unsigned $tb/dut/u_book/best_bid_price $tb/dut/u_book/best_bid_size
add wave -radix unsigned $tb/dut/u_book/best_ask_price $tb/dut/u_book/best_ask_size

add wave -divider "Strategy decision"
add wave $tb/dut/u_strategy/decision_valid $tb/dut/u_strategy/action
add wave -radix unsigned $tb/dut/u_strategy/order_price $tb/dut/u_strategy/order_size

add wave -divider "Risk check (15c3-5)"
add wave $tb/halt $tb/dut/u_risk/out_valid $tb/dut/u_risk/reject_valid
add wave -radix unsigned $tb/dut/u_risk/reject_reason
add wave -radix decimal $tb/dut/u_risk/position

add wave -divider "Latency counter"
add wave -radix unsigned $tb/dut/u_lat/free_cnt $tb/dut/u_lat/t0
add wave $tb/dut/u_lat/measuring
add wave -radix unsigned $tb/dut/u_lat/last_latency_cycles

add wave -divider "Decision out (72-bit bus)"
add wave $tb/m_axis_tvalid $tb/m_axis_tlast
add wave -radix hexadecimal $tb/m_axis_tdata

run -all
