# =================================================================
# Vivado GUI Simulation Launcher
# - Auto-create simulation project
# - Add all src/*.v, src/*.sv
# - Add all tb/*.v, tb/*.sv
# - Configure include dirs for headers (*.svh, *.vh)
# - Set selected TB module as sim top
# - Launch simulation in GUI
# =================================================================

set script_dir [file dirname [info script]]
set templates_root [file normalize [file join $script_dir ".." ".." ".." ".."]]

if {[llength $argv] < 2} {
    puts "\[ERROR\] Usage: vivado -mode gui -source run_vivado_simulation.tcl -tclargs <project_root> <tb_top> ?<vivado_root>? ?<src_list>? ?<tb_list>? ?<inc_list>? ?<selected_tb_file>? ?<sim_more_options>?"
    return -code error
}

set project_root [file normalize [lindex $argv 0]]
set sim_top [string trim [lindex $argv 1]]
if {[llength $argv] >= 3} {
    set vivado_root [file normalize [lindex $argv 2]]
} else {
    set vivado_root [file join $project_root "vivado_project"]
}
set src_list_file ""
set tb_list_file ""
set inc_list_file ""
set selected_tb_file ""
set sim_more_options ""
if {[llength $argv] >= 4} {
    set a3 [string trim [lindex $argv 3]]
    if {$a3 ne ""} { set src_list_file [file normalize $a3] }
}
if {[llength $argv] >= 5} {
    set a4 [string trim [lindex $argv 4]]
    if {$a4 ne ""} { set tb_list_file [file normalize $a4] }
}
if {[llength $argv] >= 6} {
    set a5 [string trim [lindex $argv 5]]
    if {$a5 ne ""} { set inc_list_file [file normalize $a5] }
}
if {[llength $argv] >= 7} {
    set a6 [string trim [lindex $argv 6]]
    if {$a6 ne ""} { set selected_tb_file [file normalize $a6] }
}
if {[llength $argv] >= 8} {
    set a7 [string trim [lindex $argv 7]]
    if {$a7 ne ""} { set sim_more_options $a7 }
}
file mkdir $vivado_root

if {$sim_top eq ""} {
    puts "\[ERROR\] Empty simulation top."
    return -code error
}

set part_number "xc7a35tcpg236-1"
set config_file [file join $templates_root "contexts" "vivado" "domain" "project_build_config.tcl"]
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
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

proc is_subpath {parent child} {
    set p [string map {"\\" "/"} [file normalize $parent]]
    set c [string map {"\\" "/"} [file normalize $child]]
    set p [string trimright $p "/"]
    if {[string equal -nocase $p $c]} {
        return 1
    }
    return [string match -nocase "${p}/*" $c]
}

set src_files [read_manifest_list $src_list_file $project_root]
set tb_files [read_manifest_list $tb_list_file $project_root]
if {$src_list_file eq "" || [llength $src_files] == 0} {
    puts "\[ERROR\] Manifest source list is required and cannot be empty."
    return -code error
}
if {$tb_list_file eq "" || [llength $tb_files] == 0} {
    puts "\[ERROR\] Manifest testbench list is required and cannot be empty."
    return -code error
}

set selected_tb_dir ""
if {$selected_tb_file ne "" && [file exists $selected_tb_file]} {
    set selected_tb_dir [file normalize [file dirname $selected_tb_file]]
    set scoped_tb_files {}
    foreach tbf $tb_files {
        if {[is_subpath $selected_tb_dir $tbf]} {
            lappend scoped_tb_files $tbf
        }
    }
    if {[llength $scoped_tb_files] > 0} {
        puts "\[INFO\] Applying TB scope filter by selected file folder: $selected_tb_dir"
        set tb_files [lsort -unique $scoped_tb_files]
    } else {
        puts "\[WARNING\] TB scope filter produced empty set; using full TB manifest list."
    }
}

