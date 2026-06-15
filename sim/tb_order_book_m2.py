"""
Testbench for order_book_m2.sv — Milestone 2 multi-level order book.

Key difference from tb_order_book.py:
  M1 only tracked top-of-book during ADD; cancel/delete/execute left best_bid/ask
  stale.  M2 triggers a RESCAN FSM (ORDER_DEPTH+1 cycles) after each C/D/E.

Timing budget after drive_msg() returns:
  drive_msg does TWO await RisingEdge calls.  When it returns at edge T+1:
  - NBAs from edge T have committed → entries updated, state==RESCAN, scan_idx==0
  - Edge T+1 has already executed one RESCAN cycle (entries[0] processed)
  - Still to go: ORDER_DEPTH-1 scan cycles + 1 commit cycle + 1 NBA-settle cycle
  Total: await RisingEdge × (ORDER_DEPTH + 1) more after drive_msg returns.
  We use ORDER_DEPTH + 3 for safety margin.
"""

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.clock import Clock

ADD        = 0x41  # 'A'
CANCEL     = 0x58  # 'X'
DELETE     = 0x44  # 'D'
EXECUTE    = 0x45  # 'E'
EXEC_PRICE = 0x43  # 'C'  (Order Executed with Price)
REPLACE    = 0x55  # 'U'  (Order Replace)
TRADE      = 0x50  # 'P'  (Trade print — informational, no book change)

BID = 0  # buy side
ASK = 1  # sell side

ORDER_DEPTH   = 256
NLEVELS       = 4                 # mirrors RTL parameter default
RESCAN_CYCLES = ORDER_DEPTH + 8   # safe margin for FSM + NBA settle


def level(dut, bus: str, i: int) -> int:
    """Extract 32-bit level i from a flattened {level..0} output bus."""
    raw = int(getattr(dut, bus).value)
    return (raw >> (i * 32)) & 0xFFFF_FFFF


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 5, units='ns').start())
    dut.rst_n.value         = 0
    dut.msg_valid.value     = 0
    dut.msg_type.value      = 0
    dut.order_ref.value     = 0
    dut.new_order_ref.value = 0
    dut.side.value          = 0
    dut.shares.value        = 0
    dut.price.value         = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_msg(dut, msg_type, order_ref, side, shares, price,
                    new_order_ref=0):
    """Drive one message; extra RisingEdge lets NBAs from always_ff settle.
    new_order_ref is only used by Replace (U)."""
    dut.msg_valid.value     = 1
    dut.msg_type.value      = msg_type
    dut.order_ref.value     = order_ref
    dut.new_order_ref.value = new_order_ref
    dut.side.value          = side
    dut.shares.value        = shares
    dut.price.value         = price
    await RisingEdge(dut.clk)   # always_ff fires; NBAs scheduled
    dut.msg_valid.value = 0
    await RisingEdge(dut.clk)   # NBAs committed; state/entries visible


async def wait_rescan(dut):
    """After drive_msg for C/D/E, wait for RESCAN FSM + NBA settle."""
    for _ in range(RESCAN_CYCLES):
        await RisingEdge(dut.clk)


def check(dut, *, bid_p=None, bid_s=None, ask_p=None, ask_s=None,
          valid=None, tag=""):
    if bid_p  is not None:
        got = int(dut.best_bid_price.value)
        assert got == bid_p,  f"{tag}: best_bid_price  exp={bid_p}  got={got}"
    if bid_s  is not None:
        got = int(dut.best_bid_size.value)
        assert got == bid_s,  f"{tag}: best_bid_size   exp={bid_s}  got={got}"
    if ask_p  is not None:
        got = int(dut.best_ask_price.value)
        assert got == ask_p,  f"{tag}: best_ask_price  exp={ask_p}  got={got}"
    if ask_s  is not None:
        got = int(dut.best_ask_size.value)
        assert got == ask_s,  f"{tag}: best_ask_size   exp={ask_s}  got={got}"
    if valid  is not None:
        got = int(dut.book_valid.value)
        assert got == valid,  f"{tag}: book_valid      exp={valid}  got={got}"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut):
    """After reset: book_valid=0, no best bid/ask."""
    await setup(dut)
    check(dut, valid=0, tag="reset")


