/*
[MODULE_INFO_START]
Name: bus_if
Role: SystemVerilog interface sample
Summary:
  - Validates interface/modport indexing support
[MODULE_INFO_END]
*/
`timescale 1ns / 1ps
interface bus_if (input logic iClk);
  logic req;
  logic ack;
  modport master (output req, input ack);
  modport slave (input req, output ack);
endinterface
