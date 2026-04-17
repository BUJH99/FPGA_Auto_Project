# =================================================================
# Vivado Hardware Target Discovery Script
# Lists connected hardware targets for the batch launcher
# =================================================================

set output_file ""
if {[info exists ::env(FPGA_HW_TARGETS_FILE)]} {
    set output_file $::env(FPGA_HW_TARGETS_FILE)
}

puts "\n\[STEP 1\] Connecting to Hardware Server..."
open_hw_manager
connect_hw_server -url localhost:3121

if {[catch {
    puts "Scanning for hardware targets..."
    refresh_hw_server
} msg]} {
    puts "ERROR: Failed to refresh hardware server. Is the cable connected?"
    close_hw_manager
    exit 1
}

puts "\n\[STEP 2\] Enumerating Hardware Targets..."
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "ERROR: No hardware targets found!"
    close_hw_manager
    exit 1
}

if {$output_file ne ""} {
    file mkdir [file dirname $output_file]
    set fh [open $output_file "w"]
    set idx 0
    foreach target $targets {
        puts $fh "${idx}|${target}"
        incr idx
    }
    close $fh
    puts "Wrote hardware target list to: $output_file"
}

set idx 0
foreach target $targets {
    puts "  \[$idx\] $target"
    incr idx
}

close_hw_manager
exit 0
