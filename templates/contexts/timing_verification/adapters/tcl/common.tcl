namespace eval riscv_timing_analysis {
}

proc riscv_timing_analysis::require_var {var_name message} {
  if {![info exists ::$var_name]} {
    error $message
  }
}

proc riscv_timing_analysis::ensure_default {var_name default_value} {
  if {![info exists ::$var_name]} {
    set ::$var_name $default_value
  }
}

proc riscv_timing_analysis::maybe_cd_repo_root {} {
  if {[info exists ::repo_root]} {
    cd [file normalize $::repo_root]
  }
}

proc riscv_timing_analysis::configure_max_threads {{default_threads 20}} {
  set resolved_threads $default_threads

  if {[info exists ::env(NUMBER_OF_PROCESSORS)]} {
    set candidate [string trim $::env(NUMBER_OF_PROCESSORS)]
    if {[string is integer -strict $candidate] && $candidate > 0} {
      set resolved_threads $candidate
      set_param general.maxThreads $resolved_threads
      puts " \[INFO\] CPU Optimization Enabled: Using $resolved_threads threads."
      return
    }
  }

  set_param general.maxThreads $resolved_threads
  puts " \[INFO\] CPU Count detection failed. Defaulting to $resolved_threads threads."
}

proc riscv_timing_analysis::emit_progress {current_units total_units label} {
  puts "__FPGA_AUTO_PROGRESS__\t${current_units}\t${total_units}\t${label}"
  flush stdout
}

proc riscv_timing_analysis::load_source_files {source_files} {
  foreach rtl_file $source_files {
    set rtl_file_normalized [file normalize $rtl_file]

    if {![file exists $rtl_file_normalized]} {
      error "Resolved RTL source does not exist: ${rtl_file_normalized}"
    }

    uplevel 1 [list read_verilog -sv $rtl_file_normalized]
  }
}

proc riscv_timing_analysis::write_clock_and_reset_constraints {clock_port reset_port clk_period_ns} {
  create_clock -name $clock_port -period $clk_period_ns [get_ports $clock_port]
  if {$reset_port ne ""} {
    set_false_path -from [get_ports $reset_port]
  }
  update_timing
}

proc riscv_timing_analysis::write_empty_timing_paths_tsv {outfile} {
  set fh [open $outfile w]
  puts $fh "index\tslack_ns\tmin_period_ns\tdatapath_delay_ns\tlogic_delay_ns\tnet_delay_ns\troute_share_pct\tlogic_share_pct\tlogic_levels\tmax_fanout\tstart_pin\tend_pin\tpath_name"
  close $fh
}

proc riscv_timing_analysis::write_timing_paths_tsv {outfile max_paths clk_period_ns {to_pins {}} {from_pins {}}} {
  set timing_path_cmd [list get_timing_paths -delay_type max -max_paths $max_paths -nworst $max_paths]
  if {[llength $from_pins] > 0} {
    lappend timing_path_cmd -from $from_pins
  }
  if {[llength $to_pins] > 0} {
    lappend timing_path_cmd -to $to_pins
  }
  set path_objs [eval $timing_path_cmd]

  set fh [open $outfile w]
  puts $fh "index\tslack_ns\tmin_period_ns\tdatapath_delay_ns\tlogic_delay_ns\tnet_delay_ns\troute_share_pct\tlogic_share_pct\tlogic_levels\tmax_fanout\tstart_pin\tend_pin\tpath_name"

  set idx 0
  foreach path_obj $path_objs {
    incr idx
    set slack_ns [get_property SLACK $path_obj]
    set datapath_delay_ns [get_property DATAPATH_DELAY $path_obj]
    set logic_delay_ns [get_property DATAPATH_LOGIC_DELAY $path_obj]
    set net_delay_ns [get_property DATAPATH_NET_DELAY $path_obj]
    set logic_levels [get_property LOGIC_LEVELS $path_obj]
    set max_fanout [get_property MAX_FANOUT $path_obj]
    set start_pin [get_property STARTPOINT_PIN $path_obj]
    set end_pin [get_property ENDPOINT_PIN $path_obj]
    set path_name [get_property NAME $path_obj]
    set min_period_ns [expr {$clk_period_ns - $slack_ns}]

    if {$datapath_delay_ns > 0.0} {
      set route_share_pct [expr {100.0 * $net_delay_ns / $datapath_delay_ns}]
      set logic_share_pct [expr {100.0 * $logic_delay_ns / $datapath_delay_ns}]
    } else {
      set route_share_pct 0.0
      set logic_share_pct 0.0
    }

    puts $fh [join [list \
      $idx \
      $slack_ns \
      $min_period_ns \
      $datapath_delay_ns \
      $logic_delay_ns \
      $net_delay_ns \
      $route_share_pct \
      $logic_share_pct \
      $logic_levels \
      $max_fanout \
      $start_pin \
      $end_pin \
      $path_name] "\t"]
  }

  close $fh
}

