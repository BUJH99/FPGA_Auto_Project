# =================================================================
# Vivado RTL Hierarchy Extractor (Pre-Synthesis)
# Purpose: Extract pure RTL hierarchy before synthesis optimization
# Output: output/rtl_hierarchy.mmd (Mermaid Graph)
# =================================================================

# 1. Output Setup
file mkdir "./output"
set output_file "./output/rtl_hierarchy.mmd"
set fh [open $output_file w]

puts "\[INFO\] Starting RTL Hierarchy Extraction..."

# Optional config override
set part_number "xc7a35tcpg236-1"
set top_module "Top"
set config_file "./build_config.tcl"
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
# Try to find verilog files in current dir and standard src dirs
set v_files [glob -nocomplain "*.v" "./src/*.v" "./hdl/*.v" "./Sources/*.v"]
set sv_files [glob -nocomplain "*.sv" "./src/*.sv" "./hdl/*.sv" "./Sources/*.sv"]

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
set ip_files [glob -nocomplain ./ip/*.xci]
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
