// =============================================================================
// tb_tick_to_trade_top.sv  --  native SystemVerilog testbench for QuestaSim GUI
//
// Feeds NASDAQ ITCH bytes through the full parser -> book -> strategy -> decision
// pipeline, captures the 72-bit decision, and reads the tick-to-trade latency
// back over AXI-Lite. Self-checking ($display PASS/FAIL) and ends on $finish.
//
// Run in QuestaSim:   cd sim/sv_tb && vsim -do tt_top.do
// (the .do file compiles the RTL + this TB, adds grouped waves, and runs)
// =============================================================================
`timescale 1ns/1ps

module tb_tick_to_trade_top;

    // ---- Clock / reset -----------------------------------------------------
    logic clk = 0;
    logic rst_n;
    always #2.5 clk = ~clk;          // 5 ns period = 200 MHz

    // ---- DUT I/O -----------------------------------------------------------
    logic        s_axis_tvalid, s_axis_tready, s_axis_tlast;
    logic [7:0]  s_axis_tdata;
    logic        halt, risk_reject;
    logic [2:0]  risk_reason;
    logic        m_axis_tvalid, m_axis_tready, m_axis_tlast;
    logic [71:0] m_axis_tdata;
    // AXI-Lite
    logic [8:0]  s_axil_awaddr;  logic s_axil_awvalid, s_axil_awready;
    logic [31:0] s_axil_wdata;   logic [3:0] s_axil_wstrb;
    logic        s_axil_wvalid,  s_axil_wready;
    logic [1:0]  s_axil_bresp;   logic s_axil_bvalid, s_axil_bready;
    logic [8:0]  s_axil_araddr;  logic s_axil_arvalid, s_axil_arready;
    logic [31:0] s_axil_rdata;   logic [1:0] s_axil_rresp;
    logic        s_axil_rvalid,  s_axil_rready;

    // ---- DUT ---------------------------------------------------------------
    tick_to_trade_top dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata),   .s_axis_tlast(s_axis_tlast),
        .halt(halt), .risk_reject(risk_reject), .risk_reason(risk_reason),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),   .m_axis_tlast(m_axis_tlast),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),   .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),   .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),   .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready)
    );

    // ---- ITCH message builders --------------------------------------------
    // Build an Add Order (A, 36 bytes) into a byte queue.
    function automatic void make_add(ref byte unsigned q[$],
                                     input bit is_sell,
                                     input longint unsigned oref,
                                     input int unsigned shares,
                                     input int unsigned price);
        q = {};
        q.push_back(8'h41);                         // 'A'
        q.push_back(8'h00); q.push_back(8'h01);     // stock_locate
        q.push_back(8'h00); q.push_back(8'h00);     // tracking
        for (int i = 0; i < 6; i++) q.push_back(8'h00);          // timestamp
        for (int i = 7; i >= 0; i--) q.push_back(oref[8*i +: 8]);// order_ref (BE)
        q.push_back(is_sell ? 8'h53 : 8'h42);       // side 'S'/'B'
        for (int i = 3; i >= 0; i--) q.push_back(shares[8*i +: 8]);
        for (int i = 0; i < 8; i++) q.push_back(8'h20);          // stock symbol
        for (int i = 3; i >= 0; i--) q.push_back(price[8*i +: 8]);
    endfunction

    // Drive one AXI-Stream byte stream, honouring back-pressure (s_axis_tready).
    task automatic axis_send(input byte unsigned q[$]);
        foreach (q[i]) begin
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= q[i];
            s_axis_tlast  <= (i == q.size()-1);
            @(posedge clk);
            while (s_axis_tready !== 1'b1) @(posedge clk);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
    endtask

    // ---- AXI-Lite read -----------------------------------------------------
    task automatic axil_read(input logic [8:0] addr, output logic [31:0] data);
        s_axil_araddr  <= addr;
        s_axil_arvalid <= 1'b1;
        s_axil_rready  <= 1'b1;
        @(posedge clk);
        while (s_axil_arready !== 1'b1) @(posedge clk);
        s_axil_arvalid <= 1'b0;
        while (s_axil_rvalid !== 1'b1) @(posedge clk);
        data = s_axil_rdata;
        @(posedge clk);
        s_axil_rready <= 1'b0;
    endtask

    // ---- Decision capture --------------------------------------------------
    logic        dec_action;
    logic [31:0] dec_price, dec_size;
    int          errors = 0;

    task automatic await_decision(output bit got);
        got = 0;
        for (int c = 0; c < 400 && !got; c++) begin
            @(posedge clk);
            if (m_axis_tvalid === 1'b1) begin
                got        = 1;
                dec_action = m_axis_tdata[64];
                dec_price  = m_axis_tdata[63:32];
                dec_size   = m_axis_tdata[31:0];
            end
        end
    endtask

    // ---- Stimulus ----------------------------------------------------------
    byte unsigned msg[$];
    logic [31:0]  latency_cyc;
    bit           got;

    initial begin
        // idle
        s_axis_tvalid = 0; s_axis_tdata = 0; s_axis_tlast = 0;
        halt = 0;
        m_axis_tready = 1;
        s_axil_awaddr = 0; s_axil_awvalid = 0; s_axil_wdata = 0; s_axil_wstrb = 0;
        s_axil_wvalid = 0; s_axil_bready = 0;
        s_axil_araddr = 0; s_axil_arvalid = 0; s_axil_rready = 0;

        // reset
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("=====================================================");
        $display(" tick_to_trade_top : ITCH -> decision, full pipeline");
        $display("=====================================================");

        // Feed an ask (100 sh @ 150.0100), then a bid (200 sh @ 149.9900).
        // bid:ask size = 2:1 > 1.5x threshold -> BUY at the ask price.
        make_add(msg, 1'b1, 64'd1, 32'd100, 32'd1_500_100); // ask
        axis_send(msg);
        make_add(msg, 1'b0, 64'd2, 32'd200, 32'd1_499_900); // bid
        axis_send(msg);

        await_decision(got);
        if (!got) begin
            $display("FAIL: no decision within timeout"); errors++;
        end else begin
            axil_read(9'h100, latency_cyc);
            $display(" DECISION : %s  price=%0d (%.4f)  size=%0d",
                     dec_action ? "SELL" : "BUY",
                     dec_price, real'(dec_price)/10000.0, dec_size);
            $display(" LATENCY  : %0d cycles = %0d ns (tick-to-trade)",
                     latency_cyc, latency_cyc * 5);
            if (dec_action !== 1'b0)            begin $display("FAIL: expected BUY"); errors++; end
            if (dec_price  !== 32'd1_500_100)   begin $display("FAIL: expected price 1500100"); errors++; end
        end

        repeat (10) @(posedge clk);
        $display("-----------------------------------------------------");
        if (errors == 0) $display(" RESULT  : PASS");
        else             $display(" RESULT  : FAIL (%0d errors)", errors);
        $display("=====================================================");
        $finish;
    end

    // safety timeout
    initial begin
        #50000;
        $display("FATAL: global timeout"); $finish;
    end

endmodule
