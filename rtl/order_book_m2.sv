// Multi-Level Order Book — Milestone 2 (BRAM-backed)
//
// Same behaviour as before (multi-level top-N, RESCAN, backpressure,
// rescan-skip) but the 256-entry order table is now a BRAM with SYNCHRONOUS
// (registered) reads instead of a 37k-flip-flop array. This was the timing
// wall: the FF array + combinational all-entry scan was route-dominated and
// missed 200 MHz (WNS -2.4 ns). With a registered read port the path is short.
//
// Pipelining (enabled because the parser HOLDS the message while msg_ready=0):
//   * Add / Add+MPID : O(1) in IDLE — write entry + level-insert from the
//     message itself (no read needed). Tick-to-trade latency unchanged.
//   * Cancel/Delete/Execute/Exec-Price/Replace : IDLE issues a BRAM read of the
//     target, then a 1-cycle LOOKUP checks the match and applies the edit.
//   * RESCAN : walks the table one address/cycle through the registered read
//     port (address stage + data/process stage), rebuilding the level cache.
//
// entries[] has exactly one write port and one registered read port (simple
// dual-port) and is never reset -> infers block RAM.

module order_book_m2 #(
    parameter ORDER_DEPTH = 256,
    parameter NLEVELS     = 4,
    parameter ADDR_W      = $clog2(ORDER_DEPTH)
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        msg_valid,
    output logic        msg_ready,
    input  logic [7:0]  msg_type,
    input  logic [63:0] order_ref,
    input  logic [63:0] new_order_ref,
    input  logic        side,
    input  logic [31:0] shares,
    input  logic [31:0] price,

    output logic [31:0] best_bid_price,
    output logic [31:0] best_bid_size,
    output logic [31:0] best_ask_price,
    output logic [31:0] best_ask_size,
    output logic        book_valid,

    output logic [NLEVELS*32-1:0] bid_level_price,
    output logic [NLEVELS*32-1:0] bid_level_size,
    output logic [NLEVELS*32-1:0] ask_level_price,
    output logic [NLEVELS*32-1:0] ask_level_size
);

    localparam int LVL_CW = $clog2(NLEVELS+1);

    typedef struct packed {
        logic [63:0] order_ref;
        logic        side;       // 0 = bid, 1 = ask
        logic [31:0] price;
        logic [31:0] shares;
    } order_entry_t;

    // ---- BRAM-backed order table (1 write port + 1 registered read port) ----
    order_entry_t           entries [0:ORDER_DEPTH-1];
    logic [ORDER_DEPTH-1:0] entry_valid;     // small FF vector (resettable)

    logic [ADDR_W-1:0] rd_addr;   // combinational read address
    order_entry_t      rd_data;   // registered read output (1-cycle latency)
    logic              we;        // combinational write enable
    logic [ADDR_W-1:0] wr_addr;
    order_entry_t      wr_data;

    always_ff @(posedge clk) begin
        if (we) entries[wr_addr] <= wr_data;
        rd_data <= entries[rd_addr];
    end

    logic [ADDR_W-1:0] msg_idx, new_idx;
    assign msg_idx = order_ref[ADDR_W-1:0];
    assign new_idx = new_order_ref[ADDR_W-1:0];

    // ---- per-side level cache (small, FF) ----------------------------------
    typedef struct packed {
        logic [NLEVELS-1:0][31:0] price;
        logic [NLEVELS-1:0][31:0] size;
        logic [LVL_CW-1:0]        cnt;
    } book_side_t;

    book_side_t bid_lv, ask_lv;

    function automatic book_side_t side_insert(
        input book_side_t cur, input logic [31:0] p, input logic [31:0] s, input logic is_bid);
        book_side_t  r;  logic matched, found_ins;  int unsigned ins;
        r = cur;  matched = 1'b0;
        for (int unsigned i = 0; i < NLEVELS; i++)
            if ((i < cur.cnt) && !matched && (cur.price[i] == p)) begin
                r.size[i] = cur.size[i] + s;  matched = 1'b1;
            end
        if (!matched) begin
            found_ins = 1'b0;  ins = 32'(cur.cnt);
            for (int unsigned i = 0; i < NLEVELS; i++)
                if (!found_ins && (i < cur.cnt) &&
                    (is_bid ? (p > cur.price[i]) : (p < cur.price[i]))) begin
                    ins = i;  found_ins = 1'b1;
                end
            if (ins < NLEVELS) begin
                for (int unsigned i = NLEVELS-1; i > 0; i--)
                    if (i > ins) begin
                        r.price[i] = r.price[i-1];  r.size[i] = r.size[i-1];
                    end
                r.price[ins] = p;  r.size[ins] = s;
                r.cnt = (cur.cnt < NLEVELS[LVL_CW-1:0]) ? (cur.cnt + 1'b1) : cur.cnt;
            end
        end
        return r;
    endfunction

    function automatic book_side_t empty_side();
        book_side_t e;  e = '0;  return e;
    endfunction

    // ---- outputs from the level cache --------------------------------------
    assign best_bid_price = (bid_lv.cnt != '0) ? bid_lv.price[0] : 32'h0;
    assign best_bid_size  = (bid_lv.cnt != '0) ? bid_lv.size[0]  : 32'h0;
    assign best_ask_price = (ask_lv.cnt != '0) ? ask_lv.price[0] : 32'hFFFF_FFFF;
    assign best_ask_size  = (ask_lv.cnt != '0) ? ask_lv.size[0]  : 32'h0;
    assign book_valid     = (bid_lv.cnt != '0) && (ask_lv.cnt != '0);

    genvar gi;
    generate
        for (gi = 0; gi < NLEVELS; gi++) begin : g_levels
            assign bid_level_price[gi*32 +: 32] = (gi < bid_lv.cnt) ? bid_lv.price[gi] : 32'h0;
            assign bid_level_size [gi*32 +: 32] = (gi < bid_lv.cnt) ? bid_lv.size[gi]  : 32'h0;
            assign ask_level_price[gi*32 +: 32] = (gi < ask_lv.cnt) ? ask_lv.price[gi] : 32'hFFFF_FFFF;
            assign ask_level_size [gi*32 +: 32] = (gi < ask_lv.cnt) ? ask_lv.size[gi]  : 32'h0;
        end
    endgenerate

    // ---- FSM ---------------------------------------------------------------
    typedef enum logic [1:0] { IDLE, LOOKUP, RESCAN } state_t;
    state_t state;
    assign msg_ready = (state == IDLE);

    // latched message (the parser holds it, but we latch on accept to be safe)
    logic [7:0]        m_type;
    logic [63:0]       m_ref, m_nref;
    logic [31:0]       m_shares, m_price;
    logic [ADDR_W-1:0] m_idx, m_nidx;

    // rescan pipeline
    logic [ADDR_W:0]   scan_addr;       // 0..ORDER_DEPTH+1
    logic [ADDR_W-1:0] proc_idx;
    logic              proc_en;
    book_side_t        scan_bid_lv, scan_ask_lv;

    // "displayed" check for the rescan-skip optimisation (uses the LOOKUP read)
    logic [LVL_CW-1:0] bid_widx, ask_widx;
    logic [31:0]       worst_bid_p, worst_ask_p;
    logic              aff_displayed;
    always_comb begin
        bid_widx    = (bid_lv.cnt != '0) ? (bid_lv.cnt - 1'b1) : '0;
        ask_widx    = (ask_lv.cnt != '0) ? (ask_lv.cnt - 1'b1) : '0;
        worst_bid_p = bid_lv.price[bid_widx];
        worst_ask_p = ask_lv.price[ask_widx];
        if (rd_data.side)
            aff_displayed = (ask_lv.cnt != NLEVELS[LVL_CW-1:0]) || (rd_data.price <= worst_ask_p);
        else
            aff_displayed = (bid_lv.cnt != NLEVELS[LVL_CW-1:0]) || (rd_data.price >= worst_bid_p);
    end

    wire is_reduce = (m_type == 8'h58) || (m_type == 8'h45) || (m_type == 8'h43); // X,E,C
    wire is_delete = (m_type == 8'h44);
    wire is_repl   = (m_type == 8'h55);
    wire lk_match  = entry_valid[m_idx] && (rd_data.order_ref == m_ref);

    // ---- combinational BRAM control ----------------------------------------
    always_comb begin
        // defaults
        rd_addr = '0;
        we      = 1'b0;
        wr_addr = '0;
        wr_data = '0;

        unique case (state)
            IDLE: begin
                // Add/F: write the new entry now (1-cycle)
                if (msg_valid && ((msg_type == 8'h41) || (msg_type == 8'h46))) begin
                    we      = 1'b1;
                    wr_addr = msg_idx;
                    wr_data = '{order_ref:order_ref, side:side, price:price, shares:shares};
                end
                // C/D/E/U: issue a read of the target for next-cycle LOOKUP
                rd_addr = msg_idx;
            end
            LOOKUP: begin
                rd_addr = m_idx;
                if (lk_match) begin
                    if (is_reduce && (rd_data.shares > m_shares)) begin
                        // partial reduce: write back reduced shares
                        we      = 1'b1;
                        wr_addr = m_idx;
                        wr_data = '{order_ref:rd_data.order_ref, side:rd_data.side,
                                    price:rd_data.price, shares:rd_data.shares - m_shares};
                    end else if (is_repl) begin
                        // install replacement at new index, reusing original side
                        we      = 1'b1;
                        wr_addr = m_nidx;
                        wr_data = '{order_ref:m_nref, side:rd_data.side,
                                    price:m_price, shares:m_shares};
                    end
                end
            end
            RESCAN: begin
                rd_addr = scan_addr[ADDR_W-1:0];   // issue read for this entry
            end
            default: ;
        endcase
    end

    // ---- control FSM (registered) ------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            bid_lv      <= '0;
            ask_lv      <= '0;
            scan_bid_lv <= '0;
            scan_ask_lv <= '0;
            scan_addr   <= '0;
            proc_idx    <= '0;
            proc_en     <= 1'b0;
            entry_valid <= '0;
        end else begin
            case (state)

                IDLE: begin
                    if (msg_valid) begin
                        // latch for the multi-cycle path
                        m_type   <= msg_type;  m_ref  <= order_ref;  m_nref <= new_order_ref;
                        m_shares <= shares;     m_price <= price;
                        m_idx    <= msg_idx;    m_nidx  <= new_idx;
                        case (msg_type)
                            8'h41, 8'h46: begin           // Add / Add+MPID — O(1)
                                entry_valid[msg_idx] <= 1'b1;   // entries[] written via we
                                if (!side) bid_lv <= side_insert(bid_lv, price, shares, 1'b1);
                                else       ask_lv <= side_insert(ask_lv, price, shares, 1'b0);
                            end
                            8'h58, 8'h44, 8'h45, 8'h43, 8'h55:
                                state <= LOOKUP;          // read target, decide next cycle
                            default: ;                    // unsupported -> ignore
                        endcase
                    end
                end

                LOOKUP: begin
                    if (lk_match) begin
                        // apply the structural change (entries[] data via we above)
                        if (is_reduce) begin
                            if (rd_data.shares <= m_shares) entry_valid[m_idx] <= 1'b0;
                            // else partial reduce already issued via we
                        end else if (is_delete) begin
                            entry_valid[m_idx] <= 1'b0;
                        end else if (is_repl) begin
                            entry_valid[m_idx]  <= 1'b0;
                            entry_valid[m_nidx] <= 1'b1;
                        end

                        // rescan only if a displayed level could change (replace always)
                        if (is_repl || aff_displayed) begin
                            state       <= RESCAN;
                            scan_addr   <= '0;
                            proc_en     <= 1'b0;
                            scan_bid_lv <= empty_side();
                            scan_ask_lv <= empty_side();
                        end else begin
                            state <= IDLE;
                        end
                    end else begin
                        state <= IDLE;                    // no matching order
                    end
                end

                RESCAN: begin
                    // process the entry whose data is in rd_data (issued last cycle)
                    if (proc_en && entry_valid[proc_idx]) begin
                        if (!rd_data.side)
                            scan_bid_lv <= side_insert(scan_bid_lv, rd_data.price, rd_data.shares, 1'b1);
                        else
                            scan_ask_lv <= side_insert(scan_ask_lv, rd_data.price, rd_data.shares, 1'b0);
                    end

                    if (scan_addr <= ORDER_DEPTH[ADDR_W:0]) begin
                        proc_idx  <= scan_addr[ADDR_W-1:0];
                        proc_en   <= (scan_addr < ORDER_DEPTH[ADDR_W:0]);
                        scan_addr <= scan_addr + 1'b1;
                    end else begin
                        // pipeline drained -> commit the rebuilt cache
                        bid_lv  <= scan_bid_lv;
                        ask_lv  <= scan_ask_lv;
                        proc_en <= 1'b0;
                        state   <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
