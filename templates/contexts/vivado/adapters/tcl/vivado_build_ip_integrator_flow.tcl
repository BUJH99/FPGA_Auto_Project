# =================================================================
# Build a saved Vivado IP Integrator project.
# - Opens output/vivado/<project>_ipi/<project>_ipi.xpr
# - Validates and saves the selected BD
# - Generates BD output products and a top wrapper
# - Sets the wrapper as the synthesis top
# - Runs synth_1 and impl_1 through write_bitstream
# - Leaves the bitstream in <project>.runs/impl_1/*.bit
# =================================================================

set project_root [pwd]
set xpr_path ""
set requested_top_module ""
set requested_part_number ""
set requested_board_part ""

if {[llength $argv] >= 1} {
    set a0 [string trim [lindex $argv 0]]
    if {$a0 ne ""} { set project_root [file normalize $a0] }
}
if {[llength $argv] >= 2} {
    set a1 [string trim [lindex $argv 1]]
    if {$a1 ne ""} { set xpr_path [file normalize $a1] }
}
if {[llength $argv] >= 3} {
    set a2 [string trim [lindex $argv 2]]
    if {$a2 ne ""} { set requested_top_module $a2 }
}
if {[llength $argv] >= 4} {
    set a3 [string trim [lindex $argv 3]]
    if {$a3 ne ""} { set requested_part_number $a3 }
}
if {[llength $argv] >= 5} {
    set a4 [string trim [lindex $argv 4]]
    if {$a4 ne ""} { set requested_board_part $a4 }
}

proc print_error {msg} {
    puts "\[ERROR\] $msg"
}

proc apply_board_part {board_part} {
    set board_part [string trim $board_part]
    if {$board_part eq ""} { return }
    if {[catch {set matches [get_board_parts -quiet $board_part]} err] || [llength $matches] == 0} {
        puts "\[WARN\] Board part '$board_part' is not installed in Vivado. Continuing with part only."
        return
    }
    if {[catch {set_property board_part $board_part [current_project]} err]} {
        puts "\[WARN\] Failed to set board_part '$board_part': $err"
    } else {
        puts "\[INFO\] Board part set to $board_part"
    }
}

proc find_bd_files {project_dir} {
    set candidates {}
    foreach f [get_files -quiet -all] {
        if {[string tolower [file extension $f]] eq ".bd"} {
            lappend candidates [file normalize $f]
        }
    }
    foreach f [glob -nocomplain [file join $project_dir "*.srcs" "sources_1" "bd" "*" "*.bd"]] {
        lappend candidates [file normalize $f]
    }
    return [lsort -unique $candidates]
}

proc add_project_file_if_missing {fileset_name file_path label} {
    if {$file_path eq "" || ![file exists $file_path]} {
        return
    }
    set fs [get_filesets -quiet $fileset_name]
    if {[llength $fs] == 0} {
        puts "\[WARN\] Fileset not found: $fileset_name"
        return
    }
    set existing [get_files -quiet $file_path]
    if {[llength $existing] == 0} {
        puts "\[INFO\] Adding $label to $fileset_name: $file_path"
        add_files -fileset $fileset_name -norecurse $file_path
    }
}

proc wrapper_candidates_for_bd {bd_file} {
    set bd_dir [file dirname $bd_file]
    set rows {}
    foreach pattern [list \
        [file join $bd_dir "hdl" "*_wrapper.v"] \
        [file join $bd_dir "hdl" "*_wrapper.sv"] \
    ] {
        foreach f [glob -nocomplain $pattern] {
            lappend rows [file normalize $f]
        }
    }
    return [lsort -unique $rows]
}

if {$xpr_path eq ""} {
    print_error "Vivado project path argument is required."
    exit 1
}
if {![file exists $xpr_path]} {
    print_error "IP Integrator Vivado project not found: $xpr_path"
    print_error "Open menu 29 first, edit/save the BD in Vivado GUI, then run menu 30."
    exit 1
}

