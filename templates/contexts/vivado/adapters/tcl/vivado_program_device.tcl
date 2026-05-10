# =================================================================
# Vivado Hardware Manager Script
# Program the generated bitstream to the FPGA device without GUI
# =================================================================

set top_module "Top"
set script_dir [file dirname [info script]]
set templates_root [file normalize [file join $script_dir ".." ".." ".." ".."]]
set config_file [file join $templates_root "contexts" "vivado" "domain" "project_build_config.tcl"]
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}
if {[info exists ::env(FPGA_BITSTREAM_PATH)] && [string trim $::env(FPGA_BITSTREAM_PATH)] ne ""} {
    set bitstream_file [file normalize $::env(FPGA_BITSTREAM_PATH)]
} else {
    set bitstream_file [file normalize [file join "." "output" "${top_module}.bit"]]
}
set target_idx 0
if {[info exists ::env(FPGA_TARGET_INDEX)] && $::env(FPGA_TARGET_INDEX) ne ""} {
    if {![string is integer -strict $::env(FPGA_TARGET_INDEX)] || $::env(FPGA_TARGET_INDEX) < 0} {
        puts "ERROR: FPGA_TARGET_INDEX must be a non-negative integer."
        exit 1
    }
    set target_idx $::env(FPGA_TARGET_INDEX)
}

set device_idx 0
if {[info exists ::env(FPGA_DEVICE_INDEX)] && $::env(FPGA_DEVICE_INDEX) ne ""} {
    if {![string is integer -strict $::env(FPGA_DEVICE_INDEX)] || $::env(FPGA_DEVICE_INDEX) < 0} {
        puts "ERROR: FPGA_DEVICE_INDEX must be a non-negative integer."
        exit 1
    }
    set device_idx $::env(FPGA_DEVICE_INDEX)
}

puts "\n\[STEP 1\] Checking Bitstream File..."
if { ![file exists $bitstream_file] } {
    puts "ERROR: Bitstream file not found at $bitstream_file"
    puts "Please run vivado_build_flow_run.bat (or run_vivado_build_flow.tcl) first."
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

puts "Discovered [llength $targets] hardware target(s):"
set discovered_idx 0
foreach discovered_target $targets {
    puts "  \[$discovered_idx\] $discovered_target"
    incr discovered_idx
}

if {$target_idx >= [llength $targets]} {
    puts "ERROR: Selected target index $target_idx is out of range."
    exit 1
}

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

puts "Discovered [llength $devices] device(s) on target:"
set discovered_device_idx 0
foreach discovered_device $devices {
    puts "  \[$discovered_device_idx\] $discovered_device"
    incr discovered_device_idx
}

if {$device_idx >= [llength $devices]} {
    puts "ERROR: Selected device index $device_idx is out of range."
    exit 1
}

set device [lindex $devices $device_idx]
current_hw_device $device
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
puts " \[SUCCESS\] FPGA Programmed Successfully! "
puts "==========================================="

# Clean up
close_hw_target
close_hw_manager
exit 0
