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
    puts " [ERROR] $msg"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

# -----------------------------------------------------------------
# 0. CPU Optimization (NEW FEATURE)
# -----------------------------------------------------------------
# Windows 환경 변수에서 프로세서 개수를 가져와 Vivado 최대 쓰레드로 설정
if {[info exists env(NUMBER_OF_PROCESSORS)]} {
    set cpu_count $env(NUMBER_OF_PROCESSORS)
    # Vivado 버전에 따라 최대 8개 또는 그 이상을 지원 (Standard/Enterprise)
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
set config_file "./build_config.tcl"
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
set xdc_files [glob -nocomplain ./constrs/*.xdc]

if {[llength $v_files] == 0} {
    print_error "No Verilog files (.v) found in ./src/ folder."
    exit 1
}

print_info "Found [llength $v_files] Verilog files."
if {[llength $xdc_files] > 0} {
    print_info "Found [llength $xdc_files] XDC files."
} else {
    print_info "WARNING: No XDC files found."
}

if {[catch {
    read_verilog $v_files
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
# 9. Final Verification and Bitstream
# -----------------------------------------------------------------
print_header 8 "Final Verification & Bitstream"

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
