// =============================================================================
// pipeline_sva.sv  --  SystemVerilog Assertions for the tick-to-trade pipeline
//
// Attached to the DUTs via `bind`, so the RTL stays clean and synthesis never
// sees this file (it is added to the cocotb VERILOG_SOURCES for Questa only).
// Each concurrent assertion is a regression tripwire: it holds for the current
// design and will fire (Questa error) if a future change breaks the contract.
// `cover` properties record that the interesting scenarios were exercised.
// =============================================================================

// -----------------------------------------------------------------------------
// itch_parser : valid/ready back-pressure contract
// -----------------------------------------------------------------------------
module itch_parser_sva (
    input logic clk,
    input logic rst_n,
    input logic s_axis_tready,
    input logic m_valid,
    input logic m_ready
);
    // A produced message is HELD until accepted (m_valid cannot drop while !m_ready)
    a_hold_until_ready: assert property (@(posedge clk) disable iff (!rst_n)
        (m_valid && !m_ready) |=> m_valid)
        else $error("[SVA itch_parser] m_valid dropped before m_ready");

    // The byte stream stalls ONLY while holding an unaccepted output
    a_stall_only_when_holding: assert property (@(posedge clk) disable iff (!rst_n)
        (!s_axis_tready) |-> (m_valid && !m_ready))
        else $error("[SVA itch_parser] tready low without a held output");

    // Coverage: back-pressure actually engaged at least once
    c_backpressure: cover property (@(posedge clk) disable iff (!rst_n)
        (m_valid && !m_ready));
endmodule

bind itch_parser itch_parser_sva u_itch_parser_sva (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axis_tready (s_axis_tready),
    .m_valid       (m_valid),
    .m_ready       (m_ready)
);

