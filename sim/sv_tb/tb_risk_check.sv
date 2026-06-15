// =============================================================================
// tb_risk_check.sv  --  native SystemVerilog testbench for QuestaSim GUI
// Exercises every pre-trade control: size, price collar, position, kill switch.
// Run:  cd sim/sv_tb && vsim -do risk.do
// =============================================================================
`timescale 1ns/1ps

module tb_risk_check;

    localparam int MAX_ORDER_SIZE = 500;
    localparam int MAX_POSITION   = 1000;
    localparam int MAX_PRICE_BAND = 5000;
    localparam int REF            = 1_500_000;
    localparam logic BUY = 1'b0, SELL = 1'b1;

    logic clk = 0, rst_n;
    always #2.5 clk = ~clk;

    logic        halt, in_valid, in_action;
    logic [31:0] in_price, in_size, ref_price;
    logic        out_valid, out_action;
    logic [31:0] out_price, out_size;
    logic        reject_valid;
    logic [2:0]  reject_reason;

    risk_check dut (
        .clk(clk), .rst_n(rst_n), .halt(halt),
        .in_valid(in_valid), .in_action(in_action),
        .in_price(in_price), .in_size(in_size), .ref_price(ref_price),
        .out_valid(out_valid), .out_action(out_action),
        .out_price(out_price), .out_size(out_size),
        .reject_valid(reject_valid), .reject_reason(reject_reason)
    );

    string reasons[6] = '{"OK","SIZE","PRICE","POSITION","HALT","?"};

    task automatic propose(input string tag, input logic act,
                           input int unsigned px, input int unsigned sz, input logic h);
        in_valid <= 1; in_action <= act; in_price <= px; in_size <= sz; halt <= h;
        #1;
        $display(" %-22s -> %-7s reason=%-8s (pos before=%0d)",
                 tag, out_valid ? "ACCEPT" : "BLOCK",
                 reasons[reject_reason], $signed(dut.position));
        @(posedge clk);            // commit position if accepted
        in_valid <= 0; halt <= 0;
        @(posedge clk);
    endtask

    initial begin
        halt=0; in_valid=0; in_action=0; in_price=0; in_size=0; ref_price=REF;
        rst_n=0; repeat (4) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        $display("=====================================================");
        $display(" risk_check : pre-trade SEC Rule 15c3-5 controls");
        $display("=====================================================");

        propose("normal buy 100",     BUY,  REF+100,            100, 0);
        propose("oversized 600",      BUY,  REF+100,            600, 0);
        propose("price out of band",  BUY,  REF+10000,          100, 0);
        propose("buy 500 (pos->600)", BUY,  REF,                500, 0);
        propose("buy 500 (pos->1100)",BUY,  REF,                500, 0); // exceeds MAX_POSITION
        propose("sell 500 (pos->100)",SELL, REF,                500, 0);
        propose("halted order",       BUY,  REF+100,            100, 1);

        repeat (6) @(posedge clk);
        $display("=====================================================");
        $finish;
    end

    initial begin #20000; $display("FATAL timeout"); $finish; end
endmodule
