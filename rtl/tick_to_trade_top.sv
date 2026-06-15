// Tick-to-Trade Top — wires parser → book → strategy → risk → decision output
// AXI-Stream slave in (ITCH bytes), AXI-Stream master out (decision packets)
// AXI-Lite slave out — latency histogram (see latency_counter.sv for reg map)
// Pre-trade risk check (SEC Rule 15c3-5) gates the decision; see risk_check.sv

module tick_to_trade_top (
    input  logic        clk,
    input  logic        rst_n,

    // ITCH byte stream in (from DMA)
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tlast,

    // Risk control
    input  logic        halt,          // kill switch: 1 = block all orders
    output logic        risk_reject,   // an order was blocked by a risk check
    output logic [2:0]  risk_reason,   // why (see risk_check.sv)

    // Decision stream out (to DMA → PS → IBKR bridge)
    output logic        m_axis_tvalid,
    // verilator lint_off UNUSEDSIGNAL
    input  logic        m_axis_tready, // no back-pressure: one beat per decision
    // verilator lint_on UNUSEDSIGNAL
    output logic [71:0] m_axis_tdata,  // {action[7:0], price[31:0], size[31:0]}
    output logic        m_axis_tlast,

    // AXI-Lite slave — latency counter histogram readout
    input  logic [8:0]  s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [8:0]  s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready
);

    // -----------------------------------------------------------------------
    // Parser
    // -----------------------------------------------------------------------
    logic        parser_valid;
    logic        book_ready;       // book→parser backpressure handshake
    logic [7:0]  msg_type;
    // verilator lint_off UNUSEDSIGNAL
    logic [47:0] timestamp;   // parsed but not consumed by strategy (M1/M2 scope)
    // verilator lint_on UNUSEDSIGNAL
    logic [63:0] order_ref;
    logic [63:0] new_order_ref;
    logic        side;
    logic [31:0] shares, price;

    itch_parser u_parser (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tlast   (s_axis_tlast),
        .m_valid        (parser_valid),
        .m_ready        (book_ready),
        .msg_type       (msg_type),
        /* verilator lint_off PINCONNECTEMPTY */
        .stock_locate   (),   // single-symbol top: routing not used
        /* verilator lint_on PINCONNECTEMPTY */
        .timestamp      (timestamp),
        .order_ref      (order_ref),
        .new_order_ref  (new_order_ref),
        .side           (side),
        .shares         (shares),
        .price          (price),
        /* verilator lint_off PINCONNECTEMPTY */
        .msg_unsupported()  // unsupported-message flag not used downstream
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // -----------------------------------------------------------------------
    // Order book (M2: multi-level + RESCAN FSM)
    // -----------------------------------------------------------------------
    localparam int NLEVELS = 4;

    logic [31:0] bbid_p, bask_p;
    logic        book_valid;
    // verilator lint_off UNUSEDSIGNAL
    logic [31:0] bbid_s, bask_s;                             // best sizes (== level 0) unused
    logic [NLEVELS*32-1:0] bid_level_price, ask_level_price; // level prices unused by strategy
    // verilator lint_on UNUSEDSIGNAL
    logic [NLEVELS*32-1:0] bid_level_size,  ask_level_size;

    order_book_m2 #(.NLEVELS(NLEVELS)) u_book (
        .clk             (clk),
        .rst_n           (rst_n),
        .msg_valid       (parser_valid),
        .msg_ready       (book_ready),
        .msg_type        (msg_type),
        .order_ref       (order_ref),
        .new_order_ref   (new_order_ref),
        .side            (side),
        .shares          (shares),
        .price           (price),
        .best_bid_price  (bbid_p),
        .best_bid_size   (bbid_s),
        .best_ask_price  (bask_p),
        .best_ask_size   (bask_s),
        .book_valid      (book_valid),
        .bid_level_price (bid_level_price),
        .bid_level_size  (bid_level_size),
        .ask_level_price (ask_level_price),
        .ask_level_size  (ask_level_size)
    );

    // -----------------------------------------------------------------------
    // Strategy (depth-weighted over NLEVELS)
    // -----------------------------------------------------------------------
    logic        dec_valid;
    logic        action;
    logic [31:0] order_price, order_size;

    strategy_imbalance #(.NLEVELS(NLEVELS)) u_strategy (
        .clk            (clk),
        .rst_n          (rst_n),
        .book_valid     (book_valid),
        .best_bid_price (bbid_p),
        .best_ask_price (bask_p),
        .bid_level_size (bid_level_size),
        .ask_level_size (ask_level_size),
        .decision_valid (dec_valid),
        .action         (action),
        .order_price    (order_price),
        .order_size     (order_size)
    );

    // -----------------------------------------------------------------------
    // Pre-trade risk check (SEC Rule 15c3-5) — zero-latency combinational gate.
    // Reference price for the collar is the book mid.
    // -----------------------------------------------------------------------
    logic        risk_valid_c;
    logic        risk_action_c;
    logic [31:0] risk_price_c, risk_size_c;
    logic        risk_reject_c;
    logic [2:0]  risk_reason_c;
    wire  [31:0] mid_price = (bbid_p + bask_p) >> 1;

    risk_check u_risk (
        .clk          (clk),
        .rst_n        (rst_n),
        .halt         (halt),
        .in_valid     (dec_valid),
        .in_action    (action),
        .in_price     (order_price),
        .in_size      (order_size),
        .ref_price    (mid_price),
        .out_valid    (risk_valid_c),
        .out_action   (risk_action_c),
        .out_price    (risk_price_c),
        .out_size     (risk_size_c),
        .reject_valid (risk_reject_c),
        .reject_reason(risk_reason_c)
    );

    // Register risk outputs one cycle to close output timing (OBUF + 2 ns constraint).
    // Adds one tick of latency on risk_reject/risk_reason and the decision stream.
    logic        risk_valid;
    logic        risk_action;
    logic [31:0] risk_price, risk_size;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            risk_valid   <= 1'b0;
            risk_action  <= 1'b0;
            risk_price   <= '0;
            risk_size    <= '0;
            risk_reject  <= 1'b0;
            risk_reason  <= 3'd0;
        end else begin
            risk_valid   <= risk_valid_c;
            risk_action  <= risk_action_c;
            risk_price   <= risk_price_c;
            risk_size    <= risk_size_c;
            risk_reject  <= risk_reject_c;
            risk_reason  <= risk_reason_c;
        end
    end

    // -----------------------------------------------------------------------
    // Latency counter (measures up to the risk-approved order)
    // -----------------------------------------------------------------------
    // msg_start: first byte of each new message
    logic msg_start;
    logic [5:0] byte_cnt_mon;
    wire  rx = s_axis_tvalid & s_axis_tready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) byte_cnt_mon <= '0;
        else if (rx) begin
            if (s_axis_tlast) byte_cnt_mon <= '0;
            else              byte_cnt_mon <= byte_cnt_mon + 1'b1;
        end
    end
    assign msg_start = rx & (byte_cnt_mon == '0);

    latency_counter u_lat (
        .clk              (clk),
        .rst_n            (rst_n),
        .msg_start        (msg_start),
        .decision_valid   (risk_valid),
        .s_axil_awaddr    (s_axil_awaddr),
        .s_axil_awvalid   (s_axil_awvalid),
        .s_axil_awready   (s_axil_awready),
        .s_axil_wdata     (s_axil_wdata),
        .s_axil_wstrb     (s_axil_wstrb),
        .s_axil_wvalid    (s_axil_wvalid),
        .s_axil_wready    (s_axil_wready),
        .s_axil_bresp     (s_axil_bresp),
        .s_axil_bvalid    (s_axil_bvalid),
        .s_axil_bready    (s_axil_bready),
        .s_axil_araddr    (s_axil_araddr),
        .s_axil_arvalid   (s_axil_arvalid),
        .s_axil_arready   (s_axil_arready),
        .s_axil_rdata     (s_axil_rdata),
        .s_axil_rresp     (s_axil_rresp),
        .s_axil_rvalid    (s_axil_rvalid),
        .s_axil_rready    (s_axil_rready)
    );

    // -----------------------------------------------------------------------
    // Decision output — pack the RISK-APPROVED order into an AXI-Stream beat.
    // Driven from the registered risk outputs so OBUF paths start at a FF.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tdata  <= '0;
        end else begin
            m_axis_tvalid <= risk_valid;
            m_axis_tlast  <= risk_valid;
            m_axis_tdata  <= {{7{1'b0}}, risk_action, risk_price, risk_size};
        end
    end

endmodule
