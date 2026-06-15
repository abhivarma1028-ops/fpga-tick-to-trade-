// ITCH 5.0 Parser — Milestone 2 subset:
//   Add(A), Add+MPID(F), Cancel(X), Delete(D), Execute(E),
//   Execute-with-Price(C), Replace(U)
// AXI-Stream byte-stream in → structured message out (one-cycle valid pulse)
// Always-ready (tready tied high); backpressure added in Milestone 3+.
//
// Message byte layouts (no length prefix; PS strips the 2-byte framing before DMA).
// Common header for every type: [0] type [1-2] locate [3-4] track [5-10] ts(6B) [11-18] ref(8B)
//   Add    (A/0x41,36B): +[19] side [20-23] shares [24-31] stock [32-35] price
//   Add+MPID(F/0x46,40B): identical to A for [0-35]; [36-39] attribution (ignored)
//   Cancel (X/0x58,23B): +[19-22] cancelled shares
//   Delete (D/0x44,19B): (nothing past ref)
//   Execute(E/0x45,31B): +[19-22] exec shares [23-30] match# (ignored)
//   ExecPrc(C/0x43,36B): +[19-22] exec shares [23-30] match# [31] printable [32-35] exec price
//   Replace(U/0x55,35B): +[19-26] NEW ref(8B) [27-30] shares [31-34] price
//     (Replace carries no side; the book reuses the original order's side.)
//
// Key design note: combinational _nxt wires include the CURRENT incoming byte so
// that fields whose last byte coincides with tlast are captured correctly.
// Without this, the always_ff non-blocking assignment sees the pre-shift value.

