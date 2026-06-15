// Multi-Symbol Order Book Engine
//
// Tracks NSYMBOLS independent order books by replicating the proven
// order_book_m2 (unchanged) once per symbol and routing each ITCH message to
// the book selected by its stock_locate field. Each per-symbol book keeps its
// own multi-level depth, RESCAN FSM and best bid/ask.
//
// Routing:  sym = stock_locate[SYMW-1:0]  (low bits hash, like the order_ref
//           index hash in order_book_m2).
// Back-pressure: msg_ready is the AND of all per-symbol books' msg_ready, i.e.
//           the engine accepts a new message only when EVERY book is idle. Adds
//           are O(1) (books stay idle, no stall); only a RESCAN stalls the feed.
//           This serialises rescans across symbols -> no cross-symbol overlap,
//           so the active-symbol output mux is always correctly attributed.
//
// Output:   the top-of-book / depth for the symbol of the most recent accepted
//           message (active_sym), which is what the downstream strategy reacts
//           to. Per-symbol best bid/ask are also exposed (flattened) for
//           observability.

module multi_symbol_book #(
    parameter int NSYMBOLS    = 4,
    parameter int NLEVELS     = 4,
    parameter int ORDER_DEPTH = 256
)(
    input  logic        clk,
    input  logic        rst_n,

    // Message in (from itch_parser) + symbol id
    input  logic        msg_valid,
    output logic        msg_ready,
    input  logic [7:0]  msg_type,
    // only the low SYMW bits select the symbol; upper bits intentionally unused
    // verilator lint_off UNUSEDSIGNAL
    input  logic [15:0] stock_locate,
    // verilator lint_on UNUSEDSIGNAL
    input  logic [63:0] order_ref,
    input  logic [63:0] new_order_ref,
    input  logic        side,
    input  logic [31:0] shares,
    input  logic [31:0] price,

    // Active-symbol top-of-book / depth (for the strategy)
    output logic [7:0]  active_sym,
    output logic [31:0] best_bid_price,
    output logic [31:0] best_bid_size,
    output logic [31:0] best_ask_price,
    output logic [31:0] best_ask_size,
    output logic        book_valid,
    output logic [NLEVELS*32-1:0] bid_level_size,
    output logic [NLEVELS*32-1:0] ask_level_size,

    // Per-symbol best bid/ask, flattened {sym NSYMBOLS-1 .. sym 0} (observability)
    output logic [NSYMBOLS*32-1:0] best_bid_price_all,
    output logic [NSYMBOLS*32-1:0] best_ask_price_all
);

    localparam int SYMW = (NSYMBOLS <= 1) ? 1 : $clog2(NSYMBOLS);

    // Symbol index from stock_locate (zero-extended to 8 bits)
    wire [7:0] sym_idx = {{(8-SYMW){1'b0}}, stock_locate[SYMW-1:0]};

    // Per-symbol book outputs
    logic [NSYMBOLS-1:0]  mr;          // msg_ready per book
    logic [NSYMBOLS-1:0]  bv;          // book_valid per book
    logic [31:0]          bbp [NSYMBOLS], bbs [NSYMBOLS];
    logic [31:0]          bap [NSYMBOLS], bas [NSYMBOLS];
    logic [NLEVELS*32-1:0] blz [NSYMBOLS], alz [NSYMBOLS];
    // level-price outputs are unused downstream (strategy needs sizes only)
    // verilator lint_off UNUSEDSIGNAL
    logic [NLEVELS*32-1:0] blp [NSYMBOLS], alp [NSYMBOLS];
    // verilator lint_on UNUSEDSIGNAL

    genvar g;
    generate
        for (g = 0; g < NSYMBOLS; g++) begin : gbook
            order_book_m2 #(.ORDER_DEPTH(ORDER_DEPTH), .NLEVELS(NLEVELS)) u_book (
                .clk            (clk),
                .rst_n          (rst_n),
                .msg_valid      (msg_valid && (sym_idx == g[7:0])),
                .msg_ready      (mr[g]),
                .msg_type       (msg_type),
                .order_ref      (order_ref),
                .new_order_ref  (new_order_ref),
                .side           (side),
                .shares         (shares),
                .price          (price),
                .best_bid_price (bbp[g]),
                .best_bid_size  (bbs[g]),
                .best_ask_price (bap[g]),
                .best_ask_size  (bas[g]),
                .book_valid     (bv[g]),
                .bid_level_price(blp[g]),
                .bid_level_size (blz[g]),
                .ask_level_price(alp[g]),
                .ask_level_size (alz[g])
            );
            assign best_bid_price_all[g*32 +: 32] = bbp[g];
            assign best_ask_price_all[g*32 +: 32] = bap[g];
        end
    endgenerate

    // Accept a message only when ALL books are idle (serialises rescans)
    assign msg_ready = &mr;

    // Latch the symbol of the most recent accepted message
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_sym <= '0;
        else if (msg_valid && msg_ready)
            active_sym <= sym_idx;
    end

    // Mux the active symbol's book to the engine outputs
    wire [SYMW-1:0] asel = active_sym[SYMW-1:0];
    assign best_bid_price = bbp[asel];
    assign best_bid_size  = bbs[asel];
    assign best_ask_price = bap[asel];
    assign best_ask_size  = bas[asel];
    assign book_valid     = bv[asel];
    assign bid_level_size = blz[asel];
    assign ask_level_size = alz[asel];

endmodule
