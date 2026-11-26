# create_project.tcl - builds the Vivado project for cpe_escape_top (Nexys A7).
#
#   Vivado GUI : Tools -> Run Tcl Script... -> fpga/vivado/create_project.tcl
#   batch      : vivado -mode batch -source fpga/vivado/create_project.tcl -tclargs [100t|50t] [build]
#
# "build" also runs synthesis, implementation and write_bitstream and writes the utilisation and
# timing reports to fpga/vivado/reports/.
set here   [file normalize [file dirname [info script]]]
set fpga   [file normalize "$here/.."]
set board  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "100t"}]
set build  [expr {[lsearch $argv build] >= 0}]
set part   [expr {$board eq "50t" ? "xc7a50tcsg324-1" : "xc7a100tcsg324-1"}]
if {$board eq "50t"} {
    puts "NOTE: BRAM estimate ~49 BRAM36 (rooms streamed from the QSPI flash, not yet confirmed by Vivado);"
    puts "      the XC7A50T has 75. The tested target is the Nexys A7-100T - see docs/ARCHITECTURE.md (memory budget)."
}

create_project cpe_escape "$here/cpe_escape" -part $part -force
set_property target_language Verilog [current_project]

add_files [glob $fpga/rtl/common/*.v $fpga/rtl/video/*.v $fpga/rtl/ui/*.v $fpga/rtl/stage1/*.v $fpga/rtl/stage2/*.v $fpga/rtl/stage3/*.v $fpga/rtl/top/*.v]
add_files [list $fpga/rtl/common/game_defs.vh $fpga/rtl/ui/ui_map.vh $fpga/rtl/video/pic_map.vh $fpga/rtl/stage2/s2_consts.vh $fpga/rtl/stage3/s3_consts.vh]
set_property file_type {Verilog Header} [get_files *.vh]
set_property include_dirs [list $fpga/rtl/common $fpga/rtl/ui $fpga/rtl/stage2 $fpga/rtl/stage3 $fpga/rtl/video] [current_fileset]
# memory initialisation files: referenced by file name only (MEM_DIR = "")
add_files [glob $fpga/mem/*.mem]
set_property file_type {Memory Initialization Files} [get_files *.mem]
add_files -fileset constrs_1 $fpga/constraints/nexys_a7.xdc
set_property top cpe_escape_top [current_fileset]

# simulation sources (Vivado simulator): the co-simulation testbench
add_files -fileset sim_1 [glob $fpga/tb/*.v]
set_property top tb_s1_cosim [get_filesets sim_1]

if {$build} {
    file mkdir "$here/reports"
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    open_run synth_1
    report_utilization -file "$here/reports/utilization_synth.txt"
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    open_run impl_1
    report_utilization    -file "$here/reports/utilization_impl.txt"
    report_timing_summary -file "$here/reports/timing_summary.txt"
    puts "Bitstream: [get_property DIRECTORY [get_runs impl_1]]/cpe_escape_top.bit"
}