// -----------------------------------------------------------------------------
// order_book_m2 : FSM / book-validity / level-ordering invariants
// -----------------------------------------------------------------------------
module order_book_m2_sva (
    input logic        clk,
    input logic        rst_n,
    input logic [1:0]  state,        // 0 = IDLE, 1 = LOOKUP, 2 = RESCAN
    input logic        msg_ready,
    input logic        book_valid,
    input logic [31:0] bid_p0,
    input logic [31:0] bid_p1,
    input logic [31:0] ask_p0,
    input logic [31:0] ask_p1,
    input logic        bid_two,      // bid has >= 2 levels
    input logic        ask_two,      // ask has >= 2 levels
    input logic        bid_some,     // bid has >= 1 level
    input logic        ask_some      // ask has >= 1 level
);
    // msg_ready is exactly "in IDLE" (0); low during LOOKUP (1) and RESCAN (2)
    a_ready_iff_idle: assert property (@(posedge clk) disable iff (!rst_n)
        msg_ready == (state == 2'd0))
        else $error("[SVA order_book] msg_ready != (state==IDLE)");

    a_no_accept_in_rescan: assert property (@(posedge clk) disable iff (!rst_n)
        (state == 2'd2) |-> !msg_ready)
        else $error("[SVA order_book] msg_ready high during RESCAN");

    // book_valid requires a live order on both sides
    a_book_valid_both_sides: assert property (@(posedge clk) disable iff (!rst_n)
        book_valid |-> (bid_some && ask_some))
        else $error("[SVA order_book] book_valid without both sides");

    // Levels are sorted best-first: bids descending, asks ascending
    a_bid_sorted: assert property (@(posedge clk) disable iff (!rst_n)
        bid_two |-> (bid_p0 >= bid_p1))
        else $error("[SVA order_book] bid levels not descending");

    a_ask_sorted: assert property (@(posedge clk) disable iff (!rst_n)
        ask_two |-> (ask_p0 <= ask_p1))
        else $error("[SVA order_book] ask levels not ascending");

    // Coverage: a rescan was entered, and a multi-level book was reached
    c_rescan_entered: cover property (@(posedge clk) disable iff (!rst_n)
        (state == 2'd2));
    c_two_bid_levels: cover property (@(posedge clk) disable iff (!rst_n) bid_two);
endmodule

bind order_book_m2 order_book_m2_sva u_order_book_m2_sva (
    .clk        (clk),
    .rst_n      (rst_n),
    .state      (state),
    .msg_ready  (msg_ready),
    .book_valid (book_valid),
    .bid_p0     (bid_lv.price[0]),
    .bid_p1     (bid_lv.price[1]),
    .ask_p0     (ask_lv.price[0]),
    .ask_p1     (ask_lv.price[1]),
    .bid_two    (bid_lv.cnt > 1),
    .ask_two    (ask_lv.cnt > 1),
    .bid_some   (bid_lv.cnt != 0),
    .ask_some   (ask_lv.cnt != 0)
);

// -----------------------------------------------------------------------------
// strategy_imbalance : cooldown + lot-size bounds
// -----------------------------------------------------------------------------
module strategy_imbalance_sva #(
    parameter int BASE_LOT = 100,
    parameter int MAX_LOT  = 250
)(
    input logic        clk,
    input logic        rst_n,
    input logic        decision_valid,
    input logic [31:0] order_size,
    input logic        book_valid
);
    // Cooldown: a decision is never immediately followed by another decision
    a_cooldown: assert property (@(posedge clk) disable iff (!rst_n)
        decision_valid |=> !decision_valid)
        else $error("[SVA strategy] back-to-back decisions (cooldown violated)");

    // Lot size is always within [BASE_LOT, MAX_LOT] when a decision fires
    a_lot_bounds: assert property (@(posedge clk) disable iff (!rst_n)
        decision_valid |-> (order_size >= BASE_LOT && order_size <= MAX_LOT))
        else $error("[SVA strategy] order_size out of [BASE_LOT, MAX_LOT]");

    // A decision only after the book was valid the previous cycle
    a_needs_book: assert property (@(posedge clk) disable iff (!rst_n)
        decision_valid |-> $past(book_valid))
        else $error("[SVA strategy] decision without prior book_valid");

    // Coverage: a max-size (capped) order, and both sides traded
    c_max_lot: cover property (@(posedge clk) disable iff (!rst_n)
        (decision_valid && order_size == MAX_LOT));
endmodule

bind strategy_imbalance strategy_imbalance_sva u_strategy_imbalance_sva (
    .clk            (clk),
    .rst_n          (rst_n),
    .decision_valid (decision_valid),
    .order_size     (order_size),
    .book_valid     (book_valid)
);

// -----------------------------------------------------------------------------
// latency_counter : AXI-Lite read/response channel stability
// -----------------------------------------------------------------------------
module latency_counter_sva (
    input logic       clk,
    input logic       rst_n,
    input logic       s_axil_rvalid,
    input logic       s_axil_rready,
    input logic [1:0] s_axil_rresp,
    input logic       s_axil_bvalid,
    input logic       s_axil_bready,
    input logic [1:0] s_axil_bresp
);
    // rvalid, once asserted, holds until rready (no withdrawal mid-handshake)
    a_rvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (s_axil_rvalid && !s_axil_rready) |=> s_axil_rvalid)
        else $error("[SVA latency] rvalid dropped before rready");

    a_bvalid_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (s_axil_bvalid && !s_axil_bready) |=> s_axil_bvalid)
        else $error("[SVA latency] bvalid dropped before bready");

    // Responses are always OKAY (this slave never errors)
    a_rresp_okay: assert property (@(posedge clk) disable iff (!rst_n)
        s_axil_rvalid |-> (s_axil_rresp == 2'b00))
        else $error("[SVA latency] rresp not OKAY");

    c_axil_read: cover property (@(posedge clk) disable iff (!rst_n)
        (s_axil_rvalid && s_axil_rready));
endmodule

// -----------------------------------------------------------------------------
// risk_check : pre-trade gate contract
// -----------------------------------------------------------------------------
module risk_check_sva #(
    parameter int MAX_ORDER_SIZE = 500
)(
    input logic        clk,
    input logic        rst_n,
    input logic        halt,
    input logic        in_valid,
    input logic [31:0] in_size,
    input logic        out_valid,
    input logic        reject_valid
);
    // Never pass an order that wasn't proposed
    a_out_implies_in: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> in_valid)
        else $error("[SVA risk] out_valid without in_valid");

    // Kill switch blocks everything
    a_halt_blocks: assert property (@(posedge clk) disable iff (!rst_n)
        halt |-> !out_valid)
        else $error("[SVA risk] order passed while halted");

    // An accepted order never exceeds the max size
    a_size_ok: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (in_size <= MAX_ORDER_SIZE))
        else $error("[SVA risk] oversized order accepted");

    // reject_valid is exactly a blocked proposal
    a_reject_def: assert property (@(posedge clk) disable iff (!rst_n)
        reject_valid == (in_valid && !out_valid))
        else $error("[SVA risk] reject_valid mismatch");

    c_reject:  cover property (@(posedge clk) disable iff (!rst_n) reject_valid);
    c_accept:  cover property (@(posedge clk) disable iff (!rst_n) out_valid);
endmodule

bind risk_check risk_check_sva u_risk_check_sva (
    .clk(clk), .rst_n(rst_n), .halt(halt),
    .in_valid(in_valid), .in_size(in_size),
    .out_valid(out_valid), .reject_valid(reject_valid)
);

bind latency_counter latency_counter_sva u_latency_counter_sva (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axil_rvalid (s_axil_rvalid),
    .s_axil_rready (s_axil_rready),
    .s_axil_rresp  (s_axil_rresp),
    .s_axil_bvalid (s_axil_bvalid),
    .s_axil_bready (s_axil_bready),
    .s_axil_bresp  (s_axil_bresp)
);