@cocotb.test()
async def test_add_bid_basic(dut):
    """ADD a single bid → best_bid_price/size correct, book_valid still 0 (no ask)."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=100, price=1500_0000)
    check(dut, bid_p=1500_0000, bid_s=100, valid=0, tag="single bid")


@cocotb.test()
async def test_add_ask_basic(dut):
    """ADD a single ask → best_ask_price/size correct."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=50, price=1510_0000)
    check(dut, ask_p=1510_0000, ask_s=50, valid=0, tag="single ask")


@cocotb.test()
async def test_book_valid_requires_both_sides(dut):
    """book_valid only becomes 1 after both a bid and an ask are present."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=100, price=1500_0000)
    check(dut, valid=0, tag="after bid only")
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=50,  price=1510_0000)
    check(dut, valid=1, tag="after bid+ask")


@cocotb.test()
async def test_add_bid_higher_price_wins(dut):
    """Two bids at different prices: the higher one becomes best_bid."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50,  price=900_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=80,  price=1000_0000)
    check(dut, bid_p=1000_0000, bid_s=80, tag="higher bid wins")


@cocotb.test()
async def test_add_bid_same_price_aggregates(dut):
    """Two bids at the same price: sizes aggregate."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50,  price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=30,  price=1000_0000)
    check(dut, bid_p=1000_0000, bid_s=80, tag="same price size agg")


@cocotb.test()
async def test_add_ask_lower_price_wins(dut):
    """Two asks at different prices: the lower one becomes best_ask."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=10, side=ASK, shares=40, price=1100_0000)
    await drive_msg(dut, ADD, order_ref=11, side=ASK, shares=20, price=1050_0000)
    check(dut, ask_p=1050_0000, ask_s=20, tag="lower ask wins")


@cocotb.test()
async def test_delete_best_bid_reveals_second(dut):
    """M2 KEY TEST: delete best bid → RESCAN sets best to the next-best level.
    M1 would have left best_bid stale (still pointing at the deleted price).
    order_ref=1 → slot 1,  order_ref=2 → slot 2  (no hash collision).
    """
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=30, price=900_0000)
    check(dut, bid_p=1000_0000, bid_s=50, tag="before delete")

    await drive_msg(dut, DELETE, order_ref=1, side=BID, shares=0, price=0)
    await wait_rescan(dut)
    check(dut, bid_p=900_0000, bid_s=30, tag="after delete best bid")


