# =================================================================
# Vivado HTML Report Generator (Structured)
# - Parse Vivado text reports
# - Serialize to JSON artifact (output/FINALReport/report_data.json)
# - Export JS object payload (output/FINALReport/report_data.js)
# - Render HTML from external template/assets
# =================================================================

set script_dir [file dirname [info script]]
set project_root [pwd]
if {[llength $argv] >= 1} {
    set project_root [file normalize [lindex $argv 0]]
}

set output_dir [file normalize [file join $project_root "output"]]
set final_report_dir [file normalize [file join $output_dir "FINALReport"]]
set report_dir [file normalize [file join $output_dir "reports"]]
set time_file [file normalize [file join $report_dir "timing_summary.rpt"]]
set power_file [file normalize [file join $report_dir "power_report.rpt"]]
set util_file [file normalize [file join $report_dir "post_place_util.rpt"]]
set cdc_file [file normalize [file join $report_dir "cdc_report.rpt"]]

set json_file [file normalize [file join $final_report_dir "report_data.json"]]
set data_js_file [file normalize [file join $final_report_dir "report_data.js"]]
set html_file [file normalize [file join $final_report_dir "Final_Build_Report.html"]]
set wavedrom_file [file normalize [file join $final_report_dir "wavedrom_cases.json"]]
set legacy_wavedrom_file [file normalize [file join $output_dir "wavedrom_cases.json"]]
set diagram_assets_dir [file normalize [file join $final_report_dir "diagram_assets"]]

set asset_dir [file normalize [file join $script_dir ".." "report_assets"]]
set html_template_file "$asset_dir/final_build_report_template.html"
set css_asset "$asset_dir/final_build_report.css"
set js_asset "$asset_dir/final_build_report.js"
set css_output "$final_report_dir/final_build_report.css"
set js_output "$final_report_dir/final_build_report.js"

set gen_date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]

set top_module "Top"
set config_file [file join $script_dir "project_build_config.tcl"]
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}

array set timing_data {
    wns "N/A"
    tns "N/A"
    whs "N/A"
    ths "N/A"
    tpws "N/A"
    total_endpoints "N/A"
}

array set util_summary {
    luts_used "0"
    luts_avail "0"
    luts_perc "0"
    regs_used "0"
    regs_avail "0"
    regs_perc "0"
}

array set power_summary {
    total "0.000"
    dynamic "0.000"
    static "0.000"
    junction_temp "N/A"
    confidence "N/A"
    thermal_margin "N/A"
}

set util_io_list {}
set power_env_list {}
set wavedrom_payload {{"cases":[]}}

# CDC Analysis variables
set cdc_violations 0
set cdc_safe 0

set bitstream_status "FAIL"
set bitstream_path "N/A"
set bit_file [file normalize [file join $output_dir "${top_module}.bit"]]
if {[file exists $bit_file]} {
    set bitstream_status "SUCCESS"
    set bitstream_path $bit_file
}

set has_block_diagram 0
set block_diagram_rel ""
set detailed_svg_name "${top_module}_detailed.svg"
set simple_svg_name "${top_module}.svg"
set block_diagram_src ""

foreach f [glob -nocomplain [file join $output_dir "Diagram" "Detailed" "*.svg"]] {
    if {[string equal -nocase [file tail $f] $detailed_svg_name]} {
        set has_block_diagram 1
        set block_diagram_src $f
        break
    }
}

if {!$has_block_diagram} {
    foreach f [glob -nocomplain [file join $output_dir "Diagram" "Simple" "*.svg"]] {
        if {[string equal -nocase [file tail $f] $simple_svg_name]} {
            set has_block_diagram 1
            set block_diagram_src $f
            break
        }
    }
}

if {$has_block_diagram && $block_diagram_src ne "" && [file exists $block_diagram_src]} {
    file mkdir $diagram_assets_dir
    set block_diagram_name [file tail $block_diagram_src]
    file copy -force $block_diagram_src [file join $diagram_assets_dir $block_diagram_name]
    set block_diagram_rel "./diagram_assets/$block_diagram_name"
}

proc clean_val {val} {
    return [string trim $val]
}

proc get_float {val} {
    set v [string map {"<" "" ">" "" "," "" " " "" "W" "" "C" ""} $val]
    if {[string is double -strict $v]} {
        return $v
    }
    return 0.0
}

proc json_escape {val} {
    return [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $val]
}

