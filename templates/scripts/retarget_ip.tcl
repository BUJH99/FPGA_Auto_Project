# =================================================================
# Retarget IP to the configured part and export .xci to ./ip
# =================================================================

set part_number "xc7a35tcpg236-1"
set project_name "vivado_ipi"
set project_dir "./vivado_ipi"
set config_file "./build_config.tcl"

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

set xci_files [glob -nocomplain -directory $ip_src_dir *.xci]
if {[llength $xci_files] == 0} {
    set xci_files [glob -nocomplain -directory $ip_src_dir * *.xci]
}

foreach xci $xci_files {
    file copy -force $xci $ip_dst_dir
}

if {[llength $xci_files] > 0} {
    puts "\[INFO\] Exported IP .xci to ./ip"
} else {
    puts "\[WARN\] No .xci files found to export."
}
