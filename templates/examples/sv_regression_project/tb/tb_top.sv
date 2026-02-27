/*
[TB_INFO_START]
Name: tb_top
Target: Top
Role: Testbench for validating SV regression sample
Scenario:
  - Reset behavior check
  - Request/ack handshake check
CheckPoint:
  - Verify DUT reset and default outputs first
  - Add explicit expected-value checks for auto-judgement
[TB_INFO_END]
*/
`timescale 1ns / 1ps
module tb_top;
  logic iClk;
  logic iRst;
  logic iReq;
  logic oAck;

  Top dut (
    .iClk(iClk),
    .iRst(iRst),
    .iReq(iReq),
    .oAck(oAck)
  );

  always #5 iClk = ~iClk;

  initial begin
    iClk = 1'b0;
    iRst = 1'b1;
    iReq = 1'b0;

    $dumpfile("tb_top.vcd");
    $dumpvars(0, tb_top);

    // @WAVE: iClk, iRst, iReq, oAck
    // @RUNTIME BEGIN : 0ns
    repeat (2) @(posedge iClk);
    iRst = 1'b0;
    repeat (2) @(posedge iClk);
    iReq = 1'b1;
    @(posedge iClk);
    iReq = 1'b0;
    repeat (4) @(posedge iClk);
    // @RUNTIME END : 100ns

    if (oAck !== 1'b0) $fatal(1, "oAck should return low after DONE");
    $display("tb_top finished");
    $finish;
  end
endmodule
