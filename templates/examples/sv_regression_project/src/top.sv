/*
[MODULE_INFO_START]
Name: Top
Role: Top sample using package/interface
Summary:
  - Instantiates interface and FSM module
[MODULE_INFO_END]
*/
`timescale 1ns / 1ps
module Top (
    input  logic iClk,
    input  logic iRst,
    input  logic iReq,
    output logic oAck
);
  bus_if u_bus_if (.iClk(iClk));

  fsm_ctrl u_fsm_ctrl (
    .iClk(iClk),
    .iRst(iRst),
    .iReq(iReq),
    .oAck(oAck)
  );

  always_comb begin
    u_bus_if.req = iReq;
    u_bus_if.ack = oAck;
  end
endmodule
