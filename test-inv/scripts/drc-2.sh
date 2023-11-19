#!/bin/bash

# CLI Klayout: https://www.klayout.de/command_args.html

GDS=./inv.gds
CELL=inv

LOGFILE=lvs.log
# /home/designer/.volare/gf180mcuC/libs.tech/klayout/drc/rule_decks/gf180mcuC_mr.drc
DRC_SCRIPT=$KLAYOUT_HOME/drc/rule_decks/gf180mcuC_mr.drc


rm -rf gp180_drc.lyrdb

#-----------------
# GENERAL OPTIONS
#-----------------
OPTIONS=
OPTIONS="$OPTIONS -rd input=$GDS"
OPTIONS="$OPTIONS -rd report=gp180_drc.lyrdb"
OPTIONS="$OPTIONS -rd topcell=inv"
OPTIONS="$OPTIONS -rd verbose=true"
OPTIONS="$OPTIONS -rd run_mode=deep"

#--------------
# RULES
#--------------
OPTIONS="$OPTIONS -rd feol=true"
OPTIONS="$OPTIONS -rd beol=true"
OPTIONS="$OPTIONS -rd conn_drc=true"
OPTIONS="$OPTIONS -rd offgrid=true"

OPTIONS="$OPTIONS -rd wedge=false"
OPTIONS="$OPTIONS -rd ball=false"
OPTIONS="$OPTIONS -rd gold=false"


klayout -b -r $DRC_SCRIPT $OPTIONS && klayout -rx $GDS -m gp180_drc.lyrdb

# $errs          | Contador de errores
# $gms_init      | No es relevante
# $gms_strm      | No es relevante
# $gfs_init      | No es relevante
# $gfs_strm      | No es relevante
# $freeMin       | No es relevante
# $input         | Nombre del archivo gds
# $topcell       | Nombre de la celda a analizar
# $report        | Nombre del archivo de reporte
# $thr           | Cantidad de threads a ocupar
# $verbose       | Habilitar impresión de más información
# $run_mode      | tiling; deep; flat (def)
# $metal_level   | 196 Asigna la capa de metal máxima a revisar. Eficiencia
# $metal_top     | 592 ?
# $logger        | No es relevante
# $feol=true     | Habilita verificar reglas FEOL
# $beol=true     | Habilita verificar reglas BEOL
# $conn_drc=true | Habilita verificar reglas de conectividad
# $offgrid=true  | Habilita verificar reglas de conectividad
# $wedge=false   | Deshabilita Wedge
# $ball=false    | Deshabilita Ball
# $gold=false    | Deshabilita Gold
# $mim_option    | 630 por defecto es "B"