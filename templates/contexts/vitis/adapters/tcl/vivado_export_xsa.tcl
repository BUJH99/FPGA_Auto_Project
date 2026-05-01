proc truthy {value} {
    set normalized [string tolower [string trim $value]]
    return [expr {$normalized in {"1" "true" "yes" "y" "on"}}]
}

proc normalize_optional_path {value} {
    set raw [string trim $value]
    if {$raw eq ""} { return "" }
    return [file normalize $raw]
}

proc infer_impl_run_from_bit {bit_path} {
    set parts [file split [file normalize $bit_path]]
    set count [llength $parts]
    for {set idx 0} {$idx < $count - 1} {incr idx} {
        set part [string tolower [lindex $parts $idx]]
        if {[string match "*.runs" $part]} {
            return [lindex $parts [expr {$idx + 1}]]
        }
    }
    return "impl_1"
}

proc infer_vivado_project_from_bit {bit_path} {
    set current [file dirname [file normalize $bit_path]]
    for {set depth 0} {$depth < 10} {incr depth} {
        set matches [glob -nocomplain -directory $current *.xpr]
        if {[llength $matches] > 0} {
            return [file normalize [lindex [lsort $matches] 0]]
        }
        set parent [file dirname $current]
        if {$parent eq $current} { break }
        set current $parent
    }
    return ""
}

proc is_path_under {child parent} {
    set child_norm [string map {\\ /} [string tolower [file normalize $child]]]
    set parent_norm [string map {\\ /} [string tolower [file normalize $parent]]]
    if {$child_norm eq $parent_norm} { return 1 }
    append parent_norm "/"
    return [string match "${parent_norm}*" $child_norm]
}

set project_root [normalize_optional_path [lindex $argv 0]]
set xsa_path [normalize_optional_path [lindex $argv 1]]
set bit_path [normalize_optional_path [lindex $argv 2]]
set vivado_project [normalize_optional_path [lindex $argv 3]]
set impl_run [string trim [lindex $argv 4]]
set include_bitstream [truthy [lindex $argv 5]]
set fixed_shell [truthy [lindex $argv 6]]

if {$project_root eq "" || $xsa_path eq ""} {
    puts "\[ERROR\] Usage: vivado_export_xsa.tcl <project_root> <xsa_path> <bit_path> <vivado_project> <impl_run> <include_bitstream> <fixed>"
    exit 1
}

if {$include_bitstream && ($bit_path eq "" || ![file exists $bit_path])} {
    puts "\[ERROR\] Existing bitstream is required for XSA export: $bit_path"
    puts "\[ERROR\] Run the Vivado bitstream automation first, then re-run XSA export."
    exit 1
}

if {$bit_path ne ""} {
    if {$impl_run eq ""} {
        set impl_run [infer_impl_run_from_bit $bit_path]
    }
    if {$vivado_project eq ""} {
        set vivado_project [infer_vivado_project_from_bit $bit_path]
    }
}
if {$impl_run eq ""} {
    set impl_run "impl_1"
}

if {$vivado_project eq "" || ![file exists $vivado_project]} {
    puts "\[ERROR\] Vivado project (.xpr) is required for bit-based XSA export."
    puts "\[ERROR\] A raw .bit alone is not enough for write_hw_platform without regenerating a bitstream."
    puts "\[ERROR\] Configure vitis.xsa.vivado_project or choose a bitstream under a completed <project>.runs/<run>/ directory."
    exit 1
}

file mkdir [file dirname $xsa_path]

puts "\[INFO\] Opening Vivado project: $vivado_project"
open_project $vivado_project

set runs [get_runs -quiet $impl_run]
if {[llength $runs] == 0} {
    puts "\[ERROR\] Implementation run not found in project: $impl_run"
    exit 1
}

set run_dir [file normalize [get_property DIRECTORY [get_runs $impl_run]]]
if {$include_bitstream && $bit_path ne "" && ![is_path_under $bit_path $run_dir]} {
    puts "\[ERROR\] Selected bitstream is outside implementation run directory."
    puts "\[ERROR\]   bit : $bit_path"
    puts "\[ERROR\]   run : $run_dir"
    puts "\[ERROR\] Vivado write_hw_platform cannot consume an arbitrary .bit path without regenerating."
    exit 1
}

puts "\[INFO\] Opening completed implementation run: $impl_run"
open_run $impl_run

set write_args [list -force]
if {$fixed_shell} {
    lappend write_args -fixed
}
if {$include_bitstream} {
    lappend write_args -include_bit
}
lappend write_args $xsa_path

puts "\[INFO\] Running write_hw_platform {*}$write_args"
write_hw_platform {*}$write_args
puts "\[INFO\] XSA exported from existing bitstream/run: $xsa_path"
exit 0
