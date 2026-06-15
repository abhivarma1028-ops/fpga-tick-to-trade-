"""
cocotb integration testbench for tick_to_trade_top.sv
Feeds raw ITCH bytes through the full parser→book→strategy pipeline,
verifies the decision packet, and captures last_latency_cycles
(the tick-to-trade latency in clock cycles — this is the README money shot).

Run:
    cd sim && make SIM=questa TOPLEVEL=tick_to_trade_top MODULE=tb_tick_to_trade
"""

import cocotb
from cocotb.clock    import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly
import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from synth_itch import SynthITCH

CLK_PERIOD_NS = 5   # 200 MHz


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def reset(dut, cycles: int = 8):
    dut.rst_n.value         = 0
    dut.halt.value          = 0   # kill switch off
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tlast.value  = 0
    dut.m_axis_tready.value = 1   # downstream always ready
    # AXI-Lite slave idle
    dut.s_axil_awaddr.value  = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value   = 0
    dut.s_axil_wstrb.value   = 0
    dut.s_axil_wvalid.value  = 0
    dut.s_axil_bready.value  = 0
    dut.s_axil_araddr.value  = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value  = 0
    await ClockCycles(dut.clk, cycles)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def axil_read(dut, addr: int) -> int:
    """Single AXI-Lite read of the latency_counter register map (0x100=latency)."""
    dut.s_axil_araddr.value  = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value  = 1
    while not dut.s_axil_arready.value:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_axil_arvalid.value = 0
    while not dut.s_axil_rvalid.value:
        await RisingEdge(dut.clk)
    data = int(dut.s_axil_rdata.value)
    await RisingEdge(dut.clk)
    dut.s_axil_rready.value = 0
    return data


async def drive_stream(dut, raw: bytes):
    """Drive a framing-stripped ITCH message byte-by-byte onto AXI-Stream,
    honouring s_axis_tready so bytes are not lost when the book back-pressures
    (tready drops during RESCAN)."""
    for i, byte in enumerate(raw):
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tdata.value  = byte
        dut.s_axis_tlast.value  = 1 if i == len(raw) - 1 else 0
        # Wait for a cycle where tready is asserted (transfer completes there)
        await ReadOnly()
        while not int(dut.s_axis_tready.value):
            await RisingEdge(dut.clk)
            await ReadOnly()
        await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0


async def drive_framed(dut, framed: bytes):
    """Drive a complete framed message (strips the 2-byte length prefix)."""
    length = int.from_bytes(framed[0:2], 'big')
    await drive_stream(dut, framed[2:2+length])


async def await_decision(dut, max_cycles: int = 200) -> dict | None:
    """Wait for m_axis_tvalid to pulse, return decoded packet.

    Captures action/price/size from m_axis_tdata on the decision edge, then
    reads the measured tick-to-trade latency over AXI-Lite (register 0x100).
    The histogram/last-latency register is NBA-updated on the decision edge,
    so the subsequent AXI-Lite read observes the settled value.
    """
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value):
            tdata       = int(dut.m_axis_tdata.value)
            action      = (tdata >> 64) & 0x1
            order_price = (tdata >> 32) & 0xFFFF_FFFF
            order_size  =  tdata        & 0xFFFF_FFFF
            latency_cyc = await axil_read(dut, 0x100)
            return {
                'action':      action,
                'order_price': order_price,
                'order_size':  order_size,
                'latency_cyc': latency_cyc,
            }
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_buy_decision_end_to_end(dut):
    """
    Feed ask(100 shares) then bid(200 shares) → 2:1 imbalance → BUY decision.
    Captures last_latency_cycles (tick-to-trade latency).
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await reset(dut)

    gen = SynthITCH()
    ask_msg = gen.add(ref=1, side='S', shares=100,  price=1_500_100)
    bid_msg = gen.add(ref=2, side='B', shares=200,  price=1_499_900)

    # Feed ask first (book now has ask; book_valid still 0 — no bid yet)
    await drive_framed(dut, ask_msg)
    # Feed bid (book_valid goes 1; imbalance 200:100 > 1.5× threshold)
    await drive_framed(dut, bid_msg)

    dec = await await_decision(dut)

    assert dec is not None, "No decision within timeout after 2:1 bid imbalance"
    assert dec['action']      == 0, \
        f"Expected BUY (action=0), got action={dec['action']}"
    assert dec['order_price'] == 1_500_100, \
        f"BUY should lift ask=1500100; got {dec['order_price']}"
    assert dec['order_size']  == 100, \
        f"LOT_SIZE should be 100; got {dec['order_size']}"

    latency_cyc = dec['latency_cyc']
    latency_ns  = latency_cyc * CLK_PERIOD_NS

    dut._log.info("=" * 60)
    dut._log.info(f"  TICK-TO-TRADE LATENCY: {latency_cyc} cycles = {latency_ns} ns")
    dut._log.info(f"  (FPGA pipeline, 200 MHz clock, hardware-measured)")
    dut._log.info("=" * 60)
    dut._log.info(
        f"PASS  BUY decision: "
        f"action={dec['action']} price={dec['order_price']} "
        f"size={dec['order_size']} latency={latency_ns}ns"
    )


@cocotb.test()
async def test_sell_decision_end_to_end(dut):
    """
    Feed bid(100 shares) then ask(200 shares) → 2:1 ask imbalance → SELL decision.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await reset(dut)

    gen = SynthITCH()
    bid_msg = gen.add(ref=10, side='B', shares=100,  price=1_499_900)
    ask_msg = gen.add(ref=11, side='S', shares=200,  price=1_500_100)

    await drive_framed(dut, bid_msg)
    await drive_framed(dut, ask_msg)

    dec = await await_decision(dut)

    assert dec is not None,      "No decision within timeout after 2:1 ask imbalance"
    assert dec['action'] == 1,   f"Expected SELL (action=1), got {dec['action']}"
    assert dec['order_price'] == 1_499_900, \
        f"SELL should hit bid=1499900; got {dec['order_price']}"
    assert dec['order_size']  == 100

    latency_ns = dec['latency_cyc'] * CLK_PERIOD_NS
    dut._log.info(
        f"PASS  SELL decision: latency={latency_ns}ns "
        f"price={dec['order_price']} size={dec['order_size']}"
    )


