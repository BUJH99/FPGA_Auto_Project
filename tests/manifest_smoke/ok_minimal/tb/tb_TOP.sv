/*
[TB_INFO_START]
Name: tb_TOP
Target: TOP
Role: Testbench for validating TOP
Scenario:
  - Apply and release reset, then check DUT initialization
  - Apply core stimuli and check output behavior
  - Cover boundary/error cases with PASS/FAIL criteria
CheckPoint:
  - Verify DUT reset and default outputs first
  - Compare key outputs/internal probes against expected behavior
  - Add explicit expected-value checks for auto-judgement
[TB_INFO_END]
*/

module tb_TOP;
  TOP dut();
endmodule