@cocotb.test()
async def test_delete_non_best_bid_unchanged(dut):
    """Delete the non-best bid → RESCAN, best stays at original higher price."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=30, price=900_0000)
    check(dut, bid_p=1000_0000, bid_s=50, tag="before delete lower")

    await drive_msg(dut, DELETE, order_ref=2, side=BID, shares=0, price=0)
    await wait_rescan(dut)
    check(dut, bid_p=1000_0000, bid_s=50, tag="after delete lower bid")


@cocotb.test()
async def test_cancel_partial_reduces_size(dut):
    """Cancel partial shares → after RESCAN, best_bid_size reflects remainder."""
    await setup(dut)
    await drive_msg(dut, ADD,    order_ref=1, side=BID, shares=80, price=1000_0000)
    await drive_msg(dut, CANCEL, order_ref=1, side=BID, shares=50, price=0)
    await wait_rescan(dut)
    check(dut, bid_p=1000_0000, bid_s=30, tag="cancel partial")


@cocotb.test()
async def test_cancel_full_empties_book(dut):
    """Cancel all shares (>= entry shares) → entry invalid, book_valid drops to 0."""
    await setup(dut)
    await drive_msg(dut, ADD,    order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD,    order_ref=2, side=ASK, shares=20, price=1100_0000)
    check(dut, valid=1, tag="both sides present")

    await drive_msg(dut, CANCEL, order_ref=1, side=BID, shares=50, price=0)
    await wait_rescan(dut)
    check(dut, bid_s=0, valid=0, tag="after cancel all bid shares")


@cocotb.test()
async def test_execute_reduces_size(dut):
    """Execute reduces shares; after RESCAN best_bid_size is correct."""
    await setup(dut)
    await drive_msg(dut, ADD,     order_ref=1, side=BID, shares=80, price=1000_0000)
    await drive_msg(dut, EXECUTE, order_ref=1, side=BID, shares=30, price=0)
    await wait_rescan(dut)
    check(dut, bid_p=1000_0000, bid_s=50, tag="execute partial")


@cocotb.test()
async def test_execute_full_removes_entry(dut):
    """Execute entire size → entry invalid, RESCAN returns empty book."""
    await setup(dut)
    await drive_msg(dut, ADD,     order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, EXECUTE, order_ref=1, side=BID, shares=50, price=0)
    await wait_rescan(dut)
    check(dut, bid_s=0, valid=0, tag="execute full")


@cocotb.test()
async def test_two_asks_delete_best_reveals_higher(dut):
    """Best ask is deleted → RESCAN promotes the next-best (higher) ask price.
    order_ref=10 → slot 10, order_ref=11 → slot 11 (no collision).
    """
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=10, side=ASK, shares=40, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=11, side=ASK, shares=25, price=1100_0000)
    check(dut, ask_p=1000_0000, ask_s=40, tag="before delete best ask")

    await drive_msg(dut, DELETE, order_ref=10, side=ASK, shares=0, price=0)
    await wait_rescan(dut)
    check(dut, ask_p=1100_0000, ask_s=25, tag="after delete best ask")


@cocotb.test()
async def test_aggregate_then_partial_cancel(dut):
    """Two bids at same price aggregated to 80; cancel 20 from one → size 60.
    order_ref=1 → slot 1, order_ref=2 → slot 2 (no collision).
    """
    await setup(dut)
    await drive_msg(dut, ADD,    order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD,    order_ref=2, side=BID, shares=30, price=1000_0000)
    check(dut, bid_p=1000_0000, bid_s=80, tag="after two adds")

    await drive_msg(dut, CANCEL, order_ref=2, side=BID, shares=20, price=0)
    await wait_rescan(dut)
    check(dut, bid_p=1000_0000, bid_s=60, tag="after partial cancel from aggregated")


# ---------------------------------------------------------------------------
# M2 message-type tests — Execute-with-Price (C) and Replace (U)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exec_with_price_reduces_size(dut):
    """Execute-with-Price (C) reduces resting shares; the resting order's own
    price is unchanged (the C execution price is not the book price)."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=80, price=1000_0000)
    # exec 30 @ a different execution price (990); book keeps resting price 1000
    await drive_msg(dut, EXEC_PRICE, order_ref=1, side=BID, shares=30, price=990_0000)
    await wait_rescan(dut)
    check(dut, bid_p=1000_0000, bid_s=50, tag="exec-with-price partial")


@cocotb.test()
async def test_exec_with_price_full_removes(dut):
    """Execute-with-Price for the full size removes the order from the book."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=20, price=1100_0000)
    check(dut, valid=1, tag="both sides")
    await drive_msg(dut, EXEC_PRICE, order_ref=1, side=BID, shares=50, price=990_0000)
    await wait_rescan(dut)
    check(dut, bid_s=0, valid=0, tag="exec-with-price full empties bid")


@cocotb.test()
async def test_replace_moves_bid_price(dut):
    """Replace (U): original bid retired, new bid installed at new ref/price/size,
    reusing the original side. Best bid reflects the replacement."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=20, price=1100_0000)
    check(dut, bid_p=1000_0000, bid_s=50, valid=1, tag="before replace")

    # Replace order 1 → new order 3 at a higher bid price, larger size
    await drive_msg(dut, REPLACE, order_ref=1, side=BID, shares=70,
                    price=1050_0000, new_order_ref=3)
    await wait_rescan(dut)
    check(dut, bid_p=1050_0000, bid_s=70, tag="after replace bid")