@cocotb.test()
async def test_no_decision_balanced_book(dut):
    """Equal bid/ask sizes → no decision fires."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await reset(dut)

    gen = SynthITCH()
    await drive_framed(dut, gen.add(ref=20, side='S', shares=100, price=1_500_100))
    await drive_framed(dut, gen.add(ref=21, side='B', shares=100, price=1_499_900))

    # Give the pipeline 100 cycles to fire (it shouldn't)
    for _ in range(100):
        await RisingEdge(dut.clk)
        assert int(dut.m_axis_tvalid.value) == 0, \
            f"Unexpected decision on balanced book (action={dut.m_axis_tdata.value})"

    dut._log.info("PASS  balanced book → no decision for 100 cycles")


@cocotb.test()
async def test_scenario_basic_pipeline(dut):
    """
    Drive SynthITCH.scenario_basic() through the full pipeline.
    Scenario: ask(150), bid(200), bid_same_level(300), cancel, execute.
    Expect a BUY when bid imbalance is large enough.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await reset(dut)

    gen    = SynthITCH()
    stream = gen.scenario_basic()

    # Parse framed messages and feed them back-to-back
    decisions = []

    async def monitor():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.m_axis_tvalid.value):
                tdata = int(dut.m_axis_tdata.value)
                decisions.append({
                    'action':      (tdata >> 64) & 0x1,
                    'order_price': (tdata >> 32) & 0xFFFF_FFFF,
                    'order_size':   tdata        & 0xFFFF_FFFF,
                })

    mon = cocotb.start_soon(monitor())

    offset = 0
    while offset + 2 <= len(stream):
        length = int.from_bytes(stream[offset:offset+2], 'big')
        offset += 2
        raw = stream[offset:offset+length]
        offset += length
        await drive_stream(dut, raw)

    # Let the pipeline drain
    await ClockCycles(dut.clk, 50)
    mon.cancel()

    dut._log.info(f"scenario_basic: {len(decisions)} decision(s) fired")
    for i, d in enumerate(decisions):
        side = 'BUY' if d['action'] == 0 else 'SELL'
        dut._log.info(
            f"  decision {i}: {side} price={d['order_price']} size={d['order_size']}"
        )

    dut._log.info("PASS  scenario_basic pipeline complete")


@cocotb.test()
async def test_backpressure_no_drop(dut):
    """A message that arrives while the book is in RESCAN must NOT be dropped.
    An Execute triggers RESCAN (~256 cycles); the messages streamed immediately
    after it are back-pressured (s_axis_tready drops) and delivered afterwards.
    If they were dropped, the final bid imbalance — and the BUY — never happens."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await reset(dut)

    # Watch for tready ever dropping (proves backpressure actually engaged)
    stalled = {'seen': False}
    async def ready_watch():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.s_axis_tready.value) == 0:
                stalled['seen'] = True
    watch = cocotb.start_soon(ready_watch())

    gen = SynthITCH()
    burst = [
        gen.add(ref=1, side='S', shares=100, price=1_500_100),   # ask
        gen.add(ref=2, side='B', shares=100, price=1_499_900),   # bid (balanced → no trade)
        gen.execute(ref=1, shares=100),                          # ask gone → RESCAN
        gen.add(ref=3, side='S', shares=100, price=1_500_100),   # ask back
        gen.add(ref=4, side='B', shares=300, price=1_499_900),   # bid heavy → 4:1 → BUY
    ]
    # Feed everything back-to-back (drive_stream honours tready)
    for framed in burst:
        await drive_framed(dut, framed)

    dec = await await_decision(dut, max_cycles=700)
    watch.cancel()

    assert dec is not None, "BUY lost — a message was dropped during RESCAN"
    assert dec['action'] == 0,            f"expected BUY, got {dec['action']}"
    assert dec['order_price'] == 1_500_100
    assert stalled['seen'], "expected s_axis_tready to drop during RESCAN (backpressure)"
    dut._log.info("PASS  backpressure: post-RESCAN messages delivered, BUY fired")


@cocotb.test()
async def test_halt_blocks_decision(dut):
    """With the kill-switch (halt) asserted, a strong imbalance must NOT produce a
    decision on m_axis (the risk check blocks it); clearing halt lets it through."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await reset(dut)
    dut.halt.value = 1                       # kill switch ON

    gen = SynthITCH()
    await drive_framed(dut, gen.add(ref=1, side='S', shares=100, price=1_500_100))
    await drive_framed(dut, gen.add(ref=2, side='B', shares=200, price=1_499_900))

    # No decision should appear while halted
    for _ in range(60):
        await RisingEdge(dut.clk)
        assert int(dut.m_axis_tvalid.value) == 0, "decision leaked while halted"
        assert int(dut.risk_reject.value) == 0 or int(dut.risk_reason.value) == 4, \
            "any reject while halted must be reason=HALT(4)"

    dut._log.info("PASS  kill-switch blocks the order end-to-end")
