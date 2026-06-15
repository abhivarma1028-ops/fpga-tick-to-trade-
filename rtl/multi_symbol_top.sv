// Multi-Symbol Tick-to-Trade Top
//
// Same pipeline as tick_to_trade_top, but the single order book is replaced by
// the multi_symbol_book engine (N per-symbol books routed by stock_locate). The
// strategy and risk check operate on the active symbol's top-of-book, and each
// decision is tagged with its symbol (decision_sym).
//
//   itch_parser -> multi_symbol_book -> strategy_imbalance -> risk_check -> out
//
// The proven single-symbol modules are reused unchanged.

module multi_symbol_top #(
    parameter int NSYMBOLS = 4,
    parameter int NLEVELS  = 4
)(
    input  logic        clk,
    input  logic        rst_n,

    // ITCH byte stream in
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tlast,

    // Risk control
    input  logic        halt,
    output logic        risk_reject,
    output logic [2:0]  risk_reason,

    // Decision out (tagged with its symbol)
    output logic        m_axis_tvalid,
    // verilator lint_off UNUSEDSIGNAL
    input  logic        m_axis_tready,
    // verilator lint_on UNUSEDSIGNAL
    output logic [7:0]  decision_sym,
    output logic [71:0] m_axis_tdata,
    output logic        m_axis_tlast,

    // AXI-Lite latency readout
    input  logic [8:0]  s_axil_awaddr,  input  logic s_axil_awvalid, output logic s_axil_awready,
    input  logic [31:0] s_axil_wdata,   input  logic [3:0] s_axil_wstrb,
    input  logic        s_axil_wvalid,  output logic s_axil_wready,
    output logic [1:0]  s_axil_bresp,   output logic s_axil_bvalid, input  logic s_axil_bready,
    input  logic [8:0]  s_axil_araddr,  input  logic s_axil_arvalid, output logic s_axil_arready,
    output logic [31:0] s_axil_rdata,   output logic [1:0] s_axil_rresp,
    output logic        s_axil_rvalid,  input  logic s_axil_rready
);

    // -------- Parser --------------------------------------------------------
    logic        parser_valid, book_ready;
    logic [7:0]  msg_type;
    logic [15:0] stock_locate;
    // verilator lint_off UNUSEDSIGNAL
    logic [47:0] timestamp;
    // verilator lint_on UNUSEDSIGNAL
    logic [63:0] order_ref, new_order_ref;
    logic        side;
    logic [31:0] shares, price;

    itch_parser u_parser (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),   .s_axis_tlast(s_axis_tlast),
        .m_valid(parser_valid), .m_ready(book_ready),
        .msg_type(msg_type), .stock_locate(stock_locate), .timestamp(timestamp),
        .order_ref(order_ref), .new_order_ref(new_order_ref),
        .side(side), .shares(shares), .price(price),
        /* verilator lint_off PINCONNECTEMPTY */
        .msg_unsupported()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // -------- Multi-symbol order book ---------------------------------------
    logic [7:0]  active_sym;
    logic [31:0] bbid_p, bask_p;
    // verilator lint_off UNUSEDSIGNAL
    logic [31:0] bbid_s, bask_s;
    logic [NSYMBOLS*32-1:0] bid_price_all, ask_price_all;
    // verilator lint_on UNUSEDSIGNAL
    logic        book_valid;
    logic [NLEVELS*32-1:0] bid_level_size, ask_level_size;

    multi_symbol_book #(.NSYMBOLS(NSYMBOLS), .NLEVELS(NLEVELS)) u_book (
        .clk(clk), .rst_n(rst_n),
        .msg_valid(parser_valid), .msg_ready(book_ready),
        .msg_type(msg_type), .stock_locate(stock_locate),
        .order_ref(order_ref), .new_order_ref(new_order_ref),
        .side(side), .shares(shares), .price(price),
        .active_sym(active_sym),
        .best_bid_price(bbid_p), .best_bid_size(bbid_s),
        .best_ask_price(bask_p), .best_ask_size(bask_s),
        .book_valid(book_valid),
        .bid_level_size(bid_level_size), .ask_level_size(ask_level_size),
        .best_bid_price_all(bid_price_all), .best_ask_price_all(ask_price_all)
    );

    // -------- Strategy (active symbol) --------------------------------------
    logic        dec_valid, action;
    logic [31:0] order_price, order_size;

    strategy_imbalance #(.NLEVELS(NLEVELS)) u_strategy (
        .clk(clk), .rst_n(rst_n),
        .book_valid(book_valid),
        .best_bid_price(bbid_p), .best_ask_price(bask_p),
        .bid_level_size(bid_level_size), .ask_level_size(ask_level_size),
        .decision_valid(dec_valid), .action(action),
        .order_price(order_price), .order_size(order_size)
    );

    // -------- Pre-trade risk check (combinational gate) ----------------------
    logic        risk_valid_c, risk_action_c;
    logic [31:0] risk_price_c, risk_size_c;
    logic        risk_reject_c;
    logic [2:0]  risk_reason_c;
    wire  [31:0] mid_price = (bbid_p + bask_p) >> 1;

    risk_check u_risk (
        .clk(clk), .rst_n(rst_n), .halt(halt),
        .in_valid(dec_valid), .in_action(action),
        .in_price(order_price), .in_size(order_size), .ref_price(mid_price),
        .out_valid(risk_valid_c), .out_action(risk_action_c),
        .out_price(risk_price_c), .out_size(risk_size_c),
        .reject_valid(risk_reject_c), .reject_reason(risk_reason_c)
    );

    // Register the risk/decision stage one cycle. This breaks the long
    // combinational chain book -> strategy -> risk -> (symbol mux) -> output pin
    // that limited timing; costs +1 cycle of latency. (Matches tick_to_trade_top.)
    logic        risk_valid, risk_action;
    logic [31:0] risk_price, risk_size;
    logic [7:0]  decision_sym_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            risk_valid     <= 1'b0;
            risk_action    <= 1'b0;
            risk_price     <= '0;
            risk_size      <= '0;
            risk_reject    <= 1'b0;
            risk_reason    <= 3'd0;
            decision_sym_r <= '0;
        end else begin
            risk_valid     <= risk_valid_c;
            risk_action    <= risk_action_c;
            risk_price     <= risk_price_c;
            risk_size      <= risk_size_c;
            risk_reject    <= risk_reject_c;
            risk_reason    <= risk_reason_c;
            decision_sym_r <= active_sym;
        end
    end

    // -------- Latency counter -----------------------------------------------
    logic msg_start;
    logic [5:0] byte_cnt_mon;
    wire  rx = s_axis_tvalid & s_axis_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) byte_cnt_mon <= '0;
        else if (rx) byte_cnt_mon <= s_axis_tlast ? 6'd0 : byte_cnt_mon + 1'b1;
    end
    assign msg_start = rx & (byte_cnt_mon == '0);

    latency_counter u_lat (
        .clk(clk), .rst_n(rst_n),
        .msg_start(msg_start), .decision_valid(risk_valid),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready)
    );

    // -------- Decision out (risk-approved, symbol-tagged; registered) -------
    assign m_axis_tvalid = risk_valid;
    assign decision_sym  = decision_sym_r;
    assign m_axis_tdata  = {{7{1'b0}}, risk_action, risk_price, risk_size};
    assign m_axis_tlast  = risk_valid;

endmodule
