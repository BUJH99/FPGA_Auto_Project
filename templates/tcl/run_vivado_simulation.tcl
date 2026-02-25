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

if {[llength $argv] < 2} {
    puts "\[ERROR\] Usage: vivado -mode gui -source run_vivado_simulation.tcl -tclargs <project_root> <tb_top> ?<vivado_root>?"
    return -code error
}

set project_root [file normalize [lindex $argv 0]]
set sim_top [string trim [lindex $argv 1]]
if {[llength $argv] >= 3} {
    set vivado_root [file normalize [lindex $argv 2]]
} else {
    set vivado_root [file join $project_root "vivado_project"]
}
file mkdir $vivado_root

if {$sim_top eq ""} {
    puts "\[ERROR\] Empty simulation top."
    return -code error
}

set part_number "xc7a35tcpg236-1"
set config_file [file join $script_dir "project_build_config.tcl"]
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}

proc collect_hdl_files {root_dir} {
    set out {}
    if {![file exists $root_dir]} {
        return $out
    }

    foreach p [glob -nocomplain -directory $root_dir *] {
        if {[file isdirectory $p]} {
            set out [concat $out [collect_hdl_files $p]]
        } elseif {[file isfile $p]} {
            set ext [string tolower [file extension $p]]
            if {$ext eq ".v" || $ext eq ".sv"} {
                lappend out [file normalize $p]
            }
        }
    }

    return [lsort -unique $out]
}

proc collect_include_dirs {root_dir} {
    set out {}
    if {![file exists $root_dir]} {
        return $out
    }

    foreach p [glob -nocomplain -directory $root_dir *] {
        if {[file isdirectory $p]} {
            set nested [collect_include_dirs $p]
            if {[llength $nested] > 0} {
                set out [concat $out $nested]
            }
        } elseif {[file isfile $p]} {
            set ext [string tolower [file extension $p]]
            if {$ext eq ".svh" || $ext eq ".vh"} {
                lappend out [file normalize [file dirname $p]]
            }
        }
    }

    if {[llength [glob -nocomplain -directory $root_dir *.svh]] > 0 || [llength [glob -nocomplain -directory $root_dir *.vh]] > 0} {
        lappend out [file normalize $root_dir]
    }

    return [lsort -unique $out]
}

set src_dir [file join $project_root "src"]
set tb_dir [file join $project_root "tb"]
set include_dir [file join $project_root "include"]
set inc_dir [file join $project_root "inc"]

if {![file isdirectory $src_dir]} {
    puts "\[ERROR\] Missing src directory: $src_dir"
    return -code error
}
if {![file isdirectory $tb_dir]} {
    puts "\[ERROR\] Missing tb directory: $tb_dir"
    return -code error
}

set src_files [collect_hdl_files $src_dir]
set tb_files [collect_hdl_files $tb_dir]
set include_dirs [lsort -unique [concat [list [file normalize $src_dir] [file normalize $tb_dir]] [collect_include_dirs $src_dir] [collect_include_dirs $tb_dir] [collect_include_dirs $include_dir] [collect_include_dirs $inc_dir]]]

if {[llength $src_files] == 0} {
    puts "\[ERROR\] No HDL source files found in $src_dir"
    return -code error
}
if {[llength $tb_files] == 0} {
    puts "\[ERROR\] No testbench files found in $tb_dir"
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
