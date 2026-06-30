# =================================================================
# Retarget IP to the configured part and export .xci to ./ip
# =================================================================

set part_number "xczu3eg-sbva484-1-i"
set project_name "vivado_ipi"
set project_dir "./vivado_ipi"
set script_dir [file dirname [info script]]
set templates_root [file normalize [file join $script_dir ".." ".." ".." ".."]]
set config_file [file join $templates_root "contexts" "vivado" "domain" "project_build_config.tcl"]

if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}
if {[info exists env(FPGA_CLAW_PART)] && [string trim $env(FPGA_CLAW_PART)] ne ""} {
    set part_number [string trim $env(FPGA_CLAW_PART)]
}
if {[info exists env(FPGA_CLAW_BOARD_PART)] && [string trim $env(FPGA_CLAW_BOARD_PART)] ne ""} {
    set board_part [string trim $env(FPGA_CLAW_BOARD_PART)]
}

set proj_path [file normalize $project_dir]
set xpr_path [file join $proj_path "${project_name}.xpr"]

if {![file exists $xpr_path]} {
    puts "\[ERROR\] Project not found: $xpr_path"
    exit 1
}

open_project $xpr_path
set_property part $part_number [current_project]
puts "\[INFO\] Project part set to $part_number"
if {[info exists board_part] && [string trim $board_part] ne ""} {
    if {[catch {set matches [get_board_parts -quiet $board_part]} err] || [llength $matches] == 0} {
        puts "\[WARN\] Board part '$board_part' is not installed in Vivado. Continuing with part only."
    } elseif {[catch {set_property board_part $board_part [current_project]} err]} {
        puts "\[WARN\] Failed to set board_part '$board_part': $err"
    } else {
        puts "\[INFO\] Board part set to $board_part"
    }
}

set ips [get_ips]
if {[llength $ips] == 0} {
    puts "\[WARN\] No IP found in project."
    exit 0
}

upgrade_ip $ips
generate_target all $ips
foreach ip $ips { synth_ip $ip }

set ip_src_dir [file join $proj_path "${project_name}.srcs" "sources_1" "ip"]
set ip_dst_dir [file normalize "./ip"]
file mkdir $ip_dst_dir

proc collect_xci_files {dir} {
    set found {}
    if {![file isdirectory $dir]} {
        return $found
    }

    foreach item [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $item]} {
            set sub [collect_xci_files $item]
            if {[llength $sub] > 0} {
                set found [concat $found $sub]
            }
        } elseif {[string equal -nocase [file extension $item] ".xci"]} {
            lappend found $item
        }
    }
    return $found
}

set xci_files [collect_xci_files $ip_src_dir]

foreach xci $xci_files {
    file copy -force $xci $ip_dst_dir
}

if {[llength $xci_files] > 0} {
    puts "\[INFO\] Exported IP .xci to ./ip"
} else {
    puts "\[WARN\] No .xci files found to export."
}