proc riscv_timing_analysis::dict_get_default {dictionary key default_value} {
  if {[dict exists $dictionary $key]} {
    return [dict get $dictionary $key]
  }
  return $default_value
}

proc riscv_timing_analysis::append_unique_items {var_name values} {
  upvar 1 $var_name rows
  foreach value $values {
    if {$value eq ""} {
      continue
    }
    if {[lsearch -exact $rows $value] >= 0} {
      continue
    }
    lappend rows $value
  }
}

proc riscv_timing_analysis::leaf_data_pins_for_cells {cell_objs pin_name_patterns} {
  set primitive_cells {}

  foreach cell_obj $cell_objs {
    if {$cell_obj eq ""} {
      continue
    }

    set is_primitive [get_property IS_PRIMITIVE $cell_obj]
    if {$is_primitive} {
      riscv_timing_analysis::append_unique_items primitive_cells [list $cell_obj]
      continue
    }

    set cell_name [get_property NAME $cell_obj]
    if {$cell_name eq ""} {
      continue
    }

    set nested_primitive_cells [get_cells -quiet -hier -filter "IS_PRIMITIVE == 1 && NAME =~ ${cell_name}/*"]
    riscv_timing_analysis::append_unique_items primitive_cells $nested_primitive_cells
  }

  if {[llength $primitive_cells] == 0} {
    return {}
  }

  set matched_pins {}
  foreach pin_name_pattern $pin_name_patterns {
    set candidate_pins [get_pins -quiet -of_objects $primitive_cells -filter "REF_PIN_NAME =~ ${pin_name_pattern}"]
    riscv_timing_analysis::append_unique_items matched_pins $candidate_pins
  }

  return $matched_pins
}

proc riscv_timing_analysis::resolve_timing_pins_from_spec {pin_spec {default_pin_name_patterns {D}}} {
  set to_pins {}
  set pin_name_patterns [riscv_timing_analysis::dict_get_default $pin_spec pin_name_patterns $default_pin_name_patterns]
  set instance_patterns [riscv_timing_analysis::dict_get_default $pin_spec instance_patterns {}]
  set ref_name_patterns [riscv_timing_analysis::dict_get_default $pin_spec ref_name_patterns {}]
  set endpoint_patterns [riscv_timing_analysis::dict_get_default $pin_spec endpoint_patterns {}]

  foreach instance_pattern $instance_patterns {
    set matched_cells [get_cells -quiet -hier -filter "NAME =~ ${instance_pattern}"]
    set candidate_pins [riscv_timing_analysis::leaf_data_pins_for_cells $matched_cells $pin_name_patterns]
    riscv_timing_analysis::append_unique_items to_pins $candidate_pins
  }

  foreach ref_name_pattern $ref_name_patterns {
    set matched_cells [get_cells -quiet -hier -filter "REF_NAME =~ ${ref_name_pattern}"]
    set candidate_pins [riscv_timing_analysis::leaf_data_pins_for_cells $matched_cells $pin_name_patterns]
    riscv_timing_analysis::append_unique_items to_pins $candidate_pins
  }

  foreach endpoint_pattern $endpoint_patterns {
    set matched_pins [get_pins -quiet -hier -filter "NAME =~ ${endpoint_pattern}"]
    riscv_timing_analysis::append_unique_items to_pins $matched_pins

    set matched_cells [get_cells -quiet -hier -filter "NAME =~ ${endpoint_pattern}"]
    set candidate_pins [riscv_timing_analysis::leaf_data_pins_for_cells $matched_cells $pin_name_patterns]
    riscv_timing_analysis::append_unique_items to_pins $candidate_pins
  }

  return $to_pins
}

proc riscv_timing_analysis::resolve_family_to_pins {family_config} {
  return [riscv_timing_analysis::resolve_timing_pins_from_spec $family_config [list D]]
}

proc riscv_timing_analysis::string_matches_any {value patterns} {
  foreach pattern $patterns {
    if {[string match $pattern $value]} {
      return 1
    }
  }
  return 0
}
