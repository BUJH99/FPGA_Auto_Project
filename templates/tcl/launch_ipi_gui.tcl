# =================================================================
# Open Vivado GUI with IP Integrator ready
# - Creates/opens a project
# - Adds sources/constraints/testbenches
# - Opens existing block design (does not create a new one)
# =================================================================

set part_number "xc7a35tcpg236-1"
set top_module "Top"
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

if {[file exists $xpr_path]} {
    puts "\[INFO\] Opening project: $xpr_path"
    open_project $xpr_path
} else {
    puts "\[INFO\] Creating project: $project_name"
    create_project $project_name $proj_path -part $part_number -force
}

proc add_missing_files {fileset_name file_list label} {
    if {[llength $file_list] == 0} {
        return
    }

    set fs [get_filesets -quiet $fileset_name]
    if {[llength $fs] == 0} {
        puts "\[WARN\] Fileset not found: $fileset_name"
        return
    }

    set existing {}
    foreach f [get_files -quiet -of_objects $fs] {
        set f_name [get_property NAME $f]
        if {$f_name ne ""} {
            lappend existing [file normalize $f_name]
        }
    }

    set to_add {}
    foreach f $file_list {
        set norm_f [file normalize $f]
        if {[lsearch -exact $existing $norm_f] < 0} {
            lappend to_add $f
        }
    }

    if {[llength $to_add] > 0} {
        puts "\[INFO\] Adding $label files: [llength $to_add]"
        add_files -fileset $fileset_name -norecurse $to_add
    } else {
        puts "\[INFO\] $label files already up to date."
    }
}

set src_files [glob -nocomplain ./src/*.v ./src/*.sv]
add_missing_files sources_1 $src_files "source"

set tb_files [glob -nocomplain ./tb/*.v ./tb/*.sv]
add_missing_files sim_1 $tb_files "testbench"

set xdc_files [glob -nocomplain ./constrs/*.xdc]
add_missing_files constrs_1 $xdc_files "constraint"

update_compile_order -fileset sources_1

set bd_file [file join $proj_path "${project_name}.srcs" "sources_1" "bd" $bd_name "${bd_name}.bd"]
if {[file exists $bd_file]} {
    puts "\[INFO\] Opening BD: $bd_name"
    open_bd_design $bd_name
} else {
    puts "\[WARN\] BD not found: $bd_name"
    puts "\[WARN\] Create a block design in the GUI if needed."
}

puts "\[INFO\] IP Integrator is ready in GUI."
