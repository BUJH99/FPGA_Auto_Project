# =================================================================
# Vivado High-End HTML Report Generator
# Updates: 
#   1. Robust Float Parsing (Fixes "report not generated" issue)
#   2. Safe Calculation Logic (Catch errors in percentages)
# =================================================================

set output_dir "./output"
set report_dir "$output_dir/reports"
# Priority 1: RTL Analysis Result (Mermaid File)
set rtl_mermaid_file "$output_dir/rtl_hierarchy.mmd"
# Priority 2: Standard Reports (Fallback)
set power_file "$report_dir/power_report.rpt"
set html_file "$output_dir/Final_Build_Report.html"
set gen_date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]

# Optional config override
set top_module "Top"
set config_file "./build_config.tcl"
if {[file exists $config_file]} {
    puts "\[INFO\] Loading build config: $config_file"
    source $config_file
}

# -----------------------------------------------------------------
# Data Holders
# -----------------------------------------------------------------
array set timing_data {wns "0.000" tns "0.000" whs "0.000" ths "0.000" tpws "0.000" total_endpoints "0"}
array set power_summary {total "0.000" dynamic "0.000" static "0.000" junction_temp "0.0" confidence "Low" thermal_margin "N/A"}
array set util_summary {luts_used "0" luts_avail "1" luts_perc "0" regs_used "0" regs_avail "1" regs_perc "0"}
# Detailed Power Components
array set power_components {Clocks "0.000" Signals "0.000" Logic "0.000" IO "0.000" BRAM "0.000" DSP "0.000" MMCM "0.000"}

set clock_summary_list {}
set power_env_list {}
set primitives_list {}
set util_io_list {}
set bitstream_status "FAIL"
set bitstream_path "N/A"

# Hierarchy Data
set mermaid_graph "graph TD;\n"
set parents(0) "Top"
set has_hierarchy 0

set bit_file "$output_dir/${top_module}.bit"
if {[file exists $bit_file]} {
    set bitstream_status "SUCCESS"
    set bitstream_path $bit_file
}

proc clean_val {val} { return [string trim $val] }

# STRICT ID SANITIZATION
proc sanitize_id {name} {
    set clean [string map {" " "_" "[" "_" "]" "_" "(" "_" ")" "_" "/" "_" "." "_"} $name]
    set clean [regsub -all {[^a-zA-Z0-9_]} $clean ""]
    if {[regexp {^[0-9]} $clean]} { set clean "n_$clean" }
    return $clean
}

# ROBUST FLOAT PARSER (Fixes crash on "N/A" or empty strings)
proc get_float {val} {
    # Remove common non-numeric chars
    set val [string map {"<" "" ">" "" " " "" "W" ""} $val]
    # Check if it looks like a number
    if {[string is double $val]} {
        return $val
    }
    return 0.0
}

# -----------------------------------------------------------------
# 1. LOAD HIERARCHY
# -----------------------------------------------------------------
if {[file exists $rtl_mermaid_file]} {
    puts "\[INFO\] Using RTL Hierarchy file: $rtl_mermaid_file"
    set fp [open $rtl_mermaid_file r]
    set mermaid_graph [read $fp]
    close $fp
    set has_hierarchy 1
} else {
    if {[file exists $power_file]} {
        set fp [open $power_file r]
        set section "NONE"
        while {[gets $fp line] >= 0} {
            if {[string match "*3.1 By Hierarchy*" $line] || [string match "*1. Hierarchical*" $line]} { 
                set section "HIER"
                continue 
            }
            if {[string match "*2.1 Environment*" $line]} { set section "NONE"; continue }

            if {$section == "HIER"} {
                if {[string match "|*" $line] && ![string match "*| Name |*" $line] && ![string match "*-----*" $line]} {
                    set parts [split $line "|"]
                    if {[llength $parts] < 3} continue
                    set raw_name [lindex $parts 1]
                    set name [string trim $raw_name]
                    
                    if {$name == "" || $name == "Name" || [string match "Total*" $name] || [string match "Power*" $name]} { continue }

                    set indent_count 0
                    set len [string length $raw_name]
                    for {set i 0} {$i < $len} {incr i} {
                        if {[string index $raw_name $i] != " "} { break }
                        incr indent_count
                    }
                    set level [expr {($indent_count - 1) / 2}]
                    if {$level < 0} { set level 0 }
                    
                    set parents($level) $name
                    set clean_node_id [sanitize_id $name]
                    set clean_label [string map {"[" "" "]" ""} $name]

                    if {$level > 0} {
                        set parent_level [expr {$level - 1}]
                        set parent_name $parents($parent_level)
                        set clean_parent_id [sanitize_id $parent_name]
                        if {$clean_parent_id != $clean_node_id} {
                            append mermaid_graph "    $clean_parent_id\[\"$parent_name\"\] --> $clean_node_id\[\"$clean_label\"\];\n"
                        }
                    } else {
                        append mermaid_graph "    style $clean_node_id fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px;\n"
                        append mermaid_graph "    $clean_node_id\[\"$clean_label\"\];\n"
                    }
                    set has_hierarchy 1
                }
            }
        }
        close $fp
    }
}

