# QuestaSim: risk_check waveform.   Usage: vsim -do risk.do
vlib work
vmap work work
vlog -sv +acc ../../rtl/risk_check.sv tb_risk_check.sv
vsim -voptargs=+acc work.tb_risk_check
set tb /tb_risk_check
add wave -divider "Clock / Reset"
add wave $tb/clk $tb/rst_n
add wave -divider "Proposed order in"
add wave $tb/halt $tb/in_valid $tb/in_action
add wave -radix unsigned $tb/in_price $tb/in_size $tb/ref_price
add wave -divider "Checks (internal)"
add wave $tb/dut/ok_size $tb/dut/ok_price $tb/dut/ok_position
add wave -radix decimal $tb/dut/position $tb/dut/new_position
add wave -divider "Gate out"
add wave $tb/out_valid $tb/out_action
add wave -radix unsigned $tb/out_price $tb/out_size
add wave $tb/reject_valid
add wave -radix unsigned $tb/reject_reason
run -all
