# report_baseline.tcl - synthesis-only baseline: hierarchical utilisation + timing summary.
#
#   cd fpga
#   vivado -mode batch -source vivado/create_project.tcl -tclargs 100t     (once, creates the project)
#   vivado -mode batch -source vivado/report_baseline.tcl
#
# Writes fpga/docs/audit/util_baseline.txt and fpga/docs/audit/timing_baseline.txt.
# Paths are relative to this script, so the current directory does not matter.
set here  [file normalize [file dirname [info script]]]
set fpga  [file normalize "$here/.."]
set audit "$fpga/docs/audit"
set xpr   "$here/cpe_escape/cpe_escape.xpr"

if {![file exists $xpr]} {
    error "Project not found: $xpr - run vivado/create_project.tcl first."
}
file mkdir $audit

open_project $xpr
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set status   [get_property STATUS   [get_runs synth_1]]
set progress [get_property PROGRESS [get_runs synth_1]]
if {$progress ne "100%" || ![string match "*Complete*" $status]} {
    error "synth_1 did not complete (STATUS='$status', PROGRESS='$progress')."
}

open_run synth_1
report_utilization -hierarchical -file "$audit/util_baseline.txt"
report_timing_summary -file "$audit/timing_baseline.txt"

puts "synth_1: $status ($progress)"
puts "Utilisation (look for 'Block RAM Tile' / RAMB36 / RAMB18 rows): $audit/util_baseline.txt"
puts "Timing summary: $audit/timing_baseline.txt"
close_project
