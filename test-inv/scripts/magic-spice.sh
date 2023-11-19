#!/bin/bash

GDS=./inv.gds
CELL=inv

TECHFILE=$PDK_ROOT/$PDK/libs.tech/magic/gf180mcu*.magicrc
LOGFILE=gds.log

magic -dnull -noconsole -rcfile $TECHFILE <<EOF
gds read $GDS
getcell $CELL
load $CELL
box 0 0 0 0
extract
ext2spice lvs
ext2spice
exit
EOF