# make_flash.tcl - builds the QSPI flash image: bitstream at 0x000000 + pictures.bin at 0x400000.
#
#   vivado -mode batch -source vivado/create_project.tcl -tclargs 100t build    (first: makes the .bit)
#   vivado -mode batch -source vivado/make_flash.tcl                            (then: makes the .mcs)
#
# Writes fpga/vivado/flash/cpe_escape.mcs. Programming it into the board: see fpga/README.md.
# Paths are relative to this script, so the current directory does not matter.
set here [file normalize [file dirname [info script]]]
set fpga [file normalize "$here/.."]
# the bitstream made by create_project.tcl: project "cpe_escape", run impl_1, top "cpe_escape_top"
set bit  "$here/cpe_escape/cpe_escape.runs/impl_1/cpe_escape_top.bit"
set pics "$fpga/mem/pictures.bin"
set out  "$here/flash"
set mcs  "$out/cpe_escape.mcs"
set pic_addr 0x00400000        ;# = PIC_BASE in rtl/video/pic_map.vh (tools/pic_pack.py)

if {![file exists $bit]} {
    error "Bitstream not found: $bit\nBuild it first: vivado -mode batch -source vivado/create_project.tcl -tclargs 100t build"
}
if {![file exists $pics]} {
    error "Picture image not found: $pics\nMake it with: python3 fpga/tools/pic_pack.py"
}
file mkdir $out

puts "Bitstream: $bit"
puts "           built [clock format [file mtime $bit]]  (rebuild if you changed the Verilog or XDC since)"
puts "Pictures : $pics ([file size $pics] bytes) at $pic_addr"

# -size 16 = 16 MByte flash. SPIx4 needs BITSTREAM.CONFIG.SPI_BUSWIDTH 4 (set in constraints/nexys_a7.xdc).
write_cfgmem -force -format mcs -size 16 -interface SPIx4 \
    -loadbit  [list up 0x00000000 $bit] \
    -loaddata [list up $pic_addr $pics] \
    -file $mcs

puts "Flash image: $mcs"
