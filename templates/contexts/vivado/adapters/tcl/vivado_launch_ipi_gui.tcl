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
set script_dir [file dirname [info script]]
set templates_root [file normalize [file join $script_dir ".." ".." ".." ".."]]
set config_file [file join $templates_root "contexts" "vivado" "domain" "project_build_config.tcl"]
set project_root [pwd]
set src_list_file ""
set tb_list_file ""
set xdc_list_file ""
if {[llength $argv] >= 1} {
    set a0 [string trim [lindex $argv 0]]
    if {$a0 ne ""} { set project_root [file normalize $a0] }
}
if {[llength $argv] >= 2} {
    set a1 [string trim [lindex $argv 1]]
    if {$a1 ne ""} { set src_list_file [file normalize $a1] }
}
if {[llength $argv] >= 3} {
    set a2 [string trim [lindex $argv 2]]
    if {$a2 ne ""} { set tb_list_file [file normalize $a2] }
}
if {[llength $argv] >= 4} {
    set a3 [string trim [lindex $argv 3]]
    if {$a3 ne ""} { set xdc_list_file [file normalize $a3] }
}

if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}

if {[file pathtype $project_dir] eq "absolute"} {
    set proj_path [file normalize $project_dir]
} else {
    set proj_path [file normalize [file join $project_root $project_dir]]
}
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

proc read_manifest_list {list_file project_root} {
    set out {}
    if {$list_file eq ""} { return $out }
    if {![file exists $list_file]} { return $out }
    if {[file size $list_file] == 0} { return $out }

    set fh [open $list_file r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[file pathtype $line] eq "absolute"} {
            set abs [file normalize $line]
        } else {
            set abs [file normalize [file join $project_root $line]]
        }
        lappend out $abs
    }
    close $fh
    return [lsort -unique $out]
}

set src_files [read_manifest_list $src_list_file $project_root]
if {$src_list_file eq "" || [llength $src_files] == 0} {
    puts "\[ERROR\] Manifest source list is required and cannot be empty."
    return -code error
}
add_missing_files sources_1 $src_files "source"

set tb_files [read_manifest_list $tb_list_file $project_root]
if {$tb_list_file eq "" || [llength $tb_files] == 0} {
    puts "\[ERROR\] Manifest testbench list is required and cannot be empty."
    return -code error
}
add_missing_files sim_1 $tb_files "testbench"

set xdc_files [read_manifest_list $xdc_list_file $project_root]
if {$xdc_list_file eq ""} {
    puts "\[WARN\] Manifest XDC list was not provided."
}
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
