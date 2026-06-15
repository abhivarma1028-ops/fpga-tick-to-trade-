// Pre-Trade Risk Check -- hardware SEC Rule 15c3-5 controls
//
// Sits between the strategy and the decision output. A proposed order is passed
// through ONLY if it clears every check; otherwise it is blocked and a reason is
// flagged. The gate is purely combinational (zero added tick-to-trade latency);
// only the running net position is registered.
//
// Checks (priority high -> low):
//   HALT      kill-switch asserted          -> block everything
//   SIZE      order_size > MAX_ORDER_SIZE   -> fat-finger size guard
//   PRICE     |order_price - ref_price|     -> price collar (erroneous price)
//             > MAX_PRICE_BAND
//   POSITION  |position +/- order_size|     -> net exposure limit
//             > MAX_POSITION
//
// Position model: each accepted order moves the running net position (BUY adds,
// SELL subtracts). Real fills are not modelled here -- this is open-order
// exposure, which is what a pre-trade 15c3-5 control gates on.

module risk_check #(
    parameter int MAX_ORDER_SIZE = 500,    // max shares per single order
    parameter int MAX_POSITION   = 1000,   // max |net position| (shares)
    parameter int MAX_PRICE_BAND = 5000    // max |order_px - ref_px| ticks ($0.50)
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        halt,              // kill switch: 1 = block all orders

    // Proposed order (from strategy_imbalance)
    input  logic        in_valid,
    input  logic        in_action,         // 0 = BUY, 1 = SELL
    input  logic [31:0] in_price,
    input  logic [31:0] in_size,
    input  logic [31:0] ref_price,         // reference price for the collar (e.g. mid)

    // Accepted order (to decision output) -- combinational, same cycle as in_valid
    output logic        out_valid,
    output logic        out_action,
    output logic [31:0] out_price,
    output logic [31:0] out_size,

    // Reject reporting (combinational)
    output logic        reject_valid,
    output logic [2:0]  reject_reason      // see localparams below
);

    localparam logic [2:0] R_OK = 3'd0, R_SIZE = 3'd1, R_PRICE = 3'd2,
                           R_POSITION = 3'd3, R_HALT = 3'd4;

    // Running net position (signed): + long, - short
    logic signed [31:0] position;

    // ---- combinational checks ---------------------------------------------
    logic [31:0]        price_dev;          // |in_price - ref_price|
    logic signed [31:0] signed_qty;         // +size for BUY, -size for SELL
    logic signed [31:0] new_position;       // position after this order
    logic [31:0]        abs_new_position;
    logic               ok_size, ok_price, ok_position;

    always_comb begin
        price_dev   = (in_price >= ref_price) ? (in_price - ref_price)
                                              : (ref_price - in_price);
        // share counts are well within 2^31, so a 32-bit signed view is safe
        signed_qty  = in_action ? -$signed(in_size) : $signed(in_size);
        new_position    = position + signed_qty;
        abs_new_position = new_position[31] ? (-new_position) : new_position;

        ok_size     = (in_size    <= MAX_ORDER_SIZE);
        ok_price    = (price_dev  <= MAX_PRICE_BAND);
        ok_position = (abs_new_position <= MAX_POSITION);

        // Pass-through gate
        out_valid  = in_valid && !halt && ok_size && ok_price && ok_position;
        out_action = in_action;
        out_price  = in_price;
        out_size   = in_size;

        // Reject + reason (priority encoded)
        reject_valid  = in_valid && !out_valid;
        if      (!in_valid)    reject_reason = R_OK;
        else if (halt)         reject_reason = R_HALT;
        else if (!ok_size)     reject_reason = R_SIZE;
        else if (!ok_price)    reject_reason = R_PRICE;
        else if (!ok_position) reject_reason = R_POSITION;
        else                   reject_reason = R_OK;
    end

    // ---- registered position update ---------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            position <= '0;
        else if (out_valid)
            position <= new_position;       // only accepted orders move position
    end

endmodule
