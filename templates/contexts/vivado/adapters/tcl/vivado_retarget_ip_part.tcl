# =================================================================
# Retarget IP to the configured part and export .xci to ./ip
# =================================================================

set part_number "xc7a35tcpg236-1"
set project_name "vivado_ipi"
set project_dir "./vivado_ipi"
set script_dir [file dirname [info script]]
set templates_root [file normalize [file join $script_dir ".." ".." ".." ".."]]
set config_file [file join $templates_root "contexts" "vivado" "domain" "project_build_config.tcl"]

if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
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
