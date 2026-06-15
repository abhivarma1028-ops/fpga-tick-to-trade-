"""
cocotb testbench for risk_check.sv -- pre-trade SEC Rule 15c3-5 controls.
Drives proposed orders and checks the pass/block decision + reject reason
and the running net-position limit.

Run: cd sim && make TOPLEVEL=risk_check MODULE=tb_risk_check
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

# mirrors RTL parameter defaults
MAX_ORDER_SIZE = 500
MAX_POSITION   = 1000
MAX_PRICE_BAND = 5000
REF            = 1_500_000

# reject reason codes (mirror RTL localparams)
R_OK, R_SIZE, R_PRICE, R_POSITION, R_HALT = 0, 1, 2, 3, 4
BUY, SELL = 0, 1


async def reset(dut):
    dut.halt.value      = 0
    dut.in_valid.value  = 0
    dut.in_action.value = 0
    dut.in_price.value  = 0
    dut.in_size.value   = 0
    dut.ref_price.value = REF
    dut.rst_n.value     = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def propose(dut, action, price, size, halt=0):
    """Drive one proposed order; return (out_valid, reject_reason).
    Reads the combinational gate, then clocks once so an accepted order
    commits to the running position."""
    dut.in_valid.value  = 1
    dut.in_action.value = action
    dut.in_price.value  = price
    dut.in_size.value   = size
    dut.halt.value      = halt
    await Timer(1, unit="ns")            # let combinational logic settle
    ov = int(dut.out_valid.value)
    rr = int(dut.reject_reason.value)
    await RisingEdge(dut.clk)            # commit position if accepted
    dut.in_valid.value = 0
    await RisingEdge(dut.clk)
    return ov, rr


@cocotb.test()
async def test_normal_order_passes(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    ov, rr = await propose(dut, BUY, REF + 100, 100)
    assert ov == 1 and rr == R_OK, f"normal order should pass; ov={ov} rr={rr}"
    dut._log.info("PASS normal order accepted")


@cocotb.test()
async def test_oversized_blocked(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    ov, rr = await propose(dut, BUY, REF + 100, MAX_ORDER_SIZE + 1)
    assert ov == 0 and rr == R_SIZE, f"oversize should block SIZE; ov={ov} rr={rr}"
    dut._log.info("PASS oversized order blocked (SIZE)")


@cocotb.test()
async def test_price_collar_blocked(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    # price deviates by 10000 ticks > MAX_PRICE_BAND (5000)
    ov, rr = await propose(dut, BUY, REF + 10_000, 100)
    assert ov == 0 and rr == R_PRICE, f"out-of-band price should block; ov={ov} rr={rr}"
    dut._log.info("PASS price-collar block (PRICE)")


@cocotb.test()
async def test_price_collar_edge_ok(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    # deviation exactly at the band is allowed (<=)
    ov, rr = await propose(dut, SELL, REF - MAX_PRICE_BAND, 100)
    assert ov == 1 and rr == R_OK, f"price at band edge should pass; ov={ov} rr={rr}"
    dut._log.info("PASS price at band edge accepted")


@cocotb.test()
async def test_position_limit(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    # accumulate long position: 500 + 500 = 1000 (== limit, ok), next 500 -> 1500 blocked
    ov, rr = await propose(dut, BUY, REF, 500)
    assert ov == 1, f"first 500 should pass; ov={ov}"
    ov, rr = await propose(dut, BUY, REF, 500)
    assert ov == 1, f"second 500 (pos=1000==limit) should pass; ov={ov}"
    ov, rr = await propose(dut, BUY, REF, 500)
    assert ov == 0 and rr == R_POSITION, f"third should block POSITION; ov={ov} rr={rr}"
    dut._log.info("PASS net-position limit enforced")


@cocotb.test()
async def test_position_nets_out(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    # long 500, then SELL 500 -> flat, then a fresh BUY 500 should pass again
    await propose(dut, BUY, REF, 500)     # pos +500
    await propose(dut, SELL, REF, 500)    # pos 0
    ov, rr = await propose(dut, BUY, REF, 500)  # pos +500 again
    assert ov == 1 and rr == R_OK, f"after netting flat, BUY should pass; ov={ov} rr={rr}"
    dut._log.info("PASS position nets out (BUY then SELL)")


@cocotb.test()
async def test_halt_blocks_all(dut):
    cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
    await reset(dut)
    ov, rr = await propose(dut, BUY, REF + 100, 100, halt=1)
    assert ov == 0 and rr == R_HALT, f"halt should block all; ov={ov} rr={rr}"
    # and a normal order passes once halt clears
    ov, rr = await propose(dut, BUY, REF + 100, 100, halt=0)
    assert ov == 1 and rr == R_OK, f"after halt clears, order should pass; ov={ov} rr={rr}"
    dut._log.info("PASS kill-switch blocks then clears")
