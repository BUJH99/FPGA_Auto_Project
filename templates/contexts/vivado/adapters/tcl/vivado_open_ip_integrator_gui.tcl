# =================================================================
# Open a Vivado IP Integrator project from manifest sources.
# - Project path: output/vivado/<project>_ipi/<project>_ipi.xpr
# - Adds RTL, TB, include dirs, and constraints from manifest lists
# - Uses manifest hdl.top and vivado.part values from the launch plan
# - Opens an existing BD or creates an empty design_1 for manual editing
# - Does not auto-create IP blocks or auto-connect BD interfaces
# =================================================================

set part_number "xczu3eg-sbva484-1-i"
set board_part ""
set top_module "TOP"
set bd_name "design_1"
set base_project_name "vivado"
set project_root [pwd]
set src_list_file ""
set tb_list_file ""
set xdc_list_file ""
set inc_list_file ""

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
if {[llength $argv] >= 5} {
    set a4 [string trim [lindex $argv 4]]
    if {$a4 ne ""} { set inc_list_file [file normalize $a4] }
}
if {[llength $argv] >= 6} {
    set a5 [string trim [lindex $argv 5]]
    if {$a5 ne ""} { set top_module $a5 }
}
if {[llength $argv] >= 7} {
    set a6 [string trim [lindex $argv 6]]
    if {$a6 ne ""} { set part_number $a6 }
}
if {[llength $argv] >= 8} {
    set a7 [string trim [lindex $argv 7]]
    if {$a7 ne ""} { set base_project_name $a7 }
}
if {[llength $argv] >= 9} {
    set a8 [string trim [lindex $argv 8]]
    if {$a8 ne ""} { set board_part $a8 }
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

set project_name "${base_project_name}_ipi"
set output_dir "output"
if {[info exists env(FPGA_CLAW_OUTPUT_DIR)] && [string trim $env(FPGA_CLAW_OUTPUT_DIR)] ne ""} {
    set output_dir [string trim $env(FPGA_CLAW_OUTPUT_DIR)]
}
if {[file pathtype $output_dir] eq "absolute"} {
    set output_root [file normalize $output_dir]
} else {
    set output_root [file normalize [file join $project_root $output_dir]]
}
set proj_path [file normalize [file join $output_root "vivado" $project_name]]
set xpr_path [file join $proj_path "${project_name}.xpr"]

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

proc apply_include_dirs {fileset_name inc_dirs} {
    if {[llength $inc_dirs] == 0} {
        return
    }

    set fs [get_filesets -quiet $fileset_name]
    if {[llength $fs] == 0} {
        puts "\[WARN\] Fileset not found for include_dirs: $fileset_name"
        return
    }

    if {[catch {set_property include_dirs $inc_dirs $fs} err]} {
        puts "\[WARN\] Failed to apply include_dirs to $fileset_name: $err"
        return
    }

    puts "\[INFO\] Applied include_dirs to $fileset_name: [llength $inc_dirs]"
}

proc find_project_bd_file {proj_path} {
    set candidates {}
    foreach f [get_files -quiet -all] {
        if {[string tolower [file extension $f]] eq ".bd"} {
            lappend candidates [file normalize $f]
        }
    }
    foreach f [glob -nocomplain [file join $proj_path "*.srcs" "sources_1" "bd" "*" "*.bd"]] {
        lappend candidates [file normalize $f]
    }
    set candidates [lsort -unique $candidates]
    if {[llength $candidates] == 0} {
        return ""
    }
    return [lindex $candidates 0]
}

if {[file exists $xpr_path]} {
    puts "\[INFO\] Opening IP Integrator project: $xpr_path"
    open_project $xpr_path
    if {$part_number ne ""} {
        catch { set_property part $part_number [current_project] }
    }
} else {
    puts "\[INFO\] Creating IP Integrator project: $xpr_path"
    create_project $project_name $proj_path -part $part_number -force
}
if {$part_number ne ""} {
    catch { set_property part $part_number [current_project] }
}
apply_board_part $board_part

set src_files [read_manifest_list $src_list_file $project_root]
if {$src_list_file eq "" || [llength $src_files] == 0} {
    puts "\[ERROR\] Manifest source list is required and cannot be empty."
    return -code error
}
add_missing_files sources_1 $src_files "source"

set inc_entries [read_manifest_list $inc_list_file $project_root]
set inc_dirs {}
foreach inc_entry $inc_entries {
    if {[file isdirectory $inc_entry]} {
        lappend inc_dirs $inc_entry
    } elseif {[file exists $inc_entry]} {
        lappend inc_dirs [file dirname $inc_entry]
    }
}
set inc_dirs [lsort -unique $inc_dirs]
if {$inc_list_file eq ""} {
    puts "\[WARN\] Manifest include list was not provided."
} elseif {[llength $inc_dirs] == 0} {
    puts "\[INFO\] No manifest include directories resolved."
} else {
    apply_include_dirs sources_1 $inc_dirs
}

set tb_files [read_manifest_list $tb_list_file $project_root]
if {$tb_list_file eq ""} {
    puts "\[INFO\] Manifest testbench list was not provided."
} elseif {[llength $tb_files] == 0} {
    puts "\[INFO\] No manifest testbench files resolved. Skipping sim_1 update."
} else {
    add_missing_files sim_1 $tb_files "testbench"
    if {[llength $inc_dirs] > 0} {
        apply_include_dirs sim_1 $inc_dirs
    }
    update_compile_order -fileset sim_1
}

set xdc_files [read_manifest_list $xdc_list_file $project_root]
if {$xdc_list_file eq ""} {
    puts "\[WARN\] Manifest XDC list was not provided."
}
add_missing_files constrs_1 $xdc_files "constraint"

update_compile_order -fileset sources_1
set source_fs [get_filesets -quiet sources_1]
if {[llength $source_fs] > 0 && $top_module ne ""} {
    set_property top $top_module $source_fs
    if {[catch {current_fileset -srcset $source_fs} err]} {
        puts "\[WARN\] Failed to select sources_1 as current source fileset: $err"
    }
    puts "\[INFO\] Set synthesis top on sources_1: $top_module"
}

set bd_file [find_project_bd_file $proj_path]
if {$bd_file ne "" && [file exists $bd_file]} {
    puts "\[INFO\] Opening existing block design: $bd_file"
    open_bd_design $bd_file
} else {
    puts "\[INFO\] Creating empty block design for manual IP Integrator editing: $bd_name"
    create_bd_design $bd_name
}

puts "\[INFO\] IP Integrator GUI is ready. Edit the BD manually, then save from Vivado."
