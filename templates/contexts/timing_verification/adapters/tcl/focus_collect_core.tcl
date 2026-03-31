if {![info exists repo_root]} {
  error "repo_root must be set before sourcing focus_collect_core.tcl"
}

set repo_root [file normalize $repo_root]
set output_dir [file normalize $output_dir]

set normalized_source_files [list]
foreach rtl_file $source_files {
  lappend normalized_source_files [file normalize $rtl_file]
}
set source_files $normalized_source_files

set normalized_generated_source_files [list]
foreach rtl_file $generated_source_files {
  lappend normalized_generated_source_files [file normalize $rtl_file]
}
set generated_source_files $normalized_generated_source_files

source [file join $repo_root "templates" "contexts" "timing_verification" "adapters" "tcl" "common.tcl"]

riscv_timing_analysis::require_var source_files "source_files must be set before sourcing focus_collect_core.tcl"
riscv_timing_analysis::require_var generated_source_files "generated_source_files must be set before sourcing focus_collect_core.tcl"
riscv_timing_analysis::require_var output_dir "output_dir must be set before sourcing focus_collect_core.tcl"
riscv_timing_analysis::require_var part_name "part_name must be set before sourcing focus_collect_core.tcl"
riscv_timing_analysis::require_var focus_configs "focus_configs must be set before sourcing focus_collect_core.tcl"
riscv_timing_analysis::ensure_default clock_port "iClk"
riscv_timing_analysis::ensure_default reset_port "iRstn"
riscv_timing_analysis::ensure_default clk_period_ns 10.000
riscv_timing_analysis::ensure_default synth_directive "PerformanceOptimized"
riscv_timing_analysis::ensure_default opt_directive "Explore"
riscv_timing_analysis::ensure_default place_directive "Explore"
riscv_timing_analysis::ensure_default phys_opt_directive "AggressiveExplore"
riscv_timing_analysis::ensure_default route_directive "Explore"
riscv_timing_analysis::ensure_default post_route_phys_opt_directive "AggressiveExplore"
riscv_timing_analysis::ensure_default family_configs {}
riscv_timing_analysis::maybe_cd_repo_root
riscv_timing_analysis::configure_max_threads

proc report_focus_stage_artifacts {output_dir stage_key} {
  report_timing_summary -delay_type max -file [file join $output_dir "${stage_key}_timing_summary.rpt"]
  report_utilization -file [file join $output_dir "${stage_key}_utilization.rpt"]
  report_route_status -file [file join $output_dir "${stage_key}_route_status.rpt"]
}

proc write_focus_family_timing_artifacts {output_dir family_config clk_period_ns} {
  set family_key [dict get $family_config key]
  set family_base [file join $output_dir "${family_key}_timing"]
  set report_file "${family_base}_top20.rpt"
  set tsv_file "${family_base}_paths.tsv"
  set to_pins [riscv_timing_analysis::resolve_family_to_pins $family_config]

  if {[llength $to_pins] == 0} {
    set fh [open $report_file w]
    puts $fh "No timing endpoints matched family `${family_key}` for this focus build."
    close $fh
    riscv_timing_analysis::write_empty_timing_paths_tsv $tsv_file
    return
  }

  report_timing -delay_type max -to $to_pins -max_paths 20 -file $report_file
  riscv_timing_analysis::write_timing_paths_tsv $tsv_file 20 $clk_period_ns $to_pins
}

file mkdir $::output_dir

riscv_timing_analysis::load_source_files $::source_files
riscv_timing_analysis::load_source_files $::generated_source_files
set total_focus_configs [llength $::focus_configs]
set total_progress_steps [expr {1 + ($total_focus_configs * 4)}]
riscv_timing_analysis::emit_progress 1 $total_progress_steps "Loaded focus RTL sources and generated wrappers"

set focus_index 0
foreach focus_config $::focus_configs {
  incr focus_index
  set focus_key [dict get $focus_config key]
  set focus_top_name [dict get $focus_config top_name]
  set focus_output_dir [file join $::output_dir $focus_key]
  set focus_step_base [expr {1 + (($focus_index - 1) * 4)}]

  file mkdir $focus_output_dir

  synth_design -top $focus_top_name -part $::part_name -directive $::synth_directive
  riscv_timing_analysis::write_clock_and_reset_constraints $::clock_port $::reset_port $::clk_period_ns
  report_focus_stage_artifacts $focus_output_dir "post_synth"
  riscv_timing_analysis::emit_progress [expr {$focus_step_base + 1}] $total_progress_steps "Focus ${focus_index}/${total_focus_configs} ${focus_key}: completed synthesis"

  opt_design -directive $::opt_directive
  riscv_timing_analysis::write_clock_and_reset_constraints $::clock_port $::reset_port $::clk_period_ns
  report_focus_stage_artifacts $focus_output_dir "post_opt"
  riscv_timing_analysis::emit_progress [expr {$focus_step_base + 2}] $total_progress_steps "Focus ${focus_index}/${total_focus_configs} ${focus_key}: completed optimization"

  place_design -directive $::place_directive
  phys_opt_design -directive $::phys_opt_directive
  riscv_timing_analysis::write_clock_and_reset_constraints $::clock_port $::reset_port $::clk_period_ns
  report_focus_stage_artifacts $focus_output_dir "post_place"
  riscv_timing_analysis::emit_progress [expr {$focus_step_base + 3}] $total_progress_steps "Focus ${focus_index}/${total_focus_configs} ${focus_key}: completed placement"

  route_design -directive $::route_directive
  phys_opt_design -directive $::post_route_phys_opt_directive
  riscv_timing_analysis::write_clock_and_reset_constraints $::clock_port $::reset_port $::clk_period_ns
  report_focus_stage_artifacts $focus_output_dir "post_route"

  foreach family_config $::family_configs {
    write_focus_family_timing_artifacts $focus_output_dir $family_config $::clk_period_ns
  }
  riscv_timing_analysis::emit_progress [expr {$focus_step_base + 4}] $total_progress_steps "Focus ${focus_index}/${total_focus_configs} ${focus_key}: completed routing and reports"

  close_design
}
