# =================================================================
# Vivado Full Automation Script (Non-Project Mode)
# Improved Log Readability & Formatting
# Feature: Multi-threading enabled based on CPU cores
# =================================================================

# -----------------------------------------------------------------
# Helper Procedures for Formatting
# -----------------------------------------------------------------
proc print_header {step_num title} {
    puts "\n"
    puts "#################################################################"
    puts "# STEP $step_num : $title"
    puts "#################################################################"
}

proc print_info {msg} {
    puts " \[INFO\] $msg"
}

proc print_check {param value unit status} {
    set color_reset "" 
    
    if {$status == "PASS"} {
        puts "    |-> CHECK: $param = $value $unit ... \[PASS\]"
    } else {
        puts "    |-> CHECK: $param = $value $unit ... \[FAIL\] !!!"
    }
}

proc print_error {msg} {
    puts "\n"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    puts " \[ERROR\] $msg"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

# -----------------------------------------------------------------
# 0. CPU Optimization (NEW FEATURE)
# -----------------------------------------------------------------
# Windows ???? ???????????????? ???????????? Vivado ???? ???????? ????
if {[info exists env(NUMBER_OF_PROCESSORS)]} {
    set cpu_count $env(NUMBER_OF_PROCESSORS)
    # Vivado ?????????? ???? 8?????? ????????????(Standard/Enterprise)
    set_param general.maxThreads $cpu_count
    print_info "CPU Optimization Enabled: Using $cpu_count threads."
} else {
    set_param general.maxThreads 8
    print_info "CPU Count detection failed. Defaulting to 8 threads."
}

# -----------------------------------------------------------------
# 1. Project and Hardware Settings
# -----------------------------------------------------------------
set project_name "auto_build_proj"
set part_number   "xc7a35tcpg236-1" ;# Targeted FPGA part
set top_module    "Top"             ;# Name of the Top Module
set base_output   "./output"
set dcp_dir       "$base_output/checkpoints"
set rpt_dir       "$base_output/reports"
set power_limit   2.5               ;# Power consumption limit (Watts)

# Optional config override
set config_file "./tcl/project_build_config.tcl"
if {[file exists $config_file]} {
    print_info "Loading build config: $config_file"
    source $config_file
}

# Ensure an in-memory project exists so IP generation uses the correct part
if {[llength [get_projects -quiet]] == 0} {
    create_project -in_memory -part $part_number
} else {
    set_property part $part_number [current_project]
}

# Create output directories
file mkdir $base_output
file mkdir $dcp_dir
file mkdir $rpt_dir

# -----------------------------------------------------------------
# 2. Loading Source Files
# -----------------------------------------------------------------
print_header 1 "Loading Source Files"

set v_files [glob -nocomplain ./src/*.v]
set sv_files [glob -nocomplain ./src/*.sv]
set xdc_files [glob -nocomplain ./constrs/*.xdc]

if {[llength $v_files] == 0 && [llength $sv_files] == 0} {
    print_error "No Verilog/SystemVerilog files (.v/.sv) found in ./src/ folder."
    exit 1
}

set total_src [expr {[llength $v_files] + [llength $sv_files]}]
print_info "Found $total_src HDL files (.v/.sv)."
if {[llength $xdc_files] > 0} {
    print_info "Found [llength $xdc_files] XDC files."
} else {
    print_info "WARNING: No XDC files found."
}

if {[catch {
    if {[llength $v_files] > 0} {
        read_verilog $v_files
    }
    if {[llength $sv_files] > 0} {
        read_verilog -sv $sv_files
    }
    if {[llength $xdc_files] > 0} {
        read_xdc $xdc_files
    }
} msg]} {
    print_error "Failed to read source files: $msg"
    exit 1
}

# Optional IP (.xci) support
set ip_files [glob -nocomplain ./ip/*.xci]
if {[llength $ip_files] > 0} {
    print_info "Found [llength $ip_files] IP files (.xci)."
    if {[catch {
        read_ip $ip_files
        generate_target all [get_ips]
        foreach ip [get_ips] { synth_ip $ip }
    } msg]} {
        print_error "Failed to process IP files: $msg"
        exit 1
    }
}

# -----------------------------------------------------------------
# 3. Synthesis
# -----------------------------------------------------------------
print_header 2 "Running Synthesis"
if {[catch {
    synth_design -top $top_module -part $part_number -flatten_hierarchy rebuilt
    write_checkpoint -force $dcp_dir/post_synth.dcp
    report_utilization -file $rpt_dir/post_synth_util.rpt
} msg]} {
    print_error "Synthesis failed. Check RTL errors above."
    exit 1
}
print_info "Synthesis completed successfully."

# -----------------------------------------------------------------
# 4. Logic Optimization
# -----------------------------------------------------------------
print_header 3 "Optimizing Design"
opt_design
print_info "Optimization completed."

# -----------------------------------------------------------------
# 5. Placement
# -----------------------------------------------------------------
print_header 4 "Running Placement"
if {[catch {
    place_design
    write_checkpoint -force $dcp_dir/post_place.dcp
    report_utilization -file $rpt_dir/post_place_util.rpt
} msg]} {
    print_error "Placement failed: $msg"
    exit 1
}
print_info "Placement completed successfully."

# -----------------------------------------------------------------
# 6. Routing
# -----------------------------------------------------------------
print_header 5 "Running Routing"
if {[catch {
    route_design
    write_checkpoint -force $dcp_dir/post_route.dcp
    report_route_status -file $rpt_dir/post_route_status.rpt
} msg]} {
    print_error "Routing failed: $msg"
    exit 1
}
print_info "Routing completed successfully."

# -----------------------------------------------------------------
# 7. Power Analysis
# -----------------------------------------------------------------
print_header 6 "Analyzing Power Consumption"
report_power -file $rpt_dir/power_report.rpt

# Parse Report
set total_power 0.0
set power_status "FAIL"
if {[file exists "$rpt_dir/power_report.rpt"]} {
    set pwr_file [open "$rpt_dir/power_report.rpt" r]
    while {[gets $pwr_file line] >= 0} {
        if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9\.]+)} $line match power_val]} {
            set total_power $power_val
            break
        }
    }
    close $pwr_file
}

if { $total_power <= $power_limit } {
    set power_status "PASS"
}

print_check "Total Power" $total_power "W" $power_status

if {$power_status == "FAIL"} {
    print_info "CRITICAL WARNING: Power limit ($power_limit W) exceeded!"
}

# -----------------------------------------------------------------
# 8. Timing Check
# -----------------------------------------------------------------
print_header 7 "Checking Timing Slack"
report_timing_summary -file $rpt_dir/timing_summary.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set timing_status "PASS"

if { $wns < 0 } {
    set timing_status "FAIL"
}

print_check "WNS (Worst Negative Slack)" $wns "ns" $timing_status

if {$timing_status == "FAIL"} {
    print_info "CRITICAL WARNING: Timing constraints violated!"
}

# -----------------------------------------------------------------
# 8. CDC (Clock Domain Crossing) Analysis
# -----------------------------------------------------------------
print_header 8 "Analyzing Clock Domain Crossings"

if {[catch {report_cdc -file $rpt_dir/cdc_report.rpt} msg]} {
    print_info "CDC analysis skipped."
} else {
    set cdc_violations 0
    if {[file exists "$rpt_dir/cdc_report.rpt"]} {
        set cdc_file [open "$rpt_dir/cdc_report.rpt" r]
        while {[gets $cdc_file line] >= 0} {
            if {[regexp -nocase {UNSAFE|UNKNOWN} $line]} { incr cdc_violations }
        }
        close $cdc_file
    }
    if {$cdc_violations > 0} {
        print_check "CDC Violations" $cdc_violations "paths" "FAIL"
    } else {
        print_check "CDC Violations" 0 "paths" "PASS"
    }
}

# -----------------------------------------------------------------
# 9. Final Verification and Bitstream
# -----------------------------------------------------------------
print_header 9 "Final Verification & Bitstream"

if { $power_status == "PASS" && $timing_status == "PASS" } {
    puts " \[SUCCESS\] All design requirements met."
    puts " \[ACTION\] Generating Bitstream..."
    
    write_bitstream -force $base_output/${top_module}.bit
    
    puts "\n"
    puts "*****************************************************************"
    puts "* *"
    puts "* BITSTREAM GENERATION SUCCESSFUL                              *"
    puts "* *"
    puts "*****************************************************************"
    puts " File: $base_output/${top_module}.bit"
    
} else {
    print_error "Design failed validation (Power or Timing). No bitstream generated."
    exit 1
}

exit 0