module itch_parser (
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream byte input (from DMA; tlast high on last byte of each message)
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tlast,

    // Decoded output — valid/ready handshake. m_valid is HELD until the
    // downstream asserts m_ready (so a message produced while the order book is
    // busy in RESCAN is not lost — the byte stream is back-pressured instead).
    output logic        m_valid,
    input  logic        m_ready,
    output logic [7:0]  msg_type,
    output logic [15:0] stock_locate,    // symbol id (header bytes 1-2) — multi-symbol routing
    output logic [47:0] timestamp,
    output logic [63:0] order_ref,      // original/target order reference
    output logic [63:0] new_order_ref,  // Replace(U): the NEW ref; else == order_ref
    output logic        side,           // 0=buy 1=sell (Add/Add+MPID only; 0 otherwise)
    output logic [31:0] shares,
    output logic [31:0] price,          // Add/Add+MPID/Exec-with-Price/Replace; fixed-point /10000 = USD
    output logic        msg_unsupported
);

    // Stall the byte stream while a decoded message is waiting to be accepted,
    // so we never overwrite the held output or drop the next message.
    assign s_axis_tready = !(m_valid && !m_ready);

    wire rx = s_axis_tvalid & s_axis_tready;

    // -----------------------------------------------------------------------
    // Shift-register state
    // -----------------------------------------------------------------------
    logic [5:0]  byte_cnt;
    logic [7:0]  msg_type_r;
    logic [15:0] loc_sr;
    logic [47:0] ts_sr;
    logic [63:0] ref_sr;
    logic [63:0] new_ref_sr;
    logic [31:0] sh_sr;
    logic [31:0] pr_sr;
    logic        side_r;

    // -----------------------------------------------------------------------
    // Message-type categories (decode from the registered type byte)
    // -----------------------------------------------------------------------
    wire is_add        = (msg_type_r == 8'h41) || (msg_type_r == 8'h46); // A, F
    wire is_replace    = (msg_type_r == 8'h55);                          // U
    wire is_exec_price = (msg_type_r == 8'h43);                          // C
    wire is_trade      = (msg_type_r == 8'h50);                          // P (Trade print)
    // P (Trade, 44B) uses the same side/shares/price offsets as Add; it is a
    // trade print (informational) so the order book leaves it as a no-op.
    wire is_addfields  = is_add || is_trade;
    wire is_supported  = is_add || is_replace || is_exec_price || is_trade ||
                         (msg_type_r == 8'h58) ||  // X
                         (msg_type_r == 8'h44) ||  // D
                         (msg_type_r == 8'h45);    // E

    // -----------------------------------------------------------------------
    // Combinational "next" values — include the current incoming byte.
    // Field offsets past the common header (byte >= 19) depend on the type.
    // -----------------------------------------------------------------------
    logic [15:0] loc_nxt;
    logic [47:0] ts_nxt;
    logic [63:0] ref_nxt;
    logic [63:0] new_ref_nxt;
    logic [31:0] sh_nxt;
    logic [31:0] pr_nxt;
    logic        side_nxt;

    always_comb begin
        loc_nxt     = loc_sr;
        ts_nxt      = ts_sr;
        ref_nxt     = ref_sr;
        new_ref_nxt = new_ref_sr;
        sh_nxt      = sh_sr;
        pr_nxt      = pr_sr;
        side_nxt    = side_r;

        if (rx) begin
            if (byte_cnt == 6'd1 || byte_cnt == 6'd2) begin
                // Stock locate (2B) — common header, all types
                loc_nxt = {loc_sr[7:0], s_axis_tdata};
            end
            else if (byte_cnt >= 6'd5 && byte_cnt <= 6'd10) begin
                // Timestamp (6B) — common to all types
                ts_nxt = {ts_sr[39:0], s_axis_tdata};
            end
            else if (byte_cnt >= 6'd11 && byte_cnt <= 6'd18) begin
                // Original order ref (8B) — common to all types
                ref_nxt = {ref_sr[55:0], s_axis_tdata};
            end
            else if (is_addfields) begin
                // Add / Add+MPID / Trade(P): side@19, shares@20-23, price@32-35
                case (byte_cnt)
                    6'd19:                      side_nxt = (s_axis_tdata == 8'h53); // 'S'
                    6'd20,6'd21,6'd22,6'd23:    sh_nxt   = {sh_sr[23:0], s_axis_tdata};
                    6'd32,6'd33,6'd34,6'd35:    pr_nxt   = {pr_sr[23:0], s_axis_tdata};
                    default: ;
                endcase
            end
            else if (is_replace) begin
                // Replace: new ref@19-26, shares@27-30, price@31-34
                if (byte_cnt >= 6'd19 && byte_cnt <= 6'd26)
                    new_ref_nxt = {new_ref_sr[55:0], s_axis_tdata};
                else if (byte_cnt >= 6'd27 && byte_cnt <= 6'd30)
                    sh_nxt = {sh_sr[23:0], s_axis_tdata};
                else if (byte_cnt >= 6'd31 && byte_cnt <= 6'd34)
                    pr_nxt = {pr_sr[23:0], s_axis_tdata};
            end
            else if (is_exec_price) begin
                // Execute-with-Price: exec shares@19-22, exec price@32-35 (byte 31 printable ignored)
                case (byte_cnt)
                    6'd19,6'd20,6'd21,6'd22: sh_nxt = {sh_sr[23:0], s_axis_tdata};
                    6'd32,6'd33,6'd34,6'd35: pr_nxt = {pr_sr[23:0], s_axis_tdata};
                    default: ;
                endcase
            end
            else begin
                // Cancel / Execute: shares@19-22 (Delete has nothing past ref)
                case (byte_cnt)
                    6'd19,6'd20,6'd21,6'd22: sh_nxt = {sh_sr[23:0], s_axis_tdata};
                    default: ;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential update + output capture
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt        <= '0;
            msg_type_r      <= '0;
            loc_sr          <= '0;
            ts_sr           <= '0;
            ref_sr          <= '0;
            new_ref_sr      <= '0;
            sh_sr           <= '0;
            pr_sr           <= '0;
            side_r          <= '0;
            m_valid         <= '0;
            msg_unsupported <= '0;
        end else begin
            msg_unsupported <= '0;

            // Clear the held output once the downstream accepts it.
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            // rx is gated by s_axis_tready, which is low while m_valid is held
            // and unaccepted — so we never produce a new message on top of an
            // unaccepted one.
            if (rx) begin
                // Advance shift registers with the current byte included
                loc_sr     <= loc_nxt;
                ts_sr      <= ts_nxt;
                ref_sr     <= ref_nxt;
                new_ref_sr <= new_ref_nxt;
                sh_sr      <= sh_nxt;
                pr_sr      <= pr_nxt;
                side_r     <= side_nxt;

                if (byte_cnt == '0)
                    msg_type_r <= s_axis_tdata;

                if (s_axis_tlast) begin
                    byte_cnt <= '0;

                    if (is_supported) begin
                        m_valid       <= 1'b1;
                        msg_type      <= msg_type_r;
                        stock_locate  <= loc_nxt;
                        timestamp     <= ts_nxt;
                        order_ref     <= ref_nxt;
                        new_order_ref <= is_replace ? new_ref_nxt : ref_nxt;
                        side          <= is_addfields ? side_nxt : 1'b0;
                        shares        <= sh_nxt;
                        price         <= (is_addfields || is_exec_price || is_replace)
                                            ? pr_nxt : 32'd0;
                    end else begin
                        msg_unsupported <= 1'b1;
                    end
                end else begin
                    byte_cnt <= byte_cnt + 1'b1;
                end
            end
        end
    end

endmodule