@cocotb.test()
async def test_replace_keeps_ask_side(dut):
    """Replace reuses the original order's side: replacing an ask yields an ask."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=10, side=ASK, shares=40, price=1100_0000)
    await drive_msg(dut, ADD, order_ref=1,  side=BID, shares=50, price=1000_0000)
    check(dut, ask_p=1100_0000, ask_s=40, valid=1, tag="before replace ask")

    # side arg is deliberately wrong (BID) — the book must reuse the stored ASK
    await drive_msg(dut, REPLACE, order_ref=10, side=BID, shares=25,
                    price=1090_0000, new_order_ref=11)
    await wait_rescan(dut)
    check(dut, ask_p=1090_0000, ask_s=25, tag="after replace ask (side reused)")


@cocotb.test()
async def test_replace_same_slot(dut):
    """Edge case: new ref hashes to the SAME slot as the original
    (257 & 0xFF == 1). The replacement write must fully overwrite the slot."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=20, price=1100_0000)
    check(dut, bid_p=1000_0000, bid_s=50, valid=1, tag="before same-slot replace")

    await drive_msg(dut, REPLACE, order_ref=1, side=BID, shares=80,
                    price=1005_0000, new_order_ref=257)  # 257 & 0xFF == 1
    await wait_rescan(dut)
    check(dut, bid_p=1005_0000, bid_s=80, tag="after same-slot replace")


# ---------------------------------------------------------------------------
# Multi-level depth tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_two_bid_levels(dut):
    """Two distinct bid prices → levels 0 and 1, sorted highest-first (O(1) ADD)."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=30, price=900_0000)

    assert level(dut, 'bid_level_price', 0) == 1000_0000
    assert level(dut, 'bid_level_size',  0) == 50
    assert level(dut, 'bid_level_price', 1) == 900_0000
    assert level(dut, 'bid_level_size',  1) == 30
    dut._log.info("PASS  two bid levels sorted highest-first")


@cocotb.test()
async def test_bid_levels_insert_sorted(dut):
    """Out-of-order adds (900, 1000, 950) settle into sorted levels."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=10, price=900_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=20, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=3, side=BID, shares=30, price=950_0000)

    assert level(dut, 'bid_level_price', 0) == 1000_0000
    assert level(dut, 'bid_level_price', 1) == 950_0000
    assert level(dut, 'bid_level_price', 2) == 900_0000
    dut._log.info("PASS  bid levels insertion-sorted")


@cocotb.test()
async def test_ask_levels_ascending(dut):
    """Ask levels are sorted lowest-first."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=10, side=ASK, shares=40, price=1100_0000)
    await drive_msg(dut, ADD, order_ref=11, side=ASK, shares=20, price=1050_0000)
    await drive_msg(dut, ADD, order_ref=12, side=ASK, shares=10, price=1080_0000)

    assert level(dut, 'ask_level_price', 0) == 1050_0000
    assert level(dut, 'ask_level_price', 1) == 1080_0000
    assert level(dut, 'ask_level_price', 2) == 1100_0000
    dut._log.info("PASS  ask levels ascending")


@cocotb.test()
async def test_level_size_aggregation(dut):
    """Two orders at the same price collapse into one level with summed size."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=BID, shares=30, price=1000_0000)

    assert level(dut, 'bid_level_price', 0) == 1000_0000
    assert level(dut, 'bid_level_size',  0) == 80, "same-price orders must aggregate"
    assert level(dut, 'bid_level_size',  1) == 0,  "only one distinct level expected"
    dut._log.info("PASS  same-price aggregation into one level")


@cocotb.test()
async def test_depth_cap_and_rescan_recovery(dut):
    """Adding more than NLEVELS bid prices keeps only the top NLEVELS in the
    cache; deleting the best then rescans and PROMOTES the previously-dropped
    level back into view (entries[] is the full-depth source of truth)."""
    await setup(dut)
    prices = [1000_0000, 990_0000, 980_0000, 970_0000, 960_0000]  # 5 > NLEVELS=4
    for i, p in enumerate(prices, start=1):
        await drive_msg(dut, ADD, order_ref=i, side=BID, shares=10*i, price=p)

    # Only the top 4 are cached; the worst (960) is dropped from the cache
    cached = [level(dut, 'bid_level_price', i) for i in range(NLEVELS)]
    assert cached == [1000_0000, 990_0000, 980_0000, 970_0000], f"got {cached}"

    # Delete the best (ref=1 @ 1000): rescan rebuilds and 960 reappears at level 3
    await drive_msg(dut, DELETE, order_ref=1, side=BID, shares=0, price=0)
    await wait_rescan(dut)
    after = [level(dut, 'bid_level_price', i) for i in range(NLEVELS)]
    assert after == [990_0000, 980_0000, 970_0000, 960_0000], f"got {after}"
    dut._log.info("PASS  depth cap + rescan recovers dropped level")


