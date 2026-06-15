"""
Testbench for multi_symbol_book.sv -- N independent per-symbol order books
routed by stock_locate. Verifies symbol isolation, active-symbol muxing, and
the global rescan stall.

Run: cd sim && make TOPLEVEL=multi_symbol_book MODULE=tb_multi_symbol_book
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

ADD, CANCEL, DELETE, EXECUTE = 0x41, 0x58, 0x44, 0x45
BID, ASK = 0, 1
ORDER_DEPTH   = 256
RESCAN_CYCLES = ORDER_DEPTH + 8


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 5, units='ns').start())
    dut.rst_n.value         = 0
    dut.msg_valid.value     = 0
    dut.msg_type.value      = 0
    dut.stock_locate.value  = 0
    dut.order_ref.value     = 0
    dut.new_order_ref.value = 0
    dut.side.value          = 0
    dut.shares.value        = 0
    dut.price.value         = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive(dut, t, sym, ref, side, shares, price, new_ref=0):
    dut.msg_valid.value     = 1
    dut.msg_type.value      = t
    dut.stock_locate.value  = sym
    dut.order_ref.value     = ref
    dut.new_order_ref.value = new_ref
    dut.side.value          = side
    dut.shares.value        = shares
    dut.price.value         = price
    await RisingEdge(dut.clk)
    dut.msg_valid.value = 0
    await RisingEdge(dut.clk)


async def wait_rescan(dut):
    for _ in range(RESCAN_CYCLES):
        await RisingEdge(dut.clk)


def sym_bid(dut, s):
    return (int(dut.best_bid_price_all.value) >> (s * 32)) & 0xFFFF_FFFF

def sym_ask(dut, s):
    return (int(dut.best_ask_price_all.value) >> (s * 32)) & 0xFFFF_FFFF


@cocotb.test()
async def test_two_symbols_independent(dut):
    """Two symbols get different books; each best bid/ask is tracked separately."""
    await setup(dut)
    # symbol 0
    await drive(dut, ADD, 0, ref=1, side=BID, shares=50, price=1000_0000)
    await drive(dut, ADD, 0, ref=2, side=ASK, shares=20, price=1100_0000)
    # symbol 1 (different prices)
    await drive(dut, ADD, 1, ref=3, side=BID, shares=30, price=2000_0000)
    await drive(dut, ADD, 1, ref=4, side=ASK, shares=15, price=2100_0000)

    assert sym_bid(dut, 0) == 1000_0000, f"sym0 bid {sym_bid(dut,0)}"
    assert sym_ask(dut, 0) == 1100_0000, f"sym0 ask {sym_ask(dut,0)}"
    assert sym_bid(dut, 1) == 2000_0000, f"sym1 bid {sym_bid(dut,1)}"
    assert sym_ask(dut, 1) == 2100_0000, f"sym1 ask {sym_ask(dut,1)}"
    dut._log.info("PASS  two symbols tracked independently")


@cocotb.test()
async def test_active_sym_and_mux(dut):
    """active_sym follows the last message; muxed best_bid is that symbol's."""
    await setup(dut)
    await drive(dut, ADD, 0, ref=1, side=BID, shares=50, price=1000_0000)
    await drive(dut, ADD, 0, ref=2, side=ASK, shares=20, price=1100_0000)
    assert int(dut.active_sym.value) == 0
    assert int(dut.best_bid_price.value) == 1000_0000
    assert int(dut.book_valid.value) == 1, "sym0 has both sides"

    await drive(dut, ADD, 1, ref=3, side=BID, shares=30, price=2000_0000)
    assert int(dut.active_sym.value) == 1
    assert int(dut.best_bid_price.value) == 2000_0000
    dut._log.info("PASS  active_sym + output mux follow the message symbol")


@cocotb.test()
async def test_symbol_isolation(dut):
    """A message to symbol 0 must not change symbol 1's book."""
    await setup(dut)
    await drive(dut, ADD, 0, ref=1, side=BID, shares=50, price=1000_0000)
    await drive(dut, ADD, 1, ref=3, side=BID, shares=30, price=2000_0000)
    assert sym_bid(dut, 1) == 2000_0000

    # better bid on symbol 0 — symbol 1 must be untouched
    await drive(dut, ADD, 0, ref=5, side=BID, shares=60, price=1050_0000)
    assert sym_bid(dut, 0) == 1050_0000, "sym0 best bid updated"
    assert sym_bid(dut, 1) == 2000_0000, "sym1 must be unchanged"
    dut._log.info("PASS  cross-symbol isolation")


@cocotb.test()
async def test_rescan_global_stall(dut):
    """A rescan on one symbol stalls the engine (msg_ready low) but leaves the
    other symbol's book intact; ready returns after the rescan."""
    await setup(dut)
    await drive(dut, ADD, 0, ref=1, side=BID, shares=50, price=1000_0000)
    await drive(dut, ADD, 0, ref=2, side=BID, shares=30, price=900_0000)
    await drive(dut, ADD, 1, ref=3, side=BID, shares=40, price=2000_0000)
    assert int(dut.msg_ready.value) == 1, "idle -> ready"

    # delete sym0's best bid -> rescan in book0
    await drive(dut, DELETE, 0, ref=1, side=BID, shares=0, price=0)
    assert int(dut.msg_ready.value) == 0, "engine stalls during a rescan"
    await wait_rescan(dut)
    assert int(dut.msg_ready.value) == 1, "ready again after rescan"
    assert sym_bid(dut, 0) == 900_0000, "sym0 promoted to next bid"
    assert sym_bid(dut, 1) == 2000_0000, "sym1 untouched by sym0 rescan"
    dut._log.info("PASS  rescan global-stall, other symbol intact")