set include_dirs {}
if {$inc_list_file ne "" && [file exists $inc_list_file] && [file size $inc_list_file] > 0} {
    foreach inc_entry [read_manifest_list $inc_list_file $project_root] {
        if {[file isdirectory $inc_entry]} {
            lappend include_dirs $inc_entry
        } elseif {[file exists $inc_entry]} {
            lappend include_dirs [file dirname $inc_entry]
        }
    }
}
set include_dirs [lsort -unique $include_dirs]

if {$selected_tb_dir ne ""} {
    set tb_root [file normalize [file join $project_root "tb"]]
    set scoped_inc_dirs {}
    foreach idir $include_dirs {
        if {![is_subpath $tb_root $idir] || [is_subpath $selected_tb_dir $idir]} {
            lappend scoped_inc_dirs $idir
        }
    }
    lappend scoped_inc_dirs $selected_tb_dir
    set include_dirs [lsort -unique $scoped_inc_dirs]
}

if {[llength $src_files] == 0} {
    puts "\[ERROR\] No HDL source files resolved from manifest."
    return -code error
}
if {[llength $tb_files] == 0} {
    puts "\[ERROR\] No testbench files resolved from manifest."
    return -code error
}

set safe_top [string map [list " " "_" "/" "_" "\\" "_" ":" "_" "*" "_" "?" "_" "\"" "_" "<" "_" ">" "_" "|" "_"] $sim_top]
if {$safe_top eq ""} {
    set safe_top "tb"
}

set work_dir [file join $vivado_root "project"]
file mkdir $work_dir
set wcfg_dir [file join $vivado_root "wcfg"]
file mkdir $wcfg_dir
set wcfg_file [file join $wcfg_dir "${safe_top}.wcfg"]
set project_name "sim_$safe_top"
set project_dir [file join $work_dir $project_name]

catch {close_sim -force}
catch {close_project}

puts "\[INFO\] Creating Vivado project: $project_name"
puts "\[INFO\] Project directory: $project_dir"
create_project -force $project_name $project_dir -part $part_number

puts "\[INFO\] Adding source files: [llength $src_files]"
add_files -norecurse $src_files

puts "\[INFO\] Adding testbench files: [llength $tb_files]"
add_files -fileset sim_1 -norecurse $tb_files

if {[llength $include_dirs] > 0} {
    puts "\[INFO\] Setting include dirs: [llength $include_dirs]"
    catch { set_property include_dirs $include_dirs [get_filesets sources_1] }
    catch { set_property include_dirs $include_dirs [get_filesets sim_1] }
}

update_compile_order -fileset sources_1

puts "\[INFO\] Setting simulation top: $sim_top"
if {[catch {set_property top $sim_top [get_filesets sim_1]} set_top_err]} {
    puts "\[ERROR\] Failed to set simulation top '$sim_top': $set_top_err"
    return -code error
}

if {$sim_more_options ne ""} {
    puts "\[INFO\] Setting xsim.more_options: $sim_more_options"
    if {[catch {set_property -name XSIM.SIMULATE.XSIM.MORE_OPTIONS -value $sim_more_options -objects [get_filesets sim_1]} sim_opt_err]} {
        puts "\[ERROR\] Failed to set xsim.more_options: $sim_opt_err"
        return -code error
    }
}

update_compile_order -fileset sim_1

puts "\[INFO\] Launching simulation GUI..."
if {[catch {launch_simulation} sim_err]} {
    puts "\[ERROR\] launch_simulation failed: $sim_err"
    return -code error
}

set wcfg_loaded 0
if {[file exists $wcfg_file]} {
    puts "\[INFO\] Loading waveform config: $wcfg_file"
    if {[catch {open_wave_config $wcfg_file} wcfg_open_err]} {
        puts "\[WARNING\] Failed to load waveform config: $wcfg_open_err"
    } else {
        set wcfg_loaded 1
    }
}

if {!$wcfg_loaded} {
    if {[catch {save_wave_config $wcfg_file} wcfg_save_err]} {
        puts "\[WARNING\] Failed to initialize waveform config path: $wcfg_save_err"
    } else {
        puts "\[INFO\] Initialized waveform config path: $wcfg_file"
    }
}

puts "\[SUCCESS\] Vivado simulation launched for top: $sim_top"
