set part_number "xczu3eg-sbva484-1-i"
set board_part "Avnet-tria:Ultra96v2:part0:1.3"
set top_module "TOP"
set power_limit 2.5
set bd_name "design_1"
set project_name "vivado_ipi"
set project_dir "./vivado_ipi"

set local_board_repo [file normalize [file join [file dirname [info script]] ".." "board_files"]]
if {[file isdirectory $local_board_repo]} {
    set existing_board_repos [get_param board.repoPaths]
    if {[lsearch -exact $existing_board_repos $local_board_repo] < 0} {
        set_param board.repoPaths [linsert $existing_board_repos 0 $local_board_repo]
    }
}
