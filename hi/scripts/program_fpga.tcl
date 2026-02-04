# =================================================================
# Vivado Hardware Manager Script
# Program the generated bitstream to the FPGA device without GUI
# =================================================================

set top_module "Top"
set config_file "./build_config.tcl"
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}
set bitstream_file "./output/${top_module}.bit"

puts "\n\[STEP 1\] Checking Bitstream File..."
if { ![file exists $bitstream_file] } {
    puts "ERROR: Bitstream file not found at $bitstream_file"
    puts "Please run the build script (build_all.bat) first."
    exit 1
}
puts "Found bitstream: $bitstream_file"

puts "\n\[STEP 2\] Connecting to Hardware Server..."
open_hw_manager
connect_hw_server -url localhost:3121

# Refresh targets to find connected boards
if {[catch {
    puts "Scanning for hardware targets..."
    refresh_hw_server
} msg]} {
    puts "ERROR: Failed to refresh hardware server. Is the cable connected?"
    exit 1
}

puts "\n\[STEP 3\] Opening Hardware Target..."
# Get list of targets (e.g., Digilent JTAG Cable)
set targets [get_hw_targets]

if {[llength $targets] == 0} {
    puts "ERROR: No hardware targets found!"
    puts "1. Check if the FPGA board is connected via USB."
    puts "2. Check if the board power is ON."
    puts "3. Drivers might need installation."
    exit 1
}

# Open the first target found (usually index 0)
set target_idx 0
set target [lindex $targets $target_idx]
puts "Connecting to target: $target"

current_hw_target $target
open_hw_target

puts "\n\[STEP 4\] Identifying FPGA Device..."
# Scan devices on the target (JTAG chain)
set devices [get_hw_devices]
if {[llength $devices] == 0} {
    puts "ERROR: No devices found on the target."
    exit 1
}

# Usually the first device is the FPGA (xc7a35t in your case)
set device [lindex $devices 0]
set current_hw_device $device
puts "Found Device: $device"

# Refresh device to get ready
refresh_hw_device -update_hw_probes false $device

puts "\n\[STEP 5\] Programming FPGA..."
set_property PROGRAM.FILE $bitstream_file $device

# Program the device
if {[catch {
    program_hw_devices $device
} msg]} {
    puts "ERROR: Programming failed!"
    puts "Message: $msg"
    exit 1
}

puts "\n==========================================="
puts " [SUCCESS] FPGA Programmed Successfully! "
puts "==========================================="

# Clean up
close_hw_target
close_hw_manager
exit 0