proc html_escape {val} {
    return [string map [list "&" "&amp;" "<" "&lt;" ">" "&gt;" "\"" "&quot;" "'" "&#39;"] $val]
}

proc safe_lindex {items idx} {
    if {$idx < [llength $items]} {
        return [lindex $items $idx]
    }
    return ""
}

proc read_text_file {path} {
    set fp [open $path r]
    set txt [read $fp]
    close $fp
    return $txt
}

proc write_text_file {path content} {
    set fp [open $path w]
    puts -nonewline $fp $content
    close $fp
}

proc stage_diagram_asset {src_path assets_dir} {
    if {$src_path eq "" || ![file exists $src_path]} {
        return ""
    }
    file mkdir $assets_dir
    set dst_path [file join $assets_dir [file tail $src_path]]
    file copy -force $src_path $dst_path
    return "./diagram_assets/[file tail $src_path]"
}

proc move_if_exists {src_path dst_path} {
    if {![file exists $src_path]} {
        return
    }
    file mkdir [file dirname $dst_path]
    file copy -force $src_path $dst_path
    file delete -force $src_path
}

proc is_valid_wavedrom_payload {raw_json} {
    set txt [string trim $raw_json]
    if {$txt eq ""} {
        return 0
    }
    if {![regexp {^\s*\{.*\}\s*$} $txt]} {
        return 0
    }
    if {![regexp {"cases"\s*:\s*\[} $txt]} {
        return 0
    }
    return 1
}

# -----------------------------------------------------------------
# 1. Parse timing report
# -----------------------------------------------------------------
if {[file exists $time_file]} {
    set fp [open $time_file r]
    set section "NONE"
    while {[gets $fp line] >= 0} {
        if {[string match "*Design Timing Summary*" $line]} {
            set section "SUMMARY"
            continue
        }
        if {$section == "SUMMARY"} {
            if {[regexp {^\s*(-?[0-9\.]+)\s+(-?[0-9\.]+)\s+\S+\s+(\S+)\s+(-?[0-9\.]+)\s+(-?[0-9\.]+)\s+\S+\s+\S+\s+\S+\s+(-?[0-9\.]+)} $line -> wns tns total_eps whs ths tpws]} {
                set timing_data(wns) $wns
                set timing_data(tns) $tns
                set timing_data(total_endpoints) $total_eps
                set timing_data(whs) $whs
                set timing_data(ths) $ths
                set timing_data(tpws) $tpws
                set section "NONE"
            }
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# 2. Parse power report
# -----------------------------------------------------------------
if {[file exists $power_file]} {
    set fp [open $power_file r]
    set section "NONE"
    while {[gets $fp line] >= 0} {
        if {[string match "*1. Summary*" $line]} {
            set section "SUMMARY"
            continue
        }
        if {[string match "*2.1 Environment*" $line]} {
            set section "ENV"
            continue
        }

        if {[string match "|*" $line]} {
            set parts [split $line "|"]
            if {[llength $parts] < 3} {
                continue
            }
            set name [clean_val [safe_lindex $parts 1]]
            set val [clean_val [safe_lindex $parts 2]]

            if {$section == "SUMMARY"} {
                if {[string match "Total On-Chip Power*" $name]} { set power_summary(total) $val }
                if {[string match "Dynamic*" $name]} { set power_summary(dynamic) $val }
                if {[string match "Device Static*" $name]} { set power_summary(static) $val }
                if {[string match "Junction Temperature*" $name]} { set power_summary(junction_temp) $val }
                if {[string match "Confidence Level*" $name]} { set power_summary(confidence) $val }
                if {[string match "Thermal Margin*" $name]} { set power_summary(thermal_margin) $val }
            } elseif {$section == "ENV"} {
                if {$name ne "" && $name ne "Name" && ![string match "*Setting*" $name] && ![string match "*File*" $name]} {
                    lappend power_env_list [list $name $val]
                }
            }
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# 3. Parse utilization report
# -----------------------------------------------------------------
if {[file exists $util_file]} {
    set fp [open $util_file r]
    set section "NONE"
    while {[gets $fp line] >= 0} {
        if {[string match "*1. Slice Logic*" $line]} {
            set section "SLICE"
            continue
        }
        if {[string match "*5. IO and GT Specific*" $line]} {
            set section "IO"
            continue
        }
        if {[string match "|*" $line]} {
            set parts [split $line "|"]
            set p1 [clean_val [safe_lindex $parts 1]]
            set p2 [clean_val [safe_lindex $parts 2]]

            if {$section == "SLICE"} {
                if {[string match "*Slice LUTs*" $p1]} {
                    set util_summary(luts_used) $p2
                    set util_summary(luts_avail) [clean_val [safe_lindex $parts 5]]
                    set util_summary(luts_perc) [clean_val [safe_lindex $parts 6]]
                }
                if {[string match "*Slice Registers*" $p1]} {
                    set util_summary(regs_used) $p2
                    set util_summary(regs_avail) [clean_val [safe_lindex $parts 5]]
                    set util_summary(regs_perc) [clean_val [safe_lindex $parts 6]]
                }
            } elseif {$section == "IO"} {
                if {[string match "Bonded IOB*" $p1]} {
                    lappend util_io_list [list "Bonded IOB" $p2 [clean_val [safe_lindex $parts 5]] [clean_val [safe_lindex $parts 6]]]
                }
            }
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# 3.5 Parse CDC report
# -----------------------------------------------------------------
if {[file exists $cdc_file]} {
    set fp [open $cdc_file r]
    while {[gets $fp line] >= 0} {
        if {[regexp -nocase {UNSAFE|UNKNOWN} $line]} {
            incr cdc_violations
        }
        if {[regexp -nocase {SAFE} $line]} {
            incr cdc_safe
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# 3.7 Load WaveDrom case payload (optional)
# -----------------------------------------------------------------
if {[file exists $wavedrom_file]} {
    set raw_wave_json [string trim [read_text_file $wavedrom_file]]
    if {[is_valid_wavedrom_payload $raw_wave_json]} {
        set wavedrom_payload $raw_wave_json
    } elseif {$raw_wave_json ne ""} {
        puts "\[WARNING\] Invalid WaveDrom payload in $wavedrom_file. Using empty case list."
    }
} elseif {[file exists $legacy_wavedrom_file]} {
    file mkdir $final_report_dir
    file copy -force $legacy_wavedrom_file $wavedrom_file
    set raw_wave_json [string trim [read_text_file $wavedrom_file]]
    if {[is_valid_wavedrom_payload $raw_wave_json]} {
        set wavedrom_payload $raw_wave_json
    } elseif {$raw_wave_json ne ""} {
        puts "\[WARNING\] Invalid WaveDrom payload in $legacy_wavedrom_file. Using empty case list."
    }
}

# -----------------------------------------------------------------
# 3.6 Parse Source Modules (Descriptions)
# -----------------------------------------------------------------
set modules_list {}
set src_files [glob -nocomplain [file join $project_root "src" "*.v"] [file join $project_root "src" "*.sv"]]

foreach f $src_files {
    set fp [open $f r]
    set file_content [read $fp]
    close $fp
    
    # Try to find module name
    set module_name ""
    if {[regexp {(?n)^\s*module\s+(\w+)} $file_content -> mname]} {
        set module_name $mname
    } else {
        # Skip if not a module (e.g. package or header)
        continue 
    }

    # Try to extract top-level comments (Simple heuristic: Read first 30 lines)
    set description ""
    set lines [split $file_content "\n"]
    set max_lines 30
    set count 0
    foreach line $lines {
        incr count
        if {$count > $max_lines} break
        
        set trimmed [string trim $line]
        # Skip empty lines
        if {$trimmed eq ""} continue
        
        # Stop at module declaration
        if {[string match "module*" $trimmed]} break

        # Check for // comments
        if {[string match "//*" $trimmed]} {
            append description "[string range $trimmed 2 end] "
        } elseif {[string match "/*" $trimmed]} {
             # Multi-line start - simplify by just taking this line
             append description "[string range $trimmed 2 end] "
        } elseif {[string match "\\**" $trimmed] && ![string match "*/" $trimmed]} {
             # Continuation of multi-line (starts with *)
             append description "[string range $trimmed 1 end] "
        }
    }
    
    if {$description eq ""} {
        set description "No description available."
    }
    
    lappend modules_list [list $module_name [string trim $description] [file tail $f]]
}

# -----------------------------------------------------------------
# 4. Derive status
# -----------------------------------------------------------------
set wns_num [get_float $timing_data(wns)]
set timing_pass 0
if {$timing_data(wns) ne "N/A" && $wns_num >= 0} {
    set timing_pass 1
}

set build_status "FAIL"
if {$timing_pass && $bitstream_status eq "SUCCESS"} {
    set build_status "SUCCESS"
}

set status_class "status-fail"
if {$build_status eq "SUCCESS"} {
    set status_class "status-pass"
}

set has_block_diagram_json [expr {$has_block_diagram ? "true" : "false"}]

# -----------------------------------------------------------------
# 5. Serialize report data
# -----------------------------------------------------------------
set report_json "{"

append report_json "\"meta\":{"
append report_json "\"generatedAt\":\"[json_escape $gen_date]\","
append report_json "\"topModule\":\"[json_escape $top_module]\""
append report_json "},"

append report_json "\"status\":{"
append report_json "\"build\":\"[json_escape $build_status]\","
append report_json "\"timingPass\":$timing_pass,"
append report_json "\"bitstream\":\"[json_escape $bitstream_status]\","
append report_json "\"bitstreamPath\":\"[json_escape $bitstream_path]\""
append report_json "},"

append report_json "\"blockDiagram\":{"
append report_json "\"has\":$has_block_diagram_json,"
append report_json "\"path\":\"[json_escape $block_diagram_rel]\""
append report_json "},"

append report_json "\"cdc\":{"
append report_json "\"violations\":$cdc_violations,"
append report_json "\"safe\":$cdc_safe"
append report_json "},"

append report_json "\"modules\":\["
set mod_count [llength $modules_list]
for {set i 0} {$i < $mod_count} {incr i} {
    set row [lindex $modules_list $i]
    set m_name [lindex $row 0]
    
    # Check for Schematic (Detailed > Simple)
    set schem_path ""
    if {[file exists [file join $output_dir "Diagram" "Detailed" "${m_name}_detailed.svg"]]} {
        set schem_path [stage_diagram_asset [file join $output_dir "Diagram" "Detailed" "${m_name}_detailed.svg"] $diagram_assets_dir]
    } elseif {[file exists [file join $output_dir "Diagram" "Simple" "${m_name}.svg"]]} {
        set schem_path [stage_diagram_asset [file join $output_dir "Diagram" "Simple" "${m_name}.svg"] $diagram_assets_dir]
    }

    append report_json "{"
    append report_json "\"name\":\"[json_escape $m_name]\","
    append report_json "\"desc\":\"[json_escape [lindex $row 1]]\","
    append report_json "\"file\":\"[json_escape [lindex $row 2]]\","
    append report_json "\"schematic\":\"[json_escape $schem_path]\""
    append report_json "}"
    if {$i < ($mod_count - 1)} {
        append report_json ","
    }
}
append report_json "],"

append report_json "\"timing\":{"
append report_json "\"wns\":\"[json_escape $timing_data(wns)]\","
append report_json "\"tns\":\"[json_escape $timing_data(tns)]\","
append report_json "\"whs\":\"[json_escape $timing_data(whs)]\","
append report_json "\"ths\":\"[json_escape $timing_data(ths)]\","
append report_json "\"tpws\":\"[json_escape $timing_data(tpws)]\","
append report_json "\"totalEndpoints\":\"[json_escape $timing_data(total_endpoints)]\""
append report_json "},"

append report_json "\"power\":{"
append report_json "\"total\":\"[json_escape $power_summary(total)]\","
append report_json "\"dynamic\":\"[json_escape $power_summary(dynamic)]\","
append report_json "\"static\":\"[json_escape $power_summary(static)]\","
append report_json "\"junctionTemp\":\"[json_escape $power_summary(junction_temp)]\","
append report_json "\"confidence\":\"[json_escape $power_summary(confidence)]\","
append report_json "\"thermalMargin\":\"[json_escape $power_summary(thermal_margin)]\""
append report_json "},"

append report_json "\"utilization\":{"
append report_json "\"lutsUsed\":\"[json_escape $util_summary(luts_used)]\","
append report_json "\"lutsAvail\":\"[json_escape $util_summary(luts_avail)]\","
append report_json "\"lutsPerc\":\"[json_escape $util_summary(luts_perc)]\","
append report_json "\"regsUsed\":\"[json_escape $util_summary(regs_used)]\","
append report_json "\"regsAvail\":\"[json_escape $util_summary(regs_avail)]\","
append report_json "\"regsPerc\":\"[json_escape $util_summary(regs_perc)]\","
append report_json "\"io\":\["
set util_io_count [llength $util_io_list]
for {set i 0} {$i < $util_io_count} {incr i} {
    set row [lindex $util_io_list $i]
    append report_json "{"
    append report_json "\"name\":\"[json_escape [lindex $row 0]]\","
    append report_json "\"used\":\"[json_escape [lindex $row 1]]\","
    append report_json "\"avail\":\"[json_escape [lindex $row 2]]\","
    append report_json "\"perc\":\"[json_escape [lindex $row 3]]\""
    append report_json "}"
    if {$i < ($util_io_count - 1)} {
        append report_json ","
    }
}
append report_json "]"
append report_json "},"

append report_json "\"environment\":\["
set env_count [llength $power_env_list]
for {set i 0} {$i < $env_count} {incr i} {
    set row [lindex $power_env_list $i]
    append report_json "{"
    append report_json "\"name\":\"[json_escape [lindex $row 0]]\","
    append report_json "\"value\":\"[json_escape [lindex $row 1]]\""
    append report_json "}"
    if {$i < ($env_count - 1)} {
        append report_json ","
    }
}
append report_json "]"

append report_json ","
append report_json "\"wavedrom\":$wavedrom_payload"

append report_json "}"

file mkdir $output_dir
file mkdir $final_report_dir

write_text_file $json_file "$report_json\n"
puts "\[INFO\] Structured report data saved: $json_file"

set data_js "window.REPORT_DATA = $report_json;\n"
write_text_file $data_js_file $data_js
puts "\[INFO\] JS report object saved: $data_js_file"

# -----------------------------------------------------------------
# 6. Copy UI assets
# -----------------------------------------------------------------
set missing_assets 0
foreach pair [list [list $css_asset $css_output] [list $js_asset $js_output]] {
    set src [lindex $pair 0]
    set dst [lindex $pair 1]
    if {[file exists $src]} {
        file copy -force $src $dst
    } else {
        puts "\[WARNING\] Missing asset file: $src"
        set missing_assets 1
    }
}

# -----------------------------------------------------------------
# 7. Render final HTML from template
# -----------------------------------------------------------------
if {![file exists $html_template_file]} {
    puts "\[ERROR\] Missing HTML template: $html_template_file"
    exit 1
}

set template_html [read_text_file $html_template_file]
set final_html [string map [list \
    "__GENERATED_AT__" [html_escape $gen_date] \
    "__TOP_MODULE__" [html_escape $top_module] \
    "__STATUS_CLASS__" [html_escape $status_class] \
    "__BUILD_STATUS__" [html_escape $build_status] \
] $template_html]

write_text_file $html_file $final_html

if {$missing_assets} {
    puts "\[WARNING\] Report generated, but one or more UI assets were missing."
}

# -----------------------------------------------------------------
# 8. Migrate legacy report artifacts from output root
# -----------------------------------------------------------------
set legacy_json_file [file normalize [file join $output_dir "report_data.json"]]
set legacy_data_js_file [file normalize [file join $output_dir "report_data.js"]]
set legacy_html_file [file normalize [file join $output_dir "Final_Build_Report.html"]]
set legacy_css_file [file normalize [file join $output_dir "final_build_report.css"]]
set legacy_js_file [file normalize [file join $output_dir "final_build_report.js"]]
set legacy_diagram_assets [file normalize [file join $output_dir "diagram_assets"]]

if {$legacy_json_file ne $json_file} { move_if_exists $legacy_json_file $json_file }
if {$legacy_data_js_file ne $data_js_file} { move_if_exists $legacy_data_js_file $data_js_file }
if {$legacy_html_file ne $html_file} { move_if_exists $legacy_html_file $html_file }
if {$legacy_css_file ne $css_output} { move_if_exists $legacy_css_file $css_output }
if {$legacy_js_file ne $js_output} { move_if_exists $legacy_js_file $js_output }
if {$legacy_wavedrom_file ne $wavedrom_file} { move_if_exists $legacy_wavedrom_file $wavedrom_file }

if {[file exists $legacy_diagram_assets] && [string compare $legacy_diagram_assets $diagram_assets_dir] != 0} {
    file mkdir $diagram_assets_dir
    foreach old_asset [glob -nocomplain [file join $legacy_diagram_assets "*"]] {
        file copy -force $old_asset [file join $diagram_assets_dir [file tail $old_asset]]
    }
    file delete -force $legacy_diagram_assets
}

puts "Report Generated: $html_file"
