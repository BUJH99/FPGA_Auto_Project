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

set candidates {}
set selection_idx 0
set target_idx 0
foreach target $targets {
    puts "  Target \[$target_idx\] $target"
    current_hw_target $target
    if {[catch {
        open_hw_target
    } msg]} {
        puts "WARNING: Failed to open target \[$target_idx\]: $target"
        puts "         $msg"
        incr target_idx
        continue
    }

    set devices [get_hw_devices]
    if {[llength $devices] == 0} {
        puts "WARNING: No devices found on target \[$target_idx\]: $target"
        catch { close_hw_target }
        incr target_idx
        continue
    }

    set device_idx 0
    foreach device $devices {
        lappend candidates [list $selection_idx $target_idx $device_idx $target $device]
        incr selection_idx
        incr device_idx
    }

    catch { close_hw_target }
    incr target_idx
}

if {[llength $candidates] == 0} {
    puts "ERROR: No programmable hardware devices found!"
    close_hw_manager
    exit 1
}

if {$output_file ne ""} {
    file mkdir [file dirname $output_file]
    set fh [open $output_file "w"]
    foreach candidate $candidates {
        lassign $candidate candidate_idx candidate_target_idx candidate_device_idx candidate_target candidate_device
        puts $fh "${candidate_idx}|${candidate_target_idx}|${candidate_device_idx}|${candidate_target} -> ${candidate_device}"
    }
    close $fh
    puts "Wrote programmable hardware list to: $output_file"
}

puts "\n\[STEP 3\] Programmable Hardware Devices..."
foreach candidate $candidates {
    lassign $candidate candidate_idx candidate_target_idx candidate_device_idx candidate_target candidate_device
    puts "  \[$candidate_idx\] Target\[$candidate_target_idx\] ${candidate_target} -> Device\[$candidate_device_idx\] ${candidate_device}"
}

close_hw_manager
exit 0
