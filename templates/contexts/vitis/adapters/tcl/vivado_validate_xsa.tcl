set xsa_path ""
if {[llength $argv] >= 1} {
    set xsa_path [file normalize [lindex $argv 0]]
}

if {$xsa_path eq ""} {
    puts "\[ERROR\] Usage: vivado_validate_xsa.tcl <xsa_path>"
    exit 1
}

if {![file exists $xsa_path]} {
    puts "\[ERROR\] XSA not found: $xsa_path"
    exit 1
}

puts "\[INFO\] Validating XSA: $xsa_path"
validate_hw_platform -verbose $xsa_path
puts "\[INFO\] XSA validation completed."
exit 0
