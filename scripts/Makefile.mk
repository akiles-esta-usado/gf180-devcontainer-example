# TODO: Are we catching stderr into log files?
# TODO: Can we replace TOP from cli?  (make TOP=cell magic)?

all: lvs pex


TIMESTAMP_DAY=$$(date +%Y-%m-%d)
TIMESTAMP_TIME=$$(date +%H-%M-%S)

GREP=grep --color=auto
RM=rm -rf

# Relevant directories
#################

LOGDIR=logs/$(TIMESTAMP_DAY)

MAGIC_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-magic.log
XSCHEM_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-xschem.log
NETGEN_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-netgen.log
KLAYOUT_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-klayout.log

MAGIC_LVS_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-magic-lvs.log
MAGIC_PARASITIC_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-magic-pex.log
XSCHEM_LVS_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-xschem-lvs.log
KLAYOUT_LVS_LOG=$(LOGDIR)/$(TIMESTAMP_TIME)-klayout-lvs.log

OUTDIR=output

# Configuration files
#####################

XSCHEM_RCFILE=$(PDK_ROOT)/$(PDK)/libs.tech/xschem/xschemrc

MAGIC_RCFILE=$(PDK_ROOT)/$(PDK)/libs.tech/magic/$(PDK).magicrc
MAGIC_LVS=./scripts/magic_lvs.tcl
MAGIC_PARASITIC=./scripts/magic_parasitic.tcl

NETGEN_RCFILE=$(PDK_ROOT)/$(PDK)/libs.tech/netgen/setup.tcl


# Required Files
################


# Getting source file
#####################

ALL_SCH:=$(wildcard ./schematic/*.sch)

ALL_LAYOUT:=$(wildcard ./layout/*.gds) \
			$(wildcard ./layout/*.mag)

# All circuit schematics have .sch suffix
SCH:=$(filter-out %_tb.sch,$(ALL_SCH))

# All testbench schematics have _tb.sch prefix.
TB:=$(filter %_tb.sch,$(ALL_SCH))

# We can have 2 types of layout files: mag and gds.
GDS:=$(filter %.gds,$(ALL_LAYOUT))
MAG:=$(filter %.mag,$(ALL_LAYOUT))

# Files based on TOP

TOP_SCH:=$(filter %$(TOP).sch,$(SCH))

TOP_TB:=$(filter %$(TOP)_tb.sch,$(TB))

TOP_LAYOUT:=$(strip \
			$(filter %$(TOP).gds,$(GDS)) \
	        $(filter %$(TOP).mag,$(MAG)) )


LVS_SCH=$(wildcard ./output/*_sch.spice)
LVS_LAY=$(wildcard ./output/*_lay.spice)


# Program Aliases
#################

# https://xschem.sourceforge.io/stefan/xschem_man/developer_info.html
XSCHEM=xschem --rcfile $(XSCHEM_RCFILE)
XSCHEM_NETLIST=$(XSCHEM) --netlist --netlist_path $(OUTDIR) --netlist_filename $(TOP)_sch.spice --preinit 'set lvs_netlist 1' --no_x --quit

KLAYOUT=klayout -t -d 1

MAGIC=magic -rcfile $(MAGIC_RCFILE) -noconsole
MAGIC_BATCH=$(MAGIC) -nowrapper -nowindow -D -dnull

NETGEN=netgen -batch lvs

############
## Utilities
############

.PHONY: clean
clean:
	$(RM) *.lyrdb
	$(RM) logs
	$(RM) *.ext
	$(RM) comp.out
	$(RM) *.sim *.nodes
	$(RM) output/*_lay.spice output/*_sch.spice output/*_parasitic.spice 


.PHONY: logdir
logdir:
	mkdir -p $(LOGDIR)

.PHONY: outdir
outdir:
	mkdir -p $(OUTDIR)


# https://www.cmcrossroads.com/article/printing-value-makefile-variable
# https://stackoverflow.com/questions/16467718/how-to-print-out-a-variable-in-makefile
print-% : ; $(info $*: $(flavor $*) variable - $($*)) @true


.PHONY: print-vars
print-vars : \
	print-TOP_SCH print-TOP_TB print-TOP_LAYOUT \
 	print-SCH print-TB print-GDS print-MAG \
	print-LVS_SCH print-LVS_LAY


#########
## Xschem
#########

.PHONY: xschem
xschem: xschem-tb


.PHONY: xschem-sch
xschem-sch: logdir outdir
	$(XSCHEM) $(TOP_SCH) |& tee $(XSCHEM_LOG)


.PHONY: xschem-tb
xschem-tb: logdir outdir
	$(XSCHEM) $(TOP_TB) |& tee $(XSCHEM_LOG)


.PHONY: xschem-lvs
xschem-lvs: logdir outdir
	$(XSCHEM_NETLIST) $(TOP_SCH) |& tee $(XSCHEM_LVS_LOG)


##########
## Klayout
##########

# TODO: This rules are not verified
# TODO: Klayout DRC
# TODO: Klayout LVS

.PHONY: klayout
klayout: klayout-view


.PHONY: klayout-view
klayout-view: logdir outdir
	$(KLAYOUT) -ne $(GDS) |& tee $(KLAYOUT_LOG)


.PHONY: klayout-edit
klayout-edit: logdir outdir
	$(KLAYOUT) -e $(GDS) |& tee $(KLAYOUT_LOG)


.PHONY: klayout-lvs
klayout-lvs: logdir outdir
	python $(KLAYOUT_HOME)/lvs/run_lvs.py --run_mode=flat --spice_comments --layout=layout/$(TOP).gds --netlist=output/$(TOP)_sch.spice --variant=D --run_dir=logs --verbose  |& tee $(KLAYOUT_LOG)


########
## Magic
########

# TODO: Magic DRC
# TODO: Do pex extraction include resistances?

.PHONY: magic
magic: magic-edit


.PHONY: magic-edit
magic-edit: logdir
	$(MAGIC) $(MAG) |& tee $(MAGIC_LOG)


.PHONY: magic-lvs
magic-lvs: logdir outdir
	LAYOUT=$(TOP_LAYOUT) TOP=$(TOP) $(MAGIC_BATCH) $(MAGIC_LVS) |& tee $(MAGIC_LVS_LOG)


.PHONY: magic-pex
magic-pex: logdir outdir
	LAYOUT=$(TOP_LAYOUT) TOP=$(TOP) $(MAGIC_BATCH) $(MAGIC_PARASITIC) |& tee $(MAGIC_PARASITIC_LOG)

#########
## Netgen
#########

.PHONY: netgen-lvs
netgen-lvs: logdir magic-lvs xschem-lvs
	$(NETGEN) "$(LVS_LAY) $(LVS_LAY_TOP)" "$(LVS_SCH) $(LVS_SCH_TOP)" $(NETGEN_RCFILE) |& tee $(NETGEN_LOG) || true
	grep "Netlist" comp.out


##########
## Aliases
##########

# TODO: Alias for drc

.PHONY: lvs
lvs: netgen-lvs


.PHONY: pex
pex: magic-pex