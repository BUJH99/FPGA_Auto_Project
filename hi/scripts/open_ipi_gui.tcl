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
set config_file "./build_config.tcl"

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

set src_files [glob -nocomplain ./src/*.v ./src/*.sv]
if {[llength $src_files] > 0} {
    puts "\[INFO\] Adding source files: [llength $src_files]"
    add_files -norecurse $src_files
}

set tb_files [glob -nocomplain ./tb/*.v ./tb/*.sv]
if {[llength $tb_files] > 0} {
    puts "\[INFO\] Adding testbench files: [llength $tb_files]"
    add_files -fileset sim_1 -norecurse $tb_files
}

set xdc_files [glob -nocomplain ./constrs/*.xdc]
if {[llength $xdc_files] > 0} {
    puts "\[INFO\] Adding XDC files: [llength $xdc_files]"
    add_files -fileset constrs_1 -norecurse $xdc_files
}

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
