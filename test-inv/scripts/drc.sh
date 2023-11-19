#!/bin/bash

# CLI Klayout: https://www.klayout.de/command_args.html

GDS=./inv.gds
CELL=inv

LOGFILE=lvs.log
# /home/designer/.volare/gf180mcuC/libs.tech/klayout/drc/run_drc.py
DRC_SCRIPT=$KLAYOUT_HOME/drc/run_drc.py


#klayout -b -rx -t -r 

rm -rf *.lyrdb

#----------------
# COMMON
#----------------
OPTIONS=
OPTIONS="$OPTIONS --verbose"
OPTIONS="$OPTIONS --path=$GDS"
OPTIONS="$OPTIONS --variant=C"
OPTIONS="$OPTIONS --topcell=$CELL"
OPTIONS="$OPTIONS --run_mode=deep"

#----------------
# EVALUATED RULES
#----------------
RULES=
#RULES="$RULES --no_feol"
#RULES="$RULES --no_beol"
RULES="$RULES --no_connectivity"
#RULES="$RULES --density"
#RULES="$RULES --density_only"
#RULES="$RULES --antenna"
#RULES="$RULES --antenna_only"
RULES="$RULES --no_offgrid"

OPTIONS="$OPTIONS $RULES"

#----------------
# EXTRA
#----------------
# OPTIONS=$OPTIONS --split_deep
# OPTIONS=$OPTIONS --macro_gen
# OPTIONS=$OPTIONS --slow_via

python $DRC_SCRIPT $OPTIONS


# klayout -rx $GDS -m antenna.lyrdb
# klayout -rx $GDS -m density.lyrdb # Este tiene problemas weones
# klayout -rx $GDS -m main.lyrdb # Problema NP.11
# klayout $GDS -m .lyrdb
# klayout $GDS -m .lyrdb
# klayout $GDS -m .lyrdb




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