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
    puts "\[ERROR\] Usage: vivado -mode gui -source run_vivado_simulation.tcl -tclargs <project_root> <tb_top> ?<vivado_root>? ?<src_list>? ?<tb_list>? ?<inc_list>? ?<selected_tb_file>? ?<sim_more_options>? ?<prompt_request_file>? ?<prompt_close_file>? ?<prompt_keep_file>?"
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
set prompt_request_file ""
set prompt_close_file ""
set prompt_keep_file ""
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
set prompt_marker "__PROMPT_IPC__"
set prompt_marker_index -1
for {set i 8} {$i < [llength $argv]} {incr i} {
    if {[string equal [lindex $argv $i] $prompt_marker]} {
        set prompt_marker_index $i
        break
    }
}

if {$prompt_marker_index >= 0} {
    if {$prompt_marker_index > 7} {
        set sim_more_options [string trim [join [lrange $argv 7 [expr {$prompt_marker_index - 1}]] " "]]
    }
    if {[llength $argv] >= [expr {$prompt_marker_index + 2}]} {
        set a_req [string trim [lindex $argv [expr {$prompt_marker_index + 1}]]]
        if {$a_req ne ""} { set prompt_request_file [file normalize $a_req] }
    }
    if {[llength $argv] >= [expr {$prompt_marker_index + 3}]} {
        set a_close [string trim [lindex $argv [expr {$prompt_marker_index + 2}]]]
        if {$a_close ne ""} { set prompt_close_file [file normalize $a_close] }
    }
    if {[llength $argv] >= [expr {$prompt_marker_index + 4}]} {
        set a_keep [string trim [lindex $argv [expr {$prompt_marker_index + 3}]]]
        if {$a_keep ne ""} { set prompt_keep_file [file normalize $a_keep] }
    }
} else {
    set raw8 ""
    set raw9 ""
    set raw10 ""
    set raw11 ""
    if {[llength $argv] >= 8} {
        set raw8 [string trim [lindex $argv 7]]
    }
    if {[llength $argv] >= 9} {
        set raw9 [string trim [lindex $argv 8]]
    }
    if {[llength $argv] >= 10} {
        set raw10 [string trim [lindex $argv 9]]
    }
    if {[llength $argv] >= 11} {
        set raw11 [string trim [lindex $argv 10]]
    }

    # Backward/robust parsing when sim_more_options is split into two tokens
    # (e.g. "-testplusarg" and "TESTNAME=all").
    if {$raw8 ne ""} {
        set sim_more_options $raw8
    }
    if {$raw9 ne ""} {
        set raw9_is_plusarg_value [expr {[string first "=" $raw9] >= 0 && [string first "/" $raw9] < 0 && [string first "\\" $raw9] < 0}]
        if {$raw9_is_plusarg_value} {
            set sim_more_options [string trim "$sim_more_options $raw9"]
            if {$raw10 ne ""} { set prompt_request_file [file normalize $raw10] }
            if {$raw11 ne ""} { set prompt_close_file [file normalize $raw11] }
            if {[llength $argv] >= 12} {
                set raw12 [string trim [lindex $argv 11]]
                if {$raw12 ne ""} { set prompt_keep_file [file normalize $raw12] }
            }
        } else {
            set prompt_request_file [file normalize $raw9]
            if {$raw10 ne ""} { set prompt_close_file [file normalize $raw10] }
            if {$raw11 ne ""} { set prompt_keep_file [file normalize $raw11] }
        }
    }
}

# Recover broken tokenization from launcher paths:
# "-testplusarg TESTNAME all" -> "-testplusarg TESTNAME=all"
set smo_tokens [split [string trim $sim_more_options] " "]
if {[llength $smo_tokens] >= 3 && [string equal [lindex $smo_tokens 0] "-testplusarg"]} {
    set smo_key [lindex $smo_tokens 1]
    if {[string first "=" $smo_key] < 0} {
        set smo_val [lindex $smo_tokens 2]
        set merged [list "-testplusarg" "${smo_key}=${smo_val}"]
        if {[llength $smo_tokens] > 3} {
            set merged [concat $merged [lrange $smo_tokens 3 end]]
        }
        set sim_more_options [join $merged " "]
    }
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

proc wait_close_decision_from_terminal {sim_top request_file close_file keep_file} {
    if {$request_file eq "" || $close_file eq "" || $keep_file eq ""} {
        puts "\[WARNING\] Terminal prompt channel is not configured. Keeping Vivado GUI open."
        return 0
    }

    foreach stale_file [list $request_file $close_file $keep_file] {
        catch {file delete -force $stale_file}
    }

    if {[catch {
        set req_dir [file dirname $request_file]
        if {$req_dir ne "" && ![file exists $req_dir]} {
            file mkdir $req_dir
        }
        set fh [open $request_file w]
        puts $fh "ready"
        close $fh
    } request_err]} {
        puts "\[WARNING\] Failed to request terminal close prompt: $request_err"
        return 0
    }

    puts "\[INFO\] Waiting for close decision from terminal..."
    while {1} {
        if {[file exists $close_file]} { return 1 }
        if {[file exists $keep_file]} { return 0 }
        after 200
        catch {update}
    }
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

# Prevent default pre-run logs from launch_simulation; auto replay will run the full test.
if {[catch {set_property -name XSIM.SIMULATE.RUNTIME -value "0ns" -objects [get_filesets sim_1]} sim_runtime_err]} {
    puts "\[WARNING\] Failed to set initial simulation runtime to 0ns: $sim_runtime_err"
} else {
    puts "\[INFO\] Initial launch runtime set to 0ns (auto replay mode)"
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

puts "\[INFO\] Auto replay: restart + run all"
set auto_restart_ok 1
if {[catch {restart} restart_err]} {
    puts "\[WARNING\] Auto replay restart failed: $restart_err"
    set auto_restart_ok 0
}

set auto_run_all_ok 0
if {$auto_restart_ok} {
    if {[catch {run all} run_all_err]} {
        puts "\[WARNING\] Auto replay run all failed: $run_all_err"
    } else {
        puts "\[INFO\] Auto replay run all completed."
        set auto_run_all_ok 1
    }
}

if {$auto_run_all_ok} {
    set close_gui_by_user [wait_close_decision_from_terminal $sim_top $prompt_request_file $prompt_close_file $prompt_keep_file]
    if {$close_gui_by_user} {
        puts "\[INFO\] Closing Vivado GUI by user choice..."
        if {[catch {close_sim -force} close_sim_err]} {
            puts "\[WARNING\] Failed to close simulation before exit: $close_sim_err"
        }
        if {[catch {close_project} close_project_err]} {
            puts "\[WARNING\] Failed to close project before exit: $close_project_err"
        }
        puts "\[SUCCESS\] Auto replay completed. Closing Vivado GUI for top: $sim_top"
        exit
    }
    puts "\[SUCCESS\] Auto replay completed for top: $sim_top (GUI kept open by terminal choice)"
} else {
    puts "\[SUCCESS\] Vivado simulation launched and auto replay attempted for top: $sim_top (GUI kept open)"
}
