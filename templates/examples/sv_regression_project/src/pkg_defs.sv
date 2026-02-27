/*
[MODULE_INFO_START]
Name: pkg_defs
Role: SystemVerilog package for regression sample
Summary:
  - Provides shared typedef enum and parameters
  - Used to validate package/import parsing paths
[MODULE_INFO_END]
*/
`timescale 1ns / 1ps
package pkg_defs;
  typedef enum logic [1:0] {
    IDLE,
    RUN,
    DONE
  } state_t;
endpackage
