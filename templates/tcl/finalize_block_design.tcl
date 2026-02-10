# =================================================================
# Finalize Block Design
# - Validate and save BD
# - Generate targets
# - Export BD HDL for non-project build (no wrapper generation)
# - Export IP XCI files for non-project build
# =================================================================

set part_number "xc7a35tcpg236-1"
set top_module "Top"
set power_limit 2.5
set bd_name "design_1"
set project_name "vivado_ipi"
set project_dir "./vivado_ipi"
set config_file "./tcl/project_build_config.tcl"

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

set bd_files [get_files -quiet "*${bd_name}.bd"]
if {[llength $bd_files] == 0} {
    puts "\[ERROR\] BD not found: $bd_name"
    exit 1
}

open_bd_design $bd_name
validate_bd_design
save_bd_design

puts "\[INFO\] Generating BD targets..."
generate_target all $bd_files

set src_dir [file normalize "./src"]
file mkdir $src_dir

set bd_dir [file dirname [lindex $bd_files 0]]
set bd_hdl [file join $bd_dir "hdl" "${bd_name}.v"]
if {[file exists $bd_hdl]} {
    file copy -force $bd_hdl $src_dir
    puts "\[INFO\] Exported BD HDL: $bd_hdl"
} else {
    puts "\[WARN\] BD HDL not found: $bd_hdl"
}

# Export IP XCI files for non-project flow
set ip_src_dir [file join $proj_path "${project_name}.srcs" "sources_1" "ip"]
if {[file isdirectory $ip_src_dir]} {
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

    set ip_dst_dir [file normalize "./ip"]
    file mkdir $ip_dst_dir
    set xci_files [collect_xci_files $ip_src_dir]
    foreach xci $xci_files {
        file copy -force $xci $ip_dst_dir
    }
    if {[llength $xci_files] > 0} {
        puts "\[INFO\] Exported IP files to ./ip"
    }
}

puts "\[INFO\] BD finalize complete. No wrapper generated."
