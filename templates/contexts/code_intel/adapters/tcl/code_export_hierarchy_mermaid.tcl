# =================================================================
# Vivado RTL Hierarchy Extractor (Pre-Synthesis)
# Purpose: Extract pure RTL hierarchy before synthesis optimization
# Output: output/rtl_hierarchy.mmd (Mermaid Graph)
# =================================================================

set project_root [pwd]
set src_list_file ""
if {[llength $argv] >= 1} {
    set a0 [string trim [lindex $argv 0]]
    if {$a0 ne ""} { set project_root [file normalize $a0] }
}
if {[llength $argv] >= 2} {
    set a1 [string trim [lindex $argv 1]]
    if {$a1 ne ""} { set src_list_file [file normalize $a1] }
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

# 1. Output Setup
set output_dir [file join $project_root "output"]
file mkdir $output_dir
set output_file [file join $output_dir "rtl_hierarchy.mmd"]
set fh [open $output_file w]

puts "\[INFO\] Starting RTL Hierarchy Extraction..."

# Optional config override
set part_number "xc7a35tcpg236-1"
set top_module "Top"
set script_dir [file dirname [info script]]
set templates_root [file normalize [file join $script_dir ".." ".." ".." ".."]]
set config_file [file join $templates_root "contexts" "vivado" "domain" "project_build_config.tcl"]
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}

# Ensure an in-memory project exists so IP generation uses the correct part
if {[llength [get_projects -quiet]] == 0} {
    create_project -in_memory -part $part_number
} else {
    set_property part $part_number [current_project]
}

# 2. Load Source Files
set v_files {}
set sv_files {}
set manifest_src_files [read_manifest_list $src_list_file $project_root]
foreach f $manifest_src_files {
    set ext [string tolower [file extension $f]]
    if {$ext eq ".v"} {
        lappend v_files $f
    } elseif {$ext eq ".sv"} {
        lappend sv_files $f
    }
}

if {$src_list_file eq "" || [llength $manifest_src_files] == 0} {
    puts "\[WARNING\] Manifest source list is empty. Skipping RTL hierarchy extraction."
    puts $fh "graph TD; Node\[No Source Found\];"
    close $fh
    exit 0
}

if {[llength $v_files] == 0 && [llength $sv_files] == 0} {
    puts "\[WARNING\] No source files found. Skipping RTL hierarchy extraction."
    puts $fh "graph TD; Node\[No Source Found\];"
    close $fh
    exit 0
}

# Read Sources
if {[llength $v_files] > 0} { read_verilog $v_files }
if {[llength $sv_files] > 0} { read_verilog -sv $sv_files }

# Optional IP (.xci) support
set ip_files [glob -nocomplain -directory [file join $project_root "ip"] *.xci]
if {[llength $ip_files] > 0} {
    puts "\[INFO\] Found [llength $ip_files] IP files (.xci)."
    read_ip $ip_files
    generate_target all [get_ips]
}

# 3. Elaborate Design (RTL Analysis)
# This creates the schematic view in memory without synthesizing
# We assume the top module name is set in config. If generic, Vivado auto-picks.
if {[catch {synth_design -rtl -top $top_module -part $part_number} err]} {
    puts "\[WARNING\] RTL Analysis failed: $err"
    # Fallback for generic top name if specified top fails
    synth_design -rtl -part $part_number
}

# 4. Generate Mermaid Graph
puts $fh "graph TD;"
puts $fh "    root\[\"$top_module\"\];"
puts $fh "    style root fill:#f3f4f6,stroke:#333,stroke-width:2px;"

# Recursive Helper to traverse cells
# Vivado 'get_cells' returns flat list, but names contain hierarchy (u_top/u_sub/u_leaf)
# We will iterate primitive=0 cells to show modules only.

set cells [get_cells -hierarchical -filter {IS_PRIMITIVE==0}]

# Sort by name length to process parents before children roughly, though not strictly needed
set cells [lsort $cells]

foreach cell $cells {
    set full_name [get_property NAME $cell]
    set ref_name  [get_property REF_NAME $cell]
    
    # Vivado uses '/' as separator
    set parts [split $full_name "/"]
    set depth [llength $parts]
    set self_name [lindex $parts end]
    
    # Create Safe ID (replace / with _)
    set safe_id [string map {"/" "_"} $full_name]
    
    # Determine Parent ID
    if {$depth == 1} {
        set parent_id "root"
    } else {
        # Parent is everything up to the last slash
        set parent_path [join [lrange $parts 0 end-1] "/"]
        set parent_id [string map {"/" "_"} $parent_path]
    }
    
    # Write to file: Parent --> Child
    # Use quotes for labels to prevent Syntax Error
    puts $fh "    $parent_id --> ${safe_id}\[\"${self_name}\"\];"
}

puts "\[INFO\] RTL Hierarchy saved to $output_file"
close $fh
