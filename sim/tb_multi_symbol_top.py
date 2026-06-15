"""
Integration testbench for multi_symbol_top.sv -- the multi-symbol tick-to-trade
pipeline. Feeds ITCH byte streams for two different symbols and checks each
decision is tagged with the correct symbol and price.

Run: cd sim && make TOPLEVEL=multi_symbol_top MODULE=tb_multi_symbol_top
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from synth_itch import SynthITCH

CLK = 5


async def reset(dut):
    dut.rst_n.value         = 0
    dut.halt.value          = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tlast.value  = 0
    dut.m_axis_tready.value = 1
    dut.s_axil_awaddr.value = 0; dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value  = 0; dut.s_axil_wstrb.value = 0; dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 0
    dut.s_axil_araddr.value = 0; dut.s_axil_arvalid.value = 0; dut.s_axil_rready.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_framed(dut, framed: bytes):
    length = int.from_bytes(framed[0:2], 'big')
    raw = framed[2:2+length]
    for i, b in enumerate(raw):
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tdata.value  = b
        dut.s_axis_tlast.value  = 1 if i == len(raw)-1 else 0
        await ReadOnly()
        while not int(dut.s_axis_tready.value):
            await RisingEdge(dut.clk); await ReadOnly()
        await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0


async def await_decision(dut, max_cycles=400):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value):
            t = int(dut.m_axis_tdata.value)
            return {
                'sym':    int(dut.decision_sym.value),
                'action': (t >> 64) & 0x1,
                'price':  (t >> 32) & 0xFFFF_FFFF,
                'size':    t        & 0xFFFF_FFFF,
            }
    return None


@cocotb.test()
async def test_two_symbols_decide(dut):
    """Two symbols, each with a 2:1 bid imbalance -> a BUY tagged with its symbol."""
    cocotb.start_soon(Clock(dut.clk, CLK, unit='ns').start())
    await reset(dut)

    sym1 = SynthITCH(stock_locate=1)
    sym2 = SynthITCH(stock_locate=2)

    # symbol 1: ask then heavier bid -> BUY at 150.0100
    await drive_framed(dut, sym1.add(ref=1, side='S', shares=100, price=1_500_100))
    await drive_framed(dut, sym1.add(ref=2, side='B', shares=200, price=1_499_900))
    d1 = await await_decision(dut)
    assert d1 is not None, "no decision for symbol 1"
    assert d1['sym'] == 1,            f"expected sym 1, got {d1['sym']}"
    assert d1['action'] == 0,         f"expected BUY, got {d1['action']}"
    assert d1['price'] == 1_500_100,  f"sym1 price {d1['price']}"
    dut._log.info(f"PASS  symbol 1 -> BUY @ {d1['price']} size={d1['size']}")

    # symbol 2: different price band -> BUY at 250.0100
    await drive_framed(dut, sym2.add(ref=1, side='S', shares=100, price=2_500_100))
    await drive_framed(dut, sym2.add(ref=2, side='B', shares=200, price=2_499_900))
    d2 = await await_decision(dut)
    assert d2 is not None, "no decision for symbol 2"
    assert d2['sym'] == 2,            f"expected sym 2, got {d2['sym']}"
    assert d2['action'] == 0,         f"expected BUY, got {d2['action']}"
    assert d2['price'] == 2_500_100,  f"sym2 price {d2['price']}"
    dut._log.info(f"PASS  symbol 2 -> BUY @ {d2['price']} size={d2['size']}")


@cocotb.test()
async def test_symbol_books_isolated_end_to_end(dut):
    """A full book on symbol 1 must not create a decision on symbol 3."""
    cocotb.start_soon(Clock(dut.clk, CLK, unit='ns').start())
    await reset(dut)

    s1 = SynthITCH(stock_locate=1)
    # symbol 1 balanced book (no decision), then symbol 3 gets the imbalance
    await drive_framed(dut, s1.add(ref=1, side='S', shares=100, price=1_500_100))
    await drive_framed(dut, s1.add(ref=2, side='B', shares=100, price=1_499_900))  # balanced

    s3 = SynthITCH(stock_locate=3)
    await drive_framed(dut, s3.add(ref=1, side='S', shares=100, price=3_000_100))
    await drive_framed(dut, s3.add(ref=2, side='B', shares=300, price=2_999_900))  # 3:1 -> BUY

    d = await await_decision(dut)
    assert d is not None and d['sym'] == 3, f"decision should be symbol 3, got {d}"
    assert d['action'] == 0 and d['price'] == 3_000_100
    dut._log.info("PASS  decision correctly attributed to symbol 3")