# -----------------------------------------------------------------
# 2. PARSE TIMING
# -----------------------------------------------------------------
set time_file "$report_dir/timing_summary.rpt"
if {[file exists $time_file]} {
    set fp [open $time_file r]
    set section "NONE"
    while {[gets $fp line] >= 0} {
        if {[string match "*Design Timing Summary*" $line]} { set section "SUMMARY"; continue }
        if {$section == "SUMMARY"} {
            if {[regexp {^\s*(-?[0-9\.]+)\s+(-?[0-9\.]+)\s+\S+\s+(\S+)\s+(-?[0-9\.]+)\s+(-?[0-9\.]+)\s+\S+\s+\S+\s+\S+\s+(-?[0-9\.]+)} $line match wns tns total_eps whs ths tpws]} {
                set timing_data(wns) $wns; set timing_data(tns) $tns; set timing_data(total_endpoints) $total_eps
                set timing_data(whs) $whs; set timing_data(ths) $ths; set timing_data(tpws) $tpws; set section "NONE"
            }
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# 3. PARSE POWER & ENV
# -----------------------------------------------------------------
if {[file exists $power_file]} {
    set fp [open $power_file r]
    set section "NONE"
    while {[gets $fp line] >= 0} {
        if {[string match "*1. Summary*" $line]} { set section "SUMMARY"; continue }
        if {[string match "*1.1 On-Chip Components*" $line]} { set section "ONCHIP"; continue }
        if {[string match "*2.1 Environment*" $line]} { set section "ENV"; continue }
        
        if {[string match "|*" $line]} {
            set parts [split $line "|"]
            if {[llength $parts] < 3} continue
            set name [string trim [lindex $parts 1]]
            set val [string trim [lindex $parts 2]]

            if {$section == "SUMMARY"} {
                if {[string match "Total On-Chip Power*" $name]} { set power_summary(total) $val }
                if {[string match "Dynamic*" $name]} { set power_summary(dynamic) $val }
                if {[string match "Device Static*" $name]} { set power_summary(static) $val }
                if {[string match "Junction Temperature*" $name]} { set power_summary(junction_temp) $val }
                if {[string match "Confidence Level*" $name]} { set power_summary(confidence) $val }
                if {[string match "Thermal Margin*" $name]} { set power_summary(thermal_margin) $val }
            } elseif {$section == "ONCHIP"} {
                if {[string match "Clocks*" $name]} { set power_components(Clocks) $val }
                if {[string match "Signals*" $name]} { set power_components(Signals) $val }
                if {[string match "Slice Logic*" $name]} { set power_components(Logic) $val }
                if {[string match "I/O*" $name]} { set power_components(IO) $val }
                if {[string match "Block RAM*" $name]} { set power_components(BRAM) $val }
                if {[string match "DSPs*" $name]} { set power_components(DSP) $val }
                if {[string match "MMCM*" $name]} { set power_components(MMCM) $val }
            } elseif {$section == "ENV"} {
                if {![string match "*Setting*" $name] && ![string match "*File*" $name] && $name != "Name" && $name != ""} {
                    lappend power_env_list [list $name $val] 
                }
            }
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# 4. PARSE UTILIZATION
# -----------------------------------------------------------------
set util_file "$report_dir/post_place_util.rpt"
if {[file exists $util_file]} {
    set fp [open $util_file r]
    set section "NONE"
    while {[gets $fp line] >= 0} {
        if {[string match "*1. Slice Logic*" $line]} { set section "SLICE"; continue }
        if {[string match "*5. IO and GT Specific*" $line]} { set section "IO"; continue }
        if {[string match "|*" $line]} {
            set parts [split $line "|"]
            set p1 [clean_val [lindex $parts 1]]; set p2 [clean_val [lindex $parts 2]]
            if {$section == "SLICE"} {
                if {[string match "*Slice LUTs*" $p1]} { 
                    set util_summary(luts_used) $p2; set util_summary(luts_avail) [clean_val [lindex $parts 5]]; set util_summary(luts_perc) [clean_val [lindex $parts 6]]
                }
                if {[string match "*Slice Registers*" $p1]} { 
                    set util_summary(regs_used) $p2; set util_summary(regs_avail) [clean_val [lindex $parts 5]]; set util_summary(regs_perc) [clean_val [lindex $parts 6]]
                }
            } elseif {$section == "IO"} {
                if {[string match "Bonded IOB*" $p1]} { 
                    lappend util_io_list [list "Bonded IOB" $p2 [clean_val [lindex $parts 5]] [clean_val [lindex $parts 6]]] 
                }
            }
        }
    }
    close $fp
}

# -----------------------------------------------------------------
# CALCULATION & SAFETY LOGIC
# -----------------------------------------------------------------
set total_p [get_float $power_summary(total)]
set dyn_p [get_float $power_summary(dynamic)]
set sta_p [get_float $power_summary(static)]

if {$total_p <= 0} { set total_p 0.001 }

# Safe percentage calculation
set dyn_perc 0
set sta_perc 0
if {[catch {set dyn_perc [expr {round(($dyn_p / $total_p) * 100)}]}]} { set dyn_perc 0 }
if {[catch {set sta_perc [expr {100 - $dyn_perc}]}]} { set sta_perc 0 }

# Component Perc
array set comp_perc {}
foreach {comp val} [array get power_components] {
    set fval [get_float $val]
    set p 0
    if {[catch {set p [expr {round(($fval / $total_p) * 100)}]}]} { set p 0 }
    set comp_perc($comp) $p
    
    # Visual tweak for small non-zero values
    if {$fval > 0 && $comp_perc($comp) == 0} { set comp_perc($comp) "<1" }
}

# -----------------------------------------------------------------
# 5. GENERATE HTML
# -----------------------------------------------------------------
set fh [open $html_file w]
set wns_status "PASS"
if {$timing_data(wns) != "N/A" && $timing_data(wns) < 0} { set wns_status "FAIL" }

puts $fh "<!DOCTYPE html>"
puts $fh "<html lang='ko'>"
puts $fh "<head>"
puts $fh "    <meta charset='utf-8'>"
puts $fh "    <meta name='viewport' content='width=device-width, initial-scale=1.0'>"
puts $fh "    <title>FPGA Build Report</title>"
puts $fh "    <script src='https://cdn.tailwindcss.com'></script>"
puts $fh "    <link href='https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css' rel='stylesheet'>"
puts $fh "    <link href='https://fonts.googleapis.com/css2?family=Noto+Sans+KR:wght@300;400;500;700;900&display=swap' rel='stylesheet'>"
puts $fh "    <script src='https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js'></script>"
puts $fh "    <script>mermaid.initialize({startOnLoad:true, theme:'neutral'});</script>"
puts $fh "    <style>"
puts $fh "        body { font-family: 'Noto Sans KR', sans-serif; background-color: #f3f4f6; color: #1f2937; }"
puts $fh "        .bar-stack { transition: height 0.5s ease-in-out; }"
puts $fh "    </style>"
puts $fh "</head>"
puts $fh "<body class='flex justify-center min-h-screen py-10 px-4 bg-gray-100'>"
puts $fh "    <div class='w-full max-w-6xl space-y-6'>"

# Header
puts $fh "        <div class='flex justify-between items-end pb-6'>"
puts $fh "            <div>"
puts $fh "                <div class='flex items-center gap-3 mb-2'>"
puts $fh "                    <span class='bg-blue-100 text-blue-700 px-3 py-1 rounded-full text-xs font-bold tracking-wider'>VIVADO BUILD</span>"
puts $fh "                    <span class='text-gray-400 text-xs'>$gen_date</span>"
puts $fh "                </div>"
puts $fh "                <h1 class='text-4xl font-black text-gray-800 leading-tight'>Build <span class='text-blue-600'>Report</span></h1>"
puts $fh "            </div>"
if {$wns_status == "PASS" && $bitstream_status == "SUCCESS"} {
    puts $fh "            <div class='text-3xl font-black text-green-500'><i class='fas fa-check-circle mr-2'></i>SUCCESS</div>"
} else {
    puts $fh "            <div class='text-3xl font-black text-red-500'><i class='fas fa-times-circle mr-2'></i>FAIL</div>"
}
puts $fh "        </div>"

# KPI Cards
set wns_color [expr {$timing_data(wns) < 0 ? "text-red-600" : "text-gray-800"}]
puts $fh "        <div class='grid grid-cols-1 md:grid-cols-3 gap-6'>"
puts $fh "            <div class='bg-white p-6 rounded-2xl shadow-sm border border-gray-100'><div class='text-xs font-bold text-gray-400 mb-2'>TIMING (WNS)</div><h3 class='text-2xl font-bold $wns_color'>$timing_data(wns) <span class='text-sm text-gray-400'>ns</span></h3></div>"
puts $fh "            <div class='bg-white p-6 rounded-2xl shadow-sm border border-gray-100'><div class='text-xs font-bold text-gray-400 mb-2'>TOTAL POWER</div><h3 class='text-2xl font-bold text-gray-800'>$power_summary(total) <span class='text-sm text-gray-400'>W</span></h3></div>"
puts $fh "            <div class='bg-white p-6 rounded-2xl shadow-sm border border-gray-100'><div class='text-xs font-bold text-gray-400 mb-2'>UTILIZATION</div><h3 class='text-2xl font-bold text-gray-800'>$util_summary(luts_perc)<span class='text-sm text-gray-400'>%</span></h3></div>"
puts $fh "        </div>"

# System Hierarchy
puts $fh "        <div class='bg-white rounded-2xl shadow-sm border border-gray-200 p-6'>"
puts $fh "            <h3 class='text-lg font-bold text-gray-800 mb-6'><i class='fas fa-sitemap text-gray-400 mr-2'></i>System Hierarchy (RTL Schematic)</h3>"
puts $fh "            <div class='mermaid flex justify-center'>"
if {$has_hierarchy} { puts $fh $mermaid_graph } else { puts $fh "graph TD; A\[Top\] --> B\[No Hierarchy\];" }
puts $fh "            </div>"
puts $fh "        </div>"

# Detailed Analysis Section
puts $fh "        <div class='grid grid-cols-1 lg:grid-cols-3 gap-6'>"
puts $fh "            <!-- Left Column: Timing & Utilization -->"
puts $fh "            <div class='lg:col-span-2 space-y-6'>"
puts $fh "                <!-- 1. Timing Details -->"
puts $fh "                <div class='bg-white rounded-2xl shadow-sm border border-gray-200 p-6'>"
puts $fh "                    <h3 class='text-lg font-bold text-gray-800 mb-4 flex items-center'><i class='fas fa-clock text-blue-500 mr-2'></i>Timing Details</h3>"
puts $fh "                    <div class='overflow-x-auto'>"
puts $fh "                        <table class='w-full text-sm text-left'>"
puts $fh "                            <thead class='bg-gray-50 text-xs text-gray-500 uppercase font-semibold'>"
puts $fh "                                <tr><th class='px-4 py-3 rounded-l-lg'>Metric</th><th class='px-4 py-3'>Setup (Max)</th><th class='px-4 py-3'>Hold (Min)</th><th class='px-4 py-3 rounded-r-lg'>Pulse Width</th></tr>"
puts $fh "                            </thead>"
puts $fh "                            <tbody class='text-gray-600'>"
puts $fh "                                <tr class='border-b hover:bg-gray-50'><td class='px-4 py-3 font-medium'>Slack (ns)</td><td class='px-4 py-3 font-bold $wns_color'>$timing_data(wns)</td><td class='px-4 py-3'>$timing_data(whs)</td><td class='px-4 py-3'>$timing_data(tpws)</td></tr>"
puts $fh "                                <tr class='border-b hover:bg-gray-50'><td class='px-4 py-3 font-medium'>Total Neg Slack</td><td class='px-4 py-3'>$timing_data(tns)</td><td class='px-4 py-3'>$timing_data(ths)</td><td class='px-4 py-3'>$timing_data(tpws)</td></tr>"
puts $fh "                            </tbody>"
puts $fh "                        </table>"
puts $fh "                    </div>"
puts $fh "                </div>"

puts $fh "                <!-- 2. Resource Utilization -->"
puts $fh "                <div class='bg-white rounded-2xl shadow-sm border border-gray-200 p-6'>"
puts $fh "                    <h3 class='text-lg font-bold text-gray-800 mb-4 flex items-center'><i class='fas fa-microchip text-orange-500 mr-2'></i>Resource Utilization</h3>"
puts $fh "                    <div class='overflow-x-auto'>"
puts $fh "                        <table class='w-full text-sm text-left'>"
puts $fh "                            <thead class='bg-gray-50 text-xs text-gray-500 uppercase font-semibold'>"
puts $fh "                                <tr><th class='px-4 py-3 rounded-l-lg'>Resource</th><th class='px-4 py-3'>Used</th><th class='px-4 py-3'>Available</th><th class='px-4 py-3 rounded-r-lg'>%</th></tr>"
puts $fh "                            </thead>"
puts $fh "                            <tbody class='text-gray-600'>"
puts $fh "                                <tr class='border-b hover:bg-gray-50'><td class='px-4 py-3 font-medium'>Slice LUTs</td><td class='px-4 py-3'>$util_summary(luts_used)</td><td class='px-4 py-3'>$util_summary(luts_avail)</td><td class='px-4 py-3 text-blue-600 font-bold'>$util_summary(luts_perc)%</td></tr>"
puts $fh "                                <tr class='border-b hover:bg-gray-50'><td class='px-4 py-3 font-medium'>Slice Registers</td><td class='px-4 py-3'>$util_summary(regs_used)</td><td class='px-4 py-3'>$util_summary(regs_avail)</td><td class='px-4 py-3 text-blue-600 font-bold'>$util_summary(regs_perc)%</td></tr>"
foreach row $util_io_list {
    puts $fh "                                <tr class='border-b hover:bg-gray-50'><td class='px-4 py-3 font-medium'>[lindex $row 0]</td><td class='px-4 py-3'>[lindex $row 1]</td><td class='px-4 py-3'>[lindex $row 2]</td><td class='px-4 py-3 text-blue-600 font-bold'>[lindex $row 3]%</td></tr>"
}
puts $fh "                            </tbody>"
puts $fh "                        </table>"
puts $fh "                    </div>"
puts $fh "                </div>"
puts $fh "            </div>"

puts $fh "            <!-- Right Column: Power & Environment -->"
puts $fh "            <div class='space-y-6'>"
puts $fh "                <!-- 3. Vivado-Style Power Summary -->"
puts $fh "                <div class='bg-white rounded-2xl shadow-sm border border-gray-200 p-6'>"
puts $fh "                    <h3 class='text-lg font-bold text-gray-800 mb-6'>Power Summary</h3>"
                    
                    # Flex container for the graphical breakdown
puts $fh "                    <div class='flex gap-6'>"
                        # Main Stacked Bar (Static vs Dynamic)
puts $fh "                        <div class='flex flex-col items-center gap-2'>"
puts $fh "                            <div class='relative w-16 h-64 bg-gray-100 rounded-lg overflow-hidden border border-gray-300 flex flex-col justify-end'>"
puts $fh "                                <!-- Dynamic Bar -->"
puts $fh "                                <div class='w-full bg-yellow-200 flex items-center justify-center text-xs text-yellow-800 font-bold border-b border-white' style='height: ${dyn_perc}%; transition: height 1s;'>${dyn_perc}%</div>"
puts $fh "                                <!-- Static Bar -->"
puts $fh "                                <div class='w-full bg-blue-300 flex items-center justify-center text-xs text-blue-800 font-bold' style='height: ${sta_perc}%; transition: height 1s;'>${sta_perc}%</div>"
puts $fh "                            </div>"
puts $fh "                            <span class='text-xs font-bold text-gray-500'>Total</span>"
puts $fh "                        </div>"

                        # Legend & Breakdown List
puts $fh "                        <div class='flex-1 space-y-4'>"
                            # Dynamic Breakdown
puts $fh "                            <div>"
puts $fh "                                <div class='flex items-center gap-2 mb-2'><div class='w-3 h-3 bg-yellow-200 border border-yellow-400'></div><span class='text-sm font-bold text-gray-700'>Dynamic: $power_summary(dynamic) W</span></div>"
puts $fh "                                <div class='pl-5 space-y-1 text-xs text-gray-600 border-l-2 border-gray-100 ml-1.5'>"
                                    # List Dynamic Components
                                    foreach {comp val} [array get power_components] {
                                        set c_val [get_float $val]
                                        if {$c_val > 0} {
                                            # Colors for components
                                            set comp_color "bg-gray-400"
                                            if {$comp == "Clocks"} { set comp_color "bg-pink-400" }
                                            if {$comp == "Signals"} { set comp_color "bg-cyan-400" }
                                            if {$comp == "Logic"} { set comp_color "bg-green-400" }
                                            if {$comp == "IO"} { set comp_color "bg-lime-400" }
                                            
                                            puts $fh "                                    <div class='flex justify-between items-center'>"
                                            puts $fh "                                        <div class='flex items-center gap-2'><div class='w-2 h-2 rounded-full $comp_color'></div><span>$comp</span></div>"
                                            puts $fh "                                        <div class='flex gap-2 text-gray-400'><span>$val W</span><span class='text-gray-800 font-medium'>($comp_perc($comp)%)</span></div>"
                                            puts $fh "                                    </div>"
                                        }
                                    }
puts $fh "                                </div>"
puts $fh "                            </div>"
                            # Static Breakdown
puts $fh "                            <div>"
puts $fh "                                <div class='flex items-center gap-2 mb-1'><div class='w-3 h-3 bg-blue-300 border border-blue-500'></div><span class='text-sm font-bold text-gray-700'>Static: $power_summary(static) W</span></div>"
puts $fh "                                <div class='pl-6 text-xs text-gray-500'>Device Static</div>"
puts $fh "                            </div>"
puts $fh "                        </div>"
puts $fh "                    </div>"

                    # Additional Text Metrics
puts $fh "                    <div class='mt-6 pt-4 border-t border-gray-100 grid grid-cols-2 gap-4 text-sm'>"
puts $fh "                        <div><span class='block text-xs text-gray-400'>Total On-Chip</span><span class='font-bold text-gray-800 text-lg'>$power_summary(total) W</span></div>"
puts $fh "                        <div><span class='block text-xs text-gray-400'>Junction Temp</span><span class='font-bold text-gray-800'>$power_summary(junction_temp) C</span></div>"
puts $fh "                        <div><span class='block text-xs text-gray-400'>Thermal Margin</span><span class='font-bold text-gray-800'>$power_summary(thermal_margin)</span></div>"
puts $fh "                        <div><span class='block text-xs text-gray-400'>Confidence</span><span class='font-bold text-blue-600'>$power_summary(confidence)</span></div>"
puts $fh "                    </div>"
puts $fh "                </div>"

puts $fh "                <!-- 4. Environment -->"
puts $fh "                <div class='bg-white rounded-2xl shadow-sm border border-gray-200 p-6'>"
puts $fh "                    <h3 class='text-lg font-bold text-gray-800 mb-4'>Environment</h3>"
puts $fh "                    <ul class='space-y-3 text-sm text-gray-600'>"
foreach row $power_env_list {
    puts $fh "                        <li class='flex justify-between border-b border-gray-100 pb-2'><span>[lindex $row 0]</span><span class='font-medium text-gray-800'>[lindex $row 1]</span></li>"
}
puts $fh "                    </ul>"
puts $fh "                </div>"
puts $fh "            </div>"
puts $fh "        </div>"

puts $fh "        <div class='text-center text-gray-400 text-xs mt-10'>Generated by Vivado Automation Script</div>"
puts $fh "    </div>"
puts $fh "</body></html>"
close $fh
puts "Report Generated: $html_file"
