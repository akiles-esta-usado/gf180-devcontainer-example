#!/bin/bash

SPICE1=./inv.spice
CELL1=inv

SPICE2=./inv_extracted.cir
CELL2=inv

TECHFILE=$PDK_ROOT/$PDK/libs.tech/netgen/gf180mcu*_setup.tcl
LOGFILE=lvs.log

netgen -batch lvs \"$SPICE1 $CELL1\" \"$SPICE1 $CELL1\" $TECHFILE
