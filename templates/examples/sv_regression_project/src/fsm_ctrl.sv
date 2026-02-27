/*
[MODULE_INFO_START]
Name: fsm_ctrl
Role: SV FSM sample module
Summary:
  - Uses typedef enum logic and always_ff/always_comb
StateDescription:
  - IDLE: Wait for request
  - RUN: Process request
  - DONE: Complete handshake
[MODULE_INFO_END]
*/
`timescale 1ns / 1ps
`include "include/defs.svh"
module fsm_ctrl (
    input  logic iClk,
    input  logic iRst,
    input  logic iReq,
    output logic oAck
);
  import pkg_defs::*;

  state_t rCurState, rNxtState;

  always_ff @(posedge iClk or posedge iRst) begin
    if (iRst) begin
      rCurState <= IDLE;
    end else begin
      rCurState <= rNxtState;
    end
  end

  always_comb begin
    rNxtState = rCurState;
    oAck = 1'b0;
    case (rCurState)
      IDLE: if (iReq) rNxtState = RUN;
      RUN:  rNxtState = DONE;
      DONE: begin
        oAck = 1'b1;
        rNxtState = IDLE;
      end
      default: rNxtState = IDLE;
    endcase
  end
endmodule
