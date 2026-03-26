namespace eval riscv_timing_analysis::single_cycle {
}

proc riscv_timing_analysis::single_cycle::get_data_pins_for_patterns {cell_name_patterns} {
  set family_cells {}

  foreach cell_pattern $cell_name_patterns {
    set matched_cells [get_cells -quiet -hier -filter "NAME =~ ${cell_pattern}"]
    if {[llength $matched_cells] == 0} {
      continue
    }
    foreach matched_cell $matched_cells {
      lappend family_cells $matched_cell
    }
  }

  if {[llength $family_cells] == 0} {
    return {}
  }

  set family_cells [lsort -unique $family_cells]
  return [get_pins -quiet -of_objects $family_cells -filter {REF_PIN_NAME == D}]
}

proc riscv_timing_analysis::single_cycle::write_family_timing_artifacts {output_dir family_config clk_period_ns} {
  set family_key [dict get $family_config key]
  set endpoint_patterns [dict get $family_config endpoint_patterns]
  set family_base [file join $output_dir "${family_key}_timing"]
  set report_file "${family_base}_top20.rpt"
  set tsv_file "${family_base}_paths.tsv"
  set to_pins [riscv_timing_analysis::single_cycle::get_data_pins_for_patterns $endpoint_patterns]

  if {[llength $to_pins] == 0} {
    set fh [open $report_file w]
    puts $fh "No retained timing endpoints matched family `${family_key}`."
    close $fh
    riscv_timing_analysis::write_empty_timing_paths_tsv $tsv_file
    return
  }

  report_timing -delay_type max -to $to_pins -max_paths 20 -file $report_file
  riscv_timing_analysis::write_timing_paths_tsv $tsv_file 20 $clk_period_ns $to_pins
}

proc riscv_timing_analysis::single_cycle::write_fanout_nets_tsv {outfile max_nets} {
  set rows {}
  foreach net_obj [get_nets -hier] {
    if {[catch {set flat_pin_count [get_property FLAT_PIN_COUNT $net_obj]}]} {
      continue
    }
    if {$flat_pin_count eq ""} {
      continue
    }

    set fanout_count [expr {$flat_pin_count - 1}]
    if {$fanout_count <= 1} {
      continue
    }

    lappend rows [list $fanout_count $net_obj]
  }

  set rows [lsort -integer -decreasing -index 0 $rows]

  set fh [open $outfile w]
  puts $fh "rank\tfanout_count\tnet_name"

  set rank 0
  foreach row $rows {
    incr rank
    if {$rank > $max_nets} {
      break
    }
    lassign $row fanout_count net_name
    puts $fh [join [list $rank $fanout_count $net_name] "\t"]
  }

  close $fh
}

proc riscv_timing_analysis::single_cycle::count_matching_prims {full_inst_name ref_glob} {
  set filter_expr "IS_PRIMITIVE == 1 && NAME =~ ${full_inst_name}/* && REF_NAME =~ ${ref_glob}"
  return [llength [get_cells -hier -filter $filter_expr]]
}

proc riscv_timing_analysis::single_cycle::count_all_prims {full_inst_name} {
  set filter_expr "IS_PRIMITIVE == 1 && NAME =~ ${full_inst_name}/*"
  return [llength [get_cells -hier -filter $filter_expr]]
}

proc riscv_timing_analysis::single_cycle::write_module_metrics_tsv {outfile top_name exclude_patterns} {
  set rows {}
  foreach cell_obj [get_cells -hier -filter {IS_PRIMITIVE == 0}] {
    set full_inst_name [get_property NAME $cell_obj]
    if {$full_inst_name eq "" || $full_inst_name eq $top_name} {
      continue
    }
    if {[riscv_timing_analysis::string_matches_any $full_inst_name $exclude_patterns]} {
      continue
    }

    set total_prim_cells [riscv_timing_analysis::single_cycle::count_all_prims $full_inst_name]
    if {$total_prim_cells <= 0} {
      continue
    }

    set ff_count [expr {
      [riscv_timing_analysis::single_cycle::count_matching_prims $full_inst_name "FD*"] +
      [riscv_timing_analysis::single_cycle::count_matching_prims $full_inst_name "LD*"]
    }]
    set lut_count [riscv_timing_analysis::single_cycle::count_matching_prims $full_inst_name "LUT*"]
    set carry_count [riscv_timing_analysis::single_cycle::count_matching_prims $full_inst_name "CARRY*"]
    set ram_count [riscv_timing_analysis::single_cycle::count_matching_prims $full_inst_name "RAM*"]
    set muxf_count [riscv_timing_analysis::single_cycle::count_matching_prims $full_inst_name "MUXF*"]
    set other_count [expr {$total_prim_cells - $ff_count - $lut_count - $carry_count - $ram_count - $muxf_count}]

    lappend rows [list \
      $full_inst_name \
      $total_prim_cells \
      $ff_count \
      $lut_count \
      $carry_count \
      $ram_count \
      $muxf_count \
      $other_count]
  }

  set rows [lsort -integer -decreasing -index 1 $rows]

  set fh [open $outfile w]
  puts $fh "instance\ttotal_prim_cells\tff_count\tlut_count\tcarry_count\tram_count\tmuxf_count\tother_count"
  foreach row $rows {
    puts $fh [join $row "\t"]
  }
  close $fh
}

