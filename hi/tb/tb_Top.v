`timescale 1ns/1ps

// Example testbench template.
// PR Test on Main - Direct Commit
// Branch: pr-simulation - Requesting Merge!
// Update the DUT instantiation to match your top module ports.
module tb_Top;
  reg clk = 0;
  reg rst = 1;
  reg [1023:0] vcdfile;

  // Waveform dump (supports +vcd=output/wave.vcd override)
  initial
  begin
    if (!$value$plusargs("vcd=%s", vcdfile))
      vcdfile = "output/wave.vcd";
    $dumpfile(vcdfile);
    $dumpvars(0, tb_Top);
  end

  // Simple clock/reset stimulus
  always #5 clk = ~clk;

  initial
  begin
    #20 rst = 0;
    repeat (100) @(posedge clk);
    $finish;
  end

  // TODO: instantiate your DUT here.
  // Top dut (
  //   .clk(clk),
  //   .reset(rst)
  // );
endmodule