@cocotb.test()
async def test_msg_ready_backpressure(dut):
    """msg_ready is high when idle and drops during RESCAN (so the parser holds
    off instead of having a message dropped)."""
    await setup(dut)
    assert int(dut.msg_ready.value) == 1, "ready when idle after reset"

    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=20, price=1100_0000)
    assert int(dut.msg_ready.value) == 1, "ready after ADDs (no rescan)"

    # Delete triggers RESCAN → not ready
    await drive_msg(dut, DELETE, order_ref=1, side=BID, shares=0, price=0)
    assert int(dut.msg_ready.value) == 0, "msg_ready must drop during RESCAN"

    await wait_rescan(dut)
    assert int(dut.msg_ready.value) == 1, "msg_ready restored after RESCAN"
    dut._log.info("PASS  msg_ready backpressure during RESCAN")


@cocotb.test()
async def test_rescan_skipped_below_depth(dut):
    """Optimized RESCAN: a Delete on an order priced BELOW the tracked depth must
    NOT trigger a rescan (book stays IDLE, displayed levels unchanged) — but the
    entry IS still removed, so a later displayed delete rebuilds without it."""
    await setup(dut)
    prices = [1000_0000, 990_0000, 980_0000, 970_0000, 960_0000]  # 5 > NLEVELS
    for i, p in enumerate(prices, start=1):
        await drive_msg(dut, ADD, order_ref=i, side=BID, shares=10*i, price=p)

    before = [level(dut, 'bid_level_price', i) for i in range(NLEVELS)]
    assert before == [1000_0000, 990_0000, 980_0000, 970_0000], f"got {before}"

    # Delete the below-depth order (960): must SKIP rescan. With the BRAM book a
    # C/D/E takes a 1-cycle LOOKUP; a *skipped* rescan returns to IDLE within a
    # couple of cycles, whereas a real rescan would hold msg_ready low for ~256.
    await drive_msg(dut, DELETE, order_ref=5, side=BID, shares=0, price=0)
    for _ in range(5):
        await RisingEdge(dut.clk)
    assert int(dut.msg_ready.value) == 1, "below-depth delete must skip RESCAN (idle quickly)"
    after = [level(dut, 'bid_level_price', i) for i in range(NLEVELS)]
    assert after == before, "below-depth delete must not change displayed levels"

    # Delete a displayed order (1000): triggers rescan; 960 must NOT reappear
    # (it was genuinely removed above even though we skipped its rescan)
    await drive_msg(dut, DELETE, order_ref=1, side=BID, shares=0, price=0)
    assert int(dut.msg_ready.value) == 0, "displayed delete must trigger RESCAN"
    await wait_rescan(dut)
    promoted = [level(dut, 'bid_level_price', i) for i in range(NLEVELS)]
    assert promoted[:3] == [990_0000, 980_0000, 970_0000], f"got {promoted}"
    assert promoted[3] == 0, "960 was deleted earlier; must not reappear"
    dut._log.info("PASS  below-depth delete skips RESCAN but still updates entry")


@cocotb.test()
async def test_trade_print_is_noop(dut):
    """A Trade print (P) is informational — it must not change the book or rescan."""
    await setup(dut)
    await drive_msg(dut, ADD, order_ref=1, side=BID, shares=50, price=1000_0000)
    await drive_msg(dut, ADD, order_ref=2, side=ASK, shares=20, price=1100_0000)
    check(dut, bid_p=1000_0000, bid_s=50, ask_p=1100_0000, ask_s=20, valid=1, tag="pre-trade")

    # Trade print at a different price/size — book must be untouched, no RESCAN
    await drive_msg(dut, TRADE, order_ref=99, side=BID, shares=999, price=1050_0000)
    assert int(dut.msg_ready.value) == 1, "Trade print must not trigger RESCAN"
    check(dut, bid_p=1000_0000, bid_s=50, ask_p=1100_0000, ask_s=20, valid=1,
          tag="post-trade unchanged")
    dut._log.info("PASS  Trade print is a book no-op")