proc riscv_timing_analysis::single_cycle::run {} {
  riscv_timing_analysis::require_var source_files "source_files must be set before sourcing single_cycle_perf_collect.tcl"
  riscv_timing_analysis::require_var output_dir "output_dir must be set before sourcing single_cycle_perf_collect.tcl"
  riscv_timing_analysis::require_var part_name "part_name must be set before sourcing single_cycle_perf_collect.tcl"
  riscv_timing_analysis::require_var top_name "top_name must be set before sourcing single_cycle_perf_collect.tcl"
  riscv_timing_analysis::ensure_default clock_port "iClk"
  riscv_timing_analysis::ensure_default reset_port "iRstn"
  riscv_timing_analysis::ensure_default clk_period_ns 10.000
  riscv_timing_analysis::ensure_default family_configs {}
  riscv_timing_analysis::ensure_default module_metric_exclude_patterns [list *probe* *TimingProbe* *IBUF* *OBUF* *BUFG*]
  riscv_timing_analysis::maybe_cd_repo_root

  file mkdir $::output_dir
  set total_progress_steps 6

  riscv_timing_analysis::load_source_files $::source_files
  riscv_timing_analysis::emit_progress 1 $total_progress_steps "Loaded single-cycle RTL sources"

  synth_design -top $::top_name -part $::part_name
  riscv_timing_analysis::write_clock_and_reset_constraints $::clock_port $::reset_port $::clk_period_ns
  riscv_timing_analysis::emit_progress 2 $total_progress_steps "Completed single-cycle synthesis"

  report_timing_summary -delay_type max -file [file join $::output_dir "actual_timing_summary.rpt"]
  report_timing -delay_type max -max_paths 100 -file [file join $::output_dir "actual_timing_top100.rpt"]
  report_high_fanout_nets -max_nets 50 -file [file join $::output_dir "actual_high_fanout.rpt"]
  report_utilization -file [file join $::output_dir "actual_utilization.rpt"]
  if {[catch {report_methodology -file [file join $::output_dir "actual_methodology.rpt"]} methodology_err]} {
    set fh [open [file join $::output_dir "actual_methodology.rpt"] w]
    puts $fh $methodology_err
    close $fh
  }
  if {[catch {report_qor_suggestions -file [file join $::output_dir "actual_qor_suggestions.rpt"]} qor_err]} {
    set fh [open [file join $::output_dir "actual_qor_suggestions.rpt"] w]
    puts $fh $qor_err
    close $fh
  }
  riscv_timing_analysis::write_timing_paths_tsv [file join $::output_dir "actual_timing_paths.tsv"] 100 $::clk_period_ns
  riscv_timing_analysis::single_cycle::write_fanout_nets_tsv [file join $::output_dir "actual_fanout_nets.tsv"] 50
  foreach family_config $::family_configs {
    riscv_timing_analysis::single_cycle::write_family_timing_artifacts $::output_dir $family_config $::clk_period_ns
  }
  riscv_timing_analysis::emit_progress 3 $total_progress_steps "Completed single-cycle timing artifacts"

  close_design

  riscv_timing_analysis::load_source_files $::source_files
  riscv_timing_analysis::emit_progress 4 $total_progress_steps "Reloaded RTL sources for hierarchical analysis"
  synth_design -top $::top_name -part $::part_name -flatten_hierarchy none
  riscv_timing_analysis::write_clock_and_reset_constraints $::clock_port $::reset_port $::clk_period_ns
  riscv_timing_analysis::emit_progress 5 $total_progress_steps "Completed hierarchical synthesis"

  report_utilization -hierarchical -file [file join $::output_dir "hierarchical_utilization.rpt"]
  report_timing -delay_type max -max_paths 20 -file [file join $::output_dir "hierarchical_timing_top20.rpt"]
  riscv_timing_analysis::single_cycle::write_module_metrics_tsv \
    [file join $::output_dir "module_metrics.tsv"] \
    $::top_name \
    $::module_metric_exclude_patterns
  riscv_timing_analysis::emit_progress 6 $total_progress_steps "Completed hierarchical analysis artifacts"

  close_design
}