if {[info exists env(NUMBER_OF_PROCESSORS)]} {
    set jobs $env(NUMBER_OF_PROCESSORS)
    set_param general.maxThreads $jobs
} else {
    set jobs 8
}

puts "\[INFO\] Opening IP Integrator project: $xpr_path"
open_project $xpr_path
if {$requested_part_number ne ""} {
    catch { set_property part $requested_part_number [current_project] }
}
apply_board_part $requested_board_part

set project_dir [file dirname $xpr_path]
set bd_files [find_bd_files $project_dir]
if {[llength $bd_files] == 0} {
    print_error "No block design (.bd) found in project: $xpr_path"
    print_error "Open menu 29, create or save a BD in the Vivado GUI, then run this build again."
    exit 1
}

set bd_file [lindex $bd_files 0]
add_project_file_if_missing sources_1 $bd_file "block design"
set bd_obj [get_files -quiet $bd_file]
if {[llength $bd_obj] == 0} {
    set bd_obj $bd_file
}

puts "\[INFO\] Opening block design: $bd_file"
open_bd_design $bd_file

puts "\[RUN\] validate_bd_design"
validate_bd_design
save_bd_design

puts "\[RUN\] generate_target all"
generate_target all $bd_obj

puts "\[RUN\] make_wrapper -top"
set wrapper_result [make_wrapper -files $bd_obj -top]
set wrapper_files [wrapper_candidates_for_bd $bd_file]
foreach wrapper_file $wrapper_files {
    add_project_file_if_missing sources_1 $wrapper_file "BD wrapper"
}
if {[llength $wrapper_files] == 0 && [llength $wrapper_result] > 0} {
    foreach wrapper_file $wrapper_result {
        if {[file exists $wrapper_file]} {
            lappend wrapper_files [file normalize $wrapper_file]
            add_project_file_if_missing sources_1 $wrapper_file "BD wrapper"
        }
    }
}
set wrapper_files [lsort -unique $wrapper_files]
if {[llength $wrapper_files] == 0} {
    print_error "BD wrapper was not generated for: $bd_file"
    exit 1
}

set wrapper_top [file rootname [file tail [lindex $wrapper_files 0]]]
set source_fs [get_filesets -quiet sources_1]
if {[llength $source_fs] > 0} {
    set_property top $wrapper_top $source_fs
    current_fileset -srcset $source_fs
    puts "\[INFO\] Set synthesis top to BD wrapper: $wrapper_top"
}
update_compile_order -fileset sources_1

if {[llength [get_runs -quiet synth_1]] == 0} {
    print_error "synth_1 run is missing from the Vivado project."
    exit 1
}
if {[llength [get_runs -quiet impl_1]] == 0} {
    print_error "impl_1 run is missing from the Vivado project."
    exit 1
}

catch { reset_run impl_1 }
catch { reset_run synth_1 }

puts "\[RUN\] launch_runs synth_1"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set synth_progress [get_property PROGRESS [get_runs synth_1]]
if {$synth_progress ne "100%"} {
    print_error "synth_1 did not complete successfully. Status: [get_property STATUS [get_runs synth_1]]"
    exit 1
}

puts "\[RUN\] launch_runs impl_1 -to_step write_bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set impl_progress [get_property PROGRESS [get_runs impl_1]]
if {$impl_progress ne "100%"} {
    print_error "impl_1 did not complete successfully. Status: [get_property STATUS [get_runs impl_1]]"
    exit 1
}

set bit_files [glob -nocomplain [file join $project_dir "*.runs" "impl_1" "*.bit"]]
set bit_files [lsort -unique $bit_files]
if {[llength $bit_files] > 0} {
    puts "\[DONE\] Bitstream generated: [lindex $bit_files 0]"
} else {
    puts "\[WARN\] Build completed, but no bitstream was found under *.runs/impl_1."
}
