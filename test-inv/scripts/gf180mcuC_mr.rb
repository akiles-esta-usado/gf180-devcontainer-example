# Copyright 2022 GlobalFoundries PDK Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#===========================================================================================================================
#------------------------------------------- GF 0.18um MCU DRC RULE DECK --------------------------------------------------
#===========================================================================================================================
require 'time'
require "logger"

exec_start_time = Time.now

STDOUT.sync = true    # Prompt logger output.
STDERR.sync = true    # Avoids msg loss if process killed by kernel.
$errs = 0

# non forking way to get mem-size, if /proc/self/status exists, else revert to subshell/pmap...
def getMemSize
  mSize = " "
  
  if ! $gms_init        # open status just once, reread thereafter
    $gms_init = true
    if       File.readable?("/proc/self/status")
      $gms_strm = File.open("/proc/self/status", "r")
    end
  end

  if ! $gms_strm        # revert to fork-based lookup ;(
    return `pmap #{Process.pid} | tail -1`[10,40].strip
  end

  pSize = $gms_strm.readlines.grep(/^VmSize/)[0]
  if pSize
    tok = pSize.split
    if tok.length == 3
      mSize = tok[1,2].join
    end
  end

  # rewind/flush stream for next. By doing it here at end, makes it simpler to also close/reopen for too old ruby
  $gms_strm.rewind
  begin
    $gms_strm.flush     # read new content from start
  rescue Exception
    # No .flush if too old (ruby 1.8): Force reopening file everytime.
    $gms_strm.close
    $gms_init = false
  end

  return mSize
end #def

# non forking way to get available-mem, if /proc/meminfo exists.
# Returns numeric int. If no useful value can be determined: -1.
# Else returns JUST LARGER INT of: MemAvailable SwapFree, after ignoring the units.
# That is, it is presumed (not enforced) the units are always "kB".
# No attempt made to ADD those two: would be more representative.
def getFreeSize
  free = -1

  if ! $gfs_init        # open meminfo just once, reread thereafter
    $gfs_init = true
    if       File.readable?("/proc/meminfo")
      $gfs_strm = File.open("/proc/meminfo", "r")
    end
  end

  if ! $gfs_strm
    return free         # -1: unavailable
  end

  lines = $gfs_strm.readlines
  [ lines.grep(/^MemAvailable/)[0], lines.grep(/^SwapFree/)[0] ].each do |sval|
    if sval
      tok = sval.split       # -> [ "MemAvailable:", "14593528, "kB" ]
      if tok.length == 3
        size = tok[1].to_i   # note: "junk".to_i -> 0
        if size > free
          free = size
        end
      end
    end
  end #do

  # rewind/flush stream for next. By doing it here at end, makes it simpler to also close/reopen for too old ruby
  $gfs_strm.rewind
  begin
    $gfs_strm.flush       # read new content from start
  rescue Exception
    # No .flush if too old (ruby 1.8): Force reopening file everytime.
    $gfs_strm.close
    $gfs_init = false
  end

  return free
end #def

# units:KB, threshold below which to report an "available-mem" in logger
#   Set to -1 to always report available-mem.
$freeMin = 20*(2**20)   # 20GB as "20M KB"

logger = Logger.new(STDOUT)
logger.formatter = proc do |severity, datetime, progname, msg|
  free = getFreeSize()
  if $freeMin && free && (free > -1) && (free <= $freeMin)
    str = "#{datetime}: Memory Usage (" + getMemSize() + ")(avail #{free}) : #{msg}\n"
  else
    str = "#{datetime}: Memory Usage (" + getMemSize() + ") : #{msg}\n"
  end
  str
end #do

#================================================
#----------------- FILE SETUP -------------------
#================================================

# optional for a batch launch :   klayout -b -r gf_018mcu.drc -rd input=design.gds -rd report=gp180_drc.lyrdb

logger.info("Starting running GF180MCU Klayout DRC runset on %s cell %s" % [$input, $topcell])
logger.info("Ruby Version for klayout: %s" % [RUBY_VERSION])

if   File.readable?("/proc/meminfo")
  puts "Memory/Swap config at start (/proc/meminfo):"
  puts File.foreach("/proc/meminfo").grep(/^(Mem|Swap)/)
  puts ""
end #MemSwap

if $input
    if $topcell
        source($input, $topcell)
    else
        source($input)
    end
end

logger.info("Loading database to memory is complete.")

if $report
    logger.info("GF180MCU Klayout DRC runset output at: %s" % [$report])
    report("DRC Run Report at", $report)
else
    logger.info("GF180MCU Klayout DRC runset output at default location." % [File.join(File.dirname(RBA::CellView::active.filename), "gf180_drc.lyrdb")])
    report("DRC Run Report at", File.join(File.dirname(RBA::CellView::active.filename), "gf180_drc.lyrdb"))
end

if $thr
    threads($thr)
    logger.info("Number of threads to use %s" % [$thr])
else
    threads(%x("nproc"))
    logger.info("Number of threads to use #{%x("nproc")}")
end

#=== PRINT DETAILS ===
if $verbose == "true"
  logger.info("Verbose mode: #{$verbose}")
  verbose(true)
else
  verbose(false)
  logger.info("Verbose mode: false")
end

# === TILING MODE ===
if $run_mode == "tiling"
  tiles(500.um)
  tile_borders(10.um)
  logger.info("Tiling  mode is enabled.")

elsif $run_mode == "deep"
  #=== HIER MODE ===
  deep
  logger.info("deep  mode is enabled.")

elsif $run_mode == "flat"
  #=== FLAT MODE ===
  flat
  logger.info("flat  mode is enabled.")

else
  #=== FLAT MODE ===
  flat
  logger.info("flat  mode is enabled.")

end # run_mode

# METAL_LEVEL    Assign BEFORE read-layers, so can avoid reads of unused layers.
if $metal_level
  METAL_LEVEL = $metal_level
else
  METAL_LEVEL = "5LM"
end # METAL_LEVEL

#================================================
#------------- LAYERS DEFINITIONS ---------------
#================================================

logger.info("Read in polygons from layers.")

$logger = logger
def plyMrg( lnum, ltyp, msg=nil)
    if msg
      $logger.info("Executing polygons(#{lnum}, #{ltyp}).merged for #{msg}")
    else
      $logger.info("Executing polygons(#{lnum}, #{ltyp}).merged")
    end
    return polygons( lnum, ltyp).merged
end

comp           = plyMrg(22 , 0, "comp" )
dnwell         = plyMrg(12 , 0, "dnwell" )
nwell          = plyMrg(21 , 0, "nwell" )
lvpwell        = plyMrg(204, 0, "lvpwell" )
dualgate       = plyMrg(55 , 0, "dualgate" )
poly2          = plyMrg(30 , 0, "poly2" )
nplus          = plyMrg(32 , 0, "nplus" )
pplus          = plyMrg(31 , 0, "pplus" )
sab            = plyMrg(49 , 0, "sab" )
esd            = plyMrg(24 , 0, "esd" )
contact        = plyMrg(33 , 0, "contact" )
metal1         = plyMrg(34 , 0, "metal1" )
via1           = plyMrg(35 , 0, "via1" )
metal2         = plyMrg(36 , 0, "metal2" )
via2           = plyMrg(38 , 0, "via2" )
metal3         = plyMrg(42 , 0, "metal3" )
via3           = plyMrg(40 , 0, "via3" )
metal4         = plyMrg(46 , 0, "metal4" )
via4           = plyMrg(41 , 0, "via4" )
metal5         = plyMrg(81 , 0, "metal5" )
## if METAL_LEVEL == "6LM"
  via5           = plyMrg(82 , 0, "via5" )
  metaltop       = plyMrg(53 , 0, "metaltop" )
  metaltop_dummy = plyMrg(53 , 4, "metaltop_dummy" )
  metaltop_label = plyMrg(53 , 10, "metaltop_label")
  metaltop_slot  = plyMrg(53 , 3, "metaltop_slot" )
  metalt_blk     = plyMrg(53 , 5, "metaltop_blk" )
## end #6LM
pad            = plyMrg(37 , 0, "pad" )
resistor       = plyMrg(62 , 0, "resistor" )
fhres          = plyMrg(227, 0, "fhres" )
fusetop        = plyMrg(75 , 0, "fusetop" )
fusewindow_d   = plyMrg(96 , 1, "fusewindow_d" )
polyfuse       = plyMrg(220, 0, "polyfuse" )
mvsd           = plyMrg(210, 0, "mvsd" )
mvpsd          = plyMrg(11 , 39, "mvpsd")
nat            = plyMrg(5  , 0, "nat" )
comp_dummy     = plyMrg(22 , 4, "comp_dummy" )
poly2_dummy    = plyMrg(30 , 4, "poly2_dummy" )
metal1_dummy   = plyMrg(34 , 4, "metal1_dummy" )
metal2_dummy   = plyMrg(36 , 4, "metal2_dummy" )
metal3_dummy   = plyMrg(42 , 4, "metal3_dummy" )
metal4_dummy   = plyMrg(46 , 4, "metal4_dummy" )
metal5_dummy   = plyMrg(81 , 4, "metal5_dummy" )
comp_label     = plyMrg(22 , 10, "comp_label" )
poly2_label    = plyMrg(30 , 10, "poly2_label")
metal1_label   = plyMrg(34 , 10, "metal1_label" )
metal2_label   = plyMrg(36 , 10, "metal2_label" )
metal3_label   = plyMrg(42 , 10, "metal3_label" )
metal4_label   = plyMrg(46 , 10, "metal4_label" )
metal5_label   = plyMrg(81 , 10, "metal5_label" )
metal1_slot    = plyMrg(34 , 3, "metal1_slot" )
metal2_slot    = plyMrg(36 , 3, "metal2_slot" )
metal3_slot    = plyMrg(42 , 3, "metal3_slot" )
metal4_slot    = plyMrg(46 , 3, "metal4_slot" )
metal5_slot    = plyMrg(81 , 3, "metal5_slot" )
ubmpperi       = plyMrg(183, 0, "ubmpperi" )
ubmparray      = plyMrg(184, 0, "ubmparray" )
ubmeplate      = plyMrg(185, 0, "ubmeplate" )
schottky_diode = plyMrg(241, 0, "schottky_diode" )
zener          = plyMrg(178, 0, "zener" )
res_mk         = plyMrg(110, 5, "res_mk" )
opc_drc        = plyMrg(124, 5, "opc_drc" )
ndmy           = plyMrg(111, 5, "ndmy" )
pmndmy         = plyMrg(152, 5, "pmndmy" )
v5_xtor        = plyMrg(112, 1, "v5_xtor" )
cap_mk         = plyMrg(117, 5, "cap_mk" )
mos_cap_mk     = plyMrg(166, 5, "mos_cap_mk" )
ind_mk         = plyMrg(151, 5, "ind_mk" )
diode_mk       = plyMrg(115, 5, "diode_mk" )
drc_bjt        = plyMrg(127, 5, "drc_bjt" )
lvs_bjt        = plyMrg(118, 5, "lvs_bjt" )
mim_l_mk       = plyMrg(117, 10, "mim_l_mk" )
latchup_mk     = plyMrg(137, 5, "latchup_mk" )
guard_ring_mk  = plyMrg(167, 5, "guard_ring_mk" )
otp_mk         = plyMrg(173, 5, "otp_mk" )
mtpmark        = plyMrg(122, 5, "mtpmark" )
neo_ee_mk      = plyMrg(88 , 17, "neo_ee_mk" )
sramcore       = plyMrg(108, 5, "sramcore" )
lvs_rf         = plyMrg(100, 5, "lvs_rf" )
lvs_drain      = plyMrg(100, 7, "lvs_drain" )
## dup: ind_mk         = plyMrg(151, 5 )
hvpolyrs       = plyMrg(123, 5, "hvpolyrs" )
lvs_io         = plyMrg(119, 5, "lvs_io" )
probe_mk       = plyMrg(13 , 17, "probe_mk" )
esd_mk         = plyMrg(24 , 5, "esd_mk" )
lvs_source     = plyMrg(100, 8, "lvs_source" )
well_diode_mk  = plyMrg(153, 51, "well_diode_mk" )
ldmos_xtor     = plyMrg(226, 0, "ldmos_xtor" )
plfuse         = plyMrg(125, 5, "plfuse" )
efuse_mk       = plyMrg(80 , 5, "efuse_mk" )
mcell_feol_mk  = plyMrg(11 , 17, "mcell_feol_mk" )
ymtp_mk        = plyMrg(86 , 17, "ymtp_mk" )
dev_wf_mk      = plyMrg(128, 17, "dev_wf_mk" )
metal1_blk     = plyMrg(34 , 5, "metal1_blk" )
metal2_blk     = plyMrg(36 , 5, "metal2_blk" )
metal3_blk     = plyMrg(42 , 5, "metal3_blk" )
metal4_blk     = plyMrg(46 , 5, "metal4_blk" )
metal5_blk     = plyMrg(81 , 5, "metal5_blk" )
pr_bndry       = plyMrg(0  , 0, "pr_bndry" )
mdiode         = plyMrg(116, 5, "mdiode" )
metal1_res     = plyMrg(110, 11, "metal1_res" )
metal2_res     = plyMrg(110, 12, "metal2_res" )
metal3_res     = plyMrg(110, 13, "metal3_res" )
metal4_res     = plyMrg(110, 14, "metal4_res" )
metal5_res     = plyMrg(110, 15, "metal5_res" )
# no flag to use: metal6_res     = plyMrg(110, 16)
border         = plyMrg(63 , 0, "border" )

# ================= COUNT POLYGONS =================
poly_count = 0
comp_count                     = comp.count()
poly_count                     = poly_count + comp_count
dnwell_count                   = dnwell.count()
poly_count                     = poly_count + dnwell_count
nwell_count                    = nwell.count()
poly_count                     = poly_count + nwell_count
lvpwell_count                  = lvpwell.count()
poly_count                     = poly_count + lvpwell_count
dualgate_count                 = dualgate.count()
poly_count                     = poly_count + dualgate_count
poly2_count                    = poly2.count()
poly_count                     = poly_count + poly2_count
nplus_count                    = nplus.count()
poly_count                     = poly_count + nplus_count
pplus_count                    = pplus.count()
poly_count                     = poly_count + pplus_count
sab_count                      = sab .count()
poly_count                     = poly_count + sab_count
esd_count                      = esd .count()
poly_count                     = poly_count + esd_count
contact_count                  = contact.count()
poly_count                     = poly_count + contact_count
metal1_count                   = metal1.count()
poly_count                     = poly_count + metal1_count
via1_count                     = via1.count()
poly_count                     = poly_count + via1_count
metal2_count                   = metal2.count()
poly_count                     = poly_count + metal2_count
via2_count                     = via2.count()
poly_count                     = poly_count + via2_count
metal3_count                   = metal3.count()
poly_count                     = poly_count + metal3_count
via3_count                     = via3.count()
poly_count                     = poly_count + via3_count
metal4_count                   = metal4.count()
poly_count                     = poly_count + metal4_count
via4_count                     = via4.count()
poly_count                     = poly_count + via4_count
metal5_count                   = metal5.count()
poly_count                     = poly_count + metal5_count
## if METAL_LEVEL == "6LM"
  via5_count                     = via5.count()
  poly_count                     = poly_count + via5_count
  metaltop_count                 = metaltop.count()
  poly_count                     = poly_count + metaltop_count
  metaltop_dummy_count           = metaltop_dummy.count()
  poly_count                     = poly_count + metaltop_dummy_count
  metaltop_label_count           = metaltop_label.count()
  poly_count                     = poly_count + metaltop_label_count
  metaltop_slot_count            = metaltop_slot.count()
  poly_count                     = poly_count + metaltop_slot_count
  metalt_blk_count               = metalt_blk.count()
  poly_count                     = poly_count + metalt_blk_count
## end #6LM
pad_count                      = pad .count()
poly_count                     = poly_count + pad_count
resistor_count                 = resistor.count()
poly_count                     = poly_count + resistor_count
fhres_count                    = fhres.count()
poly_count                     = poly_count + fhres_count
fusetop_count                  = fusetop.count()
poly_count                     = poly_count + fusetop_count
fusewindow_d_count             = fusewindow_d.count()
poly_count                     = poly_count + fusewindow_d_count
polyfuse_count                 = polyfuse.count()
poly_count                     = poly_count + polyfuse_count
mvsd_count                     = mvsd.count()
poly_count                     = poly_count + mvsd_count
mvpsd_count                    = mvpsd.count()
poly_count                     = poly_count + mvpsd_count
nat_count                      = nat .count()
poly_count                     = poly_count + nat_count
comp_dummy_count               = comp_dummy.count()
poly_count                     = poly_count + comp_dummy_count
poly2_dummy_count              = poly2_dummy.count()
poly_count                     = poly_count + poly2_dummy_count
metal1_dummy_count             = metal1_dummy.count()
poly_count                     = poly_count + metal1_dummy_count
metal2_dummy_count             = metal2_dummy.count()
poly_count                     = poly_count + metal2_dummy_count
metal3_dummy_count             = metal3_dummy.count()
poly_count                     = poly_count + metal3_dummy_count
metal4_dummy_count             = metal4_dummy.count()
poly_count                     = poly_count + metal4_dummy_count
metal5_dummy_count             = metal5_dummy.count()
poly_count                     = poly_count + metal5_dummy_count
comp_label_count               = comp_label.count()
poly_count                     = poly_count + comp_label_count
poly2_label_count              = poly2_label.count()
poly_count                     = poly_count + poly2_label_count
metal1_label_count             = metal1_label.count()
poly_count                     = poly_count + metal1_label_count
metal2_label_count             = metal2_label.count()
poly_count                     = poly_count + metal2_label_count
metal3_label_count             = metal3_label.count()
poly_count                     = poly_count + metal3_label_count
metal4_label_count             = metal4_label.count()
poly_count                     = poly_count + metal4_label_count
metal5_label_count             = metal5_label.count()
poly_count                     = poly_count + metal5_label_count
metal1_slot_count              = metal1_slot.count()
poly_count                     = poly_count + metal1_slot_count
metal2_slot_count              = metal2_slot.count()
poly_count                     = poly_count + metal2_slot_count
metal3_slot_count              = metal3_slot.count()
poly_count                     = poly_count + metal3_slot_count
metal4_slot_count              = metal4_slot.count()
poly_count                     = poly_count + metal4_slot_count
metal5_slot_count              = metal5_slot.count()
poly_count                     = poly_count + metal5_slot_count
ubmpperi_count                 = ubmpperi.count()
poly_count                     = poly_count + ubmpperi_count
ubmparray_count                = ubmparray.count()
poly_count                     = poly_count + ubmparray_count
ubmeplate_count                = ubmeplate.count()
poly_count                     = poly_count + ubmeplate_count
schottky_diode_count           = schottky_diode.count()
poly_count                     = poly_count + schottky_diode_count
zener_count                    = zener.count()
poly_count                     = poly_count + zener_count
res_mk_count                   = res_mk.count()
poly_count                     = poly_count + res_mk_count
opc_drc_count                  = opc_drc.count()
poly_count                     = poly_count + opc_drc_count
ndmy_count                     = ndmy.count()
poly_count                     = poly_count + ndmy_count
pmndmy_count                   = pmndmy.count()
poly_count                     = poly_count + pmndmy_count
v5_xtor_count                  = v5_xtor.count()
poly_count                     = poly_count + v5_xtor_count
cap_mk_count                   = cap_mk.count()
poly_count                     = poly_count + cap_mk_count
mos_cap_mk_count               = mos_cap_mk.count()
poly_count                     = poly_count + mos_cap_mk_count
ind_mk_count                   = ind_mk.count()
poly_count                     = poly_count + ind_mk_count
diode_mk_count                 = diode_mk.count()
poly_count                     = poly_count + diode_mk_count
drc_bjt_count                  = drc_bjt.count()
poly_count                     = poly_count + drc_bjt_count
lvs_bjt_count                  = lvs_bjt.count()
poly_count                     = poly_count + lvs_bjt_count
mim_l_mk_count                 = mim_l_mk.count()
poly_count                     = poly_count + mim_l_mk_count
latchup_mk_count               = latchup_mk.count()
poly_count                     = poly_count + latchup_mk_count
guard_ring_mk_count            = guard_ring_mk.count()
poly_count                     = poly_count + guard_ring_mk_count
otp_mk_count                   = otp_mk.count()
poly_count                     = poly_count + otp_mk_count
mtpmark_count                  = mtpmark.count()
poly_count                     = poly_count + mtpmark_count
neo_ee_mk_count                = neo_ee_mk.count()
poly_count                     = poly_count + neo_ee_mk_count
sramcore_count                 = sramcore.count()
poly_count                     = poly_count + sramcore_count
lvs_rf_count                   = lvs_rf.count()
poly_count                     = poly_count + lvs_rf_count
lvs_drain_count                = lvs_drain.count()
poly_count                     = poly_count + lvs_drain_count
## dup: ind_mk_count                   = ind_mk.count()
## dup: poly_count                     = poly_count + ind_mk_count
hvpolyrs_count                 = hvpolyrs.count()
poly_count                     = poly_count + hvpolyrs_count
lvs_io_count                   = lvs_io.count()
poly_count                     = poly_count + lvs_io_count
probe_mk_count                 = probe_mk.count()
poly_count                     = poly_count + probe_mk_count
esd_mk_count                   = esd_mk.count()
poly_count                     = poly_count + esd_mk_count
lvs_source_count               = lvs_source.count()
poly_count                     = poly_count + lvs_source_count
well_diode_mk_count            = well_diode_mk.count()
poly_count                     = poly_count + well_diode_mk_count
ldmos_xtor_count               = ldmos_xtor.count()
poly_count                     = poly_count + ldmos_xtor_count
plfuse_count                   = plfuse.count()
poly_count                     = poly_count + plfuse_count
efuse_mk_count                 = efuse_mk.count()
poly_count                     = poly_count + efuse_mk_count
mcell_feol_mk_count            = mcell_feol_mk.count()
poly_count                     = poly_count + mcell_feol_mk_count
ymtp_mk_count                  = ymtp_mk.count()
poly_count                     = poly_count + ymtp_mk_count
dev_wf_mk_count                = dev_wf_mk.count()
poly_count                     = poly_count + dev_wf_mk_count
metal1_blk_count               = metal1_blk.count()
poly_count                     = poly_count + metal1_blk_count
metal2_blk_count               = metal2_blk.count()
poly_count                     = poly_count + metal2_blk_count
metal3_blk_count               = metal3_blk.count()
poly_count                     = poly_count + metal3_blk_count
metal4_blk_count               = metal4_blk.count()
poly_count                     = poly_count + metal4_blk_count
metal5_blk_count               = metal5_blk.count()
poly_count                     = poly_count + metal5_blk_count
pr_bndry_count                 = pr_bndry.count()
poly_count                     = poly_count + pr_bndry_count
mdiode_count                   = mdiode.count()
poly_count                     = poly_count + mdiode_count
metal1_res_count               = metal1_res.count()
poly_count                     = poly_count + metal1_res_count
metal2_res_count               = metal2_res.count()
poly_count                     = poly_count + metal2_res_count
metal3_res_count               = metal3_res.count()
poly_count                     = poly_count + metal3_res_count
metal4_res_count               = metal4_res.count()
poly_count                     = poly_count + metal4_res_count
metal5_res_count               = metal5_res.count()
poly_count                     = poly_count + metal5_res_count
# no flag to use: metal6_res_count               = metal6_res.count()
#   poly_count                     = poly_count + metal6_res_count
border_count                   = border.count()
poly_count                     = poly_count + border_count

logger.info("Starting deriving base layers.")
#================================================
#------------- LAYERS DERIVATIONS ---------------
#================================================

ncomp      =  comp      & nplus
pcomp      =  comp      & pplus
tgate      =  poly2     & comp
ngate      =  nplus     & tgate
pgate      =  pplus     & tgate
natcompsd	 = (nat       & comp.interacting(poly2)) - tgate

#================================================
#------------------ SWITCHES --------------------
#================================================
logger.info("Evaluate switches.")

# Coerce optional flag-args to booleans, case-insensitive, survives absence (nil-class).
FEOL               =     $feol.to_s.downcase=="true"
BEOL               =     $beol.to_s.downcase=="true"
BEOL_EXTEND        = BEOL
CONNECTIVITY_RULES = $conn_drc.to_s.downcase=="true"
OFFGRID            =  $offgrid.to_s.downcase=="true"

# FEOL
if ! FEOL
  logger.info("FEOL is disabled.")
else
  logger.info("FEOL is enabled.")
end # FEOL

# BEOL
if ! BEOL
  logger.info("BEOL is disabled.")
else
  logger.info("BEOL is enabled.")
end # BEOL

# connectivity rules
if CONNECTIVITY_RULES
  logger.info("connectivity rules are enabled.")
else
  logger.info("connectivity rules are disabled.")
end # connectivity rules

logger.info("METAL_STACK Selected is %s" % [METAL_LEVEL]) # report level 1st, then 2nd (cond.) METAL_TOP

## if METAL_LEVEL=="6LM"   # IFF using metaltop:assign METAL_TOP. To force undef-error if its unused.
# METAL_TOP
if $metal_top
  METAL_TOP = $metal_top
else
  METAL_TOP = "9K"
end # METAL_TOP

logger.info("METAL_TOP Selected is %s" % [METAL_TOP])  # Report IFF we are using metaltop.
## end #6LM

# WEDGE
if $wedge == "false"
  WEDGE = $wedge
else
  WEDGE = "true"
end # WEDGE

logger.info("Wedge enabled  %s" % [WEDGE])

# BALL
if $ball == "false"
  BALL = $ball
else
  BALL = "true"
end # BALL

logger.info("Ball enabled  %s" % [BALL])

# GOLD
if $gold == "false"
  GOLD = $gold
else
  GOLD = "true"
end # GOLD

logger.info("Gold enabled  %s" % [GOLD])

if $mim_option
  MIM_OPTION = $mim_option
else
  MIM_OPTION = "B"
end

logger.info("MIM Option selected %s" % [MIM_OPTION])

logger.info("Offgrid enabled  %s" % [OFFGRID])

#================================================
#------------- METAL LEVEL SWITCHES -------------
#================================================


if METAL_LEVEL == "6LM"
    top_via       = via5
    topmin1_via   = via4
    top_metal     = metaltop
    topmin1_metal = metal5
elsif METAL_LEVEL == "5LM"
    top_via       = via4
    topmin1_via   = via3
    top_metal     = metal5
    topmin1_metal = metal4
elsif METAL_LEVEL == "4LM"
    top_via       = via3
    topmin1_via   = via2
    top_metal     = metal4
    topmin1_metal = metal3
elsif METAL_LEVEL == "3LM"
    top_via       = via2
    topmin1_via   = via1
    top_metal     = metal3
    topmin1_metal = metal2
elsif METAL_LEVEL == "2LM"
    top_via       = via1
    topmin1_via   = via1
    top_metal     = metal2
    topmin1_metal = metal1
end #METAL_LEVEL

#================================================
#------------- LAYERS CONNECTIONS ---------------
#================================================

if CONNECTIVITY_RULES && (FEOL || BEOL)    # required for FEOL or BEOL; But Skip for OFFGRID.

  logger.info("Construct connectivity for the design.")

  connect(dnwell,  ncomp)
  connect(ncomp,  contact)
  connect(pcomp,  contact)
  connect(lvpwell,  ncomp)
  connect(nwell,  ncomp)
  connect(natcompsd,  contact)
  connect(mvsd,  ncomp)
  connect(mvpsd,  pcomp)
  connect(contact,  metal1)
  connect(metal1,  via1)
  connect(via1,    metal2)
  connect(metal2,  via2)
  connect(via2,    metal3)
  connect(metal3,  via3)
  connect(via3,    metal4)
  connect(metal4,  via4)
  connect(via4,    metal5)
##  if METAL_LEVEL == "6LM"    # If GDS has via5,metaltop data but mode!=6LM, this corrupts connectivity.
    connect(metal5,  via5)
    connect(via5,    metaltop)
##  end #6LM

end #CONNECTIVITY_RULES

#================================================
#------------ PRE-DEFINED FUNCTIONS -------------
#================================================

def conn_space(layer,conn_val,not_conn_val, mode)
  if conn_val > not_conn_val
    raise "ERROR : Wrong connectivity implementation"
  end
  connected_output = layer.space(conn_val.um, mode).polygons(0.001)
  unconnected_errors_unfiltered = layer.space(not_conn_val.um, mode)
  singularity_errors = layer.space(0.001.um)
  # Filter out the errors arising from the same net
  unconnected_errors = DRC::DRCLayer::new(self, RBA::EdgePairs::new)
  unconnected_errors_unfiltered.data.each do |ep|
    net1 = l2n_data.probe_net(layer.data, ep.first.p1)
    net2 = l2n_data.probe_net(layer.data, ep.second.p1)
    if !net1 || !net2
      puts "Should not happen ..."
    elsif net1.circuit != net2.circuit || net1.cluster_id != net2.cluster_id
      # unconnected
      unconnected_errors.data.insert(ep)
    end
  end
  unconnected_output = unconnected_errors.polygons.or(singularity_errors.polygons(0.001))
  return connected_output, unconnected_output
end

def conn_separation(layer1, layer2, conn_val,not_conn_val, mode)
  if conn_val > not_conn_val
    raise "ERROR : Wrong connectivity implementation"
  end
  connected_output = layer1.separation(layer2, conn_val.um, mode).polygons(0.001)
  unconnected_errors_unfiltered = layer1.separation(layer2, not_conn_val.um, mode)
  # Filter out the errors arising from the same net
  unconnected_errors = DRC::DRCLayer::new(self, RBA::EdgePairs::new)
  unconnected_errors_unfiltered.data.each do |ep|
    net1 = l2n_data.probe_net(layer1.data, ep.first.p1)
    net2 = l2n_data.probe_net(layer2.data, ep.second.p1)
    if !net1 || !net2
      puts "Should not happen ..."
    elsif net1.circuit != net2.circuit || net1.cluster_id != net2.cluster_id
      # unconnected
      unconnected_errors.data.insert(ep)
    end
  end
  unconnected_output = unconnected_errors.polygons(0.001)
  return connected_output, unconnected_output
end

# === IMPLICIT EXTRACTION ===
if CONNECTIVITY_RULES
  logger.info("Connectivity rules enabled, Netlist object will be generated.")
  netlist
end #CONNECTIVITY_RULES

# === LAYOUT EXTENT ===
CHIP = extent.sized(0.0)

logger.info("Total area of the design is #{CHIP.area()} um^2.")

logger.info("Total no. of polygons in the design is #{poly_count}")

logger.info("Initialization and base layers definition.")

#================================================
#----------------- MAIN RUNSET ------------------
#================================================

logger.info("Starting GF180MCU DRC rules.")

if FEOL
logger.info("FEOL section")

#================================================
#---------------------DNWELL---------------------
#================================================

# Rule DN.1: Min. DNWELL Width is 1.7µm
logger.info("Executing rule DN.1")
dn1_l1  = dnwell.width(1.7.um, euclidian).polygons(0.001)
dn1_l1.output("DN.1", "DN.1 : Min. DNWELL Width : 1.7µm")
dn1_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_dnwell, unconnected_dnwell = conn_space(dnwell, 2.5, 5.42, euclidian)

# Rule DN.2a: Min. DNWELL Space (Equi-potential), Merge if the space is less than is 2.5µm
logger.info("Executing rule DN.2a")
dn2a_l1  = connected_dnwell
dn2a_l1.output("DN.2a", "DN.2a : Min. DNWELL Space (Equi-potential), Merge if the space is less than : 2.5µm")
dn2a_l1.forget

# Rule DN.2b: Min. DNWELL Space (Different potential) is 5.42µm
logger.info("Executing rule DN.2b")
dn2b_l1  = unconnected_dnwell
dn2b_l1.output("DN.2b", "DN.2b : Min. DNWELL Space (Different potential) : 5.42µm")
dn2b_l1.forget

else
logger.info("CONNECTIVITY_RULES disabled section")

# Rule DN.2b_: Min. DNWELL Space (Different potential) is 5.42µm
logger.info("Executing rule DN.2b_")
dn2b_l1  = dnwell.isolated(5.42.um, euclidian).polygons(0.001)
dn2b_l1.output("DN.2b_", "DN.2b_ : Min. DNWELL Space (Different potential) : 5.42µm")
dn2b_l1.forget

end #CONNECTIVITY_RULES

dn3_1 = dnwell.not_inside(pcomp.holes.not(pcomp).interacting(dnwell, 1..1).extents)
dn3_2 = dnwell.inside((pcomp.holes.not(pcomp).covering(nat.or(ncomp).or(nwell).not_interacting(dnwell))))
# Rule DN.3: Each DNWELL shall be directly surrounded by PCOMP guard ring tied to the P-substrate potential.
logger.info("Executing rule DN.3")
dn3_l1 = dn3_1.or(dn3_2)
dn3_l1.output("DN.3", "DN.3 : Each DNWELL shall be directly surrounded by PCOMP guard ring tied to the P-substrate potential.")
dn3_l1.forget

dn3_1.forget

dn3_2.forget

#================================================
#--------------------LVPWELL---------------------
#================================================

# Rule LPW.1_3.3V: Min. LVPWELL Width. is 0.6µm
logger.info("Executing rule LPW.1_3.3V")
lpw1_l1  = lvpwell.width(0.6.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
lpw1_l1.output("LPW.1_3.3V", "LPW.1_3.3V : Min. LVPWELL Width. : 0.6µm")
lpw1_l1.forget

# Rule LPW.1_5V: Min. LVPWELL Width. is 0.74µm
logger.info("Executing rule LPW.1_5V")
lpw1_l1  = lvpwell.width(0.74.um, euclidian).polygons(0.001).overlapping(dualgate)
lpw1_l1.output("LPW.1_5V", "LPW.1_5V : Min. LVPWELL Width. : 0.74µm")
lpw1_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_lvpwell_3p3v, unconnected_lvpwell_3p3v = conn_space(lvpwell, 0.86, 1.4, euclidian)

connected_lvpwell_5p0v, unconnected_lvpwell_5p0v = conn_space(lvpwell, 0.86, 1.7, euclidian)

# Rule LPW.2a_3.3V: Min. LVPWELL to LVWELL Space (Inside DNWELL) [Different potential]. is 1.4µm
logger.info("Executing rule LPW.2a_3.3V")
lpw2a_l1  = unconnected_lvpwell_3p3v.not_interacting(v5_xtor).not_interacting(dualgate)
lpw2a_l1.output("LPW.2a_3.3V", "LPW.2a_3.3V : Min. LVPWELL to LVWELL Space (Inside DNWELL) [Different potential]. : 1.4µm")
lpw2a_l1.forget

# Rule LPW.2a_5V: Min. LVPWELL to LVPWELL Space (Inside DNWELL) [Different potential]. is 1.7µm
logger.info("Executing rule LPW.2a_5V")
lpw2a_l1  = unconnected_lvpwell_5p0v.overlapping(dualgate)
lpw2a_l1.output("LPW.2a_5V", "LPW.2a_5V : Min. LVPWELL to LVPWELL Space (Inside DNWELL) [Different potential]. : 1.7µm")
lpw2a_l1.forget

# Rule LPW.2b_3.3V: Min. LVPWELL to LVPWELL Space [Equi potential]. is 0.86µm
logger.info("Executing rule LPW.2b_3.3V")
lpw2b_l1  = connected_lvpwell_3p3v.not_interacting(v5_xtor).not_interacting(dualgate)
lpw2b_l1.output("LPW.2b_3.3V", "LPW.2b_3.3V : Min. LVPWELL to LVPWELL Space [Equi potential]. : 0.86µm")
lpw2b_l1.forget

# Rule LPW.2b_5V: Min. LVPWELL to LVPWELL Space [Equi potential]. is 0.86µm
logger.info("Executing rule LPW.2b_5V")
lpw2b_l1  = connected_lvpwell_5p0v.overlapping(dualgate)
lpw2b_l1.output("LPW.2b_5V", "LPW.2b_5V : Min. LVPWELL to LVPWELL Space [Equi potential]. : 0.86µm")
lpw2b_l1.forget

else
logger.info("CONNECTIVITY_RULES disabled section")

# Rule LPW.2a_3.3V_: Min. LVPWELL to LVWELL Space (Inside DNWELL) [Different potential]. is 1.4µm
logger.info("Executing rule LPW.2a_3.3V_")
lpw2a_l1  = lvpwell.isolated(1.4.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
lpw2a_l1.output("LPW.2a_3.3V_", "LPW.2a_3.3V_ : Min. LVPWELL to LVWELL Space (Inside DNWELL) [Different potential]. : 1.4µm")
lpw2a_l1.forget

# Rule LPW.2a_5V_: Min. LVPWELL to LVPWELL Space (Inside DNWELL) [Different potential]. is 1.7µm
logger.info("Executing rule LPW.2a_5V_")
lpw2a_l1  = lvpwell.isolated(1.7.um, euclidian).polygons(0.001).overlapping(dualgate)
lpw2a_l1.output("LPW.2a_5V_", "LPW.2a_5V_ : Min. LVPWELL to LVPWELL Space (Inside DNWELL) [Different potential]. : 1.7µm")
lpw2a_l1.forget

end #CONNECTIVITY_RULES

# Rule LPW.3_3.3V: Min. DNWELL enclose LVPWELL. is 2.5µm
logger.info("Executing rule LPW.3_3.3V")
lpw3_l1 = dnwell.enclosing(lvpwell, 2.5.um, euclidian).polygons(0.001)
lpw3_l2 = lvpwell.not_outside(dnwell).not(dnwell)
lpw3_l  = lpw3_l1.or(lpw3_l2).not_interacting(v5_xtor).not_interacting(dualgate)
lpw3_l.output("LPW.3_3.3V", "LPW.3_3.3V : Min. DNWELL enclose LVPWELL. : 2.5µm")
lpw3_l1.forget
lpw3_l2.forget
lpw3_l.forget

# Rule LPW.3_5V: Min. DNWELL enclose LVPWELL. is 2.5µm
logger.info("Executing rule LPW.3_5V")
lpw3_l1 = dnwell.enclosing(lvpwell, 2.5.um, euclidian).polygons(0.001)
lpw3_l2 = lvpwell.not_outside(dnwell).not(dnwell)
lpw3_l  = lpw3_l1.or(lpw3_l2).overlapping(dualgate)
lpw3_l.output("LPW.3_5V", "LPW.3_5V : Min. DNWELL enclose LVPWELL. : 2.5µm")
lpw3_l1.forget
lpw3_l2.forget
lpw3_l.forget

# rule LPW.4_3.3V is not a DRC check

# rule LPW.4_5V is not a DRC check

# Rule LPW.5_3.3V: LVPWELL resistors must be enclosed by DNWELL.
logger.info("Executing rule LPW.5_3.3V")
lpw5_l1 = lvpwell.inside(res_mk).not_inside(dnwell).not_interacting(v5_xtor).not_interacting(dualgate)
lpw5_l1.output("LPW.5_3.3V", "LPW.5_3.3V : LVPWELL resistors must be enclosed by DNWELL.")
lpw5_l1.forget

# Rule LPW.5_5V: LVPWELL resistors must be enclosed by DNWELL.
logger.info("Executing rule LPW.5_5V")
lpw5_l1 = lvpwell.inside(res_mk).not_inside(dnwell).overlapping(dualgate)
lpw5_l1.output("LPW.5_5V", "LPW.5_5V : LVPWELL resistors must be enclosed by DNWELL.")
lpw5_l1.forget

# Rule LPW.11: Min. (LVPWELL outside DNWELL) space to DNWELL. is 1.5µm
logger.info("Executing rule LPW.11")
lpw11_l1  = lvpwell.outside(dnwell).separation(dnwell, 1.5.um, euclidian).polygons(0.001)
lpw11_l1.output("LPW.11", "LPW.11 : Min. (LVPWELL outside DNWELL) space to DNWELL. : 1.5µm")
lpw11_l1.forget

# Rule LPW.12: LVPWELL cannot overlap with Nwell.
logger.info("Executing rule LPW.12")
lpw12_l1 = lvpwell.not_outside(nwell)
lpw12_l1.output("LPW.12", "LPW.12 : LVPWELL cannot overlap with Nwell.")
lpw12_l1.forget

#================================================
#---------------------NWELL----------------------
#================================================

# Rule NW.1a_3.3V: Min. Nwell Width (This is only for litho purpose on the generated area). is 0.86µm
logger.info("Executing rule NW.1a_3.3V")
nw1a_l1  = nwell.width(0.86.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
nw1a_l1.output("NW.1a_3.3V", "NW.1a_3.3V : Min. Nwell Width (This is only for litho purpose on the generated area). : 0.86µm")
nw1a_l1.forget

# Rule NW.1a_5V: Min. Nwell Width (This is only for litho purpose on the generated area). is 0.86µm
logger.info("Executing rule NW.1a_5V")
nw1a_l1  = nwell.width(0.86.um, euclidian).polygons(0.001).overlapping(dualgate)
nw1a_l1.output("NW.1a_5V", "NW.1a_5V : Min. Nwell Width (This is only for litho purpose on the generated area). : 0.86µm")
nw1a_l1.forget

nw_1b = nwell.outside(dnwell).and(res_mk)
# Rule NW.1b_3.3V: Min. Nwell Width as a resistor (Outside DNWELL only). is 2µm
logger.info("Executing rule NW.1b_3.3V")
nw1b_l1  = nw_1b.width(2.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
nw1b_l1.output("NW.1b_3.3V", "NW.1b_3.3V : Min. Nwell Width as a resistor (Outside DNWELL only). : 2µm")
nw1b_l1.forget

# Rule NW.1b_5V: Min. Nwell Width as a resistor (Outside DNWELL only). is 2µm
logger.info("Executing rule NW.1b_5V")
nw1b_l1  = nw_1b.width(2.um, euclidian).polygons(0.001).overlapping(dualgate)
nw1b_l1.output("NW.1b_5V", "NW.1b_5V : Min. Nwell Width as a resistor (Outside DNWELL only). : 2µm")
nw1b_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_nwell_3p3v, unconnected_nwell_3p3v = conn_space(nwell, 0.6, 1.4, euclidian)

connected_nwell_5p0v, unconnected_nwell_5p0v = conn_space(nwell, 0.74, 1.7, euclidian)

# Rule NW.2a_3.3V: Min. Nwell Space (Outside DNWELL) [Equi-potential], Merge if the space is less than. is 0.6µm
logger.info("Executing rule NW.2a_3.3V")
nw2a_l1  = connected_nwell_3p3v.not_inside(ymtp_mk).not_interacting(v5_xtor).not_interacting(dualgate)
nw2a_l1.output("NW.2a_3.3V", "NW.2a_3.3V : Min. Nwell Space (Outside DNWELL) [Equi-potential], Merge if the space is less than. : 0.6µm")
nw2a_l1.forget

# Rule NW.2a_5V: Min. Nwell Space (Outside DNWELL) [Equi-potential], Merge if the space is less than. is 0.74µm
logger.info("Executing rule NW.2a_5V")
nw2a_l1  = connected_nwell_5p0v.not_inside(ymtp_mk).overlapping(dualgate)
nw2a_l1.output("NW.2a_5V", "NW.2a_5V : Min. Nwell Space (Outside DNWELL) [Equi-potential], Merge if the space is less than. : 0.74µm")
nw2a_l1.forget

# Rule NW.2b_3.3V: Min. Nwell Space (Outside DNWELL) [Different potential]. is 1.4µm
logger.info("Executing rule NW.2b_3.3V")
nw2b_l1  = unconnected_nwell_3p3v.not_interacting(v5_xtor).not_interacting(dualgate)
nw2b_l1.output("NW.2b_3.3V", "NW.2b_3.3V : Min. Nwell Space (Outside DNWELL) [Different potential]. : 1.4µm")
nw2b_l1.forget

# Rule NW.2b_5V: Min. Nwell Space (Outside DNWELL) [Different potential]. is 1.7µm
logger.info("Executing rule NW.2b_5V")
nw2b_l1  = unconnected_nwell_5p0v.overlapping(dualgate)
nw2b_l1.output("NW.2b_5V", "NW.2b_5V : Min. Nwell Space (Outside DNWELL) [Different potential]. : 1.7µm")
nw2b_l1.forget

else
logger.info("CONNECTIVITY_RULES disabled section")

# Rule NW.2b_3.3V_: Min. Nwell Space (Outside DNWELL) [Different potential]. is 1.4µm
logger.info("Executing rule NW.2b_3.3V_")
nw2b_l1  = nwell.isolated(1.4.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
nw2b_l1.output("NW.2b_3.3V_", "NW.2b_3.3V_ : Min. Nwell Space (Outside DNWELL) [Different potential]. : 1.4µm")
nw2b_l1.forget

# Rule NW.2b_5V_: Min. Nwell Space (Outside DNWELL) [Different potential]. is 1.7µm
logger.info("Executing rule NW.2b_5V_")
nw2b_l1  = nwell.isolated(1.7.um, euclidian).polygons(0.001).overlapping(dualgate)
nw2b_l1.output("NW.2b_5V_", "NW.2b_5V_ : Min. Nwell Space (Outside DNWELL) [Different potential]. : 1.7µm")
nw2b_l1.forget

end #CONNECTIVITY_RULES

# Rule NW.3_3.3V: Min. Nwell to DNWELL space. is 3.1µm
logger.info("Executing rule NW.3_3.3V")
nw3_l1  = nwell.separation(dnwell, 3.1.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
nw3_l1.output("NW.3_3.3V", "NW.3_3.3V : Min. Nwell to DNWELL space. : 3.1µm")
nw3_l1.forget

# Rule NW.3_5V: Min. Nwell to DNWELL space. is 3.1µm
logger.info("Executing rule NW.3_5V")
nw3_l1  = nwell.separation(dnwell, 3.1.um, euclidian).polygons(0.001).overlapping(dualgate)
nw3_l1.output("NW.3_5V", "NW.3_5V : Min. Nwell to DNWELL space. : 3.1µm")
nw3_l1.forget

# Rule NW.4_3.3V: Min. Nwell to LVPWELL space.
logger.info("Executing rule NW.4_3.3V")
nw4_l1 = nwell.not_outside(lvpwell).not_interacting(v5_xtor).not_interacting(dualgate)
nw4_l1.output("NW.4_3.3V", "NW.4_3.3V : Min. Nwell to LVPWELL space.")
nw4_l1.forget

# Rule NW.4_5V: Min. Nwell to LVPWELL space.
logger.info("Executing rule NW.4_5V")
nw4_l1 = nwell.not_outside(lvpwell).overlapping(dualgate)
nw4_l1.output("NW.4_5V", "NW.4_5V : Min. Nwell to LVPWELL space.")
nw4_l1.forget

# Rule NW.5_3.3V: Min. DNWELL enclose Nwell. is 0.5µm
logger.info("Executing rule NW.5_3.3V")
nw5_l1 = dnwell.enclosing(nwell, 0.5.um, euclidian).polygons(0.001)
nw5_l2 = nwell.not_outside(dnwell).not(dnwell)
nw5_l  = nw5_l1.or(nw5_l2).not_interacting(v5_xtor).not_interacting(dualgate)
nw5_l.output("NW.5_3.3V", "NW.5_3.3V : Min. DNWELL enclose Nwell. : 0.5µm")
nw5_l1.forget
nw5_l2.forget
nw5_l.forget

# Rule NW.5_5V: Min. DNWELL enclose Nwell. is 0.5µm
logger.info("Executing rule NW.5_5V")
nw5_l1 = dnwell.enclosing(nwell, 0.5.um, euclidian).polygons(0.001)
nw5_l2 = nwell.not_outside(dnwell).not(dnwell)
nw5_l  = nw5_l1.or(nw5_l2).overlapping(dualgate)
nw5_l.output("NW.5_5V", "NW.5_5V : Min. DNWELL enclose Nwell. : 0.5µm")
nw5_l1.forget
nw5_l2.forget
nw5_l.forget

# Rule NW.6: Nwell resistors can only exist outside DNWELL.
logger.info("Executing rule NW.6")
nw6_l1 = nwell.inside(res_mk).interacting(dnwell)
nw6_l1.output("NW.6", "NW.6 : Nwell resistors can only exist outside DNWELL.")
nw6_l1.forget

# rule NW.6_5V is not a DRC check

# rule NW.7_3.3V is not a DRC check

# rule NW.7_5V is not a DRC check

#================================================
#----------------------COMP----------------------
#================================================

# Rule DF.1a_3.3V: Min. COMP Width. is 0.22µm
logger.info("Executing rule DF.1a_3.3V")
df1a_l1  = comp.width(0.22.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df1a_l1.output("DF.1a_3.3V", "DF.1a_3.3V : Min. COMP Width. : 0.22µm")
df1a_l1.forget

# Rule DF.1a_5V: Min. COMP Width. is 0.3µm
logger.info("Executing rule DF.1a_5V")
df1a_l1  = comp.not_inside(mvsd).not_inside(mvpsd).width(0.3.um, euclidian).polygons(0.001).overlapping(dualgate)
df1a_l1.output("DF.1a_5V", "DF.1a_5V : Min. COMP Width. : 0.3µm")
df1a_l1.forget

# rule DF.1b_3.3V is not a DRC check

# rule DF.1b_5V is not a DRC check

# Rule DF.1c_3.3V: Min. COMP Width for MOSCAP. is 1µm
logger.info("Executing rule DF.1c_3.3V")
df1c_l1  = comp.and(mos_cap_mk).width(1.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df1c_l1.output("DF.1c_3.3V", "DF.1c_3.3V : Min. COMP Width for MOSCAP. : 1µm")
df1c_l1.forget

# Rule DF.1c_5V: Min. COMP Width for MOSCAP. is 1µm
logger.info("Executing rule DF.1c_5V")
df1c_l1  = comp.and(mos_cap_mk).width(1.um, euclidian).polygons(0.001).overlapping(dualgate)
df1c_l1.output("DF.1c_5V", "DF.1c_5V : Min. COMP Width for MOSCAP. : 1µm")
df1c_l1.forget

df_2a = comp.not(poly2).edges.and(tgate.edges)
# Rule DF.2a_3.3V: Min Channel Width. is nil,0.22µm
logger.info("Executing rule DF.2a_3.3V")
df2a_l1 = df_2a.with_length(nil,0.22.um).extended(0, 0, 0.001, 0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df2a_l1.output("DF.2a_3.3V", "DF.2a_3.3V : Min Channel Width. : nil,0.22µm")
df2a_l1.forget

# Rule DF.2a_5V: Min Channel Width. is nil,0.3µm
logger.info("Executing rule DF.2a_5V")
df2a_l1 = df_2a.with_length(nil,0.3.um).extended(0, 0, 0.001, 0.001).overlapping(dualgate)
df2a_l1.output("DF.2a_5V", "DF.2a_5V : Min Channel Width. : nil,0.3µm")
df2a_l1.forget

df_2a.forget

df_2b = comp.drc(width <= 100.um).polygons(0.001).not_inside(mos_cap_mk)
# Rule DF.2b_3.3V: Max. COMP width for all cases except those used for capacitors, marked by ‘MOS_CAP_MK’ layer.
logger.info("Executing rule DF.2b_3.3V")
df2b_l1 = comp.not_inside(mos_cap_mk).not_interacting(df_2b).not_interacting(v5_xtor).not_interacting(dualgate)
df2b_l1.output("DF.2b_3.3V", "DF.2b_3.3V : Max. COMP width for all cases except those used for capacitors, marked by ‘MOS_CAP_MK’ layer.")
df2b_l1.forget

# Rule DF.2b_5V: Max. COMP width for all cases except those used for capacitors, marked by ‘MOS_CAP_MK’ layer.
logger.info("Executing rule DF.2b_5V")
df2b_l1 = comp.not_inside(mos_cap_mk).not_interacting(df_2b).overlapping(dualgate)
df2b_l1.output("DF.2b_5V", "DF.2b_5V : Max. COMP width for all cases except those used for capacitors, marked by ‘MOS_CAP_MK’ layer.")
df2b_l1.forget

df_2b.forget

# Rule DF.3a_3.3V: Min. COMP Space P-substrate tap (PCOMP outside NWELL and DNWELL) can be butted for different voltage devices as the potential is same. is 0.28µm
logger.info("Executing rule DF.3a_3.3V")
df3a_l1  = comp.not(otp_mk).space(0.28.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df3a_l1.output("DF.3a_3.3V", "DF.3a_3.3V : Min. COMP Space P-substrate tap (PCOMP outside NWELL and DNWELL) can be butted for different voltage devices as the potential is same. : 0.28µm")
df3a_l1.forget

# Rule DF.3a_5V: Min. COMP Space P-substrate tap (PCOMP outside NWELL and DNWELL) can be butted for different voltage devices as the potential is same. is 0.36µm
logger.info("Executing rule DF.3a_5V")
df3a_l1  = comp.not(otp_mk).space(0.36.um, euclidian).polygons(0.001).overlapping(dualgate)
df3a_l1.output("DF.3a_5V", "DF.3a_5V : Min. COMP Space P-substrate tap (PCOMP outside NWELL and DNWELL) can be butted for different voltage devices as the potential is same. : 0.36µm")
df3a_l1.forget

df_3b_same_well = ncomp.inside(nwell).not_outside(pcomp.inside(nwell)).or(ncomp.inside(lvpwell).not_outside(pcomp.inside(lvpwell)))
df_3b_moscap = ncomp.inside(nwell).interacting(pcomp.inside(nwell)).or(ncomp.inside(lvpwell).interacting(pcomp.inside(lvpwell))).inside(mos_cap_mk)
# Rule DF.3b_3.3V: Min./Max. NCOMP Space to PCOMP in the same well for butted COMP (MOSCAP butting is not allowed).
logger.info("Executing rule DF.3b_3.3V")
df3b_l1 = df_3b_same_well.or(df_3b_moscap).not_interacting(v5_xtor).not_interacting(dualgate)
df3b_l1.output("DF.3b_3.3V", "DF.3b_3.3V : Min./Max. NCOMP Space to PCOMP in the same well for butted COMP (MOSCAP butting is not allowed).")
df3b_l1.forget

# Rule DF.3b_5V: Min./Max. NCOMP Space to PCOMP in the same well for butted COMP(MOSCAP butting is not allowed).
logger.info("Executing rule DF.3b_5V")
df3b_l1 = df_3b_same_well.or(df_3b_moscap).overlapping(dualgate)
df3b_l1.output("DF.3b_5V", "DF.3b_5V : Min./Max. NCOMP Space to PCOMP in the same well for butted COMP(MOSCAP butting is not allowed).")
df3b_l1.forget

df_3b_same_well.forget

df_3b_moscap.forget

# Rule DF.3c_3.3V: Min. COMP Space in BJT area (area marked by DRC_BJT layer). is 0.32µm
logger.info("Executing rule DF.3c_3.3V")
df3c_l1  = comp.inside(drc_bjt).space(0.32.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df3c_l1.output("DF.3c_3.3V", "DF.3c_3.3V : Min. COMP Space in BJT area (area marked by DRC_BJT layer). : 0.32µm")
df3c_l1.forget

# Rule DF.3c_5V: Min. COMP Space in BJT area (area marked by DRC_BJT layer) hasn’t been assessed.
logger.info("Executing rule DF.3c_5V")
df3c_l1 = comp.interacting(comp.inside(drc_bjt).and(dualgate).space(10.um, euclidian).polygons(0.001))
df3c_l1.output("DF.3c_5V", "DF.3c_5V : Min. COMP Space in BJT area (area marked by DRC_BJT layer) hasn’t been assessed.")
df3c_l1.forget

ntap_dnwell = ncomp.not_interacting(tgate).inside(dnwell)
# Rule DF.4a_3.3V: Min. (LVPWELL Space to NCOMP well tap) inside DNWELL. is 0.12µm
logger.info("Executing rule DF.4a_3.3V")
df4a_l1  = ntap_dnwell.separation(lvpwell.inside(dnwell), 0.12.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df4a_l1.output("DF.4a_3.3V", "DF.4a_3.3V : Min. (LVPWELL Space to NCOMP well tap) inside DNWELL. : 0.12µm")
df4a_l1.forget

# Rule DF.4a_5V: Min. (LVPWELL Space to NCOMP well tap) inside DNWELL. is 0.16µm
logger.info("Executing rule DF.4a_5V")
df4a_l1  = ntap_dnwell.separation(lvpwell.inside(dnwell), 0.16.um, euclidian).polygons(0.001).overlapping(dualgate)
df4a_l1.output("DF.4a_5V", "DF.4a_5V : Min. (LVPWELL Space to NCOMP well tap) inside DNWELL. : 0.16µm")
df4a_l1.forget

# Rule DF.4b_3.3V: Min. DNWELL overlap of NCOMP well tap. is 0.62µm
logger.info("Executing rule DF.4b_3.3V")
df4b_l1 = dnwell.enclosing(ncomp.not_interacting(tgate), 0.62.um, euclidian).polygons(0.001)
df4b_l2 = ncomp.not_interacting(tgate).not_outside(dnwell).not(dnwell)
df4b_l  = df4b_l1.or(df4b_l2).not_interacting(v5_xtor).not_interacting(dualgate)
df4b_l.output("DF.4b_3.3V", "DF.4b_3.3V : Min. DNWELL overlap of NCOMP well tap. : 0.62µm")
df4b_l1.forget
df4b_l2.forget
df4b_l.forget

# Rule DF.4b_5V: Min. DNWELL overlap of NCOMP well tap. is 0.66µm
logger.info("Executing rule DF.4b_5V")
df4b_l1 = dnwell.enclosing(ncomp.not_interacting(tgate), 0.66.um, euclidian).polygons(0.001)
df4b_l2 = ncomp.not_interacting(tgate).not_outside(dnwell).not(dnwell)
df4b_l  = df4b_l1.or(df4b_l2).overlapping(dualgate)
df4b_l.output("DF.4b_5V", "DF.4b_5V : Min. DNWELL overlap of NCOMP well tap. : 0.66µm")
df4b_l1.forget
df4b_l2.forget
df4b_l.forget

ntap_dnwell.forget

nwell_n_dnwell = nwell.outside(dnwell)
# Rule DF.4c_3.3V: Min. (Nwell overlap of PCOMP) outside DNWELL. is 0.43µm
logger.info("Executing rule DF.4c_3.3V")
df4c_l1 = nwell_n_dnwell.outside(sramcore).enclosing(pcomp.outside(dnwell), 0.43.um, euclidian).polygons(0.001)
df4c_l2 = pcomp.outside(dnwell).not_outside(nwell_n_dnwell.outside(sramcore)).not(nwell_n_dnwell.outside(sramcore))
df4c_l  = df4c_l1.or(df4c_l2).not_interacting(v5_xtor).not_interacting(dualgate)
df4c_l.output("DF.4c_3.3V", "DF.4c_3.3V : Min. (Nwell overlap of PCOMP) outside DNWELL. : 0.43µm")
df4c_l1.forget
df4c_l2.forget
df4c_l.forget

# Rule DF.4c_5V: Min. (Nwell overlap of PCOMP) outside DNWELL. is 0.6µm
logger.info("Executing rule DF.4c_5V")
df4c_l1 = nwell_n_dnwell.outside(sramcore).enclosing(pcomp.outside(dnwell), 0.6.um, euclidian).polygons(0.001)
df4c_l2 = pcomp.outside(dnwell).not_outside(nwell_n_dnwell.outside(sramcore)).not(nwell_n_dnwell.outside(sramcore))
df4c_l  = df4c_l1.or(df4c_l2).overlapping(dualgate)
df4c_l.output("DF.4c_5V", "DF.4c_5V : Min. (Nwell overlap of PCOMP) outside DNWELL. : 0.6µm")
df4c_l1.forget
df4c_l2.forget
df4c_l.forget

# Rule DF.4d_3.3V: Min. (Nwell overlap of NCOMP) outside DNWELL. is 0.12µm
logger.info("Executing rule DF.4d_3.3V")
df4d_l1 = nwell_n_dnwell.not_inside(ymtp_mk).not_inside(neo_ee_mk).enclosing(ncomp.outside(dnwell).not_inside(ymtp_mk), 0.12.um, euclidian).polygons(0.001)
df4d_l2 = ncomp.outside(dnwell).not_inside(ymtp_mk).not_outside(nwell_n_dnwell.not_inside(ymtp_mk).not_inside(neo_ee_mk)).not(nwell_n_dnwell.not_inside(ymtp_mk).not_inside(neo_ee_mk))
df4d_l  = df4d_l1.or(df4d_l2).not_interacting(v5_xtor).not_interacting(dualgate)
df4d_l.output("DF.4d_3.3V", "DF.4d_3.3V : Min. (Nwell overlap of NCOMP) outside DNWELL. : 0.12µm")
df4d_l1.forget
df4d_l2.forget
df4d_l.forget

# Rule DF.4d_5V: Min. (Nwell overlap of NCOMP) outside DNWELL. is 0.16µm
logger.info("Executing rule DF.4d_5V")
df4d_l1 = nwell_n_dnwell.not_inside(ymtp_mk).enclosing(ncomp.outside(dnwell).not_inside(ymtp_mk), 0.16.um, euclidian).polygons(0.001)
df4d_l2 = ncomp.outside(dnwell).not_inside(ymtp_mk).not_outside(nwell_n_dnwell.not_inside(ymtp_mk)).not(nwell_n_dnwell.not_inside(ymtp_mk))
df4d_l  = df4d_l1.or(df4d_l2).overlapping(dualgate)
df4d_l.output("DF.4d_5V", "DF.4d_5V : Min. (Nwell overlap of NCOMP) outside DNWELL. : 0.16µm")
df4d_l1.forget
df4d_l2.forget
df4d_l.forget

nwell_n_dnwell.forget

# Rule DF.4e_3.3V: Min. DNWELL overlap of PCOMP. is 0.93µm
logger.info("Executing rule DF.4e_3.3V")
df4e_l1 = dnwell.enclosing(pcomp, 0.93.um, euclidian).polygons(0.001)
df4e_l2 = pcomp.not_outside(dnwell).not(dnwell)
df4e_l  = df4e_l1.or(df4e_l2).not_interacting(v5_xtor).not_interacting(dualgate)
df4e_l.output("DF.4e_3.3V", "DF.4e_3.3V : Min. DNWELL overlap of PCOMP. : 0.93µm")
df4e_l1.forget
df4e_l2.forget
df4e_l.forget

# Rule DF.4e_5V: Min. DNWELL overlap of PCOMP. is 1.1µm
logger.info("Executing rule DF.4e_5V")
df4e_l1 = dnwell.enclosing(pcomp, 1.1.um, euclidian).polygons(0.001)
df4e_l2 = pcomp.not_outside(dnwell).not(dnwell)
df4e_l  = df4e_l1.or(df4e_l2).overlapping(dualgate)
df4e_l.output("DF.4e_5V", "DF.4e_5V : Min. DNWELL overlap of PCOMP. : 1.1µm")
df4e_l1.forget
df4e_l2.forget
df4e_l.forget

pwell_dnwell = lvpwell.inside(dnwell)
# Rule DF.5_3.3V: Min. (LVPWELL overlap of PCOMP well tap) inside DNWELL. is 0.12µm
logger.info("Executing rule DF.5_3.3V")
df5_l1 = pwell_dnwell.enclosing(pcomp.outside(nwell), 0.12.um, euclidian).polygons(0.001)
df5_l2 = pcomp.outside(nwell).not_outside(pwell_dnwell).not(pwell_dnwell)
df5_l  = df5_l1.or(df5_l2).not_interacting(v5_xtor).not_interacting(dualgate)
df5_l.output("DF.5_3.3V", "DF.5_3.3V : Min. (LVPWELL overlap of PCOMP well tap) inside DNWELL. : 0.12µm")
df5_l1.forget
df5_l2.forget
df5_l.forget

# Rule DF.5_5V: Min. (LVPWELL overlap of PCOMP well tap) inside DNWELL. is 0.16µm
logger.info("Executing rule DF.5_5V")
df5_l1 = pwell_dnwell.enclosing(pcomp.outside(nwell), 0.16.um, euclidian).polygons(0.001)
df5_l2 = pcomp.outside(nwell).not_outside(pwell_dnwell).not(pwell_dnwell)
df5_l  = df5_l1.or(df5_l2).overlapping(dualgate)
df5_l.output("DF.5_5V", "DF.5_5V : Min. (LVPWELL overlap of PCOMP well tap) inside DNWELL. : 0.16µm")
df5_l1.forget
df5_l2.forget
df5_l.forget

# Rule DF.6_3.3V: Min. COMP extend beyond gate (it also means source/drain overhang). is 0.24µm
logger.info("Executing rule DF.6_3.3V")
df6_l1 = comp.not(otp_mk).not_inside(ymtp_mk).enclosing(poly2.not_inside(ymtp_mk), 0.24.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df6_l1.output("DF.6_3.3V", "DF.6_3.3V : Min. COMP extend beyond gate (it also means source/drain overhang). : 0.24µm")
df6_l1.forget

# Rule DF.6_5V: Min. COMP extend beyond gate (it also means source/drain overhang). is 0.4µm
logger.info("Executing rule DF.6_5V")
df6_l1 = comp.not(otp_mk).not_inside(mvpsd).not_inside(mvsd).not_inside(ymtp_mk).outside(sramcore).enclosing(poly2.not_inside(ymtp_mk), 0.4.um, euclidian).polygons(0.001).overlapping(dualgate)
df6_l1.output("DF.6_5V", "DF.6_5V : Min. COMP extend beyond gate (it also means source/drain overhang). : 0.4µm")
df6_l1.forget

# Rule DF.7_3.3V: Min. (LVPWELL Spacer to PCOMP) inside DNWELL. is 0.43µm
logger.info("Executing rule DF.7_3.3V")
df7_l1  = pcomp.inside(dnwell).separation(pwell_dnwell, 0.43.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df7_l1.output("DF.7_3.3V", "DF.7_3.3V : Min. (LVPWELL Spacer to PCOMP) inside DNWELL. : 0.43µm")
df7_l1.forget

# Rule DF.7_5V: Min. (LVPWELL Spacer to PCOMP) inside DNWELL. is 0.6µm
logger.info("Executing rule DF.7_5V")
df7_l1  = pcomp.inside(dnwell).outside(sramcore).separation(pwell_dnwell, 0.6.um, euclidian).polygons(0.001).overlapping(dualgate)
df7_l1.output("DF.7_5V", "DF.7_5V : Min. (LVPWELL Spacer to PCOMP) inside DNWELL. : 0.6µm")
df7_l1.forget

# Rule DF.8_3.3V: Min. (LVPWELL overlap of NCOMP) Inside DNWELL. is 0.43µm
logger.info("Executing rule DF.8_3.3V")
df8_l1 = pwell_dnwell.enclosing(ncomp.inside(dnwell), 0.43.um, euclidian).polygons(0.001)
df8_l2 = ncomp.inside(dnwell).not_outside(pwell_dnwell).not(pwell_dnwell)
df8_l  = df8_l1.or(df8_l2).not_interacting(v5_xtor).not_interacting(dualgate)
df8_l.output("DF.8_3.3V", "DF.8_3.3V : Min. (LVPWELL overlap of NCOMP) Inside DNWELL. : 0.43µm")
df8_l1.forget
df8_l2.forget
df8_l.forget

# Rule DF.8_5V: Min. (LVPWELL overlap of NCOMP) Inside DNWELL. is 0.6µm
logger.info("Executing rule DF.8_5V")
df8_l1 = pwell_dnwell.outside(sramcore).enclosing(ncomp.inside(dnwell), 0.6.um, euclidian).polygons(0.001)
df8_l2 = ncomp.inside(dnwell).not_outside(pwell_dnwell.outside(sramcore)).not(pwell_dnwell.outside(sramcore))
df8_l  = df8_l1.or(df8_l2).overlapping(dualgate)
df8_l.output("DF.8_5V", "DF.8_5V : Min. (LVPWELL overlap of NCOMP) Inside DNWELL. : 0.6µm")
df8_l1.forget
df8_l2.forget
df8_l.forget

pwell_dnwell.forget

# Rule DF.9_3.3V: Min. COMP area (um2). is 0.2025µm²
logger.info("Executing rule DF.9_3.3V")
df9_l1  = comp.not(otp_mk).with_area(nil, 0.2025.um).not_interacting(v5_xtor).not_interacting(dualgate)
df9_l1.output("DF.9_3.3V", "DF.9_3.3V : Min. COMP area (um2). : 0.2025µm²")
df9_l1.forget

# Rule DF.9_5V: Min. COMP area (um2). is 0.2025µm²
logger.info("Executing rule DF.9_5V")
df9_l1  = comp.not(otp_mk).with_area(nil, 0.2025.um).overlapping(dualgate)
df9_l1.output("DF.9_5V", "DF.9_5V : Min. COMP area (um2). : 0.2025µm²")
df9_l1.forget

# Rule DF.10_3.3V: Min. field area (um2). is 0.26µm²
logger.info("Executing rule DF.10_3.3V")
df10_l1  = comp.holes.not(comp).with_area(nil, 0.26.um).not_interacting(v5_xtor).not_interacting(dualgate)
df10_l1.output("DF.10_3.3V", "DF.10_3.3V : Min. field area (um2). : 0.26µm²")
df10_l1.forget

# Rule DF.10_5V: Min. field area (um2). is 0.26µm²
logger.info("Executing rule DF.10_5V")
df10_l1  = comp.holes.not(comp).with_area(nil, 0.26.um).overlapping(dualgate)
df10_l1.output("DF.10_5V", "DF.10_5V : Min. field area (um2). : 0.26µm²")
df10_l1.forget

comp_butt = comp.interacting(ncomp.interacting(pcomp).outside(pcomp))
# Rule DF.11_3.3V: Min. Length of butting COMP edge. is 0.3µm
logger.info("Executing rule DF.11_3.3V")
df11_l1  = comp_butt.width(0.3.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df11_l1.output("DF.11_3.3V", "DF.11_3.3V : Min. Length of butting COMP edge. : 0.3µm")
df11_l1.forget

# Rule DF.11_5V: Min. Length of butting COMP edge. is 0.3µm
logger.info("Executing rule DF.11_5V")
df11_l1  = comp_butt.width(0.3.um, euclidian).polygons(0.001).overlapping(dualgate)
df11_l1.output("DF.11_5V", "DF.11_5V : Min. Length of butting COMP edge. : 0.3µm")
df11_l1.forget

comp_butt.forget

# Rule DF.12_3.3V: COMP not covered by Nplus or Pplus is forbidden (except those COMP under marking).
logger.info("Executing rule DF.12_3.3V")
df12_l1 = comp.not_interacting(schottky_diode).not_inside(nplus.or(pplus)).not_interacting(v5_xtor).not_interacting(dualgate)
df12_l1.output("DF.12_3.3V", "DF.12_3.3V : COMP not covered by Nplus or Pplus is forbidden (except those COMP under marking).")
df12_l1.forget

# Rule DF.12_5V: COMP not covered by Nplus or Pplus is forbidden (except those COMP under marking).
logger.info("Executing rule DF.12_5V")
df12_l1 = comp.not_interacting(schottky_diode).not_inside(nplus.or(pplus)).overlapping(dualgate)
df12_l1.output("DF.12_5V", "DF.12_5V : COMP not covered by Nplus or Pplus is forbidden (except those COMP under marking).")
df12_l1.forget

df13_ncomp = ncomp.inside(nwell.covering(ncomp).covering(pcomp))
df13_pcomp = pcomp.inside(nwell.covering(ncomp).covering(pcomp))
# Rule DF.13_3.3V: Max distance of Nwell tap (NCOMP inside Nwell) from (PCOMP inside Nwell).
logger.info("Executing rule DF.13_3.3V")
df13_l1 = df13_ncomp.not_interacting(df13_pcomp.sized(20.um)).not_interacting(v5_xtor).not_interacting(dualgate)
df13_l1.output("DF.13_3.3V", "DF.13_3.3V : Max distance of Nwell tap (NCOMP inside Nwell) from (PCOMP inside Nwell).")
df13_l1.forget

# Rule DF.13_5V: Max distance of Nwell tap (NCOMP inside Nwell) from (PCOMP inside Nwell).
logger.info("Executing rule DF.13_5V")
df13_l1 = df13_ncomp.not_interacting(df13_pcomp.sized(15.um)).overlapping(dualgate)
df13_l1.output("DF.13_5V", "DF.13_5V : Max distance of Nwell tap (NCOMP inside Nwell) from (PCOMP inside Nwell).")
df13_l1.forget

df13_ncomp.forget

df13_pcomp.forget

# Rule DF.14_3.3V: Max distance of substrate tap (PCOMP outside Nwell) from (NCOMP outside Nwell).
logger.info("Executing rule DF.14_3.3V")
df14_l1 = pcomp.outside(nwell).not_interacting(ncomp.outside(nwell).sized(20.um)).not_interacting(v5_xtor).not_interacting(dualgate)
df14_l1.output("DF.14_3.3V", "DF.14_3.3V : Max distance of substrate tap (PCOMP outside Nwell) from (NCOMP outside Nwell).")
df14_l1.forget

# Rule DF.14_5V: Max distance of substrate tap (PCOMP outside Nwell) from (NCOMP outside Nwell).
logger.info("Executing rule DF.14_5V")
df14_l1 = pcomp.outside(nwell).not_interacting(ncomp.outside(nwell).sized(15.um)).overlapping(dualgate)
df14_l1.output("DF.14_5V", "DF.14_5V : Max distance of substrate tap (PCOMP outside Nwell) from (NCOMP outside Nwell).")
df14_l1.forget

# rule DF.15a_3.3V is not a DRC check

# rule DF.15a_5V is not a DRC check

# rule DF.15b_3.3V is not a DRC check

# rule DF.15b_5V is not a DRC check

ncomp_df16 = ncomp.outside(nwell).outside(dnwell)
# Rule DF.16_3.3V: Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). is 0.43µm
logger.info("Executing rule DF.16_3.3V")
df16_l1  = ncomp_df16.not_inside(ymtp_mk).outside(sramcore).separation(nwell.outside(dnwell).not_inside(ymtp_mk), 0.43.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df16_l1.output("DF.16_3.3V", "DF.16_3.3V : Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). : 0.43µm")
df16_l1.forget

# Rule DF.16_5V: Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). is 0.6µm
logger.info("Executing rule DF.16_5V")
df16_l1  = ncomp_df16.not_inside(ymtp_mk).outside(sramcore).separation(nwell.outside(dnwell).not_inside(ymtp_mk), 0.6.um, euclidian).polygons(0.001).overlapping(dualgate)
df16_l1.output("DF.16_5V", "DF.16_5V : Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). : 0.6µm")
df16_l1.forget

pcomp_df17 = pcomp.outside(nwell).outside(dnwell)
# Rule DF.17_3.3V: Min. space from (Nwell Outside DNWELL) to (PCOMP outside Nwell and DNWELL). is 0.12µm
logger.info("Executing rule DF.17_3.3V")
df17_l1  = pcomp_df17.separation(nwell.outside(dnwell), 0.12.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df17_l1.output("DF.17_3.3V", "DF.17_3.3V : Min. space from (Nwell Outside DNWELL) to (PCOMP outside Nwell and DNWELL). : 0.12µm")
df17_l1.forget

# Rule DF.17_5V: Min. space from (Nwell Outside DNWELL) to (PCOMP outside Nwell and DNWELL). is 0.16µm
logger.info("Executing rule DF.17_5V")
df17_l1  = pcomp_df17.separation(nwell.outside(dnwell), 0.16.um, euclidian).polygons(0.001).overlapping(dualgate)
df17_l1.output("DF.17_5V", "DF.17_5V : Min. space from (Nwell Outside DNWELL) to (PCOMP outside Nwell and DNWELL). : 0.16µm")
df17_l1.forget

# Rule DF.18_3.3V: Min. DNWELL space to (PCOMP outside Nwell and DNWELL). is 2.5µm
logger.info("Executing rule DF.18_3.3V")
df18_l1  = pcomp_df17.separation(dnwell, 2.5.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df18_l1.output("DF.18_3.3V", "DF.18_3.3V : Min. DNWELL space to (PCOMP outside Nwell and DNWELL). : 2.5µm")
df18_l1.forget

# Rule DF.18_5V: Min. DNWELL space to (PCOMP outside Nwell and DNWELL). is 2.5µm
logger.info("Executing rule DF.18_5V")
df18_l1  = pcomp_df17.separation(dnwell, 2.5.um, euclidian).polygons(0.001).overlapping(dualgate)
df18_l1.output("DF.18_5V", "DF.18_5V : Min. DNWELL space to (PCOMP outside Nwell and DNWELL). : 2.5µm")
df18_l1.forget

pcomp_df17.forget

# Rule DF.19_3.3V: Min. DNWELL space to (NCOMP outside Nwell and DNWELL). is 3.2µm
logger.info("Executing rule DF.19_3.3V")
df19_l1  = ncomp_df16.separation(dnwell, 3.2.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
df19_l1.output("DF.19_3.3V", "DF.19_3.3V : Min. DNWELL space to (NCOMP outside Nwell and DNWELL). : 3.2µm")
df19_l1.forget

# Rule DF.19_5V: Min. DNWELL space to (NCOMP outside Nwell and DNWELL). is 3.28µm
logger.info("Executing rule DF.19_5V")
df19_l1  = ncomp_df16.separation(dnwell, 3.28.um, euclidian).polygons(0.001).overlapping(dualgate)
df19_l1.output("DF.19_5V", "DF.19_5V : Min. DNWELL space to (NCOMP outside Nwell and DNWELL). : 3.28µm")
df19_l1.forget

ncomp_df16.forget

#================================================
#--------------------DUALGATE--------------------
#================================================

# Rule DV.1: Min. Dualgate enclose DNWELL. is 0.5µm
logger.info("Executing rule DV.1")
dv1_l1 = dualgate.enclosing(dnwell, 0.5.um, euclidian).polygons(0.001)
dv1_l2 = dnwell.not_outside(dualgate).not(dualgate)
dv1_l  = dv1_l1.or(dv1_l2)
dv1_l.output("DV.1", "DV.1 : Min. Dualgate enclose DNWELL. : 0.5µm")
dv1_l1.forget
dv1_l2.forget
dv1_l.forget

# Rule DV.2: Min. Dualgate Space. Merge if Space is less than this design rule. is 0.44µm
logger.info("Executing rule DV.2")
dv2_l1  = dualgate.space(0.44.um, euclidian).polygons(0.001)
dv2_l1.output("DV.2", "DV.2 : Min. Dualgate Space. Merge if Space is less than this design rule. : 0.44µm")
dv2_l1.forget

# Rule DV.3: Min. Dualgate to COMP space [unrelated]. is 0.24µm
logger.info("Executing rule DV.3")
dv3_l1  = dualgate.separation(comp.outside(dualgate), 0.24.um, euclidian).polygons(0.001)
dv3_l1.output("DV.3", "DV.3 : Min. Dualgate to COMP space [unrelated]. : 0.24µm")
dv3_l1.forget

# rule DV.4 is not a DRC check

# Rule DV.5: Min. Dualgate width. is 0.7µm
logger.info("Executing rule DV.5")
dv5_l1  = dualgate.width(0.7.um, euclidian).polygons(0.001)
dv5_l1.output("DV.5", "DV.5 : Min. Dualgate width. : 0.7µm")
dv5_l1.forget

comp_dv = comp.not(pcomp.outside(nwell))
# Rule DV.6: Min. Dualgate enclose COMP (except substrate tap). is 0.24µm
logger.info("Executing rule DV.6")
dv6_l1 = dualgate.enclosing(comp_dv, 0.24.um, euclidian).polygons(0.001)
dv6_l2 = comp_dv.not_outside(dualgate).not(dualgate)
dv6_l  = dv6_l1.or(dv6_l2)
dv6_l.output("DV.6", "DV.6 : Min. Dualgate enclose COMP (except substrate tap). : 0.24µm")
dv6_l1.forget
dv6_l2.forget
dv6_l.forget

# Rule DV.7: COMP (except substrate tap) can not be partially overlapped by Dualgate.
logger.info("Executing rule DV.7")
dv7_l1 = dualgate.not_outside(comp_dv).not(dualgate.covering(comp_dv))
dv7_l1.output("DV.7", "DV.7 : COMP (except substrate tap) can not be partially overlapped by Dualgate.")
dv7_l1.forget

comp_dv.forget

# Rule DV.8: Min Dualgate enclose Poly2. is 0.4µm
logger.info("Executing rule DV.8")
dv8_l1 = dualgate.enclosing(poly2, 0.4.um, euclidian).polygons(0.001)
dv8_l2 = poly2.not_outside(dualgate).not(dualgate)
dv8_l  = dv8_l1.or(dv8_l2)
dv8_l.output("DV.8", "DV.8 : Min Dualgate enclose Poly2. : 0.4µm")
dv8_l1.forget
dv8_l2.forget
dv8_l.forget

# Rule DV.9: 3.3V and 5V/6V PMOS cannot be sitting inside same NWELL.
logger.info("Executing rule DV.9")
dv9_l1 = nwell.covering(pgate.and(dualgate)).covering(pgate.not_inside(v5_xtor).not_inside(dualgate))
dv9_l1.output("DV.9", "DV.9 : 3.3V and 5V/6V PMOS cannot be sitting inside same NWELL.")
dv9_l1.forget

#================================================
#---------------------POLY2----------------------
#================================================

# Rule PL.1_3.3V: Interconnect Width (outside PLFUSE). is 0.18µm
logger.info("Executing rule PL.1_3.3V")
pl1_l1  = poly2.outside(plfuse).not(ymtp_mk).width(0.18.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl1_l1.output("PL.1_3.3V", "PL.1_3.3V : Interconnect Width (outside PLFUSE). : 0.18µm")
pl1_l1.forget

# Rule PL.1_5V: Interconnect Width (outside PLFUSE). is 0.2µm
logger.info("Executing rule PL.1_5V")
pl1_l1  = poly2.outside(plfuse).not(ymtp_mk).width(0.2.um, euclidian).polygons(0.001).overlapping(dualgate)
pl1_l1.output("PL.1_5V", "PL.1_5V : Interconnect Width (outside PLFUSE). : 0.2µm")
pl1_l1.forget

# Rule PL.1a_3.3V: Interconnect Width (inside PLFUSE). is 0.18µm
logger.info("Executing rule PL.1a_3.3V")
pl1a_l1  = poly2.inside(plfuse).width(0.18.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl1a_l1.output("PL.1a_3.3V", "PL.1a_3.3V : Interconnect Width (inside PLFUSE). : 0.18µm")
pl1a_l1.forget

# Rule PL.1a_5V: Interconnect Width (inside PLFUSE). is 0.18µm
logger.info("Executing rule PL.1a_5V")
pl1a_l1  = poly2.inside(plfuse).width(0.18.um, euclidian).polygons(0.001).overlapping(dualgate)
pl1a_l1.output("PL.1a_5V", "PL.1a_5V : Interconnect Width (inside PLFUSE). : 0.18µm")
pl1a_l1.forget

# Rule PL.2_3.3V: Gate Width (Channel Length). is 0.28µm
logger.info("Executing rule PL.2_3.3V")
pl2_l1  = poly2.edges.and(tgate.edges).not(otp_mk).not(ymtp_mk).width(0.28.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl2_l1.output("PL.2_3.3V", "PL.2_3.3V : Gate Width (Channel Length). : 0.28µm")
pl2_l1.forget

pl_2_5v_n = comp.not(poly2).edges.and(ngate.edges).and(v5_xtor).and(dualgate).space(0.6.um, euclidian).polygons
pl_2_5v_p = comp.not(poly2).edges.and(pgate.edges).and(v5_xtor).and(dualgate).space(0.5.um, euclidian).polygons
pl_2_6v_n = comp.not(poly2).edges.and(ngate.edges).not(v5_xtor).and(dualgate).space(0.7.um, euclidian).polygons
pl_2_6v_p = comp.not(poly2).edges.and(pgate.edges).not(v5_xtor).and(dualgate).space(0.55.um, euclidian).polygons
# Rule PL.2_5V: Gate Width (Channel Length).
logger.info("Executing rule PL.2_5V")
pl2_l1 = pl_2_5v_n.or(pl_2_5v_p).or(pl_2_6v_n.or(pl_2_6v_p))
pl2_l1.output("PL.2_5V", "PL.2_5V : Gate Width (Channel Length).")
pl2_l1.forget

pl_2_5v_n.forget
pl_2_5v_p.forget
pl_2_6v_n.forget
pl_2_6v_p.forget

# Rule PL.3a_3.3V: Space on COMP/Field. is 0.24µm
logger.info("Executing rule PL.3a_3.3V")
pl3a_l1  = (tgate).or(poly2.not(comp)).not(otp_mk).space(0.24.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl3a_l1.output("PL.3a_3.3V", "PL.3a_3.3V : Space on COMP/Field. : 0.24µm")
pl3a_l1.forget

# Rule PL.3a_5V: Space on COMP/Field. is 0.24µm
logger.info("Executing rule PL.3a_5V")
pl3a_l1  = (tgate).or(poly2.not(comp)).not(otp_mk).space(0.24.um, euclidian).polygons(0.001).overlapping(dualgate)
pl3a_l1.output("PL.3a_5V", "PL.3a_5V : Space on COMP/Field. : 0.24µm")
pl3a_l1.forget

# rule PL.3b_3.3V is not a DRC check

# rule PL.3b_5V is not a DRC check

poly_pl = poly2.not(otp_mk).not(ymtp_mk).not(mvsd).not(mvpsd)
comp_pl = comp.not(otp_mk).not(ymtp_mk).not(mvsd).not(mvpsd)
# Rule PL.4_3.3V: Extension beyond COMP to form Poly2 end cap. is 0.22µm
logger.info("Executing rule PL.4_3.3V")
pl4_l1 = poly_pl.enclosing(comp.not(otp_mk).not(ymtp_mk), 0.22.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl4_l1.output("PL.4_3.3V", "PL.4_3.3V : Extension beyond COMP to form Poly2 end cap. : 0.22µm")
pl4_l1.forget

# Rule PL.4_5V: Extension beyond COMP to form Poly2 end cap. is 0.22µm
logger.info("Executing rule PL.4_5V")
pl4_l1 = poly_pl.enclosing(comp.not(otp_mk).not(ymtp_mk), 0.22.um, euclidian).polygons(0.001).overlapping(dualgate)
pl4_l1.output("PL.4_5V", "PL.4_5V : Extension beyond COMP to form Poly2 end cap. : 0.22µm")
pl4_l1.forget

# Rule PL.5a_3.3V: Space from field Poly2 to unrelated COMP Spacer from field Poly2 to Guard-ring. is 0.1µm
logger.info("Executing rule PL.5a_3.3V")
pl5a_l1  = poly_pl.separation(comp_pl, 0.1.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl5a_l1.output("PL.5a_3.3V", "PL.5a_3.3V : Space from field Poly2 to unrelated COMP Spacer from field Poly2 to Guard-ring. : 0.1µm")
pl5a_l1.forget

# Rule PL.5a_5V: Space from field Poly2 to unrelated COMP Spacer from field Poly2 to Guard-ring. is 0.3µm
logger.info("Executing rule PL.5a_5V")
pl5a_l1  = poly_pl.outside(sramcore).separation(comp_pl, 0.3.um, euclidian).polygons(0.001).overlapping(dualgate)
pl5a_l1.output("PL.5a_5V", "PL.5a_5V : Space from field Poly2 to unrelated COMP Spacer from field Poly2 to Guard-ring. : 0.3µm")
pl5a_l1.forget

# Rule PL.5b_3.3V: Space from field Poly2 to related COMP. is 0.1µm
logger.info("Executing rule PL.5b_3.3V")
pl5b_l1  = poly_pl.separation(comp_pl, 0.1.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl5b_l1.output("PL.5b_3.3V", "PL.5b_3.3V : Space from field Poly2 to related COMP. : 0.1µm")
pl5b_l1.forget

# Rule PL.5b_5V: Space from field Poly2 to related COMP. is 0.3µm
logger.info("Executing rule PL.5b_5V")
pl5b_l1  = poly_pl.outside(sramcore).separation(comp_pl, 0.3.um, euclidian).polygons(0.001).overlapping(dualgate)
pl5b_l1.output("PL.5b_5V", "PL.5b_5V : Space from field Poly2 to related COMP. : 0.3µm")
pl5b_l1.forget
poly_pl.forget
comp_pl.forget

poly_90deg = poly2.corners(90.0).sized(0.1).or(poly2.corners(-90.0).sized(0.1)).not(ymtp_mk)
# Rule PL.6: 90 degree bends on the COMP are not allowed.
logger.info("Executing rule PL.6")
pl6_l1 = poly2.corners(90.0).sized(0.1).or(poly2.corners(-90.0).sized(0.1)).not(ymtp_mk).inside(comp.not(ymtp_mk))
pl6_l1.output("PL.6", "PL.6 : 90 degree bends on the COMP are not allowed.")
pl6_l1.forget

poly_90deg.forget

poly_45deg = poly2.edges.with_angle(-45).or(poly2.edges.with_angle(45))
# Rule PL.7_3.3V: 45 degree bent gate width is 0.3µm
logger.info("Executing rule PL.7_3.3V")
pl7_l1  = poly_45deg.width(0.3.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
pl7_l1.output("PL.7_3.3V", "PL.7_3.3V : 45 degree bent gate width : 0.3µm")
pl7_l1.forget

# Rule PL.7_5V: 45 degree bent gate width is 0.7µm
logger.info("Executing rule PL.7_5V")
pl7_l2  = poly_45deg.width(0.7.um, euclidian).polygons(0.001).overlapping(dualgate)
pl7_l2.output("PL.7_5V", "PL.7_5V : 45 degree bent gate width : 0.7µm")
pl7_l2.forget

poly_45deg.forget

# Rule PL.9: Poly2 inter connect connecting 3.3V and 5V areas (area inside and outside Dualgate) are not allowed. They shall be done though metal lines only.
logger.info("Executing rule PL.9")
pl9_l1 = poly2.interacting(poly2.not(v5_xtor).not(dualgate)).interacting(poly2.and(dualgate))
pl9_l1.output("PL.9", "PL.9 : Poly2 inter connect connecting 3.3V and 5V areas (area inside and outside Dualgate) are not allowed. They shall be done though metal lines only.")
pl9_l1.forget

# rule PL.10 is not a DRC check

# Rule PL.11: V5_Xtor must enclose 5V device.
logger.info("Executing rule PL.11")
pl11_l1 = v5_xtor.not_interacting(dualgate.or(otp_mk))
pl11_l1.output("PL.11", "PL.11 : V5_Xtor must enclose 5V device.")
pl11_l1.forget

# rule PL.12_3.3V is not a DRC check

# Rule PL.12: V5_Xtor enclose 5V Comp.
logger.info("Executing rule PL.12")
pl12_l1 = comp.interacting(v5_xtor).not(v5_xtor)
pl12_l1.output("PL.12", "PL.12 : V5_Xtor enclose 5V Comp.")
pl12_l1.forget

#================================================
#---------------------NPLUS----------------------
#================================================

# Rule NP.1: min. nplus width is 0.4µm
logger.info("Executing rule NP.1")
np1_l1  = nplus.width(0.4.um, euclidian).polygons(0.001)
np1_l1.output("NP.1", "NP.1 : min. nplus width : 0.4µm")
np1_l1.forget

# Rule NP.2: min. nplus spacing is 0.4µm
logger.info("Executing rule NP.2")
np2_l1  = nplus.space(0.4.um, euclidian).polygons(0.001)
np2_l1.output("NP.2", "NP.2 : min. nplus spacing : 0.4µm")
np2_l1.forget

# Rule NP.3a: Space to PCOMP for PCOMP: (1) Inside Nwell (2) Outside LVPWELL but inside DNWELL. is 0.16µm
logger.info("Executing rule NP.3a")
np3a_l1  = nplus.separation((pcomp.inside(nwell)).or(pcomp.outside(lvpwell).inside(dnwell)), 0.16.um, euclidian).polygons(0.001)
np3a_l1.output("NP.3a", "NP.3a : Space to PCOMP for PCOMP: (1) Inside Nwell (2) Outside LVPWELL but inside DNWELL. : 0.16µm")
np3a_l1.forget

np_3bi_extend = lvpwell.inside(dnwell).sized(-0.429.um)
np_3bi = pcomp.edges.and(lvpwell.inside(dnwell).not(np_3bi_extend))
# Rule NP.3bi: Space to PCOMP: For Inside DNWELL, inside LVPWELL:(i) For PCOMP overlap by LVPWELL < 0.43um. is 0.16µm
logger.info("Executing rule NP.3bi")
np3bi_l1  = nplus.not_outside(lvpwell).inside(dnwell).edges.separation(np_3bi, 0.16.um, euclidian).polygons(0.001)
np3bi_l1.output("NP.3bi", "NP.3bi : Space to PCOMP: For Inside DNWELL, inside LVPWELL:(i) For PCOMP overlap by LVPWELL < 0.43um. : 0.16µm")
np3bi_l1.forget

np_3bi_extend.forget

np_3bi.forget

np_3bii_extend = lvpwell.inside(dnwell).sized(-0.429.um)
np_3bii = pcomp.edges.and(np_3bii_extend)
# Rule NP.3bii: Space to PCOMP: For Inside DNWELL, inside LVPWELL:(ii) For PCOMP overlap by LVPWELL >= 0.43um. is 0.08µm
logger.info("Executing rule NP.3bii")
np3bii_l1  = nplus.not_outside(lvpwell).inside(dnwell).edges.separation(np_3bii, 0.08.um, euclidian).polygons(0.001)
np3bii_l1.output("NP.3bii", "NP.3bii : Space to PCOMP: For Inside DNWELL, inside LVPWELL:(ii) For PCOMP overlap by LVPWELL >= 0.43um. : 0.08µm")
np3bii_l1.forget

np_3bii_extend.forget

np_3bii.forget

np_3ci = pcomp.edges.and(nwell.outside(dnwell).sized(0.429.um))
# Rule NP.3ci: Space to PCOMP: For Outside DNWELL:(i) For PCOMP space to Nwell < 0.43um. is 0.16µm
logger.info("Executing rule NP.3ci")
np3ci_l1 = nplus.outside(dnwell).edges.separation(np_3ci, 0.16.um, euclidian).polygons
np3ci_l1.output("NP.3ci", "NP.3ci : Space to PCOMP: For Outside DNWELL:(i) For PCOMP space to Nwell < 0.43um. : 0.16µm")
np3ci_l1.forget

np_3ci.forget

np_3cii = pcomp.edges.not(nwell.outside(dnwell).sized(0.429.um))
# Rule NP.3cii: Space to PCOMP: For Outside DNWELL:(ii) For PCOMP space to Nwell >= 0.43um. is 0.08µm
logger.info("Executing rule NP.3cii")
np3cii_l1 = nplus.outside(dnwell).edges.separation(np_3cii, 0.08.um, euclidian).polygons
np3cii_l1.output("NP.3cii", "NP.3cii : Space to PCOMP: For Outside DNWELL:(ii) For PCOMP space to Nwell >= 0.43um. : 0.08µm")
np3cii_l1.forget

np_3cii.forget

# Rule NP.3d: Min/max space to a butted PCOMP.
logger.info("Executing rule NP.3d")
np3d_l1 = nplus.not_outside(pcomp)
np3d_l1.output("NP.3d", "NP.3d : Min/max space to a butted PCOMP.")
np3d_l1.forget

# Rule NP.3e: Space to related PCOMP edge adjacent to a butting edge.
logger.info("Executing rule NP.3e")
np3e_l1 = nplus.not_outside(pcomp)
np3e_l1.output("NP.3e", "NP.3e : Space to related PCOMP edge adjacent to a butting edge.")
np3e_l1.forget

# Rule NP.4a: Space to related P-channel gate at a butting edge parallel to gate. is 0.32µm
logger.info("Executing rule NP.4a")
np4a_l1 = nplus.edges.and(pcomp.edges).separation(pgate.edges, 0.32.um, projection).polygons(0.001)
np4a_l1.output("NP.4a", "NP.4a : Space to related P-channel gate at a butting edge parallel to gate. : 0.32µm")
np4a_l1.forget

np_4b_poly = poly2.edges.interacting(pgate.edges.not(pcomp.edges)).centers(0, 0.99).and(pgate.sized(0.32.um))
# Rule NP.4b: Within 0.32um of channel, space to P-channel gate extension perpendicular to the direction of Poly2.
logger.info("Executing rule NP.4b")
np4b_l1 = nplus.interacting(nplus.edges.separation(np_4b_poly, 0.22.um, projection).polygons(0.001))
np4b_l1.output("NP.4b", "NP.4b : Within 0.32um of channel, space to P-channel gate extension perpendicular to the direction of Poly2.")
np4b_l1.forget

np_4b_poly.forget

# Rule NP.5a: Overlap of N-channel gate. is 0.23µm
logger.info("Executing rule NP.5a")
np5a_l1 = nplus.enclosing(ngate, 0.23.um, euclidian).polygons(0.001)
np5a_l2 = ngate.not_outside(nplus).not(nplus)
np5a_l  = np5a_l1.or(np5a_l2)
np5a_l.output("NP.5a", "NP.5a : Overlap of N-channel gate. : 0.23µm")
np5a_l1.forget
np5a_l2.forget
np5a_l.forget

# Rule NP.5b: Extension beyond COMP for the COMP (1) inside LVPWELL (2) outside Nwell and DNWELL. is 0.16µm
logger.info("Executing rule NP.5b")
np5b_l1 = nplus.not_outside(lvpwell).or(nplus.outside(nwell).outside(dnwell)).edges.not(pplus).enclosing(comp.edges, 0.16.um, euclidian).polygons(0.001)
np5b_l1.output("NP.5b", "NP.5b : Extension beyond COMP for the COMP (1) inside LVPWELL (2) outside Nwell and DNWELL. : 0.16µm")
np5b_l1.forget

np_5ci_background = nplus.not_inside(lvpwell).inside(dnwell).edges
np_5ci_foreground = ncomp.not_inside(lvpwell).inside(dnwell).edges.not(pplus.edges).and(lvpwell.inside(dnwell).sized(0.429.um))
# Rule NP.5ci: Extension beyond COMP: For Inside DNWELL: (i)For Nplus < 0.43um from LVPWELL edge for Nwell or DNWELL tap inside DNWELL. is 0.16µm
logger.info("Executing rule NP.5ci")
np5ci_l1 = np_5ci_background.enclosing(np_5ci_foreground, 0.16.um, projection).polygons(0.001)
np5ci_l1.output("NP.5ci", "NP.5ci : Extension beyond COMP: For Inside DNWELL: (i)For Nplus < 0.43um from LVPWELL edge for Nwell or DNWELL tap inside DNWELL. : 0.16µm")
np5ci_l1.forget

np_5ci_background.forget

np_5ci_foreground.forget

np_5cii_background = nplus.not_inside(lvpwell).inside(dnwell).edges
np_5cii_foreground = ncomp.not_inside(lvpwell).inside(dnwell).edges.not(pplus.edges).not(lvpwell.inside(dnwell).sized(0.429.um))
# Rule NP.5cii: Extension beyond COMP: For Inside DNWELL: (ii) For Nplus >= 0.43um from LVPWELL edge for Nwell or DNWELL tap inside DNWELL. is 0.02µm
logger.info("Executing rule NP.5cii")
np5cii_l1 = np_5cii_background.enclosing(np_5cii_foreground, 0.02.um, projection).polygons(0.001)
np5cii_l1.output("NP.5cii", "NP.5cii : Extension beyond COMP: For Inside DNWELL: (ii) For Nplus >= 0.43um from LVPWELL edge for Nwell or DNWELL tap inside DNWELL. : 0.02µm")
np5cii_l1.forget

np_5cii_background.forget

np_5cii_foreground.forget

np_5di_background = nplus.not_outside(nwell).outside(dnwell).edges
np_5di_extend     = nwell.outside(dnwell).not(nwell.outside(dnwell).sized(-0.429.um))
np_5di_foreground = ncomp.not_outside(nwell).outside(dnwell).edges.not(pplus.edges).and(np_5di_extend)
# Rule NP.5di: Extension beyond COMP: For Outside DNWELL, inside Nwell: (i) For Nwell overlap of Nplus < 0.43um. is 0.16µm
logger.info("Executing rule NP.5di")
np5di_l1 = np_5di_background.enclosing(np_5di_foreground, 0.16.um, projection).polygons(0.001)
np5di_l1.output("NP.5di", "NP.5di : Extension beyond COMP: For Outside DNWELL, inside Nwell: (i) For Nwell overlap of Nplus < 0.43um. : 0.16µm")
np5di_l1.forget

np_5di_background.forget

np_5di_extend.forget

np_5di_foreground.forget

np_5dii_background = nplus.not_outside(nwell).outside(dnwell).edges.not(pplus.edges)
np_5dii_extend     = nwell.outside(dnwell).sized(-0.429.um)
np_5dii_foreground = ncomp.not_outside(nwell).outside(dnwell).edges.not(pplus.edges).and(np_5dii_extend)
# Rule NP.5dii: Extension beyond COMP: For Outside DNWELL, inside Nwell: (ii) For Nwell overlap of Nplus >= 0.43um. is 0.02µm
logger.info("Executing rule NP.5dii")
np5dii_l1 = np_5dii_background.enclosing(np_5dii_foreground, 0.02.um, euclidian).polygons(0.001)
np5dii_l1.output("NP.5dii", "NP.5dii : Extension beyond COMP: For Outside DNWELL, inside Nwell: (ii) For Nwell overlap of Nplus >= 0.43um. : 0.02µm")
np5dii_l1.forget

np_5dii_background.forget

np_5dii_extend.forget

np_5dii_foreground.forget

# Rule NP.6: Overlap with NCOMP butted to PCOMP. is 0.22µm
logger.info("Executing rule NP.6")
np6_l1 = comp.interacting(nplus).enclosing(pcomp.interacting(nplus), 0.22.um, projection).polygons
np6_l1.output("NP.6", "NP.6 : Overlap with NCOMP butted to PCOMP. : 0.22µm")
np6_l1.forget

# Rule NP.7: Space to unrelated unsalicided Poly2. is 0.18µm
logger.info("Executing rule NP.7")
np7_l1  = nplus.separation(poly2.and(sab), 0.18.um, euclidian).polygons(0.001)
np7_l1.output("NP.7", "NP.7 : Space to unrelated unsalicided Poly2. : 0.18µm")
np7_l1.forget

# Rule NP.8a: Minimum Nplus area (um2). is 0.35µm²
logger.info("Executing rule NP.8a")
np8a_l1  = nplus.with_area(nil, 0.35.um)
np8a_l1.output("NP.8a", "NP.8a : Minimum Nplus area (um2). : 0.35µm²")
np8a_l1.forget

# Rule NP.8b: Minimum area enclosed by Nplus (um2). is 0.35µm²
logger.info("Executing rule NP.8b")
np8b_l1  = nplus.holes.with_area(nil, 0.35.um)
np8b_l1.output("NP.8b", "NP.8b : Minimum area enclosed by Nplus (um2). : 0.35µm²")
np8b_l1.forget

# Rule NP.9: Overlap of unsalicided Poly2. is 0.18µm
logger.info("Executing rule NP.9")
np9_l1 = nplus.enclosing(poly2.and(sab), 0.18.um, euclidian).polygons(0.001)
np9_l2 = poly2.and(sab).not_outside(nplus).not(nplus)
np9_l  = np9_l1.or(np9_l2)
np9_l.output("NP.9", "NP.9 : Overlap of unsalicided Poly2. : 0.18µm")
np9_l1.forget
np9_l2.forget
np9_l.forget

# Rule NP.10: Overlap of unsalicided COMP. is 0.18µm
logger.info("Executing rule NP.10")
np10_l1 = nplus.enclosing(comp.and(sab), 0.18.um, euclidian).polygons(0.001)
np10_l1.output("NP.10", "NP.10 : Overlap of unsalicided COMP. : 0.18µm")
np10_l1.forget

np_11_in_dnwell = nplus.interacting(nplus.edges.and(pcomp.edges).and(lvpwell.inside(dnwell).not(lvpwell.inside(dnwell).sized(-0.429.um))))
np_11_out_dnwell = nplus.interacting(nplus.edges.and(pcomp.edges).and(nwell.outside(dnwell).sized(0.429.um)))
# Rule NP.11: Butting Nplus and PCOMP is forbidden within 0.43um of Nwell edge (for outside DNWELL) and of LVPWELL edge (for inside DNWELL case).
logger.info("Executing rule NP.11")
np11_l1 = np_11_in_dnwell.or(np_11_out_dnwell)
np11_l1.output("NP.11", "NP.11 : Butting Nplus and PCOMP is forbidden within 0.43um of Nwell edge (for outside DNWELL) and of LVPWELL edge (for inside DNWELL case).")
np11_l1.forget

np_11_in_dnwell.forget

np_11_out_dnwell.forget

# Rule NP.12: Overlap with P-channel poly2 gate extension is forbidden within 0.32um of P-channel gate.
logger.info("Executing rule NP.12")
np12_l1 = nplus.interacting(nplus.edges.separation(pgate.edges.and(pcomp.edges), 0.32.um, euclidian).polygons(0.001))
np12_l1.output("NP.12", "NP.12 : Overlap with P-channel poly2 gate extension is forbidden within 0.32um of P-channel gate.")
np12_l1.forget

#================================================
#---------------------PPLUS----------------------
#================================================

# Rule PP.1: min. pplus width is 0.4µm
logger.info("Executing rule PP.1")
pp1_l1  = pplus.width(0.4.um, euclidian).polygons(0.001)
pp1_l1.output("PP.1", "PP.1 : min. pplus width : 0.4µm")
pp1_l1.forget

# Rule PP.2: min. pplus spacing is 0.4µm
logger.info("Executing rule PP.2")
pp2_l1  = pplus.space(0.4.um, euclidian).polygons(0.001)
pp2_l1.output("PP.2", "PP.2 : min. pplus spacing : 0.4µm")
pp2_l1.forget

# Rule PP.3a: Space to NCOMP for NCOMP (1) inside LVPWELL (2) outside NWELL and DNWELL. is 0.16µm
logger.info("Executing rule PP.3a")
pp3a_l1  = pplus.separation((ncomp.inside(lvpwell)).or(ncomp.outside(nwell).outside(dnwell)), 0.16.um, euclidian).polygons(0.001)
pp3a_l1.output("PP.3a", "PP.3a : Space to NCOMP for NCOMP (1) inside LVPWELL (2) outside NWELL and DNWELL. : 0.16µm")
pp3a_l1.forget

pp_3bi = ncomp.edges.not(lvpwell.inside(dnwell).sized(0.429.um))
# Rule PP.3bi: Space to NCOMP: For Inside DNWELL. (i) NCOMP space to LVPWELL >= 0.43um. is 0.08µm
logger.info("Executing rule PP.3bi")
pp3bi_l1  = pplus.inside(dnwell).edges.separation(pp_3bi, 0.08.um, euclidian).polygons(0.001)
pp3bi_l1.output("PP.3bi", "PP.3bi : Space to NCOMP: For Inside DNWELL. (i) NCOMP space to LVPWELL >= 0.43um. : 0.08µm")
pp3bi_l1.forget

pp_3bi.forget

pp_3bii = ncomp.edges.and(lvpwell.inside(dnwell).sized(0.429.um))
# Rule PP.3bii: Space to NCOMP: For Inside DNWELL. (ii) NCOMP space to LVPWELL < 0.43um. is 0.16µm
logger.info("Executing rule PP.3bii")
pp3bii_l1  = pplus.inside(dnwell).edges.separation(pp_3bii, 0.16.um, euclidian).polygons(0.001)
pp3bii_l1.output("PP.3bii", "PP.3bii : Space to NCOMP: For Inside DNWELL. (ii) NCOMP space to LVPWELL < 0.43um. : 0.16µm")
pp3bii_l1.forget

pp_3bii.forget

pp_3ci_extend = nwell.outside(dnwell).sized(-0.429.um)
pp_3ci = ncomp.edges.and(pp_3ci_extend)
# Rule PP.3ci: Space to NCOMP: For Outside DNWELL, inside Nwell: (i) NWELL Overlap of NCOMP >= 0.43um. is 0.08µm
logger.info("Executing rule PP.3ci")
pp3ci_l1  = pplus.outside(dnwell).edges.separation(pp_3ci, 0.08.um, euclidian).polygons(0.001)
pp3ci_l1.output("PP.3ci", "PP.3ci : Space to NCOMP: For Outside DNWELL, inside Nwell: (i) NWELL Overlap of NCOMP >= 0.43um. : 0.08µm")
pp3ci_l1.forget

pp_3ci_extend.forget

pp_3ci.forget

pp_3cii_extend = nwell.outside(dnwell).not(nwell.outside(dnwell).sized(-0.429.um))
pp_3cii = ncomp.edges.and(pp_3cii_extend)
# Rule PP.3cii: Space to NCOMP: For Outside DNWELL, inside Nwell: (ii) NWELL Overlap of NCOMP 0.43um. is 0.16µm
logger.info("Executing rule PP.3cii")
pp3cii_l1  = pplus.outside(dnwell).edges.separation(pp_3cii, 0.16.um, euclidian).polygons(0.001)
pp3cii_l1.output("PP.3cii", "PP.3cii : Space to NCOMP: For Outside DNWELL, inside Nwell: (ii) NWELL Overlap of NCOMP 0.43um. : 0.16µm")
pp3cii_l1.forget

pp_3cii_extend.forget

pp_3cii.forget

# Rule PP.3d: Min/max space to a butted NCOMP.
logger.info("Executing rule PP.3d")
pp3d_l1 = pplus.not_outside(ncomp)
pp3d_l1.output("PP.3d", "PP.3d : Min/max space to a butted NCOMP.")
pp3d_l1.forget

# Rule PP.3e: Space to NCOMP edge adjacent to a butting edge.
logger.info("Executing rule PP.3e")
pp3e_l1 = pplus.not_outside(ncomp)
pp3e_l1.output("PP.3e", "PP.3e : Space to NCOMP edge adjacent to a butting edge.")
pp3e_l1.forget

# Rule PP.4a: Space related to N-channel gate at a butting edge parallel to gate. is 0.32µm
logger.info("Executing rule PP.4a")
pp4a_l1 = pplus.edges.and(ncomp.edges).separation(ngate.edges, 0.32.um, projection).polygons(0.001)
pp4a_l1.output("PP.4a", "PP.4a : Space related to N-channel gate at a butting edge parallel to gate. : 0.32µm")
pp4a_l1.forget

pp_4b_poly = poly2.edges.interacting(ngate.edges.not(ncomp.edges)).centers(0, 0.99).and(ngate.sized(0.32.um))
# Rule PP.4b: Within 0.32um of channel, space to N-channel gate extension perpendicular to the direction of Poly2.
logger.info("Executing rule PP.4b")
pp4b_l1 = pplus.interacting(pplus.edges.separation(pp_4b_poly, 0.22.um, projection).polygons(0.001))
pp4b_l1.output("PP.4b", "PP.4b : Within 0.32um of channel, space to N-channel gate extension perpendicular to the direction of Poly2.")
pp4b_l1.forget

pp_4b_poly.forget

# Rule PP.5a: Overlap of P-channel gate. is 0.23µm
logger.info("Executing rule PP.5a")
pp5a_l1 = pplus.enclosing(pgate, 0.23.um, euclidian).polygons(0.001)
pp5a_l2 = pgate.not_outside(pplus).not(pplus)
pp5a_l  = pp5a_l1.or(pp5a_l2)
pp5a_l.output("PP.5a", "PP.5a : Overlap of P-channel gate. : 0.23µm")
pp5a_l1.forget
pp5a_l2.forget
pp5a_l.forget

# Rule PP.5b: Extension beyond COMP for COMP (1) Inside NWELL (2) outside LVPWELL but inside DNWELL. is 0.16µm
logger.info("Executing rule PP.5b")
pp5b_l1 = pplus.not_outside(nwell).or(pplus.outside(lvpwell).inside(dnwell)).edges.not(nplus).enclosing(comp.edges, 0.16.um, euclidian).polygons(0.001)
pp5b_l1.output("PP.5b", "PP.5b : Extension beyond COMP for COMP (1) Inside NWELL (2) outside LVPWELL but inside DNWELL. : 0.16µm")
pp5b_l1.forget

pp_5ci_background = pplus.not_outside(lvpwell).inside(dnwell).edges.not(nplus.edges)
pp_5ci_extend = lvpwell.inside(dnwell).sized(-0.429.um)
pp_5ci_foreground = pcomp.not_outside(lvpwell).inside(dnwell).edges.not(nplus.edges).inside_part(pp_5ci_extend)
# Rule PP.5ci: Extension beyond COMP: For Inside DNWELL, inside LVPWELL: (i) For LVPWELL overlap of Pplus >= 0.43um for LVPWELL tap. is 0.02µm
logger.info("Executing rule PP.5ci")
pp5ci_l1 = pp_5ci_background.enclosing(pp_5ci_foreground, 0.02.um, euclidian).polygons(0.001)
pp5ci_l1.output("PP.5ci", "PP.5ci : Extension beyond COMP: For Inside DNWELL, inside LVPWELL: (i) For LVPWELL overlap of Pplus >= 0.43um for LVPWELL tap. : 0.02µm")
pp5ci_l1.forget

pp_5ci_background.forget

pp_5ci_extend.forget

pp_5ci_foreground.forget

pp_5cii_background = pplus.not_outside(lvpwell).inside(dnwell).edges
pp_5cii_extend = lvpwell.inside(dnwell).not(lvpwell.inside(dnwell).sized(-0.429.um))
pp_5cii_foreground = pcomp.not_outside(lvpwell).inside(dnwell).edges.not(nplus.edges).and(pp_5cii_extend)
# Rule PP.5cii: Extension beyond COMP: For Inside DNWELL, inside LVPWELL: (ii) For LVPWELL overlap of Pplus < 0.43um for the LVPWELL tap. is 0.16µm
logger.info("Executing rule PP.5cii")
pp5cii_l1 = pp_5cii_background.enclosing(pp_5cii_foreground, 0.16.um, projection).polygons(0.001)
pp5cii_l1.output("PP.5cii", "PP.5cii : Extension beyond COMP: For Inside DNWELL, inside LVPWELL: (ii) For LVPWELL overlap of Pplus < 0.43um for the LVPWELL tap. : 0.16µm")
pp5cii_l1.forget

pp_5cii_background.forget

pp_5cii_extend.forget

pp_5cii_foreground.forget

pp_5di_background = pplus.outside(dnwell).edges
pp_5di_foreground = pcomp.outside(dnwell).edges.not(nplus.edges).not(nwell.outside(dnwell).sized(0.429.um))
# Rule PP.5di: Extension beyond COMP: For Outside DNWELL (i) For Pplus to NWELL space >= 0.43um for Pfield or LVPWELL tap. is 0.02µm
logger.info("Executing rule PP.5di")
pp5di_l1 = pp_5di_background.enclosing(pp_5di_foreground, 0.02.um, projection).polygons(0.001)
pp5di_l1.output("PP.5di", "PP.5di : Extension beyond COMP: For Outside DNWELL (i) For Pplus to NWELL space >= 0.43um for Pfield or LVPWELL tap. : 0.02µm")
pp5di_l1.forget

pp_5di_background.forget

pp_5di_foreground.forget

pp_5dii_background = pplus.outside(dnwell).edges
pp_5dii_foreground = pcomp.outside(dnwell).edges.not(nplus.edges).and(nwell.outside(dnwell).sized(0.429.um))
# Rule PP.5dii: Extension beyond COMP: For Outside DNWELL (ii) For Pplus to NWELL space < 0.43um for Pfield or LVPWELL tap. is 0.16µm
logger.info("Executing rule PP.5dii")
pp5dii_l1 = pp_5dii_background.enclosing(pp_5dii_foreground, 0.16.um, projection).polygons(0.001)
pp5dii_l1.output("PP.5dii", "PP.5dii : Extension beyond COMP: For Outside DNWELL (ii) For Pplus to NWELL space < 0.43um for Pfield or LVPWELL tap. : 0.16µm")
pp5dii_l1.forget

pp_5dii_background.forget

pp_5dii_foreground.forget

# Rule PP.6: Overlap with PCOMP butted to NCOMP. is 0.22µm
logger.info("Executing rule PP.6")
pp6_l1 = comp.interacting(pplus).enclosing(ncomp.interacting(pplus), 0.22.um, projection).polygons
pp6_l1.output("PP.6", "PP.6 : Overlap with PCOMP butted to NCOMP. : 0.22µm")
pp6_l1.forget

# Rule PP.7: Space to unrelated unsalicided Poly2. is 0.18µm
logger.info("Executing rule PP.7")
pp7_l1  = pplus.separation(poly2.and(sab), 0.18.um, euclidian).polygons(0.001)
pp7_l1.output("PP.7", "PP.7 : Space to unrelated unsalicided Poly2. : 0.18µm")
pp7_l1.forget

# Rule PP.8a: Minimum Pplus area (um2). is 0.35µm²
logger.info("Executing rule PP.8a")
pp8a_l1  = pplus.with_area(nil, 0.35.um)
pp8a_l1.output("PP.8a", "PP.8a : Minimum Pplus area (um2). : 0.35µm²")
pp8a_l1.forget

# Rule PP.8b: Minimum area enclosed by Pplus (um2). is 0.35µm²
logger.info("Executing rule PP.8b")
pp8b_l1  = pplus.holes.with_area(nil, 0.35.um)
pp8b_l1.output("PP.8b", "PP.8b : Minimum area enclosed by Pplus (um2). : 0.35µm²")
pp8b_l1.forget

# Rule PP.9: Overlap of unsalicided Poly2. is 0.18µm
logger.info("Executing rule PP.9")
pp9_l1 = pplus.enclosing(poly2.not_interacting(resistor).and(sab), 0.18.um, euclidian).polygons(0.001)
pp9_l2 = poly2.not_interacting(resistor).and(sab).not_outside(pplus).not(pplus)
pp9_l  = pp9_l1.or(pp9_l2)
pp9_l.output("PP.9", "PP.9 : Overlap of unsalicided Poly2. : 0.18µm")
pp9_l1.forget
pp9_l2.forget
pp9_l.forget

# Rule PP.10: Overlap of unsalicided COMP. is 0.18µm
logger.info("Executing rule PP.10")
pp10_l1 = pplus.enclosing(comp.and(sab), 0.18.um, euclidian).polygons(0.001)
pp10_l1.output("PP.10", "PP.10 : Overlap of unsalicided COMP. : 0.18µm")
pp10_l1.forget

pp_11_in_dnwell = pplus.interacting(pplus.edges.and(ncomp.edges).and(lvpwell.inside(dnwell).sized(0.429.um)))
pp_11_out_dnwell = pplus.interacting(pplus.edges.and(ncomp.edges).and(nwell.outside(dnwell).not(nwell.outside(dnwell).sized(-0.429.um))))
# Rule PP.11: Butting Pplus and NCOMP is forbidden within 0.43um of Nwell edge (for outside DNWELL) and of LVPWELL edge (for inside DNWELL case).
logger.info("Executing rule PP.11")
pp11_l1 = pp_11_in_dnwell.or(pp_11_out_dnwell)
pp11_l1.output("PP.11", "PP.11 : Butting Pplus and NCOMP is forbidden within 0.43um of Nwell edge (for outside DNWELL) and of LVPWELL edge (for inside DNWELL case).")
pp11_l1.forget

pp_11_in_dnwell.forget

pp_11_out_dnwell.forget

# Rule PP.12: Overlap with N-channel Poly2 gate extension is forbidden within 0.32um of N-channel gate.
logger.info("Executing rule PP.12")
pp12_l1 = pplus.interacting(pplus.edges.separation(ngate.edges.and(ncomp.edges), 0.32.um, euclidian).polygons(0.001))
pp12_l1.output("PP.12", "PP.12 : Overlap with N-channel Poly2 gate extension is forbidden within 0.32um of N-channel gate.")
pp12_l1.forget

#================================================
#----------------------SAB-----------------------
#================================================

# Rule SB.1: min. sab width is 0.42µm
logger.info("Executing rule SB.1")
sb1_l1  = sab.width(0.42.um, euclidian).polygons(0.001)
sb1_l1.output("SB.1", "SB.1 : min. sab width : 0.42µm")
sb1_l1.forget

# Rule SB.2: min. sab spacing is 0.42µm
logger.info("Executing rule SB.2")
sb2_l1  = sab.outside(otp_mk).space(0.42.um, euclidian).polygons(0.001)
sb2_l1.output("SB.2", "SB.2 : min. sab spacing : 0.42µm")
sb2_l1.forget

# Rule SB.3: Space from salicide block to unrelated COMP. is 0.22µm
logger.info("Executing rule SB.3")
sb3_l1  = sab.outside(comp).outside(otp_mk).separation(comp.outside(sab), 0.22.um, euclidian).polygons(0.001)
sb3_l1.output("SB.3", "SB.3 : Space from salicide block to unrelated COMP. : 0.22µm")
sb3_l1.forget

# Rule SB.4: Space from salicide block to contact.
logger.info("Executing rule SB.4")
sb4_l1 = sab.outside(otp_mk).separation(contact, 0.15.um, euclidian).polygons(0.001).or(sab.outside(otp_mk).and(contact))
sb4_l1.output("SB.4", "SB.4 : Space from salicide block to contact.")
sb4_l1.forget

# Rule SB.5a: Space from salicide block to unrelated Poly2 on field. is 0.3µm
logger.info("Executing rule SB.5a")
sb5a_l1  = sab.outside(poly2.not(comp)).outside(otp_mk).separation(poly2.not(comp).outside(sab), 0.3.um, euclidian).polygons(0.001)
sb5a_l1.output("SB.5a", "SB.5a : Space from salicide block to unrelated Poly2 on field. : 0.3µm")
sb5a_l1.forget

# Rule SB.5b: Space from salicide block to unrelated Poly2 on COMP. is 0.28µm
logger.info("Executing rule SB.5b")
sb5b_l1  = sab.outside(tgate).outside(otp_mk).separation(tgate.outside(sab), 0.28.um, euclidian).polygons(0.001)
sb5b_l1.output("SB.5b", "SB.5b : Space from salicide block to unrelated Poly2 on COMP. : 0.28µm")
sb5b_l1.forget

# Rule SB.6: Salicide block extension beyond related COMP. is 0.22µm
logger.info("Executing rule SB.6")
sb6_l1 = sab.enclosing(comp, 0.22.um, euclidian).polygons(0.001)
sb6_l1.output("SB.6", "SB.6 : Salicide block extension beyond related COMP. : 0.22µm")
sb6_l1.forget

# Rule SB.7: COMP extension beyond related salicide block. is 0.22µm
logger.info("Executing rule SB.7")
sb7_l1 = comp.enclosing(sab, 0.22.um, euclidian).polygons
sb7_l1.output("SB.7", "SB.7 : COMP extension beyond related salicide block. : 0.22µm")
sb7_l1.forget

# Rule SB.8: Non-salicided contacts are forbidden.
logger.info("Executing rule SB.8")
sb8_l1 = contact.inside(sab)
sb8_l1.output("SB.8", "SB.8 : Non-salicided contacts are forbidden.")
sb8_l1.forget

# Rule SB.9: Salicide block extension beyond unsalicided Poly2. is 0.22µm
logger.info("Executing rule SB.9")
sb9_l1 = sab.outside(otp_mk).enclosing(poly2.and(sab), 0.22.um, euclidian).polygons
sb9_l1.output("SB.9", "SB.9 : Salicide block extension beyond unsalicided Poly2. : 0.22µm")
sb9_l1.forget

# Rule SB.10: Poly2 extension beyond related salicide block. is 0.22µm
logger.info("Executing rule SB.10")
sb10_l1 = poly2.enclosing(sab, 0.22.um, euclidian).polygons(0.001)
sb10_l1.output("SB.10", "SB.10 : Poly2 extension beyond related salicide block. : 0.22µm")
sb10_l1.forget

# Rule SB.11: Overlap with COMP. is 0.22µm
logger.info("Executing rule SB.11")
sb11_l1 = sab.outside(otp_mk).overlap(comp, 0.22.um, euclidian).polygons
sb11_l1.output("SB.11", "SB.11 : Overlap with COMP. : 0.22µm")
sb11_l1.forget

# Rule SB.12: Overlap with Poly2 outside ESD_MK. is 0.22µm
logger.info("Executing rule SB.12")
sb12_l1 = sab.outside(otp_mk).outside(esd_mk).overlap(poly2.outside(otp_mk).outside(esd_mk), 0.22.um, euclidian).polygons
sb12_l1.output("SB.12", "SB.12 : Overlap with Poly2 outside ESD_MK. : 0.22µm")
sb12_l1.forget

# Rule SB.13: Min. area (um2). is 2µm²
logger.info("Executing rule SB.13")
sb13_l1  = sab.outside(otp_mk).with_area(nil, 2.um)
sb13_l1.output("SB.13", "SB.13 : Min. area (um2). : 2µm²")
sb13_l1.forget

# Rule SB.14a: Space from unsalicided Nplus Poly2 to unsalicided Pplus Poly2. (Unsalicided Nplus Poly2 must not fall within a square of 0.56um x 0.56um at unsalicided Pplus Poly2 corners). is 0.56µm
logger.info("Executing rule SB.14a")
sb14a_l1 = poly2.and(nplus).and(sab).separation(poly2.and(pplus).and(sab), 0.56.um, square).polygons
sb14a_l1.output("SB.14a", "SB.14a : Space from unsalicided Nplus Poly2 to unsalicided Pplus Poly2. (Unsalicided Nplus Poly2 must not fall within a square of 0.56um x 0.56um at unsalicided Pplus Poly2 corners). : 0.56µm")
sb14a_l1.forget

# Rule SB.14b: Space from unsalicided Nplus Poly2 to P-channel gate. (Unsalicided Nplus Poly2 must not fall within a square of 0.56um x 0.56um at P-channel gate corners). is 0.56µm
logger.info("Executing rule SB.14b")
sb14b_l1 = poly2.and(nplus).and(sab).separation(pgate, 0.56.um, square).polygons
sb14b_l1.output("SB.14b", "SB.14b : Space from unsalicided Nplus Poly2 to P-channel gate. (Unsalicided Nplus Poly2 must not fall within a square of 0.56um x 0.56um at P-channel gate corners). : 0.56µm")
sb14b_l1.forget

# Rule SB.15a: Space from unsalicided Poly2 to unrelated Nplus/Pplus. is 0.18µm
logger.info("Executing rule SB.15a")
sb15a_l1  = poly2.and(sab).separation(nplus.or(pplus), 0.18.um, euclidian).polygons(0.001)
sb15a_l1.output("SB.15a", "SB.15a : Space from unsalicided Poly2 to unrelated Nplus/Pplus. : 0.18µm")
sb15a_l1.forget

sb_15b_1 = poly2.interacting(nplus.or(pplus)).and(sab).edges.not(poly2.edges.and(sab)).separation(nplus.or(pplus).edges, 0.32.um, projection).polygons(0.001)
sb_15b_2 = poly2.interacting(nplus.or(pplus)).and(sab).separation(nplus.or(pplus), 0.32.um, projection).polygons(0.001)
# Rule SB.15b: Space from unsalicided Poly2 to unrelated Nplus/Pplus along Poly2 line. is 0.32µm
logger.info("Executing rule SB.15b")
sb15b_l1 = sb_15b_1.and(sb_15b_2).outside(otp_mk)
sb15b_l1.output("SB.15b", "SB.15b : Space from unsalicided Poly2 to unrelated Nplus/Pplus along Poly2 line. : 0.32µm")
sb15b_l1.forget

sb_15b_1.forget

sb_15b_2.forget

# Rule SB.16: SAB layer cannot exist on 3.3V and 5V/6V CMOS transistors' Poly and COMP area of the core circuit (Excluding the transistors used for ESD purpose). It can only exist on CMOS transistors marked by LVS_IO, OTP_MK, ESD_MK layers.
logger.info("Executing rule SB.16")
sb16_l1 = sab.outside(otp_mk).outside(otp_mk.or(lvs_io).or(esd_mk)).not_outside(ngate.or(pgate.and(nwell)))
sb16_l1.output("SB.16", "SB.16 : SAB layer cannot exist on 3.3V and 5V/6V CMOS transistors' Poly and COMP area of the core circuit (Excluding the transistors used for ESD purpose). It can only exist on CMOS transistors marked by LVS_IO, OTP_MK, ESD_MK layers.")
sb16_l1.forget

#================================================
#----------------------ESD-----------------------
#================================================

# Rule ESD.1: Minimum width of an ESD implant area. is 0.6µm
logger.info("Executing rule ESD.1")
esd1_l1  = esd.width(0.6.um, euclidian).polygons(0.001)
esd1_l1.output("ESD.1", "ESD.1 : Minimum width of an ESD implant area. : 0.6µm")
esd1_l1.forget

# Rule ESD.2: Minimum space between two ESD implant areas. (Merge if the space is less than 0.6um). is 0.6µm
logger.info("Executing rule ESD.2")
esd2_l1  = esd.space(0.6.um, euclidian).polygons(0.001)
esd2_l1.output("ESD.2", "ESD.2 : Minimum space between two ESD implant areas. (Merge if the space is less than 0.6um). : 0.6µm")
esd2_l1.forget

# Rule ESD.3a: Minimum space to NCOMP. is 0.6µm
logger.info("Executing rule ESD.3a")
esd3a_l1  = esd.separation(ncomp, 0.6.um, euclidian).polygons(0.001)
esd3a_l1.output("ESD.3a", "ESD.3a : Minimum space to NCOMP. : 0.6µm")
esd3a_l1.forget

# Rule ESD.3b: Min/max space to a butted PCOMP.
logger.info("Executing rule ESD.3b")
esd3b_l1 = esd.not_outside(pcomp)
esd3b_l1.output("ESD.3b", "ESD.3b : Min/max space to a butted PCOMP.")
esd3b_l1.forget

# Rule ESD.4a: Extension beyond NCOMP. is 0.24µm
logger.info("Executing rule ESD.4a")
esd4a_l1 = esd.edges.not_interacting(pcomp).enclosing(ncomp.edges, 0.24.um, euclidian).polygons(0.001)
esd4a_l1.output("ESD.4a", "ESD.4a : Extension beyond NCOMP. : 0.24µm")
esd4a_l1.forget

# Rule ESD.4b: Minimum overlap of an ESD implant edge to a COMP. is 0.45µm
logger.info("Executing rule ESD.4b")
esd4b_l1  = esd.overlap(comp, 0.45.um, euclidian).polygons(0.001)
esd4b_l1.output("ESD.4b", "ESD.4b : Minimum overlap of an ESD implant edge to a COMP. : 0.45µm")
esd4b_l1.forget

# Rule ESD.5a: Minimum ESD area (um2). is 0.49µm²
logger.info("Executing rule ESD.5a")
esd5a_l1  = esd.with_area(nil, 0.49.um)
esd5a_l1.output("ESD.5a", "ESD.5a : Minimum ESD area (um2). : 0.49µm²")
esd5a_l1.forget

# Rule ESD.5b: Minimum field area enclosed by ESD implant (um2). is 0.49µm²
logger.info("Executing rule ESD.5b")
esd5b_l1  = esd.holes.with_area(nil, 0.49.um)
esd5b_l1.output("ESD.5b", "ESD.5b : Minimum field area enclosed by ESD implant (um2). : 0.49µm²")
esd5b_l1.forget

# Rule ESD.6: Extension perpendicular to Poly2 gate. is 0.45µm
logger.info("Executing rule ESD.6")
esd6_l1 = esd.edges.enclosing(poly2.edges.interacting(tgate.edges), 0.45.um, projection).polygons(0.001)
esd6_l1.output("ESD.6", "ESD.6 : Extension perpendicular to Poly2 gate. : 0.45µm")
esd6_l1.forget

# Rule ESD.7: No ESD implant inside PCOMP.
logger.info("Executing rule ESD.7")
esd7_l1 = esd.not_outside(pcomp)
esd7_l1.output("ESD.7", "ESD.7 : No ESD implant inside PCOMP.")
esd7_l1.forget

# Rule ESD.8: Minimum space to Nplus/Pplus. is 0.3µm
logger.info("Executing rule ESD.8")
esd8_l1 = esd.separation(nplus.or(pplus), 0.3.um).polygons
esd8_l1.output("ESD.8", "ESD.8 : Minimum space to Nplus/Pplus. : 0.3µm")
esd8_l1.forget

# Rule ESD.pl: Minimum gate length of 5V/6V gate NMOS. is 0.8µm
logger.info("Executing rule ESD.pl")
esdpl_l1  = poly2.interacting(esd).edges.and(tgate.edges).width(0.8.um, euclidian).polygons(0.001).overlapping(dualgate)
esdpl_l1.output("ESD.pl", "ESD.pl : Minimum gate length of 5V/6V gate NMOS. : 0.8µm")
esdpl_l1.forget

# Rule ESD.9: ESD implant layer must be overlapped by Dualgate layer (as ESD implant option is only for 5V/6V devices).
logger.info("Executing rule ESD.9")
esd9_l1 = esd.not_inside(dualgate)
esd9_l1.output("ESD.9", "ESD.9 : ESD implant layer must be overlapped by Dualgate layer (as ESD implant option is only for 5V/6V devices).")
esd9_l1.forget

# Rule ESD.10: LVS_IO shall be drawn covering I/O MOS active area by minimum overlap.
logger.info("Executing rule ESD.10")
esd10_l1 = comp.and(esd).not_outside(lvs_io).not(lvs_io)
esd10_l1.output("ESD.10", "ESD.10 : LVS_IO shall be drawn covering I/O MOS active area by minimum overlap.")
esd10_l1.forget

#================================================
#--------------------CONTACT---------------------
#================================================

# Rule CO.1: Min/max contact size. is 0.22µm
logger.info("Executing rule CO.1")
co1_l1 = contact.edges.without_length(0.22.um).extended(0, 0, 0.001, 0.001)
co1_l1.output("CO.1", "CO.1 : Min/max contact size. : 0.22µm")
co1_l1.forget

# Rule CO.2a: min. contact spacing is 0.25µm
logger.info("Executing rule CO.2a")
co2a_l1  = contact.space(0.25.um, euclidian).polygons(0.001)
co2a_l1.output("CO.2a", "CO.2a : min. contact spacing : 0.25µm")
co2a_l1.forget

merged_co1 = contact.sized(0.18.um).sized(-0.18.um).with_bbox_min(1.63.um , nil).extents.inside(metal1)
contact_mask = merged_co1.size(1).not(contact).with_holes(16, nil)
selected_co1 = contact.interacting(contact_mask)
# Rule CO.2b: Space in 4x4 or larger contact array. is 0.28µm
logger.info("Executing rule CO.2b")
co2b_l1  = selected_co1.space(0.28.um, euclidian).polygons(0.001)
co2b_l1.output("CO.2b", "CO.2b : Space in 4x4 or larger contact array. : 0.28µm")
co2b_l1.forget

merged_co1.forget

contact_mask.forget

selected_co1.forget

# Rule CO.3: Poly2 overlap of contact. is 0.07µm
logger.info("Executing rule CO.3")
co3_l1 = poly2.enclosing(contact.outside(sramcore), 0.07.um, euclidian).polygons(0.001)
co3_l2 = contact.outside(sramcore).not_outside(poly2).not(poly2)
co3_l  = co3_l1.or(co3_l2)
co3_l.output("CO.3", "CO.3 : Poly2 overlap of contact. : 0.07µm")
co3_l1.forget
co3_l2.forget
co3_l.forget

# Rule CO.4: COMP overlap of contact. is 0.07µm
logger.info("Executing rule CO.4")
co4_l1 = comp.not(mvsd).not(mvpsd).enclosing(contact.outside(sramcore), 0.07.um, euclidian).polygons(0.001)
co4_l2 = contact.outside(sramcore).not_outside(comp.not(mvsd).not(mvpsd)).not(comp.not(mvsd).not(mvpsd))
co4_l  = co4_l1.or(co4_l2)
co4_l.output("CO.4", "CO.4 : COMP overlap of contact. : 0.07µm")
co4_l1.forget
co4_l2.forget
co4_l.forget

co_5a_ncomp_butted = ncomp.not(pplus).interacting(pcomp.not(nplus)).not_overlapping(pcomp.not(nplus))
# Rule CO.5a: Nplus overlap of contact on COMP (Only for contacts to butted Nplus and Pplus COMP areas). is 0.1µm
logger.info("Executing rule CO.5a")
co5a_l1 = co_5a_ncomp_butted.enclosing(contact, 0.1.um, euclidian).polygons(0.001)
co5a_l2 = contact.not_outside(co_5a_ncomp_butted).not(co_5a_ncomp_butted)
co5a_l  = co5a_l1.or(co5a_l2)
co5a_l.output("CO.5a", "CO.5a : Nplus overlap of contact on COMP (Only for contacts to butted Nplus and Pplus COMP areas). : 0.1µm")
co5a_l1.forget
co5a_l2.forget
co5a_l.forget

co_5a_ncomp_butted.forget

co_5b_pcomp_butted = pcomp.not(nplus).interacting(ncomp.not(pplus)).not_overlapping(ncomp.not(pplus))
# Rule CO.5b: Pplus overlap of contact on COMP (Only for contacts to butted Nplus and Pplus COMP areas). is 0.1µm
logger.info("Executing rule CO.5b")
co5b_l1 = co_5b_pcomp_butted.enclosing(contact, 0.1.um, euclidian).polygons(0.001)
co5b_l2 = contact.not_outside(co_5b_pcomp_butted).not(co_5b_pcomp_butted)
co5b_l  = co5b_l1.or(co5b_l2)
co5b_l.output("CO.5b", "CO.5b : Pplus overlap of contact on COMP (Only for contacts to butted Nplus and Pplus COMP areas). : 0.1µm")
co5b_l1.forget
co5b_l2.forget
co5b_l.forget

co_5b_pcomp_butted.forget

# Rule CO.6: Metal1 overlap of contact.
logger.info("Executing rule CO.6")
co6_l1 = metal1.enclosing(contact, 0.005.um, euclidian).polygons(0.001).or(contact.not_inside(metal1).not(metal1))
co6_l1.output("CO.6", "CO.6 : Metal1 overlap of contact.")
co6_l1.forget

cop6a_cond = metal1.drc( width <= 0.34.um).with_length(0.24.um,nil,both)
cop6a_eol = metal1.edges.with_length(nil, 0.34.um).interacting(cop6a_cond.first_edges).interacting(cop6a_cond.second_edges).not(cop6a_cond.first_edges).not(cop6a_cond.second_edges)
# Rule CO.6a: (i) Metal1 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule CO.6a")
co6a_l1 = cop6a_eol.enclosing(contact.edges,0.06.um, projection).polygons(0.001)
co6a_l1.output("CO.6a", "CO.6a : (i) Metal1 (< 0.34um) end-of-line overlap. : 0.06µm")
co6a_l1.forget

cop6a_cond.forget

cop6a_eol.forget

co_6b_1 = contact.edges.interacting(contact.drc(enclosed(metal1, projection) < 0.04.um).edges.centers(0, 0.5))
co_6b_2 = contact.edges.interacting(contact.drc(0.04.um <= enclosed(metal1, projection) < 0.06.um).centers(0, 0.5))
co_6b_3 = co_6b_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule CO.6b: (ii) If Metal1 overlaps contact by < 0.04um on one side, adjacent metal1 edges overlap is 0.06µm
logger.info("Executing rule CO.6b")
co6b_l1 = co_6b_2.not_in(co_6b_1).interacting(co_6b_1).or(co_6b_1.interacting(co_6b_3)).not(sramcore).enclosed(metal1.outside(sramcore).edges, 0.06.um).polygons(0.001)
co6b_l1.output("CO.6b", "CO.6b : (ii) If Metal1 overlaps contact by < 0.04um on one side, adjacent metal1 edges overlap : 0.06µm")
co6b_l1.forget

co_6b_1.forget

co_6b_2.forget

co_6b_3.forget

# rule CO.6c is not a DRC check

# Rule CO.7: Space from COMP contact to Poly2 on COMP. is 0.15µm
logger.info("Executing rule CO.7")
co7_l1  = contact.not_outside(comp).not(otp_mk).separation(tgate.not(otp_mk), 0.15.um, euclidian).polygons(0.001)
co7_l1.output("CO.7", "CO.7 : Space from COMP contact to Poly2 on COMP. : 0.15µm")
co7_l1.forget

# Rule CO.8: Space from Poly2 contact to COMP. is 0.17µm
logger.info("Executing rule CO.8")
co8_l1  = contact.not_outside(poly2).separation(comp, 0.17.um, euclidian).polygons(0.001)
co8_l1.output("CO.8", "CO.8 : Space from Poly2 contact to COMP. : 0.17µm")
co8_l1.forget

# Rule CO.9: Contact on NCOMP to PCOMP butting edge is forbidden (contact must not straddle butting edge).
logger.info("Executing rule CO.9")
co9_l1 = contact.interacting(ncomp.edges.and(pcomp.edges))
co9_l1.output("CO.9", "CO.9 : Contact on NCOMP to PCOMP butting edge is forbidden (contact must not straddle butting edge).")
co9_l1.forget

# Rule CO.10: Contact on Poly2 gate over COMP is forbidden.
logger.info("Executing rule CO.10")
co10_l1 = contact.not_outside(tgate)
co10_l1.output("CO.10", "CO.10 : Contact on Poly2 gate over COMP is forbidden.")
co10_l1.forget

# Rule CO.11: Contact on field oxide is forbidden.
logger.info("Executing rule CO.11")
co11_l1 = contact.not_inside(comp.or(poly2))
co11_l1.output("CO.11", "CO.11 : Contact on field oxide is forbidden.")
co11_l1.forget

end #FEOL

if BEOL
logger.info("BEOL section")

#================================================
#---------------------METAL1---------------------
#================================================

# Rule M1.1: min. metal1 width is 0.23µm
logger.info("Executing rule M1.1")
m11_l1  = metal1.not(sramcore).width(0.23.um, euclidian).polygons(0.001)
m11_l1.output("M1.1", "M1.1 : min. metal1 width : 0.23µm")
m11_l1.forget

# Rule M1.2a: min. metal1 spacing is 0.23µm
logger.info("Executing rule M1.2a")
m12a_l1  = metal1.space(0.23.um, euclidian).polygons(0.001)
m12a_l1.output("M1.2a", "M1.2a : min. metal1 spacing : 0.23µm")
m12a_l1.forget

# Rule M1.2b: Space to wide Metal1 (length & width > 10um) is 0.3µm
logger.info("Executing rule M1.2b")
m12b_l1  = metal1.separation(metal1.not_interacting(metal1.edges.with_length(nil, 10.um)), 0.3.um, euclidian).polygons(0.001)
m12b_l1.output("M1.2b", "M1.2b : Space to wide Metal1 (length & width > 10um) : 0.3µm")
m12b_l1.forget

# Rule M1.3: Minimum Metal1 area is 0.1444µm²
logger.info("Executing rule M1.3")
m13_l1  = metal1.with_area(nil, 0.1444.um)
m13_l1.output("M1.3", "M1.3 : Minimum Metal1 area : 0.1444µm²")
m13_l1.forget

#================================================
#---------------------METAL2---------------------
#================================================

# Rule M2.1: min. metal2 width is 0.28µm
logger.info("Executing rule M2.1")
m21_l1  = metal2.width(0.28.um, euclidian).polygons(0.001)
m21_l1.output("M2.1", "M2.1 : min. metal2 width : 0.28µm")
m21_l1.forget

# Rule M2.2a: min. metal2 spacing is 0.28µm
logger.info("Executing rule M2.2a")
m22a_l1  = metal2.space(0.28.um, euclidian).polygons(0.001)
m22a_l1.output("M2.2a", "M2.2a : min. metal2 spacing : 0.28µm")
m22a_l1.forget

# Rule M2.2b: Space to wide Metal2 (length & width > 10um) is 0.3µm
logger.info("Executing rule M2.2b")
m22b_l1  = metal2.separation(metal2.not_interacting(metal2.edges.with_length(nil, 10.um)), 0.3.um, euclidian).polygons(0.001)
m22b_l1.output("M2.2b", "M2.2b : Space to wide Metal2 (length & width > 10um) : 0.3µm")
m22b_l1.forget

# Rule M2.3: Minimum metal2 area is 0.1444µm²
logger.info("Executing rule M2.3")
m23_l1  = metal2.with_area(nil, 0.1444.um)
m23_l1.output("M2.3", "M2.3 : Minimum metal2 area : 0.1444µm²")
m23_l1.forget

#================================================
#---------------------METAL3---------------------
#================================================

# Rule M3.1: min. metal3 width is 0.28µm
logger.info("Executing rule M3.1")
m31_l1  = metal3.width(0.28.um, euclidian).polygons(0.001)
m31_l1.output("M3.1", "M3.1 : min. metal3 width : 0.28µm")
m31_l1.forget

# Rule M3.2a: min. metal3 spacing is 0.28µm
logger.info("Executing rule M3.2a")
m32a_l1  = metal3.space(0.28.um, euclidian).polygons(0.001)
m32a_l1.output("M3.2a", "M3.2a : min. metal3 spacing : 0.28µm")
m32a_l1.forget

# Rule M3.2b: Space to wide Metal3 (length & width > 10um) is 0.3µm
logger.info("Executing rule M3.2b")
m32b_l1  = metal3.separation(metal3.not_interacting(metal3.edges.with_length(nil, 10.um)), 0.3.um, euclidian).polygons(0.001)
m32b_l1.output("M3.2b", "M3.2b : Space to wide Metal3 (length & width > 10um) : 0.3µm")
m32b_l1.forget

# Rule M3.3: Minimum metal3 area is 0.1444µm²
logger.info("Executing rule M3.3")
m33_l1  = metal3.with_area(nil, 0.1444.um)
m33_l1.output("M3.3", "M3.3 : Minimum metal3 area : 0.1444µm²")
m33_l1.forget

#================================================
#---------------------METAL4---------------------
#================================================

# Rule M4.1: min. metal4 width is 0.28µm
logger.info("Executing rule M4.1")
m41_l1  = metal4.width(0.28.um, euclidian).polygons(0.001)
m41_l1.output("M4.1", "M4.1 : min. metal4 width : 0.28µm")
m41_l1.forget

# Rule M4.2a: min. metal4 spacing is 0.28µm
logger.info("Executing rule M4.2a")
m42a_l1  = metal4.space(0.28.um, euclidian).polygons(0.001)
m42a_l1.output("M4.2a", "M4.2a : min. metal4 spacing : 0.28µm")
m42a_l1.forget

# Rule M4.2b: Space to wide Metal4 (length & width > 10um) is 0.3µm
logger.info("Executing rule M4.2b")
m42b_l1  = metal4.separation(metal4.not_interacting(metal4.edges.with_length(nil, 10.um)), 0.3.um, euclidian).polygons(0.001)
m42b_l1.output("M4.2b", "M4.2b : Space to wide Metal4 (length & width > 10um) : 0.3µm")
m42b_l1.forget

# Rule M4.3: Minimum metal4 area is 0.1444µm²
logger.info("Executing rule M4.3")
m43_l1  = metal4.with_area(nil, 0.1444.um)
m43_l1.output("M4.3", "M4.3 : Minimum metal4 area : 0.1444µm²")
m43_l1.forget

#================================================
#---------------------METAL5---------------------
#================================================

# Rule M5.1: min. metal5 width is 0.28µm
logger.info("Executing rule M5.1")
m51_l1  = metal5.width(0.28.um, euclidian).polygons(0.001)
m51_l1.output("M5.1", "M5.1 : min. metal5 width : 0.28µm")
m51_l1.forget

# Rule M5.2a: min. metal5 spacing is 0.28µm
logger.info("Executing rule M5.2a")
m52a_l1  = metal5.space(0.28.um, euclidian).polygons(0.001)
m52a_l1.output("M5.2a", "M5.2a : min. metal5 spacing : 0.28µm")
m52a_l1.forget

# Rule M5.2b: Space to wide Metal5 (length & width > 10um) is 0.3µm
logger.info("Executing rule M5.2b")
m52b_l1  = metal5.separation(metal5.not_interacting(metal5.edges.with_length(nil, 10.um)), 0.3.um, euclidian).polygons(0.001)
m52b_l1.output("M5.2b", "M5.2b : Space to wide Metal5 (length & width > 10um) : 0.3µm")
m52b_l1.forget

# Rule M5.3: Minimum metal5 area is 0.1444µm²
logger.info("Executing rule M5.3")
m53_l1  = metal5.with_area(nil, 0.1444.um)
m53_l1.output("M5.3", "M5.3 : Minimum metal5 area : 0.1444µm²")
m53_l1.forget

#================================================
#----------------------VIA1----------------------
#================================================

# Rule V1.1: Min/max Via1 size . is 0.26µm
logger.info("Executing rule V1.1")
v11_l1 = via1.edges.without_length(0.26.um).extended(0, 0, 0.001, 0.001)
v11_l1.output("V1.1", "V1.1 : Min/max Via1 size . : 0.26µm")
v11_l1.forget

# Rule V1.2a: min. via1 spacing is 0.26µm
logger.info("Executing rule V1.2a")
v12a_l1  = via1.space(0.26.um, euclidian).polygons(0.001)
v12a_l1.output("V1.2a", "V1.2a : min. via1 spacing : 0.26µm")
v12a_l1.forget

merged_via1 = via1.sized(0.18.um).sized(-0.18.um).with_bbox_min(1.82.um , nil).extents.inside(metal1)
via1_mask = merged_via1.size(1).not(via1).with_holes(16, nil)
selected_via1 = via1.interacting(via1_mask)
# Rule V1.2b: Via1 Space in 4x4 or larger via1 array is 0.36µm
logger.info("Executing rule V1.2b")
v12b_l1  = selected_via1.space(0.36.um, euclidian).polygons(0.001)
v12b_l1.output("V1.2b", "V1.2b : Via1 Space in 4x4 or larger via1 array : 0.36µm")
v12b_l1.forget

merged_via1.forget

via1_mask.forget

selected_via1.forget

# Rule V1.3a: metal-1  overlap of via1.
logger.info("Executing rule V1.3a")
v13a_l1 = via1.not_inside(metal1)
v13a_l1.output("V1.3a", "V1.3a : metal-1  overlap of via1.")
v13a_l1.forget

# rule V1.3b is not a DRC check

v1p3c_cond = metal1.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v1p3c_eol = metal1.edges.with_length(nil, 0.34.um).interacting(v1p3c_cond.first_edges).interacting(v1p3c_cond.second_edges).not(v1p3c_cond.first_edges).not(v1p3c_cond.second_edges)
# Rule V1.3c: metal-1 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V1.3c")
v13c_l1 = v1p3c_eol.enclosing(via1.edges,0.06.um, projection).polygons(0.001)
v13c_l1.output("V1.3c", "V1.3c : metal-1 (< 0.34um) end-of-line overlap. : 0.06µm")
v13c_l1.forget

v1p3c_cond.forget

v1p3c_eol.forget

v1_3d_1 = via1.edges.interacting(via1.drc(enclosed(metal1, projection) < 0.04.um).edges.centers(0, 0.5))
v1_3d_2 = via1.edges.interacting(via1.drc(0.04.um <= enclosed(metal1, projection) < 0.06.um).centers(0, 0.5))
v1_3d_3 = v1_3d_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V1.3d: If metal-1 overlap via1 by < 0.04um on one side, adjacent metal-1 edges overlap. is 0.06µm
logger.info("Executing rule V1.3d")
v13d_l1 = v1_3d_2.not_in(v1_3d_1).interacting(v1_3d_1).or(v1_3d_1.interacting(v1_3d_3)).enclosed(metal1.edges, 0.06.um).polygons(0.001)
v13d_l1.output("V1.3d", "V1.3d : If metal-1 overlap via1 by < 0.04um on one side, adjacent metal-1 edges overlap. : 0.06µm")
v13d_l1.forget

v1_3d_1.forget

v1_3d_2.forget

v1_3d_3.forget

# rule V1.3e is not a DRC check

# Rule V1.4a: metal-2 overlap of via1.
logger.info("Executing rule V1.4a")
v14a_l1 = metal2.enclosing(via1, 0.01.um, euclidian).polygons(0.001).or(via1.not_inside(metal2).not(metal2))
v14a_l1.output("V1.4a", "V1.4a : metal-2 overlap of via1.")
v14a_l1.forget

v1p4b_cond = metal2.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v1p4b_eol = metal2.edges.with_length(nil, 0.34.um).interacting(v1p4b_cond.first_edges).interacting(v1p4b_cond.second_edges).not(v1p4b_cond.first_edges).not(v1p4b_cond.second_edges)
# Rule V1.4b: metal-2 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V1.4b")
v14b_l1 = v1p4b_eol.enclosing(via1.edges,0.06.um, projection).polygons(0.001)
v14b_l1.output("V1.4b", "V1.4b : metal-2 (< 0.34um) end-of-line overlap. : 0.06µm")
v14b_l1.forget

v1p4b_cond.forget

v1p4b_eol.forget

v1_4c_1 = via1.edges.interacting(via1.drc(enclosed(metal2, projection) < 0.04.um).edges.centers(0, 0.5))
v1_4c_2 = via1.edges.interacting(via1.drc(0.04.um <= enclosed(metal2, projection) < 0.06.um).centers(0, 0.5))
v1_4c_3 = v1_4c_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V1.4c: If metal-2 overlap via1 by < 0.04um on one side, adjacent metal-2 edges overlap. is 0.06µm
logger.info("Executing rule V1.4c")
v14c_l1 = v1_4c_2.not_in(v1_4c_1).interacting(v1_4c_1).or(v1_4c_1.interacting(v1_4c_3)).enclosed(metal2.edges, 0.06.um).polygons(0.001)
v14c_l1.output("V1.4c", "V1.4c : If metal-2 overlap via1 by < 0.04um on one side, adjacent metal-2 edges overlap. : 0.06µm")
v14c_l1.forget

v1_4c_1.forget

v1_4c_2.forget

v1_4c_3.forget

# rule V1.4d is not a DRC check

# rule V1.5 is not a DRC check

#================================================
#----------------------VIA2----------------------
#================================================

# Rule V2.1: Min/max Via2 size . is 0.26µm
logger.info("Executing rule V2.1")
v21_l1 = via2.edges.without_length(0.26.um).extended(0, 0, 0.001, 0.001)
v21_l1.output("V2.1", "V2.1 : Min/max Via2 size . : 0.26µm")
v21_l1.forget

# Rule V2.2a: min. via2 spacing is 0.26µm
logger.info("Executing rule V2.2a")
v22a_l1  = via2.space(0.26.um, euclidian).polygons(0.001)
v22a_l1.output("V2.2a", "V2.2a : min. via2 spacing : 0.26µm")
v22a_l1.forget

merged_via2 = via2.sized(0.18.um).sized(-0.18.um).with_bbox_min(1.82.um , nil).extents.inside(metal2)
via2_mask = merged_via2.size(1).not(via2).with_holes(16, nil)
selected_via2 = via2.interacting(via2_mask)
# Rule V2.2b: Via2 Space in 4x4 or larger via2 array is 0.36µm
logger.info("Executing rule V2.2b")
v22b_l1  = selected_via2.space(0.36.um, euclidian).polygons(0.001)
v22b_l1.output("V2.2b", "V2.2b : Via2 Space in 4x4 or larger via2 array : 0.36µm")
v22b_l1.forget

merged_via2.forget

via2_mask.forget

selected_via2.forget

# rule V2.3a is not a DRC check

# Rule V2.3b: metal2  overlap of via2.
logger.info("Executing rule V2.3b")
v23b_l1 = metal2.enclosing(via2, 0.01.um, euclidian).polygons(0.001).or(via2.not_inside(metal2).not(metal2))
v23b_l1.output("V2.3b", "V2.3b : metal2  overlap of via2.")
v23b_l1.forget

v2p3c_cond = metal2.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v2p3c_eol = metal2.edges.with_length(nil, 0.34.um).interacting(v2p3c_cond.first_edges).interacting(v2p3c_cond.second_edges).not(v2p3c_cond.first_edges).not(v2p3c_cond.second_edges)
# Rule V2.3c: metal2 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V2.3c")
v23c_l1 = v2p3c_eol.enclosing(via2.edges,0.06.um, projection).polygons(0.001)
v23c_l1.output("V2.3c", "V2.3c : metal2 (< 0.34um) end-of-line overlap. : 0.06µm")
v23c_l1.forget

v2p3c_cond.forget

v2p3c_eol.forget

v2_3d_1 = via2.edges.interacting(via2.drc(enclosed(metal2, projection) < 0.04.um).edges.centers(0, 0.5))
v2_3d_2 = via2.edges.interacting(via2.drc(0.04.um <= enclosed(metal2, projection) < 0.06.um).centers(0, 0.5))
v2_3d_3 = v2_3d_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V2.3d: If metal2 overlap via2 by < 0.04um on one side, adjacent metal2 edges overlap. is 0.06µm
logger.info("Executing rule V2.3d")
v23d_l1 = v2_3d_2.not_in(v2_3d_1).interacting(v2_3d_1).or(v2_3d_1.interacting(v2_3d_3)).enclosed(metal2.edges, 0.06.um).polygons(0.001)
v23d_l1.output("V2.3d", "V2.3d : If metal2 overlap via2 by < 0.04um on one side, adjacent metal2 edges overlap. : 0.06µm")
v23d_l1.forget

v2_3d_1.forget

v2_3d_2.forget

v2_3d_3.forget

# rule V2.3e is not a DRC check

# Rule V2.4a: metal3 overlap of via2.
logger.info("Executing rule V2.4a")
v24a_l1 = metal3.enclosing(via2, 0.01.um, euclidian).polygons(0.001).or(via2.not_inside(metal3).not(metal3))
v24a_l1.output("V2.4a", "V2.4a : metal3 overlap of via2.")
v24a_l1.forget

v2p4b_cond = metal3.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v2p4b_eol = metal3.edges.with_length(nil, 0.34.um).interacting(v2p4b_cond.first_edges).interacting(v2p4b_cond.second_edges).not(v2p4b_cond.first_edges).not(v2p4b_cond.second_edges)
# Rule V2.4b: metal3 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V2.4b")
v24b_l1 = v2p4b_eol.enclosing(via2.edges,0.06.um, projection).polygons(0.001)
v24b_l1.output("V2.4b", "V2.4b : metal3 (< 0.34um) end-of-line overlap. : 0.06µm")
v24b_l1.forget

v2p4b_cond.forget

v2p4b_eol.forget

v2_4c_1 = via2.edges.interacting(via2.drc(enclosed(metal3, projection) < 0.04.um).edges.centers(0, 0.5))
v2_4c_2 = via2.edges.interacting(via2.drc(0.04.um <= enclosed(metal3, projection) < 0.06.um).centers(0, 0.5))
v2_4c_3 = v2_4c_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V2.4c: If metal3 overlap via2 by < 0.04um on one side, adjacent metal3 edges overlap. is 0.06µm
logger.info("Executing rule V2.4c")
v24c_l1 = v2_4c_2.not_in(v2_4c_1).interacting(v2_4c_1).or(v2_4c_1.interacting(v2_4c_3)).enclosed(metal3.edges, 0.06.um).polygons(0.001)
v24c_l1.output("V2.4c", "V2.4c : If metal3 overlap via2 by < 0.04um on one side, adjacent metal3 edges overlap. : 0.06µm")
v24c_l1.forget

v2_4c_1.forget

v2_4c_2.forget

v2_4c_3.forget

# rule V2.4d is not a DRC check

# rule V2.5 is not a DRC check

#================================================
#----------------------VIA3----------------------
#================================================

# Rule V3.1: Min/max Via3 size . is 0.26µm
logger.info("Executing rule V3.1")
v31_l1 = via3.edges.without_length(0.26.um).extended(0, 0, 0.001, 0.001)
v31_l1.output("V3.1", "V3.1 : Min/max Via3 size . : 0.26µm")
v31_l1.forget

# Rule V3.2a: min. via3 spacing is 0.26µm
logger.info("Executing rule V3.2a")
v32a_l1  = via3.space(0.26.um, euclidian).polygons(0.001)
v32a_l1.output("V3.2a", "V3.2a : min. via3 spacing : 0.26µm")
v32a_l1.forget

merged_via3   = via3.sized(0.18.um).sized(-0.18.um).with_bbox_min(1.82.um , nil).extents.inside(metal3)
via3_mask     = merged_via3.size(1).not(via3).with_holes(16, nil)
selected_via3 = via3.interacting(via3_mask)
# Rule V3.2b: Via3 Space in 4x4 or larger via3 array is 0.36µm
logger.info("Executing rule V3.2b")
v32b_l1  = selected_via3.space(0.36.um, euclidian).polygons(0.001)
v32b_l1.output("V3.2b", "V3.2b : Via3 Space in 4x4 or larger via3 array : 0.36µm")
v32b_l1.forget

merged_via3.forget

via3_mask.forget

selected_via3.forget

# rule V3.3a is not a DRC check

# Rule V3.3b: metal3  overlap of via3.
logger.info("Executing rule V3.3b")
v33b_l1 = metal3.enclosing(via3, 0.01.um, euclidian).polygons(0.001).or(via3.not_inside(metal3).not(metal3))
v33b_l1.output("V3.3b", "V3.3b : metal3  overlap of via3.")
v33b_l1.forget

v3p3c_cond = metal3.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v3p3c_eol = metal3.edges.with_length(nil, 0.34.um).interacting(v3p3c_cond.first_edges).interacting(v3p3c_cond.second_edges).not(v3p3c_cond.first_edges).not(v3p3c_cond.second_edges)
# Rule V3.3c: metal3 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V3.3c")
v33c_l1 = v3p3c_eol.enclosing(via3.edges,0.06.um, projection).polygons(0.001)
v33c_l1.output("V3.3c", "V3.3c : metal3 (< 0.34um) end-of-line overlap. : 0.06µm")
v33c_l1.forget

v3p3c_cond.forget

v3p3c_eol.forget

v3_3d_1 = via3.edges.interacting(via3.drc(enclosed(metal3, projection) < 0.04.um).edges.centers(0, 0.5))
v3_3d_2 = via3.edges.interacting(via3.drc(0.04.um <= enclosed(metal3, projection) < 0.06.um).centers(0, 0.5))
v3_3d_3 = v3_3d_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V3.3d: If metal3 overlap via3 by < 0.04um on one side, adjacent metal3 edges overlap. is 0.06µm
logger.info("Executing rule V3.3d")
v33d_l1 = v3_3d_2.not(v3_3d_1).interacting(v3_3d_1).or(v3_3d_1.interacting(v3_3d_3)).enclosed(metal3.edges, 0.06.um).polygons(0.001)
v33d_l1.output("V3.3d", "V3.3d : If metal3 overlap via3 by < 0.04um on one side, adjacent metal3 edges overlap. : 0.06µm")
v33d_l1.forget

v3_3d_1.forget

v3_3d_2.forget

v3_3d_3.forget

# rule V3.3e is not a DRC check

# Rule V3.4a: metal4 overlap of via3.
logger.info("Executing rule V3.4a")
v34a_l1 = metal4.enclosing(via3, 0.01.um, euclidian).polygons(0.001).or(via3.not_inside(metal4).not(metal4))
v34a_l1.output("V3.4a", "V3.4a : metal4 overlap of via3.")
v34a_l1.forget

v3p4b_cond = metal4.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v3p4b_eol = metal4.edges.with_length(nil, 0.34.um).interacting(v3p4b_cond.first_edges).interacting(v3p4b_cond.second_edges).not(v3p4b_cond.first_edges).not(v3p4b_cond.second_edges)
# Rule V3.4b: metal4 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V3.4b")
v34b_l1 = v3p4b_eol.enclosing(via3.edges,0.06.um, projection).polygons(0.001)
v34b_l1.output("V3.4b", "V3.4b : metal4 (< 0.34um) end-of-line overlap. : 0.06µm")
v34b_l1.forget

v3p4b_cond.forget

v3p4b_eol.forget

v3_4c_1 = via3.edges.interacting(via3.drc(enclosed(metal4, projection) < 0.04.um).edges.centers(0, 0.5))
v3_4c_2 = via3.edges.interacting(via3.drc(0.04.um <= enclosed(metal4, projection) < 0.06.um).centers(0, 0.5))
v3_4c_3 = v3_4c_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V3.4c: If metal4 overlap via3 by < 0.04um on one side, adjacent metal4 edges overlap. is 0.06µm
logger.info("Executing rule V3.4c")
v34c_l1 = v3_4c_2.not_in(v3_4c_1).interacting(v3_4c_1).or(v3_4c_1.interacting(v3_4c_3)).enclosed(metal4.edges, 0.06.um).polygons(0.001)
v34c_l1.output("V3.4c", "V3.4c : If metal4 overlap via3 by < 0.04um on one side, adjacent metal4 edges overlap. : 0.06µm")
v34c_l1.forget

v3_4c_1.forget

v3_4c_2.forget

v3_4c_3.forget

# rule V3.4d is not a DRC check

# rule V3.5 is not a DRC check

#================================================
#----------------------VIA4----------------------
#================================================

# Rule V4.1: Min/max Via4 size . is 0.26µm
logger.info("Executing rule V4.1")
v41_l1 = via4.edges.without_length(0.26.um).extended(0, 0, 0.001, 0.001)
v41_l1.output("V4.1", "V4.1 : Min/max Via4 size . : 0.26µm")
v41_l1.forget

# Rule V4.2a: min. via4 spacing is 0.26µm
logger.info("Executing rule V4.2a")
v42a_l1  = via4.space(0.26.um, euclidian).polygons(0.001)
v42a_l1.output("V4.2a", "V4.2a : min. via4 spacing : 0.26µm")
v42a_l1.forget

merged_via4   = via4.sized(0.18.um).sized(-0.18.um).with_bbox_min(1.82.um , nil).extents.inside(metal4)
via4_mask     = merged_via4.size(1).not(via4).with_holes(16, nil)
selected_via4 = via4.interacting(via4_mask)
# Rule V4.2b: Via4 Space in 4x4 or larger Vian array is 0.36µm
logger.info("Executing rule V4.2b")
v42b_l1  = selected_via4.space(0.36.um, euclidian).polygons(0.001)
v42b_l1.output("V4.2b", "V4.2b : Via4 Space in 4x4 or larger Vian array : 0.36µm")
v42b_l1.forget

merged_via4.forget

via4_mask.forget

selected_via4.forget

# rule V4.3a is not a DRC check

# Rule V4.3b: metal4  overlap of via4.
logger.info("Executing rule V4.3b")
v43b_l1 = metal4.enclosing(via4, 0.01.um, euclidian).polygons(0.001).or(via4.not_inside(metal4).not(metal4))
v43b_l1.output("V4.3b", "V4.3b : metal4  overlap of via4.")
v43b_l1.forget

v4p3c_cond = metal4.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v4p3c_eol = metal4.edges.with_length(nil, 0.34.um).interacting(v4p3c_cond.first_edges).interacting(v4p3c_cond.second_edges).not(v4p3c_cond.first_edges).not(v4p3c_cond.second_edges)
# Rule V4.3c: metal4 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V4.3c")
v43c_l1 = v4p3c_eol.enclosing(via4.edges,0.06.um, projection).polygons(0.001)
v43c_l1.output("V4.3c", "V4.3c : metal4 (< 0.34um) end-of-line overlap. : 0.06µm")
v43c_l1.forget

v4p3c_cond.forget

v4p3c_eol.forget

v4_3d_1 = via4.edges.interacting(via4.drc(enclosed(metal4, projection) < 0.04.um).edges.centers(0, 0.5))
v4_3d_2 = via4.edges.interacting(via4.drc(0.04.um <= enclosed(metal4, projection) < 0.06.um).centers(0, 0.5))
v4_3d_3 = v4_3d_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V4.3d: If metal4 overlap Vian by < 0.04um on one side, adjacent metal4 edges overlap. is 0.06µm
logger.info("Executing rule V4.3d")
v43d_l1 = v4_3d_2.not_in(v4_3d_1).interacting(v4_3d_1).or(v4_3d_1.interacting(v4_3d_3)).enclosed(metal4.edges, 0.06.um).polygons(0.001)
v43d_l1.output("V4.3d", "V4.3d : If metal4 overlap Vian by < 0.04um on one side, adjacent metal4 edges overlap. : 0.06µm")
v43d_l1.forget

v4_3d_1.forget

v4_3d_2.forget

v4_3d_3.forget

# rule V4.3e is not a DRC check

# Rule V4.4a: metal5 overlap of via4.
logger.info("Executing rule V4.4a")
v44a_l1 = metal5.enclosing(via4, 0.01.um, euclidian).polygons(0.001).or(via4.not_inside(metal5).not(metal5))
v44a_l1.output("V4.4a", "V4.4a : metal5 overlap of via4.")
v44a_l1.forget

v4p4b_cond = metal5.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v4p4b_eol = metal5.edges.with_length(nil, 0.34.um).interacting(v4p4b_cond.first_edges).interacting(v4p4b_cond.second_edges).not(v4p4b_cond.first_edges).not(v4p4b_cond.second_edges)
# Rule V4.4b: metal5 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V4.4b")
v44b_l1 = v4p4b_eol.enclosing(via4.edges,0.06.um, projection).polygons(0.001)
v44b_l1.output("V4.4b", "V4.4b : metal5 (< 0.34um) end-of-line overlap. : 0.06µm")
v44b_l1.forget

v4p4b_cond.forget

v4p4b_eol.forget

v4_4c_1 = via4.edges.interacting(via4.drc(enclosed(metal5, projection) < 0.04.um).edges.centers(0, 0.5))
v4_4c_2 = via4.edges.interacting(via4.drc(0.04.um <= enclosed(metal5, projection) < 0.06.um).centers(0, 0.5))
v4_4c_3 = v4_4c_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V4.4c: If metal5 overlap via4 by < 0.04um on one side, adjacent metal5 edges overlap. is 0.06µm
logger.info("Executing rule V4.4c")
v44c_l1 = v4_4c_2.not_in(v4_4c_1).interacting(v4_4c_1).or(v4_4c_1.interacting(v4_4c_3)).enclosed(metal5.edges, 0.06.um).polygons(0.001)
v44c_l1.output("V4.4c", "V4.4c : If metal5 overlap via4 by < 0.04um on one side, adjacent metal5 edges overlap. : 0.06µm")
v44c_l1.forget

v4_4c_1.forget

v4_4c_2.forget

v4_4c_3.forget

# rule V4.4d is not a DRC check

# rule V4.5 is not a DRC check

#================================================
#----------------------VIA5----------------------
#================================================

# Rule V5.1: Min/max Via5 size . is 0.26µm
logger.info("Executing rule V5.1")
v51_l1 = via5.edges.without_length(0.26.um).extended(0, 0, 0.001, 0.001)
v51_l1.output("V5.1", "V5.1 : Min/max Via5 size . : 0.26µm")
v51_l1.forget

# Rule V5.2a: min. via5 spacing is 0.26µm
logger.info("Executing rule V5.2a")
v52a_l1  = via5.space(0.26.um, euclidian).polygons(0.001)
v52a_l1.output("V5.2a", "V5.2a : min. via5 spacing : 0.26µm")
v52a_l1.forget

merged_via5   = via5.sized(0.18.um).sized(-0.18.um).with_bbox_min(1.82.um , nil).extents.inside(metal5)
via5_mask     = merged_via5.size(1).not(via5).with_holes(16, nil)
selected_via5 = via5.interacting(via5_mask)
# Rule V5.2b: Via5 Space in 4x4 or larger via5 array is 0.36µm
logger.info("Executing rule V5.2b")
v52b_l1  = selected_via5.space(0.36.um, euclidian).polygons(0.001)
v52b_l1.output("V5.2b", "V5.2b : Via5 Space in 4x4 or larger via5 array : 0.36µm")
v52b_l1.forget

merged_via5.forget

via5_mask.forget

selected_via5.forget

# rule V5.3a is not a DRC check

# Rule V5.3b: metal5  overlap of via5.
logger.info("Executing rule V5.3b")
v53b_l1 = metal5.enclosing(via5, 0.01.um, euclidian).polygons(0.001).or(via5.not_inside(metal5).not(metal5))
v53b_l1.output("V5.3b", "V5.3b : metal5  overlap of via5.")
v53b_l1.forget

v5p3c_cond = metal5.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v5p3c_eol = metal5.edges.with_length(nil, 0.34.um).interacting(v5p3c_cond.first_edges).interacting(v5p3c_cond.second_edges).not(v5p3c_cond.first_edges).not(v5p3c_cond.second_edges)
# Rule V5.3c: metal5 (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V5.3c")
v53c_l1 = v5p3c_eol.enclosing(via5.edges,0.06.um, projection).polygons(0.001)
v53c_l1.output("V5.3c", "V5.3c : metal5 (< 0.34um) end-of-line overlap. : 0.06µm")
v53c_l1.forget

v5p3c_cond.forget

v5p3c_eol.forget

v5_3d_1 = via5.edges.interacting(via5.drc(enclosed(metal5, projection) < 0.04.um).edges.centers(0, 0.5))
v5_3d_2 = via5.edges.interacting(via5.drc(0.04.um <= enclosed(metal5, projection) < 0.06.um).centers(0, 0.5))
v5_3d_3 = v5_3d_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V5.3d: If metal5 overlap via5 by < 0.04um on one side, adjacent metal5 edges overlap. is 0.06µm
logger.info("Executing rule V5.3d")
v53d_l1 = v5_3d_2.not_in(v5_3d_1).interacting(v5_3d_1).or(v5_3d_1.interacting(v5_3d_3)).enclosed(metal5.edges, 0.06.um).polygons(0.001)
v53d_l1.output("V5.3d", "V5.3d : If metal5 overlap via5 by < 0.04um on one side, adjacent metal5 edges overlap. : 0.06µm")
v53d_l1.forget

v5_3d_1.forget

v5_3d_2.forget

v5_3d_3.forget

# rule V5.3e is not a DRC check

# Rule V5.4a: metaltop overlap of via5.
logger.info("Executing rule V5.4a")
v54a_l1 = metaltop.enclosing(via5, 0.01.um, euclidian).polygons(0.001).or(via5.not_inside(metaltop).not(metaltop))
v54a_l1.output("V5.4a", "V5.4a : metaltop overlap of via5.")
v54a_l1.forget

v5p4b_cond = metaltop.drc( width <= 0.34.um).with_length(0.28.um,nil,both)
v5p4b_eol = metaltop.edges.with_length(nil, 0.34.um).interacting(v5p4b_cond.first_edges).interacting(v5p4b_cond.second_edges).not(v5p4b_cond.first_edges).not(v5p4b_cond.second_edges)
# Rule V5.4b: metaltop (< 0.34um) end-of-line overlap. is 0.06µm
logger.info("Executing rule V5.4b")
v54b_l1 = v5p4b_eol.enclosing(via5.edges,0.06.um, projection).polygons(0.001)
v54b_l1.output("V5.4b", "V5.4b : metaltop (< 0.34um) end-of-line overlap. : 0.06µm")
v54b_l1.forget

v5p4b_cond.forget

v5p4b_eol.forget

v5_4c_1 = via5.edges.interacting(via5.drc(enclosed(metaltop, projection) < 0.04.um).edges.centers(0, 0.5))
v5_4c_2 = via5.edges.interacting(via5.drc(0.04.um <= enclosed(metaltop, projection) < 0.06.um).centers(0, 0.5))
v5_4c_3 = v5_4c_1.extended(0, 0, 0, 0.001, joined).corners(90)
# Rule V5.4c: If metaltop overlap via5 by < 0.04um on one side, adjacent metaltop edges overlap. is 0.06µm
logger.info("Executing rule V5.4c")
v54c_l1 = v5_4c_2.not_in(v5_4c_1).interacting(v5_4c_1).or(v5_4c_1.interacting(v5_4c_3)).enclosed(metaltop.edges, 0.06.um).polygons(0.001)
v54c_l1.output("V5.4c", "V5.4c : If metaltop overlap via5 by < 0.04um on one side, adjacent metaltop edges overlap. : 0.06µm")
v54c_l1.forget

v5_4c_1.forget

v5_4c_2.forget

v5_4c_3.forget

# rule V5.4d is not a DRC check

# rule V5.5 is not a DRC check

#================================================
#--------------------METALTOP--------------------
#================================================

if METAL_TOP == "6K"
logger.info("MetalTop thickness 6k section")

# Rule MT.1: min. metaltop width is 0.36µm
logger.info("Executing rule MT.1")
mt1_l1  = metaltop.width(0.36.um, euclidian).polygons(0.001)
mt1_l1.output("MT.1", "MT.1 : min. metaltop width : 0.36µm")
mt1_l1.forget

# Rule MT.2a: min. metaltop spacing is 0.38µm
logger.info("Executing rule MT.2a")
mt2a_l1  = metaltop.space(0.38.um, euclidian).polygons(0.001)
mt2a_l1.output("MT.2a", "MT.2a : min. metaltop spacing : 0.38µm")
mt2a_l1.forget

# Rule MT.2b: Space to wide Metal2 (length & width > 10um) is 0.5µm
logger.info("Executing rule MT.2b")
mt2b_l1  = metaltop.separation(metal2.not_interacting(metal2.edges.with_length(nil, 10.um)), 0.5.um, euclidian).polygons(0.001)
mt2b_l1.output("MT.2b", "MT.2b : Space to wide Metal2 (length & width > 10um) : 0.5µm")
mt2b_l1.forget

# Rule MT.4: Minimum MetalTop area is 0.5625µm²
logger.info("Executing rule MT.4")
mt4_l1  = metaltop.with_area(nil, 0.5625.um)
mt4_l1.output("MT.4", "MT.4 : Minimum MetalTop area : 0.5625µm²")
mt4_l1.forget

elsif METAL_TOP == "9K"
logger.info("MetalTop thickness 9k/11k section")

# Rule MT.1: min. metaltop width is 0.44µm
logger.info("Executing rule MT.1")
mt1_l1  = metaltop.width(0.44.um, euclidian).polygons(0.001)
mt1_l1.output("MT.1", "MT.1 : min. metaltop width : 0.44µm")
mt1_l1.forget

# Rule MT.2a: min. metaltop spacing is 0.46µm
logger.info("Executing rule MT.2a")
mt2a_l1  = metaltop.space(0.46.um, euclidian).polygons(0.001)
mt2a_l1.output("MT.2a", "MT.2a : min. metaltop spacing : 0.46µm")
mt2a_l1.forget

# Rule MT.2b: Space to wide Metal2 (length & width > 10um) is 0.6µm
logger.info("Executing rule MT.2b")
mt2b_l1  = metaltop.separation(metaltop.not_interacting(metal2.edges.with_length(nil, 10.um)), 0.6.um, euclidian).polygons(0.001)
mt2b_l1.output("MT.2b", "MT.2b : Space to wide Metal2 (length & width > 10um) : 0.6µm")
mt2b_l1.forget

# Rule MT.4: Minimum MetalTop area is 0.5625µm²
logger.info("Executing rule MT.4")
mt4_l1  = metaltop.with_area(nil, 0.5625.um)
mt4_l1.output("MT.4", "MT.4 : Minimum MetalTop area : 0.5625µm²")
mt4_l1.forget

elsif METAL_TOP == "30K"
logger.info("MetalTop thickness 30K section")

# Rule MT30.1a: Min. thick MetalTop width. is 1.8µm
logger.info("Executing rule MT30.1a")
mt301a_l1  = metaltop.width(1.8.um, euclidian).polygons(0.001)
mt301a_l1.output("MT30.1a", "MT30.1a : Min. thick MetalTop width. : 1.8µm")
mt301a_l1.forget

# Rule MT30.1b: Min width for >1000um long metal line (based on metal edge). is 2.2µm
logger.info("Executing rule MT30.1b")
mt301b_l1  = metaltop.interacting(metaltop.edges.with_length(1000.um, nil)).width(2.2.um, euclidian).polygons(0.001)
mt301b_l1.output("MT30.1b", "MT30.1b : Min width for >1000um long metal line (based on metal edge). : 2.2µm")
mt301b_l1.forget

# Rule MT30.2: Min. thick MetalTop space. is 1.8µm
logger.info("Executing rule MT30.2")
mt302_l1  = metaltop.space(1.8.um, euclidian).polygons(0.001)
mt302_l1.output("MT30.2", "MT30.2 : Min. thick MetalTop space. : 1.8µm")
mt302_l1.forget

# Rule MT30.3: The separation of two corners should satisfy the minimum spacing. is 1.8µm
logger.info("Executing rule MT30.3")
mt303_l1  = metaltop.space(1.8.um, euclidian).polygons(0.001)
mt303_l1.output("MT30.3", "MT30.3 : The separation of two corners should satisfy the minimum spacing. : 1.8µm")
mt303_l1.forget

# Rule MT30.4: The separation of single metal line from a any degree metal line should satisfy the minimum spacing. is 1.8µm
logger.info("Executing rule MT30.4")
mt304_l1  = metaltop.space(1.8.um, euclidian).polygons(0.001)
mt304_l1.output("MT30.4", "MT30.4 : The separation of single metal line from a any degree metal line should satisfy the minimum spacing. : 1.8µm")
mt304_l1.forget

# Rule MT30.5: Minimum thick MetalTop enclose underlying via (for example: via5 for 6LM case) [Outside Not Allowed].
logger.info("Executing rule MT30.5")
mt305_l1 = top_metal.enclosing(top_via, 0.12.um, euclidian).polygons(0.001).or(top_via.not_inside(top_metal))
mt305_l1.output("MT30.5", "MT30.5 : Minimum thick MetalTop enclose underlying via (for example: via5 for 6LM case) [Outside Not Allowed].")
mt305_l1.forget

mt30p6_cond = top_metal.drc( width < 2.5.um)
mt30p6_eol = top_metal.edges.with_length(nil, 2.5.um).interacting(mt30p6_cond.first_edges).interacting(mt30p6_cond.second_edges).not(mt30p6_cond.first_edges).not(mt30p6_cond.second_edges)
# Rule MT30.6: Thick MetalTop end-of-line (width <2.5um) enclose underlying via (for example: via5 for 6LM case) [Outside Not Allowed].
logger.info("Executing rule MT30.6")
mt306_l1 = mt30p6_eol.enclosing(top_via.edges,0.25.um, projection).polygons(0.001).or(top_via.not_inside(top_metal))
mt306_l1.output("MT30.6", "MT30.6 : Thick MetalTop end-of-line (width <2.5um) enclose underlying via (for example: via5 for 6LM case) [Outside Not Allowed].")
mt306_l1.forget

mt30p6_cond.forget

mt30p6_eol.forget

mt30p8_via_no_mim  = top_via.sized(0.18.um).sized(-0.18.um).with_bbox_min(0.78.um , nil).extents.inside(top_metal)
mt30p8_via_mim     = top_via.interacting(fusetop).sized(0.3.um).sized(-0.3.um).with_bbox_min(1.02.um , nil).extents.inside(top_metal)
mt30p8_via         = mt30p8_via_no_mim.or(mt30p8_via_mim)
mt30p8_mask        = mt30p8_via.size(1).not(top_via).with_holes(4, nil)
mt30p8_slct_via    = top_via.interacting(mt30p8_mask)
# Rule MT30.8: There shall be minimum 2X2 array of vias (top vias) at one location connecting to 3um thick top metal.
logger.info("Executing rule MT30.8")
mt308_l1 = topmin1_metal.outside(guard_ring_mk).not_interacting(mt30p8_slct_via)
mt308_l1.output("MT30.8", "MT30.8 : There shall be minimum 2X2 array of vias (top vias) at one location connecting to 3um thick top metal.")
mt308_l1.forget

mt30p8_via.forget

mt30p8_mask.forget

mt30p8_slct_via.forget

end #METAL_TOP

end #BEOL

if BEOL_EXTEND   # were unconditional rules, now specific to BEOL: Not Repeated by each discrete job (by FEOL, OFFGRID)
#================================================
#---------------------MCELL----------------------
#================================================

# Rule MC.1: min. mcell width is 0.4µm
logger.info("Executing rule MC.1")
mc1_l1  = mcell_feol_mk.width(0.4.um, euclidian).polygons(0.001)
mc1_l1.output("MC.1", "MC.1 : min. mcell width : 0.4µm")
mc1_l1.forget

# Rule MC.2: min. mcell spacing is 0.4µm
logger.info("Executing rule MC.2")
mc2_l1  = mcell_feol_mk.space(0.4.um, euclidian).polygons(0.001)
mc2_l1.output("MC.2", "MC.2 : min. mcell spacing : 0.4µm")
mc2_l1.forget

# Rule MC.3: Minimum Mcell area is 0.35µm²
logger.info("Executing rule MC.3")
mc3_l1  = mcell_feol_mk.with_area(nil, 0.35.um)
mc3_l1.output("MC.3", "MC.3 : Minimum Mcell area : 0.35µm²")
mc3_l1.forget

# Rule MC.4: Minimum area enclosed by Mcell is 0.35µm²
logger.info("Executing rule MC.4")
mc4_l1  = mcell_feol_mk.holes.with_area(nil, 0.35.um)
mc4_l1.output("MC.4", "MC.4 : Minimum area enclosed by Mcell : 0.35µm²")
mc4_l1.forget

#================================================
#----------------P+ POLY RESISTOR----------------
#================================================

pres_poly = poly2.and(pplus).interacting(sab).interacting(res_mk).not_interacting(resistor)
# Rule PRES.1: Minimum width of Poly2 resistor. is 0.8µm
logger.info("Executing rule PRES.1")
pres1_l1  = pres_poly.width(0.8.um, euclidian).polygons(0.001)
pres1_l1.output("PRES.1", "PRES.1 : Minimum width of Poly2 resistor. : 0.8µm")
pres1_l1.forget

# Rule PRES.2: Minimum space between Poly2 resistors. is 0.4µm
logger.info("Executing rule PRES.2")
pres2_l1  = pres_poly.isolated(0.4.um, euclidian).polygons(0.001)
pres2_l1.output("PRES.2", "PRES.2 : Minimum space between Poly2 resistors. : 0.4µm")
pres2_l1.forget

# Rule PRES.3: Minimum space from Poly2 resistor to COMP.
logger.info("Executing rule PRES.3")
pres3_l1 = pres_poly.separation(comp, 0.6.um, euclidian).polygons(0.001).or(comp.not_outside(pres_poly))
pres3_l1.output("PRES.3", "PRES.3 : Minimum space from Poly2 resistor to COMP.")
pres3_l1.forget

# Rule PRES.4: Minimum space from Poly2 resistor to unrelated Poly2. is 0.6µm
logger.info("Executing rule PRES.4")
pres4_l1  = pres_poly.separation(poly2.not_interacting(sab), 0.6.um, euclidian).polygons(0.001)
pres4_l1.output("PRES.4", "PRES.4 : Minimum space from Poly2 resistor to unrelated Poly2. : 0.6µm")
pres4_l1.forget

# Rule PRES.5: Minimum Plus implant overlap of Poly2 resistor. is 0.3µm
logger.info("Executing rule PRES.5")
pres5_l1 = pplus.enclosing(pres_poly, 0.3.um, euclidian).polygons(0.001)
pres5_l2 = pres_poly.not_outside(pplus).not(pplus)
pres5_l  = pres5_l1.or(pres5_l2)
pres5_l.output("PRES.5", "PRES.5 : Minimum Plus implant overlap of Poly2 resistor. : 0.3µm")
pres5_l1.forget
pres5_l2.forget
pres5_l.forget

# Rule PRES.6: Minimum salicide block overlap of Poly2 resistor in width direction. is 0.28µm
logger.info("Executing rule PRES.6")
pres6_l1 = sab.enclosing(pres_poly,0.28.um).polygons(0.001)
pres6_l1.output("PRES.6", "PRES.6 : Minimum salicide block overlap of Poly2 resistor in width direction. : 0.28µm")
pres6_l1.forget

# Rule PRES.7: Space from salicide block to contact on Poly2 resistor.
logger.info("Executing rule PRES.7")
pres7_l1 = contact.inside(pres_poly).separation(sab,0.22.um).polygons(0.001).or(contact.inside(pres_poly).interacting(sab))
pres7_l1.output("PRES.7", "PRES.7 : Space from salicide block to contact on Poly2 resistor.")
pres7_l1.forget

# rule PRES.8 is not a DRC check

mk_pres9a = res_mk.edges.not(poly2.and(pplus).and(sab).edges).inside_part(poly2)
# Rule PRES.9a: Pplus Poly2 resistor shall be covered by RES_MK marking. RES_MK length shall be coincide with resistor length (Defined by SAB length) and width covering the width of Poly2.
logger.info("Executing rule PRES.9a")
pres9a_l1 = res_mk.interacting(pres_poly).interacting(mk_pres9a)
pres9a_l1.output("PRES.9a", "PRES.9a : Pplus Poly2 resistor shall be covered by RES_MK marking. RES_MK length shall be coincide with resistor length (Defined by SAB length) and width covering the width of Poly2.")
pres9a_l1.forget

mk_pres9a.forget

pres9b = res_mk.with_area(15000.01.um,nil).in(res_mk.interacting(res_mk.edges.with_length(80.01.um,nil)))
# Rule PRES.9b: If the size of single RES_MK mark layer is greater than 15000um2 and both side (X and Y) are greater than 80um. then the minimum spacing to adjacent RES_MK layer. is 20µm
logger.info("Executing rule PRES.9b")
pres9b_l1 = pres9b.interacting(pres_poly).drc(separation(pres9b) < 20.um).polygons(0.001)
pres9b_l1.output("PRES.9b", "PRES.9b : If the size of single RES_MK mark layer is greater than 15000um2 and both side (X and Y) are greater than 80um. then the minimum spacing to adjacent RES_MK layer. : 20µm")
pres9b_l1.forget

pres9b.forget

pres_poly.forget

#================================================
#----------------N+ POLY RESISTOR----------------
#================================================

lres_poly = poly2.and(nplus).interacting(sab).interacting(res_mk)
# Rule LRES.1: Minimum width of Poly2 resistor. is 0.8µm
logger.info("Executing rule LRES.1")
lres1_l1  = lres_poly.width(0.8.um, euclidian).polygons(0.001)
lres1_l1.output("LRES.1", "LRES.1 : Minimum width of Poly2 resistor. : 0.8µm")
lres1_l1.forget

# Rule LRES.2: Minimum space between Poly2 resistors. is 0.4µm
logger.info("Executing rule LRES.2")
lres2_l1  = lres_poly.isolated(0.4.um, euclidian).polygons(0.001)
lres2_l1.output("LRES.2", "LRES.2 : Minimum space between Poly2 resistors. : 0.4µm")
lres2_l1.forget

# Rule LRES.3: Minimum space from Poly2 resistor to COMP.
logger.info("Executing rule LRES.3")
lres3_l1 = lres_poly.separation(comp, 0.6.um, euclidian).polygons(0.001).or(comp.not_outside(lres_poly))
lres3_l1.output("LRES.3", "LRES.3 : Minimum space from Poly2 resistor to COMP.")
lres3_l1.forget

# Rule LRES.4: Minimum space from Poly2 resistor to unrelated Poly2. is 0.6µm
logger.info("Executing rule LRES.4")
lres4_l1  = lres_poly.separation(poly2.not_interacting(sab), 0.6.um, euclidian).polygons(0.001)
lres4_l1.output("LRES.4", "LRES.4 : Minimum space from Poly2 resistor to unrelated Poly2. : 0.6µm")
lres4_l1.forget

# Rule LRES.5: Minimum Nplus implant overlap of Poly2 resistor. is 0.3µm
logger.info("Executing rule LRES.5")
lres5_l1 = nplus.enclosing(poly2.and(nplus).interacting(sab).interacting(res_mk), 0.3.um, euclidian).polygons(0.001)
lres5_l2 = poly2.and(nplus).interacting(sab).interacting(res_mk).not_outside(nplus).not(nplus)
lres5_l  = lres5_l1.or(lres5_l2)
lres5_l.output("LRES.5", "LRES.5 : Minimum Nplus implant overlap of Poly2 resistor. : 0.3µm")
lres5_l1.forget
lres5_l2.forget
lres5_l.forget

# Rule LRES.6: Minimum salicide block overlap of Poly2 resistor in width direction. is 0.28µm
logger.info("Executing rule LRES.6")
lres6_l1 = sab.enclosing(lres_poly,0.28.um).polygons(0.001)
lres6_l1.output("LRES.6", "LRES.6 : Minimum salicide block overlap of Poly2 resistor in width direction. : 0.28µm")
lres6_l1.forget

cont_lres7 = contact.inside(poly2.and(nplus).interacting(sab).interacting(res_mk))
# Rule LRES.7: Space from salicide block to contact on Poly2 resistor.
logger.info("Executing rule LRES.7")
lres7_l1 = cont_lres7.separation(sab,0.22.um).polygons(0.001).or(cont_lres7.interacting(sab))
lres7_l1.output("LRES.7", "LRES.7 : Space from salicide block to contact on Poly2 resistor.")
lres7_l1.forget

cont_lres7.forget

# rule LRES.8 is not a DRC check

mk_lres9 = res_mk.edges.not(poly2.and(nplus).and(sab).edges).inside_part(poly2)
# Rule LRES.9a: Nplus Poly2 resistor shall be covered by RES_MK marking. RES_MK length shall be coincide with resistor length (Defined by SAB length) and width covering the width of Poly2.
logger.info("Executing rule LRES.9a")
lres9a_l1 = res_mk.interacting(lres_poly).interacting(mk_lres9)
lres9a_l1.output("LRES.9a", "LRES.9a : Nplus Poly2 resistor shall be covered by RES_MK marking. RES_MK length shall be coincide with resistor length (Defined by SAB length) and width covering the width of Poly2. ")
lres9a_l1.forget

mk_lres9.forget

lres9b = res_mk.with_area(15000.01.um,nil).in(res_mk.interacting(res_mk.edges.with_length(80.01.um,nil)))
# Rule LRES.9b: If the size of single RES_MK mark layer is greater than 15000um2 and both side (X and Y) are greater than 80um. then the minimum spacing to adjacent RES_MK layer. is 20µm
logger.info("Executing rule LRES.9b")
lres9b_l1 = res_mk.interacting(lres_poly).drc(separation(lres9b) < 20.um).polygons(0.001)
lres9b_l1.output("LRES.9b", "LRES.9b : If the size of single RES_MK mark layer is greater than 15000um2 and both side (X and Y) are greater than 80um. then the minimum spacing to adjacent RES_MK layer. : 20µm")
lres9b_l1.forget

lres9b.forget

lres_poly.forget

#================================================
#----------------H POLY RESISTOR-----------------
#================================================

hres_poly = poly2.interacting(pplus).interacting(sab).interacting(res_mk).interacting(resistor)
hres1_poly = poly2.interacting(pplus).interacting(sab).interacting(res_mk)
# Rule HRES.1: Minimum space. Note : Merge if the spacing is less than 0.4 um. is 0.4µm
logger.info("Executing rule HRES.1")
hres1_l1  = resistor.interacting(hres1_poly).space(0.4.um, euclidian).polygons(0.001)
hres1_l1.output("HRES.1", "HRES.1 : Minimum space. Note : Merge if the spacing is less than 0.4 um. : 0.4µm")
hres1_l1.forget

# Rule HRES.2: Minimum width of Poly2 resistor. is 1µm
logger.info("Executing rule HRES.2")
hres2_l1  = hres_poly.width(1.um, euclidian).polygons(0.001)
hres2_l1.output("HRES.2", "HRES.2 : Minimum width of Poly2 resistor. : 1µm")
hres2_l1.forget

# Rule HRES.3: Minimum space between Poly2 resistors. is 0.4µm
logger.info("Executing rule HRES.3")
hres3_l1  = hres_poly.space(0.4.um, euclidian).polygons(0.001)
hres3_l1.output("HRES.3", "HRES.3 : Minimum space between Poly2 resistors. : 0.4µm")
hres3_l1.forget

# Rule HRES.4: Minimum RESISTOR overlap of Poly2 resistor. is 0.4µm
logger.info("Executing rule HRES.4")
hres4_l1 = resistor.enclosing(hres_poly, 0.4.um, euclidian).polygons(0.001)
hres4_l2 = hres_poly.not_outside(resistor).not(resistor)
hres4_l  = hres4_l1.or(hres4_l2)
hres4_l.output("HRES.4", "HRES.4 : Minimum RESISTOR overlap of Poly2 resistor. : 0.4µm")
hres4_l1.forget
hres4_l2.forget
hres4_l.forget

# Rule HRES.5: Minimum RESISTOR space to unrelated Poly2. is 0.3µm
logger.info("Executing rule HRES.5")
hres5_l1  = resistor.interacting(hres1_poly).separation(poly2.not_interacting(sab), 0.3.um, euclidian).polygons(0.001)
hres5_l1.output("HRES.5", "HRES.5 : Minimum RESISTOR space to unrelated Poly2. : 0.3µm")
hres5_l1.forget

# Rule HRES.6: Minimum RESISTOR space to COMP.
logger.info("Executing rule HRES.6")
hres6_l1 = resistor.interacting(hres1_poly).separation(comp, 0.3.um, euclidian).polygons(0.001).or(comp.not_outside(resistor.interacting(poly2.interacting(pplus).interacting(sab).interacting(res_mk))))
hres6_l1.output("HRES.6", "HRES.6 : Minimum RESISTOR space to COMP.")
hres6_l1.forget

hres1_poly.forget

# Rule HRES.7: Minimum Pplus overlap of contact on Poly2 resistor. is 0.2µm
logger.info("Executing rule HRES.7")
hres7_l1 = pplus.enclosing(contact.inside(hres_poly), 0.2.um, euclidian).polygons(0.001)
hres7_l2 = contact.inside(hres_poly).not_outside(pplus).not(pplus)
hres7_l  = hres7_l1.or(hres7_l2)
hres7_l.output("HRES.7", "HRES.7 : Minimum Pplus overlap of contact on Poly2 resistor. : 0.2µm")
hres7_l1.forget
hres7_l2.forget
hres7_l.forget

# Rule HRES.8: Space from salicide block to contact on Poly2 resistor.
logger.info("Executing rule HRES.8")
hres8_l1 = contact.inside(hres_poly).separation(sab,0.22.um).polygons(0.001).or(contact.inside(hres_poly).interacting(sab))
hres8_l1.output("HRES.8", "HRES.8 : Space from salicide block to contact on Poly2 resistor.")
hres8_l1.forget

hres9_sab             = sab.interacting(pplus).interacting(res_mk).interacting(resistor)
hres9_clear_sab       = hres9_sab.not(hres_poly)
hres9_bad_inside_edge = hres9_sab.edges.inside_part(hres_poly).extended(0,0,0.001,0.001).interacting(hres9_clear_sab, 1, 1)
hres9_sab_hole        = hres9_sab.holes.and(hres_poly)
# Rule HRES.9: Minimum salicide block overlap of Poly2 resistor in width direction.
logger.info("Executing rule HRES.9")
hres9_l1 = hres9_sab.enclosing(hres_poly, 0.28.um, euclidian).polygons(0.001).or(hres9_bad_inside_edge).or(hres9_sab_hole)
hres9_l1.output("HRES.9", "HRES.9 : Minimum salicide block overlap of Poly2 resistor in width direction.")
hres9_l1.forget

hres9_sab.forget

hres9_clear_sab.forget

hres9_bad_inside_edge.forget

hres9_sab_hole.forget

pplus1_hres10 = pplus.and(sab).drc(width != 0.1.um)
pplus2_hres10 = pplus.not_overlapping(sab).edges
# Rule HRES.10: Minimum & maximum Pplus overlap of SAB.
logger.info("Executing rule HRES.10 (requires flat)")
begin
  hres10_l1 = pplus1_hres10.or(pplus2_hres10).extended(0, 0, 0.001, 0.001).interacting(hres_poly)
  hres10_l1.output("HRES.10", "HRES.10 : Minimum & maximum Pplus overlap of SAB.")
  hres10_l1.forget
rescue
  $errs += 1
  CHIP.output("HRES.10", "HRES.10: SKIPPED. Internal error, failed to check. Try flat.")
  logger.error("EXCEPTION in rule HRES.10")
end
pplus1_hres10.forget
pplus2_hres10.forget

# rule HRES.11 is not a DRC check

mk_hres12a = res_mk.edges.not(poly2.not(pplus).and(sab).edges).inside_part(poly2)
# Rule HRES.12a: P type Poly2 resistor (high sheet rho) shall be covered by RES_MK marking. RES_MK length shall be coincide with resistor length (Defined by Pplus space) and width covering the width of Poly2.
logger.info("Executing rule HRES.12a")
hres12a_l1 = res_mk.interacting(resistor).interacting(mk_hres12a)
hres12a_l1.output("HRES.12a", "HRES.12a : P type Poly2 resistor (high sheet rho) shall be covered by RES_MK marking. RES_MK length shall be coincide with resistor length (Defined by Pplus space) and width covering the width of Poly2. ")
hres12a_l1.forget

mk_hres12a.forget

hres12b = res_mk.with_area(15000.01.um,nil).in(res_mk.interacting(res_mk.edges.with_length(80.01.um,nil)))
# Rule HRES.12b: If the size of single RES_MK mark layer is greater than 15000 um2 and both side (X and Y) are greater than 80 um. Then the minimum spacing to adjacent RES_MK layer. is 20µm
logger.info("Executing rule HRES.12b")
hres12b_l1 = res_mk.interacting(hres_poly).drc(separation(hres12b) < 20.um).polygons(0.001)
hres12b_l1.output("HRES.12b", "HRES.12b : If the size of single RES_MK mark layer is greater than 15000 um2 and both side (X and Y) are greater than 80 um. Then the minimum spacing to adjacent RES_MK layer. : 20µm")
hres12b_l1.forget

hres12b.forget

hres_poly.forget

#================================================
#------------MIM CAPACITOR OPTION A -------------
#================================================

if MIM_OPTION == "A"
logger.info("MIM Capacitor Option A section")

mim_virtual = fusetop.sized(1.06.um).and(metal2.interacting(fusetop))
# Rule MIM.1: Minimum MiM bottom plate spacing to the bottom plate metal (whether adjacent MiM or routing metal). is 1.2µm
logger.info("Executing rule MIM.1")
mim1_l1 = metal2.separation(mim_virtual ,transparent, 1.2.um).polygons(0.001)
mim1_l1.output("MIM.1", "MIM.1 : Minimum MiM bottom plate spacing to the bottom plate metal (whether adjacent MiM or routing metal). : 1.2µm")
mim1_l1.forget

# Rule MIM.2: Minimum MiM bottom plate overlap of Via2 layer. [This is applicable for via2 within 1.06um oversize of FuseTop layer (referenced to virtual bottom plate)]. is 0.4µm
logger.info("Executing rule MIM.2")
mim2_l1 = metal2.enclosing(via2.overlapping(mim_virtual), 0.4.um, euclidian).polygons(0.001)
mim2_l2 = via2.overlapping(mim_virtual).not_outside(metal2).not(metal2)
mim2_l  = mim2_l1.or(mim2_l2)
mim2_l.output("MIM.2", "MIM.2 : Minimum MiM bottom plate overlap of Via2 layer. [This is applicable for via2 within 1.06um oversize of FuseTop layer (referenced to virtual bottom plate)]. : 0.4µm")
mim2_l1.forget
mim2_l2.forget
mim2_l.forget

# Rule MIM.3: Minimum MiM bottom plate overlap of Top plate.
logger.info("Executing rule MIM.3")
mim3_l1 = mim_virtual.enclosing(fusetop,0.6.um).polygons(0.001).or(fusetop.not_inside(mim_virtual))
mim3_l1.output("MIM.3", "MIM.3 : Minimum MiM bottom plate overlap of Top plate.")
mim3_l1.forget

mim_virtual.forget

# Rule MIM.4: Minimum MiM top plate (FuseTop) overlap of Via2. is 0.4µm
logger.info("Executing rule MIM.4")
mim4_l1 = fusetop.enclosing(via2, 0.4.um, euclidian).polygons(0.001)
mim4_l2 = via2.not_outside(fusetop).not(fusetop)
mim4_l  = mim4_l1.or(mim4_l2)
mim4_l.output("MIM.4", "MIM.4 : Minimum MiM top plate (FuseTop) overlap of Via2. : 0.4µm")
mim4_l1.forget
mim4_l2.forget
mim4_l.forget

# Rule MIM.5: Minimum spacing between top plate and the Via2 connecting to the bottom plate. is 0.4µm
logger.info("Executing rule MIM.5")
mim5_l1  = fusetop.separation(via2.interacting(metal2), 0.4.um, euclidian).polygons(0.001)
mim5_l1.output("MIM.5", "MIM.5 : Minimum spacing between top plate and the Via2 connecting to the bottom plate. : 0.4µm")
mim5_l1.forget

# Rule MIM.6: Minimum spacing between unrelated top plates. is 0.6µm
logger.info("Executing rule MIM.6")
mim6_l1  = fusetop.space(0.6.um, euclidian).polygons(0.001)
mim6_l1.output("MIM.6", "MIM.6 : Minimum spacing between unrelated top plates. : 0.6µm")
mim6_l1.forget

# Rule MIM.7: Min FuseTop enclosure by CAP_MK.
logger.info("Executing rule MIM.7")
mim7_l1 = fusetop.not_inside(cap_mk)
mim7_l1.output("MIM.7", "MIM.7 : Min FuseTop enclosure by CAP_MK.")
mim7_l1.forget

# Rule MIM.8a: Minimum MIM cap area (defined by FuseTop area) (um2). is 25µm²
logger.info("Executing rule MIM.8a")
mim8a_l1  = fusetop.with_area(nil, 25.um)
mim8a_l1.output("MIM.8a", "MIM.8a : Minimum MIM cap area (defined by FuseTop area) (um2). : 25µm²")
mim8a_l1.forget

# Rule MIM.8b: Maximum single MIM Cap area (Use multiple MIM caps in parallel connection if bigger capacitors are required) (um2). is 10000µm
logger.info("Executing rule MIM.8b")
mim8b_l1 = fusetop.with_area(10000.um,nil).not_in(fusetop.with_area(10000.um))
mim8b_l1.output("MIM.8b", "MIM.8b : Maximum single MIM Cap area (Use multiple MIM caps in parallel connection if bigger capacitors are required) (um2). : 10000µm")
mim8b_l1.forget

# Rule MIM.9: Min. via spacing for sea of via on MIM top plate. is 0.5µm
logger.info("Executing rule MIM.9")
mim9_l1  = via2.inside(fusetop).space(0.5.um, euclidian).polygons(0.001)
mim9_l1.output("MIM.9", "MIM.9 : Min. via spacing for sea of via on MIM top plate. : 0.5µm")
mim9_l1.forget

# Rule MIM.10: (a) There cannot be any Via1 touching MIM bottom plate Metal2. (b) MIM bottom plate Metal2 can only be connected through the higher Via (Via2).
logger.info("Executing rule MIM.10")
mim10_l1 = via1.interacting(metal2.interacting(fusetop))
mim10_l1.output("MIM.10", "MIM.10 : (a) There cannot be any Via1 touching MIM bottom plate Metal2. (b) MIM bottom plate Metal2 can only be connected through the higher Via (Via2).")
mim10_l1.forget

mim11_large_metal2 = metal2.interacting(fusetop).with_area(10000, nil)
mim11_large_metal2_violation = polygon_layer
mim11_large_metal2.data.each do |p|
  mim11_metal2_polygon_layer = polygon_layer
  mim11_metal2_polygon_layer.data.insert(p)
  fuse_in_polygon = fusetop.and(mim11_metal2_polygon_layer)
  if (fuse_in_polygon.area > 10000)
    mim11_bad_metal2_polygon = mim11_metal2_polygon_layer.interacting(fuse_in_polygon)
    mim11_bad_metal2_polygon.data.each do |b|
      b.num_points > 0 && mim11_large_metal2_violation.data.insert(b)
    end
  end
end
# Rule MIM.11: Bottom plate of multiple MIM caps can be shared (for common nodes) as long as total MIM area with that single common plate does not exceed MIM.8b rule. is -µm
logger.info("Executing rule MIM.11")
mim11_l1  = mim11_large_metal2_violation
mim11_l1.output("MIM.11", "MIM.11 : Bottom plate of multiple MIM caps can be shared (for common nodes) as long as total MIM area with that single common plate does not exceed MIM.8b rule. : -µm")
mim11_l1.forget

mim11_large_metal2.forget

mim11_large_metal2_violation.forget

# rule MIM.12 is not a DRC check

#================================================
#-------------MIM CAPACITOR OPTION B-------------
#================================================

elsif MIM_OPTION == "B"
logger.info("MIM Capacitor Option B section")

mimtm_virtual = fusetop.sized(1.06.um).and(topmin1_metal.interacting(fusetop))
# Rule MIMTM.1: Minimum MiM bottom plate spacing to the bottom plate metal (whether adjacent MiM or routing metal). is 1.2µm
logger.info("Executing rule MIMTM.1")
mimtm1_l1 = topmin1_metal.separation(mimtm_virtual ,transparent, 1.2.um).polygons(0.001)
mimtm1_l1.output("MIMTM.1", "MIMTM.1 : Minimum MiM bottom plate spacing to the bottom plate metal (whether adjacent MiM or routing metal). : 1.2µm")
mimtm1_l1.forget

# Rule MIMTM.2: Minimum MiM bottom plate overlap of Vian-1 layer. [This is applicable for Vian-1 within 1.06um oversize of FuseTop layer (referenced to virtual bottom plate)]. is 0.4µm
logger.info("Executing rule MIMTM.2")
mimtm2_l1 = topmin1_metal.enclosing(top_via.overlapping(mimtm_virtual), 0.4.um, euclidian).polygons(0.001)
mimtm2_l2 = top_via.overlapping(mimtm_virtual).not_outside(topmin1_metal).not(topmin1_metal)
mimtm2_l  = mimtm2_l1.or(mimtm2_l2)
mimtm2_l.output("MIMTM.2", "MIMTM.2 : Minimum MiM bottom plate overlap of Vian-1 layer. [This is applicable for Vian-1 within 1.06um oversize of FuseTop layer (referenced to virtual bottom plate)]. : 0.4µm")
mimtm2_l1.forget
mimtm2_l2.forget
mimtm2_l.forget

# Rule MIMTM.3: Minimum MiM bottom plate overlap of Top plate.
logger.info("Executing rule MIMTM.3")
mimtm3_l1 = mimtm_virtual.enclosing(fusetop,0.6.um).polygons(0.001).or(fusetop.not_inside(mimtm_virtual))
mimtm3_l1.output("MIMTM.3", "MIMTM.3 : Minimum MiM bottom plate overlap of Top plate.")
mimtm3_l1.forget

mimtm_virtual.forget

# Rule MIMTM.4: Minimum MiM top plate (FuseTop) overlap of Vian-1. is 0.4µm
logger.info("Executing rule MIMTM.4")
mimtm4_l1 = fusetop.enclosing(top_via, 0.4.um, euclidian).polygons(0.001)
mimtm4_l2 = top_via.not_outside(fusetop).not(fusetop)
mimtm4_l  = mimtm4_l1.or(mimtm4_l2)
mimtm4_l.output("MIMTM.4", "MIMTM.4 : Minimum MiM top plate (FuseTop) overlap of Vian-1. : 0.4µm")
mimtm4_l1.forget
mimtm4_l2.forget
mimtm4_l.forget

# Rule MIMTM.5: Minimum spacing between top plate and the Vian-1 connecting to the bottom plate. is 0.4µm
logger.info("Executing rule MIMTM.5")
mimtm5_l1  = fusetop.separation(top_via.interacting(topmin1_metal), 0.4.um, euclidian).polygons(0.001)
mimtm5_l1.output("MIMTM.5", "MIMTM.5 : Minimum spacing between top plate and the Vian-1 connecting to the bottom plate. : 0.4µm")
mimtm5_l1.forget

# Rule MIMTM.6: Minimum spacing between unrelated top plates. is 0.6µm
logger.info("Executing rule MIMTM.6")
mimtm6_l1  = fusetop.space(0.6.um, euclidian).polygons(0.001)
mimtm6_l1.output("MIMTM.6", "MIMTM.6 : Minimum spacing between unrelated top plates. : 0.6µm")
mimtm6_l1.forget

# Rule MIMTM.7: Min FuseTop enclosure by CAP_MK.
logger.info("Executing rule MIMTM.7")
mimtm7_l1 = fusetop.not_inside(cap_mk)
mimtm7_l1.output("MIMTM.7", "MIMTM.7 : Min FuseTop enclosure by CAP_MK.")
mimtm7_l1.forget

# Rule MIMTM.8a: Minimum MIM cap area (defined by FuseTop area) (um2). is 25µm²
logger.info("Executing rule MIMTM.8a")
mimtm8a_l1  = fusetop.with_area(nil, 25.um)
mimtm8a_l1.output("MIMTM.8a", "MIMTM.8a : Minimum MIM cap area (defined by FuseTop area) (um2). : 25µm²")
mimtm8a_l1.forget

# Rule MIMTM.8b: Maximum single MIM Cap area (Use multiple MIM caps in parallel connection if bigger capacitors are required) (um2). is 10000µm
logger.info("Executing rule MIMTM.8b")
mimtm8b_l1 = fusetop.with_area(10000.um,nil).not_in(fusetop.with_area(10000.um))
mimtm8b_l1.output("MIMTM.8b", "MIMTM.8b : Maximum single MIM Cap area (Use multiple MIM caps in parallel connection if bigger capacitors are required) (um2). : 10000µm")
mimtm8b_l1.forget

# Rule MIMTM.9: Min. Via (Vian-1) spacing for sea of Via on MIM top plate. is 0.5µm
logger.info("Executing rule MIMTM.9")
mimtm9_l1  = top_via.inside(fusetop).space(0.5.um, euclidian).polygons(0.001)
mimtm9_l1.output("MIMTM.9", "MIMTM.9 : Min. Via (Vian-1) spacing for sea of Via on MIM top plate. : 0.5µm")
mimtm9_l1.forget

# Rule MIMTM.10: (a) There cannot be any Vian-2 touching MIM bottom plate Metaln-1. (b) MIM bottom plate Metaln-1 can only be connected through the higher Via (Vian-1).
logger.info("Executing rule MIMTM.10")
mimtm10_l1 = topmin1_via.interacting(topmin1_metal.interacting(fusetop))
mimtm10_l1.output("MIMTM.10", "MIMTM.10 : (a) There cannot be any Vian-2 touching MIM bottom plate Metaln-1. (b) MIM bottom plate Metaln-1 can only be connected through the higher Via (Vian-1).")
mimtm10_l1.forget

mimtm11_large_topmin1_metal = topmin1_metal.interacting(fusetop).with_area(10000, nil)
mimtm11_large_topmin1_metal_violation = polygon_layer
mimtm11_large_topmin1_metal.data.each do |p|
  mimtm11_topmin1_metal_polygon_layer = polygon_layer
  mimtm11_topmin1_metal_polygon_layer.data.insert(p)
  fuse_in_polygon = fusetop.and(mimtm11_topmin1_metal_polygon_layer)
  if (fuse_in_polygon.area > 10000)
    mimtm11_bad_topmin1_metal_polygon = mimtm11_topmin1_metal_polygon_layer.interacting(fuse_in_polygon)
    mimtm11_bad_topmin1_metal_polygon.data.each do |b|
      b.num_points > 0 && mimtm11_large_topmin1_metal_violation.data.insert(b)
    end
  end
end
# Rule MIMTM.11: Bottom plate of multiple MIM caps can be shared (for common nodes) as long as total MIM area with that single common plate does not exceed MIMTM.8b rule. is -µm
logger.info("Executing rule MIMTM.11")
mimtm11_l1  = mimtm11_large_topmin1_metal_violation
mimtm11_l1.output("MIMTM.11", "MIMTM.11 : Bottom plate of multiple MIM caps can be shared (for common nodes) as long as total MIM area with that single common plate does not exceed MIMTM.8b rule. : -µm")
mimtm11_l1.forget

mimtm11_large_topmin1_metal.forget

mimtm11_large_topmin1_metal_violation.forget

# rule MIMTM.12 is not a DRC check

else
logger.info("No MIM Capacitor Option Selected section")

end #MIM_OPTION

#================================================
#-----------------NATIVE VT NMOS-----------------
#================================================

# Rule NAT.1: Min. NAT Overlap of COMP of Native Vt NMOS. is 2µm
logger.info("Executing rule NAT.1")
nat1_l1 = nat.enclosing(ncomp.outside(nwell).interacting(nat), 2.um, euclidian).polygons(0.001)
nat1_l1.output("NAT.1", "NAT.1 : Min. NAT Overlap of COMP of Native Vt NMOS. : 2µm")
nat1_l1.forget

# Rule NAT.2: Space to unrelated COMP (outside NAT). is 0.3µm
logger.info("Executing rule NAT.2")
nat2_l1  = nat.separation(comp.outside(nat), 0.3.um, euclidian).polygons(0.001)
nat2_l1.output("NAT.2", "NAT.2 : Space to unrelated COMP (outside NAT). : 0.3µm")
nat2_l1.forget

# Rule NAT.3: Space to NWell edge. is 0.5µm
logger.info("Executing rule NAT.3")
nat3_l1  = nat.separation(nwell, 0.5.um, euclidian).polygons(0.001)
nat3_l1.output("NAT.3", "NAT.3 : Space to NWell edge. : 0.5µm")
nat3_l1.forget

# Rule NAT.4: Minimum channel length for 3.3V Native Vt NMOS (For smaller L Ioff will be higher than Spec). is 1.8µm
logger.info("Executing rule NAT.4")
nat4_l1  = poly2.edges.and(ngate.edges).not(nwell).interacting(nat).width(1.8.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
nat4_l1.output("NAT.4", "NAT.4 : Minimum channel length for 3.3V Native Vt NMOS (For smaller L Ioff will be higher than Spec). : 1.8µm")
nat4_l1.forget

# Rule NAT.5: Minimum channel length for 6.0V Native Vt NMOS (For smaller L Ioff will be higher than Spec). is 1.8µm
logger.info("Executing rule NAT.5")
nat5_l1  = poly2.edges.and(ngate.edges).not(nwell).interacting(nat).width(1.8.um, euclidian).polygons(0.001).overlapping(dualgate)
nat5_l1.output("NAT.5", "NAT.5 : Minimum channel length for 6.0V Native Vt NMOS (For smaller L Ioff will be higher than Spec). : 1.8µm")
nat5_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_nat, unconnected_nat = conn_space(natcompsd, 10, 10, transparent)

# Rule NAT.6: Two or more COMPs if connected to different potential are not allowed under same NAT layer.
logger.info("Executing rule NAT.6")
nat6_l1 = comp.and(nat).interacting(unconnected_nat.inside(nat.covering(comp, 2)).not(poly2))
nat6_l1.output("NAT.6", "NAT.6 : Two or more COMPs if connected to different potential are not allowed under same NAT layer.")
nat6_l1.forget

end #CONNECTIVITY_RULES

natcompsd.forget

# Rule NAT.7: Minimum NAT to NAT spacing. is 0.74µm
logger.info("Executing rule NAT.7")
nat7_l1  = nat.space(0.74.um, euclidian).polygons(0.001)
nat7_l1.output("NAT.7", "NAT.7 : Minimum NAT to NAT spacing. : 0.74µm")
nat7_l1.forget

# Rule NAT.8: Min. Dualgate overlap of NAT (for 5V/6V) native VT NMOS only.
logger.info("Executing rule NAT.8")
nat8_l1 = nat.not_outside(dualgate).not(dualgate)
nat8_l1.output("NAT.8", "NAT.8 : Min. Dualgate overlap of NAT (for 5V/6V) native VT NMOS only.")
nat8_l1.forget

nat9_1 = poly2.and(nat).not(ncomp).interacting(ngate.and(nat) , 2)
nat9_2 = poly2.not(nat).separation(nat, 0.3.um, euclidian).polygons(0.001)
# Rule NAT.9: Poly interconnect under NAT layer is not allowed, minimum spacing of un-related poly from the NAT layer.
logger.info("Executing rule NAT.9")
nat9_l1 = nat9_1.or(nat9_2)
nat9_l1.output("NAT.9", "NAT.9 : Poly interconnect under NAT layer is not allowed, minimum spacing of un-related poly from the NAT layer.")
nat9_l1.forget

nat9_1.forget

nat9_2.forget

# Rule NAT.10: Nwell, inside NAT layer are not allowed.
logger.info("Executing rule NAT.10")
nat10_l1 = nwell.inside(nat)
nat10_l1.output("NAT.10", "NAT.10 : Nwell, inside NAT layer are not allowed.")
nat10_l1.forget

# Rule NAT.11: NCOMP not intersecting to Poly2, is not allowed inside NAT layer.
logger.info("Executing rule NAT.11")
nat11_l1 = ncomp.and(nat).outside(poly2)
nat11_l1.output("NAT.11", "NAT.11 : NCOMP not intersecting to Poly2, is not allowed inside NAT layer.")
nat11_l1.forget

# Rule NAT.12: Poly2 not intersecting with COMP is not allowed inside NAT (Poly2 resistor is not allowed inside NAT).
logger.info("Executing rule NAT.12")
nat12_l1 = poly2.interacting(nat).not_interacting(comp.and(nat))
nat12_l1.output("NAT.12", "NAT.12 : Poly2 not intersecting with COMP is not allowed inside NAT (Poly2 resistor is not allowed inside NAT).")
nat12_l1.forget

#================================================
#--------------------DRC_BJT---------------------
#================================================

# Rule BJT.1: Min. DRC_BJT overlap of DNWELL for NPN BJT.
logger.info("Executing rule BJT.1")
bjt1_l1 = dnwell.interacting(drc_bjt).not(dnwell.inside(drc_bjt))
bjt1_l1.output("BJT.1", "BJT.1 : Min. DRC_BJT overlap of DNWELL for NPN BJT.")
bjt1_l1.forget

# Rule BJT.2: Min. DRC_BJT overlap of PCOM in Psub.
logger.info("Executing rule BJT.2")
bjt2_l1 = pcomp.outside(nwell).outside(dnwell).interacting(drc_bjt).not(pcomp.outside(nwell).outside(dnwell).inside(drc_bjt))
bjt2_l1.output("BJT.2", "BJT.2 : Min. DRC_BJT overlap of PCOM in Psub.")
bjt2_l1.forget

# Rule BJT.3: Minimum space of DRC_BJT layer to unrelated COMP. is 0.1µm
logger.info("Executing rule BJT.3")
bjt3_l1  = comp.outside(drc_bjt).separation(drc_bjt, 0.1.um, euclidian).polygons(0.001)
bjt3_l1.output("BJT.3", "BJT.3 : Minimum space of DRC_BJT layer to unrelated COMP. : 0.1µm")
bjt3_l1.forget

#================================================
#--------------DUMMY EXCLUDE LAYERS--------------
#================================================

# rule DE.1 is not a DRC check

# Rule DE.2: Minimum NDMY or PMNDMY size (x or y dimension in um). is 0.8µm
logger.info("Executing rule DE.2")
de2_l1  = ndmy.or(pmndmy).width(0.8.um, euclidian).polygons(0.001)
de2_l1.output("DE.2", "DE.2 : Minimum NDMY or PMNDMY size (x or y dimension in um). : 0.8µm")
de2_l1.forget

de3_ndmy_area = ndmy.with_area(15000.um, nil)
# Rule DE.3: If size greater than 15000 um2 then two sides should not be greater than (um).
logger.info("Executing rule DE.3")
de3_l1 = de3_ndmy_area.edges.with_length(80.um, nil).not_interacting(de3_ndmy_area.edges.with_length(nil, 80.um))
de3_l1.output("DE.3", "DE.3 : If size greater than 15000 um2 then two sides should not be greater than (um).")
de3_l1.forget

de3_ndmy_area.forget

# Rule DE.4: Minimum NDMY to NDMY space (Merge if space is less). is 20µm
logger.info("Executing rule DE.4")
de4_l1  = ndmy.space(20.um, euclidian).polygons(0.001)
de4_l1.output("DE.4", "DE.4 : Minimum NDMY to NDMY space (Merge if space is less). : 20µm")
de4_l1.forget

#================================================
#--------------------LVS_BJT---------------------
#================================================

vnpn_e = ncomp.interacting(lvs_bjt).inside(dnwell)
vpnp_e = pcomp.inside(nwell).interacting(lvs_bjt)
# Rule LVS_BJT.1: Minimum LVS_BJT enclosure of NPN or PNP Emitter COMP layers
logger.info("Executing rule LVS_BJT.1")
lvs_l1 = vnpn_e.or(vpnp_e).not_inside(lvs_bjt)
lvs_l1.output("LVS_BJT.1", "LVS_BJT.1 : Minimum LVS_BJT enclosure of NPN or PNP Emitter COMP layers")
lvs_l1.forget

vnpn_e.forget

vpnp_e.forget

#================================================
#---------------------OTP_MK---------------------
#================================================

# Rule O.DF.3a: Min. COMP Space. P-substrate tap (PCOMP outside NWELL) can be butted for different voltage devices as the potential is same. is 0.24µm
logger.info("Executing rule O.DF.3a")
odf3a_l1  = comp.and(otp_mk).space(0.24.um, euclidian).polygons(0.001)
odf3a_l1.output("O.DF.3a", "O.DF.3a : Min. COMP Space. P-substrate tap (PCOMP outside NWELL) can be butted for different voltage devices as the potential is same. : 0.24µm")
odf3a_l1.forget

# Rule O.DF.6: Min. COMP extend beyond poly2 (it also means source/drain overhang). is 0.22µm
logger.info("Executing rule O.DF.6")
odf6_l1 = comp.and(otp_mk).enclosing(poly2.and(otp_mk), 0.22.um, euclidian).polygons(0.001)
odf6_l1.output("O.DF.6", "O.DF.6 : Min. COMP extend beyond poly2 (it also means source/drain overhang). : 0.22µm")
odf6_l1.forget

# Rule O.DF.9: Min. COMP area (um2). is 0.1444µm²
logger.info("Executing rule O.DF.9")
odf9_l1  = comp.and(otp_mk).with_area(nil, 0.1444.um)
odf9_l1.output("O.DF.9", "O.DF.9 : Min. COMP area (um2). : 0.1444µm²")
odf9_l1.forget

# Rule O.PL.2: Min. poly2 width. is 0.22µm
logger.info("Executing rule O.PL.2")
opl2_l1  = poly2.edges.and(tgate.edges).and(otp_mk).width(0.22.um, euclidian).polygons(0.001)
opl2_l1.output("O.PL.2", "O.PL.2 : Min. poly2 width. : 0.22µm")
opl2_l1.forget

# Rule O.PL.3a: Min. poly2 Space on COMP. is 0.18µm
logger.info("Executing rule O.PL.3a")
opl3a_l1  = (tgate).or(poly2.not(comp)).and(otp_mk).space(0.18.um, euclidian).polygons(0.001)
opl3a_l1.output("O.PL.3a", "O.PL.3a : Min. poly2 Space on COMP. : 0.18µm")
opl3a_l1.forget

# Rule O.PL.4: Min. extension beyond COMP to form Poly2 end cap. is 0.14µm
logger.info("Executing rule O.PL.4")
opl4_l1 = poly2.and(otp_mk).enclosing(comp.and(otp_mk), 0.14.um, euclidian).polygons(0.001)
opl4_l1.output("O.PL.4", "O.PL.4 : Min. extension beyond COMP to form Poly2 end cap. : 0.14µm")
opl4_l1.forget

# rule O.PL.5a is not a DRC check

# rule O.PL.5b is not a DRC check

# Rule O.SB.2: Min. salicide Block Space. is 0.28µm
logger.info("Executing rule O.SB.2")
osb2_l1  = sab.and(otp_mk).space(0.28.um, euclidian).polygons(0.001)
osb2_l1.output("O.SB.2", "O.SB.2 : Min. salicide Block Space. : 0.28µm")
osb2_l1.forget

# Rule O.SB.3: Min. space from salicide block to unrelated COMP. is 0.09µm
logger.info("Executing rule O.SB.3")
osb3_l1  = sab.outside(comp).and(otp_mk).separation(comp.outside(sab), 0.09.um, euclidian).polygons(0.001)
osb3_l1.output("O.SB.3", "O.SB.3 : Min. space from salicide block to unrelated COMP. : 0.09µm")
osb3_l1.forget

# Rule O.SB.4: Min. space from salicide block to contact.
logger.info("Executing rule O.SB.4")
osb4_l1 = sab.and(otp_mk).separation(contact, 0.03.um, euclidian).polygons(0.001).or(sab.and(otp_mk).and(contact))
osb4_l1.output("O.SB.4", "O.SB.4 : Min. space from salicide block to contact.")
osb4_l1.forget

# rule O.SB.5a is not a DRC check

# Rule O.SB.5b_3.3V: Min. space from salicide block to unrelated Poly2 on COMP. is 0.1µm
logger.info("Executing rule O.SB.5b_3.3V")
osb5b_l1  = sab.outside(tgate).and(otp_mk).separation(tgate.outside(sab), 0.1.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
osb5b_l1.output("O.SB.5b_3.3V", "O.SB.5b_3.3V : Min. space from salicide block to unrelated Poly2 on COMP. : 0.1µm")
osb5b_l1.forget

# rule O.SB.5b_5V is not a DRC check

# Rule O.SB.9: Min. salicide block extension beyond unsalicided Poly2. is 0.1µm
logger.info("Executing rule O.SB.9")
osb9_l1 = sab.and(otp_mk).enclosing(poly2.and(sab), 0.1.um, euclidian).polygons
osb9_l1.output("O.SB.9", "O.SB.9 : Min. salicide block extension beyond unsalicided Poly2. : 0.1µm")
osb9_l1.forget

# Rule O.SB.11: Min. salicide block overlap with COMP. is 0.04µm
logger.info("Executing rule O.SB.11")
osb11_l1 = sab.and(otp_mk).overlap(comp, 0.04.um, euclidian).polygons
osb11_l1.output("O.SB.11", "O.SB.11 : Min. salicide block overlap with COMP. : 0.04µm")
osb11_l1.forget

# rule O.SB.12 is not a DRC check

# Rule O.SB.13_3.3V: Min. area of silicide block (um2). is 1.488µm²
logger.info("Executing rule O.SB.13_3.3V")
osb13_l1  = sab.and(otp_mk).with_area(nil, 1.488.um).not_interacting(v5_xtor).not_interacting(dualgate)
osb13_l1.output("O.SB.13_3.3V", "O.SB.13_3.3V : Min. area of silicide block (um2). : 1.488µm²")
osb13_l1.forget

# Rule O.SB.13_5V: Min. area of silicide block (um2). is 2µm²
logger.info("Executing rule O.SB.13_5V")
osb13_l1  = sab.and(otp_mk).and(v5_xtor).with_area(nil, 2.um)
osb13_l1.output("O.SB.13_5V", "O.SB.13_5V : Min. area of silicide block (um2). : 2µm²")
osb13_l1.forget

# rule O.SB.15b is not a DRC check

# Rule O.CO.7: Min. space from COMP contact to Poly2 on COMP. is 0.13µm
logger.info("Executing rule O.CO.7")
oco7_l1  = contact.not_outside(comp).and(otp_mk).separation(tgate.and(otp_mk), 0.13.um, euclidian).polygons(0.001)
oco7_l1.output("O.CO.7", "O.CO.7 : Min. space from COMP contact to Poly2 on COMP. : 0.13µm")
oco7_l1.forget

# Rule O.PL.ORT: Orientation-restricted gates must have the gate width aligned along the X-axis (poly line running horizontally) in reference to wafer notch down. is 0µm
logger.info("Executing rule O.PL.ORT")
oplort_l1 = comp.not(poly2).edges.and(tgate.edges).and(otp_mk).without_angle(0.um).extended(0, 0, 0.001, 0.001)
oplort_l1.output("O.PL.ORT", "O.PL.ORT : Orientation-restricted gates must have the gate width aligned along the X-axis (poly line running horizontally) in reference to wafer notch down. : 0µm")
oplort_l1.forget

#================================================
#---------------------EFUSE----------------------
#================================================

# Rule EF.01: Min. (Poly2 butt PLFUSE) within EFUSE_MK and Pplus.
logger.info("Executing rule EF.01")
ef01_l1 = poly2.or(plfuse).interacting(efuse_mk).not_inside(efuse_mk.and(pplus))
ef01_l1.output("EF.01", "EF.01 : Min. (Poly2 butt PLFUSE) within EFUSE_MK and Pplus.")
ef01_l1.forget

# Rule EF.02: Min. Max. PLFUSE width. is 0.18µm
logger.info("Executing rule EF.02")
ef02_l1 = plfuse.drc(width != 0.18.um).extended(0, 0, 0.001, 0.001)
ef02_l1.output("EF.02", "EF.02 : Min. Max. PLFUSE width. : 0.18µm")
ef02_l1.forget

# Rule EF.03: Min. Max. PLFUSE length. is 1.26µm
logger.info("Executing rule EF.03")
ef03_l1 = plfuse.edges.interacting(poly2.edges.and(plfuse.edges).centers(0, 0.95)).without_length(1.26.um).extended(0, 0, 0.001, 0.001)
ef03_l1.output("EF.03", "EF.03 : Min. Max. PLFUSE length. : 1.26µm")
ef03_l1.forget

# Rule EF.04a: Min. Max. PLFUSE overlap Poly2 (coinciding permitted) and touch cathode and anode.
logger.info("Executing rule EF.04a")
ef04a_l1 = plfuse.not_in(plfuse.interacting(poly2.not(plfuse), 2, 2)).inside(efuse_mk).or(plfuse.not(poly2).inside(efuse_mk))
ef04a_l1.output("EF.04a", "EF.04a : Min. Max. PLFUSE overlap Poly2 (coinciding permitted) and touch cathode and anode.")
ef04a_l1.forget

# Rule EF.04b: PLFUSE must be rectangular. is -µm
logger.info("Executing rule EF.04b")
ef04b_l1 = plfuse.non_rectangles
ef04b_l1.output("EF.04b", "EF.04b : PLFUSE must be rectangular. : -µm")
ef04b_l1.forget

cathode = poly2.inside(efuse_mk).not(lvs_source.or(plfuse))
# Rule EF.04c: Cathode Poly2 must be rectangular. is -µm
logger.info("Executing rule EF.04c")
ef04c_l1 = cathode.non_rectangles
ef04c_l1.output("EF.04c", "EF.04c : Cathode Poly2 must be rectangular. : -µm")
ef04c_l1.forget

anode = poly2.and(lvs_source).inside(efuse_mk)
# Rule EF.04d: Anode Poly2 must be rectangular. is -µm
logger.info("Executing rule EF.04d")
ef04d_l1 = anode.non_rectangles
ef04d_l1.output("EF.04d", "EF.04d : Anode Poly2 must be rectangular. : -µm")
ef04d_l1.forget

# Rule EF.05: Min./Max. LVS_Source overlap Poly2 (at Anode).
logger.info("Executing rule EF.05")
ef05_l1 = poly2.not(plfuse).interacting(lvs_source).not(lvs_source).inside(efuse_mk).or(lvs_source.not(poly2).inside(efuse_mk))
ef05_l1.output("EF.05", "EF.05 : Min./Max. LVS_Source overlap Poly2 (at Anode).")
ef05_l1.forget

cathode_width = cathode.edges.not_interacting(cathode.edges.interacting(plfuse)).or(cathode.edges.interacting(plfuse))
# Rule EF.06: Min./Max. Cathode Poly2 width. is 2.26µm
logger.info("Executing rule EF.06")
ef06_l1 = cathode_width.without_length(2.26.um).extended(0, 0, 0.001, 0.001)
ef06_l1.output("EF.06", "EF.06 : Min./Max. Cathode Poly2 width. : 2.26µm")
ef06_l1.forget

# Rule EF.07: Min./Max. Cathode Poly2 length. is 1.84µm
logger.info("Executing rule EF.07")
ef07_l1 = cathode.edges.not(cathode_width).without_length(1.84.um).extended(0, 0, 0.001, 0.001)
ef07_l1.output("EF.07", "EF.07 : Min./Max. Cathode Poly2 length. : 1.84µm")
ef07_l1.forget

anode_width = anode.edges.not_interacting(anode.edges.interacting(plfuse)).or(anode.edges.interacting(plfuse))
# Rule EF.08: Min./Max. Anode Poly2 width. is 1.06µm
logger.info("Executing rule EF.08")
ef08_l1 = anode_width.without_length(1.06.um).extended(0, 0, 0.001, 0.001)
ef08_l1.output("EF.08", "EF.08 : Min./Max. Anode Poly2 width. : 1.06µm")
ef08_l1.forget

# Rule EF.09: Min./Max. Anode Poly2 length. is 2.43µm
logger.info("Executing rule EF.09")
ef09_l1 = anode.edges.not(anode_width).without_length(2.43.um).extended(0, 0, 0.001, 0.001)
ef09_l1.output("EF.09", "EF.09 : Min./Max. Anode Poly2 length. : 2.43µm")
ef09_l1.forget

# Rule EF.10: Min. Cathode Poly2 to Poly2 space. is 0.26µm
logger.info("Executing rule EF.10")
ef10_l1  = cathode.space(0.26.um, euclidian).polygons(0.001)
ef10_l1.output("EF.10", "EF.10 : Min. Cathode Poly2 to Poly2 space. : 0.26µm")
ef10_l1.forget

# Rule EF.11: Min. Anode Poly2 to Poly2 space. is 0.26µm
logger.info("Executing rule EF.11")
ef11_l1  = anode.space(0.26.um, euclidian).polygons(0.001)
ef11_l1.output("EF.11", "EF.11 : Min. Anode Poly2 to Poly2 space. : 0.26µm")
ef11_l1.forget

cont_ef = contact.and(plfuse.inside(efuse_mk))
# Rule EF.12: Min. Space of Cathode Contact to PLFUSE end.
logger.info("Executing rule EF.12")
ef12_l1 = plfuse.inside(efuse_mk).separation(contact.inside(cathode), 0.155.um).polygons(0.001).or(cont_ef)
ef12_l1.output("EF.12", "EF.12 : Min. Space of Cathode Contact to PLFUSE end.")
ef12_l1.forget

# Rule EF.13: Min. Space of Anode Contact to PLFUSE end.
logger.info("Executing rule EF.13")
ef13_l1 = plfuse.inside(efuse_mk).separation(contact.inside(anode), 0.14.um).polygons(0.001).or(cont_ef)
ef13_l1.output("EF.13", "EF.13 : Min. Space of Anode Contact to PLFUSE end.")
ef13_l1.forget

cont_ef.forget

# Rule EF.14: Min. EFUSE_MK enclose LVS_Source.
logger.info("Executing rule EF.14")
ef14_l1 = lvs_source.not_outside(efuse_mk).not(efuse_mk)
ef14_l1.output("EF.14", "EF.14 : Min. EFUSE_MK enclose LVS_Source.")
ef14_l1.forget

# Rule EF.15: NO Contact is allowed to touch PLFUSE.
logger.info("Executing rule EF.15")
ef15_l1 = plfuse.interacting(contact)
ef15_l1.output("EF.15", "EF.15 : NO Contact is allowed to touch PLFUSE.")
ef15_l1.forget

# Rule EF.16a: Cathode must contain exact number of Contacts at each ends. is 4µm
logger.info("Executing rule EF.16a")
ef16a_l1 = cathode.not_covering(contact, 4, 4)
ef16a_l1.output("EF.16a", "EF.16a : Cathode must contain exact number of Contacts at each ends. : 4µm")
ef16a_l1.forget

# Rule EF.16b: Anode must contain exact number of Contacts at each ends. is 4µm
logger.info("Executing rule EF.16b")
ef16b_l1 = anode.not_covering(contact, 4, 4)
ef16b_l1.output("EF.16b", "EF.16b : Anode must contain exact number of Contacts at each ends. : 4µm")
ef16b_l1.forget

# Rule EF.17: Min. Space of EFUSE_MK to EFUSE_MK. is 0.26µm
logger.info("Executing rule EF.17")
ef17_l1  = efuse_mk.space(0.26.um, euclidian).polygons(0.001)
ef17_l1.output("EF.17", "EF.17 : Min. Space of EFUSE_MK to EFUSE_MK. : 0.26µm")
ef17_l1.forget

# Rule EF.18: PLFUSE must sit on field oxide (NOT COMP), no cross with any COMP, Nplus, Pplus, ESD, SAB, Resistor, Metal1, Metal2.
logger.info("Executing rule EF.18")
ef18_l1 = plfuse.not_outside(comp.or(nplus).or(esd).or(sab).or(resistor).or(metal1).or(metal2))
ef18_l1.output("EF.18", "EF.18 : PLFUSE must sit on field oxide (NOT COMP), no cross with any COMP, Nplus, Pplus, ESD, SAB, Resistor, Metal1, Metal2.")
ef18_l1.forget

# Rule EF.19: Min. PLFUSE space to Metal1, Metal2.
logger.info("Executing rule EF.19")
ef19_l1 = plfuse.not_outside(metal1.or(metal2))
ef19_l1.output("EF.19", "EF.19 : Min. PLFUSE space to Metal1, Metal2.")
ef19_l1.forget

# Rule EF.20: Min. PLFUSE space to COMP, Nplus, Pplus, Resistor, ESD, SAB. is 2.73µm
logger.info("Executing rule EF.20")
ef20_l1  = plfuse.separation(comp.or(nplus).or(esd).or(sab).or(resistor), 2.73.um, euclidian).polygons(0.001)
ef20_l1.output("EF.20", "EF.20 : Min. PLFUSE space to COMP, Nplus, Pplus, Resistor, ESD, SAB. : 2.73µm")
ef20_l1.forget

ef_21_fuse    = poly2.interacting(plfuse).inside(efuse_mk.and(pplus)).extents.edges
ef_21_anode   = anode.edges.not_interacting(anode.edges.interacting(plfuse))
ef_21_cathode = cathode.edges.not_interacting(cathode.edges.interacting(plfuse))
# Rule EF.21: Min./Max. eFUSE Poly2 length. is 5.53µm
logger.info("Executing rule EF.21")
ef21_l1 = ef_21_fuse.not_interacting(ef_21_anode.or(ef_21_cathode).centers(0, 0.95)).without_length(5.53.um).extended(0, 0, 0.001, 0.001)
ef21_l1.output("EF.21", "EF.21 : Min./Max. eFUSE Poly2 length. : 5.53µm")
ef21_l1.forget

ef_21_fuse.forget

ef_21_anode.forget

ef_21_cathode.forget

# Rule EF.22a: Min./Max. Cathode Poly2 overlap with PLFUSE in width direction. is 1.04µm
logger.info("Executing rule EF.22a")
ef22a_l1 = cathode.edges.interacting(plfuse).not(plfuse.edges).without_length(1.04.um).extended(0, 0, 0.001, 0.001)
ef22a_l1.output("EF.22a", "EF.22a : Min./Max. Cathode Poly2 overlap with PLFUSE in width direction. : 1.04µm")
ef22a_l1.forget

# Rule EF.22b: Min./Max. Anode Poly2 overlap with PLFUSE in width direction. is 0.44µm
logger.info("Executing rule EF.22b")
ef22b_l1 = anode.edges.interacting(plfuse).not(plfuse.edges).without_length(0.44.um).extended(0, 0, 0.001, 0.001)
ef22b_l1.output("EF.22b", "EF.22b : Min./Max. Anode Poly2 overlap with PLFUSE in width direction. : 0.44µm")
ef22b_l1.forget

#================================================
#-------------------10V LDNMOS-------------------
#================================================

# Rule MDN.1: Min MVSD width (for litho purpose). is 1µm
logger.info("Executing rule MDN.1")
mdn1_l1  = mvsd.width(1.um, euclidian).polygons(0.001)
mdn1_l1.output("MDN.1", "MDN.1 : Min MVSD width (for litho purpose). : 1µm")
mdn1_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_mdn_2a, unconnected_mdn_2b = conn_space(mvsd, 1, 2, euclidian)

# Rule MDN.2a: Min MVSD space [Same Potential]. is 1µm
logger.info("Executing rule MDN.2a")
mdn2a_l1  = connected_mdn_2a
mdn2a_l1.output("MDN.2a", "MDN.2a : Min MVSD space [Same Potential]. : 1µm")
mdn2a_l1.forget

# Rule MDN.2b: Min MVSD space [Diff Potential]. is 2µm
logger.info("Executing rule MDN.2b")
mdn2b_l1  = unconnected_mdn_2b
mdn2b_l1.output("MDN.2b", "MDN.2b : Min MVSD space [Diff Potential]. : 2µm")
mdn2b_l1.forget

else
logger.info("CONNECTIVITY_RULES disabled section")

# Rule MDN.2b: Min MVSD space [Diff Potential]. is 2µm
logger.info("Executing rule MDN.2b")
mdn2b_l1  = mvsd.space(2.um, euclidian).polygons(0.001)
mdn2b_l1.output("MDN.2b", "MDN.2b : Min MVSD space [Diff Potential]. : 2µm")
mdn2b_l1.forget

end #CONNECTIVITY_RULES

gate_mdn = poly2.and(comp).and(ldmos_xtor).and(dualgate)
# Rule MDN.3a: Min transistor channel length. is 0.6µm
logger.info("Executing rule MDN.3a")
mdn3a_l1 = gate_mdn.width(0.6.um, euclidian).polygons(0.001)
mdn3a_l1.output("MDN.3a", "MDN.3a : Min transistor channel length. : 0.6µm")
mdn3a_l1.forget

# Rule MDN.3b: Max transistor channel length.
logger.info("Executing rule MDN.3b")
good_mvsd = gate_mdn.width(20.001.um, euclidian).polygons(0.001)
mdn3b_l1 = gate_mdn.not(good_mvsd)
mdn3b_l1.output("MDN.3b", "MDN.3b : Max transistor channel length: 20 um")
mdn3b_l1.forget

# Rule MDN.4a: Min transistor channel width. is 4µm
logger.info("Executing rule MDN.4a")
mdn4a_l1  = gate_mdn.width(4.um, euclidian).polygons(0.001)
mdn4a_l1.output("MDN.4a", "MDN.4a : Min transistor channel width. : 4 µm")
mdn4a_l1.forget

# Rule MDN.4b: Max transistor channel width.
logger.info("Executing rule MDN.4b")
good_gate = gate_mdn.width(50.001.um, euclidian).polygons(0.001)
mdn4b_l1 = gate_mdn.not(good_gate)
mdn4b_l1.output("MDN.4b", "MDN.4b : Max transistor channel width. : 50 um ")
mdn4b_l1.forget

gate_mdn.forget

pcomp_mdn5a = pcomp.not_interacting(ncomp).inside(ldmos_xtor).inside(dualgate)
# Rule MDN.5ai: Min PCOMP (Pplus AND COMP) space to LDNMOS Drain MVSD (source and body tap non-butted). PCOMP (Pplus AND COMP) intercept with LDNMOS Drain MVSD is not allowed.
logger.info("Executing rule MDN.5ai")
mdn5ai_l1 = mvsd.and(pcomp_mdn5a).or(pcomp_mdn5a.separation(mvsd, 1.um, euclidian).polygons(0.001))
mdn5ai_l1.output("MDN.5ai", "MDN.5ai : Min PCOMP (Pplus AND COMP) space to LDNMOS Drain MVSD (source and body tap non-butted). PCOMP (Pplus AND COMP) intercept with LDNMOS Drain MVSD is not allowed.")
mdn5ai_l1.forget

pcomp_mdn5a.forget

# Rule MDN.5aii: Min PCOMP (Pplus AND COMP) space to LDNMOS Drain MVSD (source and body tap butted). PCOMP (Pplus AND COMP) intercept with LDNMOS Drain MVSD is not allowed. is 0.92µm
logger.info("Executing rule MDN.5aii")
mdn5aii_l1  = pcomp.interacting(ncomp).inside(ldmos_xtor).inside(dualgate).not(nplus).separation(mvsd, 0.92.um, euclidian).polygons(0.001)
mdn5aii_l1.output("MDN.5aii", "MDN.5aii : Min PCOMP (Pplus AND COMP) space to LDNMOS Drain MVSD (source and body tap butted). PCOMP (Pplus AND COMP) intercept with LDNMOS Drain MVSD is not allowed. : 0.92µm")
mdn5aii_l1.forget

ncomp_mdn5b = ncomp.inside(ldmos_xtor).inside(dualgate)
pcomp_mdn5b = pcomp.inside(ldmos_xtor).inside(dualgate)
# Rule MDN.5b: Min PCOMP (Pplus AND COMP) space to LDNMOS Source (Nplus AND COMP). Use butted source and p-substrate tab otherwise and that is good for Latch-up immunity as well.
logger.info("Executing rule MDN.5b")
mdn5b_l1 = ncomp_mdn5b.not(poly2).not(mvsd).separation(pcomp_mdn5b, 0.4.um, euclidian).polygons.or(ncomp_mdn5b.not(poly2).not(mvsd).and(pcomp_mdn5b))
mdn5b_l1.output("MDN.5b", "MDN.5b : Min PCOMP (Pplus AND COMP) space to LDNMOS Source (Nplus AND COMP). Use butted source and p-substrate tab otherwise and that is good for Latch-up immunity as well.")
mdn5b_l1.forget

ncomp_mdn5b.forget

pcomp_mdn5b.forget

mdn_5c_ncompsd = ncomp.inside(ldmos_xtor).inside(dualgate).interacting(mvsd).sized(0.36.um).sized(-0.36.um).extents
mdn_5c_error = mdn_5c_ncompsd.edges.centers(0, 0.99).not_interacting(mdn_5c_ncompsd.drc(separation(pcomp, euclidian) <= 15.um).polygons(0.001))
# Rule MDN.5c: Maximum distance of the nearest edge of the substrate tab from NCOMP edge. is 15µm
logger.info("Executing rule MDN.5c")
mdn5c_l1 = mdn_5c_error.and(ncomp).and(pcomp.holes).extended(0, 0, 0.001, 0.001)
mdn5c_l1.output("MDN.5c", "MDN.5c : Maximum distance of the nearest edge of the substrate tab from NCOMP edge. : 15µm")
mdn5c_l1.forget

mdn_5c_ncompsd.forget

mdn_5c_error.forget

# Rule MDN.6: ALL LDNMOS shall be covered by Dualgate layer.
logger.info("Executing rule MDN.6")
mdn6_l1 = ncomp.not(poly2).not(mvsd).or(ngate.not(mvsd)).or(ncomp.and(mvsd)).inside(ldmos_xtor).not_inside(dualgate)
mdn6_l1.output("MDN.6", "MDN.6 : ALL LDNMOS shall be covered by Dualgate layer.")
mdn6_l1.forget

# Rule MDN.6a: Min Dualgate enclose NCOMP.
logger.info("Executing rule MDN.6a")
mdn6a_l1 = dualgate.enclosing(ncomp.inside(ldmos_xtor), 0.5.um, euclidian).polygons(0.001).or(ncomp.inside(ldmos_xtor).not_inside(dualgate))
mdn6a_l1.output("MDN.6a", "MDN.6a : Min Dualgate enclose NCOMP.")
mdn6a_l1.forget

# Rule MDN.7: Each LDNMOS shall be covered by LDMOS_XTOR (GDS#226) mark layer.
logger.info("Executing rule MDN.7")
mdn7_l1 = ncomp.interacting(mvsd).not(poly2).not(mvsd).or(ngate.interacting(mvsd).not(mvsd)).or(ncomp.and(mvsd)).inside(dualgate).not_inside(ldmos_xtor)
mdn7_l1.output("MDN.7", "MDN.7 : Each LDNMOS shall be covered by LDMOS_XTOR (GDS#226) mark layer.")
mdn7_l1.forget

# Rule MDN.7a: Min LDMOS_XTOR enclose Dualgate.
logger.info("Executing rule MDN.7a")
mdn7a_l1 = dualgate.not_outside(ldmos_xtor).not(ldmos_xtor).or(dualgate.interacting(mvsd).not_inside(ldmos_xtor))
mdn7a_l1.output("MDN.7a", "MDN.7a : Min LDMOS_XTOR enclose Dualgate.")
mdn7a_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_mdn_8a, unconnected_mdn_8b = conn_separation(mvsd, nwell, 1, 2, euclidian)

# Rule MDN.8a: Min LDNMOS drain MVSD space to any other equal potential Nwell space.
logger.info("Executing rule MDN.8a")
mdn8a_l1 = connected_mdn_8a.or(mvsd.not_outside(nwell))
mdn8a_l1.output("MDN.8a", "MDN.8a : Min LDNMOS drain MVSD space to any other equal potential Nwell space.")
mdn8a_l1.forget

# Rule MDN.8b: Min LDNMOS drain MVSD space to any other different potential Nwell space.
logger.info("Executing rule MDN.8b")
mdn8b_l1 = unconnected_mdn_8b.or(mvsd.not_outside(nwell))
mdn8b_l1.output("MDN.8b", "MDN.8b : Min LDNMOS drain MVSD space to any other different potential Nwell space.")
mdn8b_l1.forget

else
logger.info("CONNECTIVITY_RULES disabled section")

# Rule MDN.8b: Min LDNMOS drain MVSD space to any other different potential Nwell space.
logger.info("Executing rule MDN.8b")
mdn8b_l1 = mvsd.separation(nwell, 2.um, euclidian).polygons(0.001).or(mvsd.not_outside(nwell))
mdn8b_l1.output("MDN.8b", "MDN.8b : Min LDNMOS drain MVSD space to any other different potential Nwell space.")
mdn8b_l1.forget

end #CONNECTIVITY_RULES

# Rule MDN.9: Min LDNMOS drain MVSD space to NCOMP (Nplus AND COMP) outside LDNMOS drain MVSD. is 4µm
logger.info("Executing rule MDN.9")
mdn9_l1  = mvsd.inside(dualgate).inside(ldmos_xtor).separation(ncomp.not_interacting(mvsd), 4.um, euclidian).polygons(0.001)
mdn9_l1.output("MDN.9", "MDN.9 : Min LDNMOS drain MVSD space to NCOMP (Nplus AND COMP) outside LDNMOS drain MVSD. : 4µm")
mdn9_l1.forget

# rule MDN.10 is not a DRC check

poly_mdn10 = poly2.inside(dualgate).inside(ldmos_xtor.interacting(mvsd))
# Rule MDN.10a: Min LDNMOS POLY2 width. is 1.2µm
logger.info("Executing rule MDN.10a")
mdn10a_l1  = poly_mdn10.width(1.2.um, euclidian).polygons(0.001)
mdn10a_l1.output("MDN.10a", "MDN.10a : Min LDNMOS POLY2 width. : 1.2µm")
mdn10a_l1.forget

# Rule MDN.10b: Min POLY2 extension beyond COMP in the width direction of the transistor (other than the LDNMOS drain direction). is 0.4µm
logger.info("Executing rule MDN.10b")
mdn10b_l1 = poly_mdn10.edges.enclosing(ncomp.interacting(poly_mdn10).edges.interacting(ncomp.edges.not_interacting(poly2)), 0.4.um, euclidian)
mdn10b_l1.output("MDN.10b", "MDN.10b : Min POLY2 extension beyond COMP in the width direction of the transistor (other than the LDNMOS drain direction). : 0.4µm")
mdn10b_l1.forget

mdn_10c_all_errors   = poly_mdn10.drc(enclosing(ncomp.interacting(poly_mdn10), euclidian) != 0.2.um)
mdn_10c_error_region = ncomp.inside(dualgate).inside(ldmos_xtor).sized(0.36.um).sized(-0.36.um).extents.and(mvsd).and(poly2)
# Rule MDN.10c: Min/Max POLY2 extension beyond COMP on the field towards LDNMOS drain COMP direction.
logger.info("Executing rule MDN.10c")
mdn10c_l1 = mdn_10c_all_errors.and(mdn_10c_error_region)
mdn10c_l1.output("MDN.10c", "MDN.10c : Min/Max POLY2 extension beyond COMP on the field towards LDNMOS drain COMP direction.")
mdn10c_l1.forget

mdn_10c_all_errors.forget

mdn_10c_error_region.forget

mdn_10d_field   = ncomp.and(poly2).sized(1.um, 0).and(poly2)
mdn_10d_not_max = ncomp.inside(mvsd).inside(dualgate).inside(ldmos_xtor).drc(separation(mdn_10d_field) <= 0.16.um)
mdn_10d_max     = ncomp.sized(0.36.um).sized(-0.36.um).extents.not(mdn_10d_not_max.polygons).not(ncomp).not(poly2).inside(mvsd)
mdn_10d_min     = ncomp.inside(mvsd).inside(dualgate).inside(ldmos_xtor).separation(mdn_10d_field , 0.16.um).polygons(0.001)
mdn_10d_overlap = ncomp.inside(mvsd).inside(dualgate).inside(ldmos_xtor).and(poly2)
# Rule MDN.10d: Min/Max POLY2 on field space to LDNMOS drain COMP.
logger.info("Executing rule MDN.10d")
mdn10d_l1 = mdn_10d_max.or(mdn_10d_min).or(mdn_10d_overlap)
mdn10d_l1.output("MDN.10d", "MDN.10d : Min/Max POLY2 on field space to LDNMOS drain COMP.")
mdn10d_l1.forget

mdn_10d_field.forget

mdn_10d_not_max.forget

mdn_10d_max.forget

mdn_10d_min.forget

mdn_10d_overlap.forget

# Rule MDN.10ei: Min POLY2 space to Psub tap (source and body tap non-butted).
logger.info("Executing rule MDN.10ei")
mdn10ei_l1 = poly_mdn10.separation(pcomp.not_interacting(ncomp), 0.4.um).polygons(0.001).or(poly_mdn10.and(pcomp.not(nplus).not_interacting(ncomp.not(pplus))))
mdn10ei_l1.output("MDN.10ei", "MDN.10ei : Min POLY2 space to Psub tap (source and body tap non-butted).")
mdn10ei_l1.forget

# Rule MDN.10eii: Min POLY2 space to Psub tap (source and body tap butted). is 0.32µm
logger.info("Executing rule MDN.10eii")
mdn10eii_l1  = poly_mdn10.separation(pcomp.not(nplus).interacting(ncomp.not(pplus)), 0.32.um, euclidian).polygons(0.001)
mdn10eii_l1.output("MDN.10eii", "MDN.10eii : Min POLY2 space to Psub tap (source and body tap butted). : 0.32µm")
mdn10eii_l1.forget

# Rule MDN.10f: Poly2 interconnect in HV region (LDMOS_XTOR marked region) not allowed. Also, any Poly2 interconnect with poly2 to substrate potential greater than 6V is not allowed.
logger.info("Executing rule MDN.10f")
mdn10f_l1 = poly_mdn10.not(nplus).interacting(poly_mdn10.and(nplus),2).or(poly2.and(ldmos_xtor).interacting(poly2.not(ldmos_xtor)))
mdn10f_l1.output("MDN.10f", "MDN.10f : Poly2 interconnect in HV region (LDMOS_XTOR marked region) not allowed. Also, any Poly2 interconnect with poly2 to substrate potential greater than 6V is not allowed.")
mdn10f_l1.forget

poly_mdn10.forget

mdn_11_layer      = ldmos_xtor.and(mvsd).and(comp).and(poly2).and(nplus)
mdn_11_max        = mdn_11_layer.not(mdn_11_layer.drc(width <= 0.4.um).polygons)
mdn_11_min        = mdn_11_layer.width(0.4.um).polygons(0.001).not_interacting(mdn_11_max)
mdn_11_no_channel = mvsd.covering(ncomp).outside(tgate).inside(dualgate).inside(ldmos_xtor).or(mvsd.not_covering(ncomp.not_interacting(poly2)).inside(dualgate).inside(ldmos_xtor))
# Rule MDN.11: Min/Max MVSD overlap channel COMP ((((LDMOS_XTOR AND MVSD) AND COMP) AND POLY2) AND NPlus).
logger.info("Executing rule MDN.11")
mdn11_l1 = mdn_11_max.or(mdn_11_min).or(mdn_11_no_channel)
mdn11_l1.output("MDN.11", "MDN.11 : Min/Max MVSD overlap channel COMP ((((LDMOS_XTOR AND MVSD) AND COMP) AND POLY2) AND NPlus).")
mdn11_l1.forget

mdn_11_layer.forget

mdn_11_max.forget

mdn_11_min.forget

mdn_11_no_channel.forget

mdn12_a = mvsd.covering(ncomp.not_interacting(poly2)).enclosing(ncomp, 0.5.um, transparent).polygons(0.001).outside(poly2).inside(dualgate).inside(ldmos_xtor)
mdn12_b = mvsd.not_covering(ncomp.not_interacting(poly2)).inside(dualgate).inside(ldmos_xtor)
# Rule MDN.12: Min MVSD enclose NCOMP in the LDNMOS drain and in the direction along the transistor width.
logger.info("Executing rule MDN.12")
mdn12_l1 = mdn12_a.or(mdn12_b)
mdn12_l1.output("MDN.12", "MDN.12 : Min MVSD enclose NCOMP in the LDNMOS drain and in the direction along the transistor width.")
mdn12_l1.forget

mdn12_a.forget

mdn12_b.forget

# rule MDN.13 is not a DRC check

# Rule MDN.13a: Max single finger width. is 50µm
logger.info("Executing rule MDN.13a")
mdn13a_l1 = poly2.and(ncomp).not(mvsd).inside(dualgate).inside(ldmos_xtor).drc(length > 50.um)
mdn13a_l1.output("MDN.13a", "MDN.13a : Max single finger width. : 50µm")
mdn13a_l1.forget

mdn_source = ncomp.interacting(poly2.and(dualgate).and(ldmos_xtor).and(mvsd)).not(poly2)
mdn_ldnmos = poly2.and(ncomp).and(dualgate).not(mvsd).inside(ldmos_xtor)
# Rule MDN.13b: Layout shall have alternative source & drain.
logger.info("Executing rule MDN.13b")
mdn13b_l1 = mdn_ldnmos.not_interacting(mdn_source,1,1).or(mdn_ldnmos.not_interacting(mvsd,1,1)).or(mdn_source.interacting(mvsd))
mdn13b_l1.output("MDN.13b", "MDN.13b : Layout shall have alternative source & drain.")
mdn13b_l1.forget

mdn_13c_source_side = mdn_ldnmos.interacting(mdn_source.interacting(mdn_ldnmos, 2, 2).or(mdn_source.interacting(pcomp.interacting(mdn_source, 2, 2))))
# Rule MDN.13c: Both sides of the transistor shall be terminated by source.
logger.info("Executing rule MDN.13c")
mdn13c_l1 = mvsd.covering(ncomp.not_interacting(poly2)).interacting(ncomp, 2, 2).interacting(mdn_13c_source_side)
mdn13c_l1.output("MDN.13c", "MDN.13c : Both sides of the transistor shall be terminated by source.")
mdn13c_l1.forget

mdn_13c_source_side.forget

mdn_13d_single      = mvsd.covering(ncomp.not_interacting(poly2)).interacting(ncomp, 2, 2).inside(ldmos_xtor)
mdn_13d_multi       = mvsd.covering(ncomp.not_interacting(poly2)).interacting(ncomp, 3, 3).inside(ldmos_xtor)
mdn_13d_butted_well = mdn_source.sized(1.um).sized(-1.um).extents.not(pcomp).interacting(mdn_ldnmos,2,2)
# Rule MDN.13d: Every two poly fingers shall be surrounded by a P-sub guard ring. (Exclude the case when each LDNMOS transistor have full width butting to well tap).
logger.info("Executing rule MDN.13d")
mdn13d_l1 = pcomp.holes.covering(mdn_13d_single, 2).or(pcomp.holes.covering(mdn_13d_single).covering(mdn_13d_multi)).or(mdn_13d_butted_well)
mdn13d_l1.output("MDN.13d", "MDN.13d : Every two poly fingers shall be surrounded by a P-sub guard ring. (Exclude the case when each LDNMOS transistor have full width butting to well tap).")
mdn13d_l1.forget

mdn_13d_single.forget

mdn_13d_multi.forget

mdn_13d_butted_well.forget

mdn_source.forget

mdn_ldnmos.forget

# Rule MDN.14: Min MVSD space to any DNWELL.
logger.info("Executing rule MDN.14")
mdn14_l1 = mvsd.separation(dnwell,6.0.um).polygons(0.001).or(mvsd.not_outside(dnwell))
mdn14_l1.output("MDN.14", "MDN.14 : Min MVSD space to any DNWELL.")
mdn14_l1.forget

# Rule MDN.15a: Min LDNMOS drain COMP width. is 0.22µm
logger.info("Executing rule MDN.15a")
mdn15a_l1  = comp.inside(mvsd).inside(dualgate).inside(ldmos_xtor).width(0.22.um, euclidian).polygons(0.001)
mdn15a_l1.output("MDN.15a", "MDN.15a : Min LDNMOS drain COMP width. : 0.22µm")
mdn15a_l1.forget

# Rule MDN.15b: Min LDNMOS drain COMP enclose contact. is 0µm
logger.info("Executing rule MDN.15b")
mdn15b_l1 = contact.interacting(ncomp.inside(mvsd).inside(dualgate).inside(ldmos_xtor)).not_inside(ncomp.inside(mvsd))
mdn15b_l1.output("MDN.15b", "MDN.15b : Min LDNMOS drain COMP enclose contact. : 0µm")
mdn15b_l1.forget

# rule MDN.16 is not a DRC check

mdn_17_blockages = pcomp.holes.not(ncomp.or(poly2).interacting(mvsd)).covering(dnwell.or(nwell)).inside(dualgate).inside(ldmos_xtor.interacting(mvsd))
mdn_17_mos_in_gr = ngate.not(mvsd).not_inside(pcomp.holes).inside(dualgate).inside(ldmos_xtor.interacting(mvsd))
mdn_17_gr_in_ldmos_mk = ldmos_xtor.interacting(mvsd).and(dualgate).not_covering(pcomp)
# Rule MDN.17: It is recommended to surround the LDNMOS transistor with non-broken Psub guard ring to improve the latch up immunity. Guideline to improve the latch up immunity.
logger.info("Executing rule MDN.17")
mdn17_l1 = mdn_17_blockages.or(mdn_17_mos_in_gr).or(mdn_17_gr_in_ldmos_mk)
mdn17_l1.output("MDN.17", "MDN.17 : It is recommended to surround the LDNMOS transistor with non-broken Psub guard ring to improve the latch up immunity. Guideline to improve the latch up immunity.")
mdn17_l1.forget

mdn_17_blockages.forget

mdn_17_mos_in_gr.forget

mdn_17_gr_in_ldmos_mk.forget

#================================================
#-------------------10V LDPMOS-------------------
#================================================

mdp_source = (pcomp).interacting(poly2.and(dualgate).and(ldmos_xtor).and(mvpsd)).not(poly2)
ldpmos     = poly2.and(pcomp).and(dualgate).not(mvpsd).inside(ldmos_xtor)
# Rule MDP.1: Minimum transistor channel length. is 0.6µm
logger.info("Executing rule MDP.1")
mdp1_l1 = poly2.and(comp).inside(ldmos_xtor).inside(dualgate).enclosing(mvpsd, 0.6.um, euclidian).polygons(0.001)
mdp1_l1.output("MDP.1", "MDP.1 : Minimum transistor channel length. : 0.6µm")
mdp1_l1.forget

mvpsd_mdp = mvpsd.edges.and(pcomp).and(poly2)
# Rule MDP.1a: Max transistor channel length.
logger.info("Executing rule MDP.1a")
mdp1a_l1 = poly2.edges.and(pcomp).or(mvpsd_mdp).and(ldmos_xtor).and(dualgate).not(pgate.not(mvpsd).edges.interacting(poly2.edges.and(pcomp).or(mvpsd_mdp)).width(20.001.um).edges)
mdp1a_l1.output("MDP.1a", "MDP.1a : Max transistor channel length.")
mdp1a_l1.forget

mvpsd_mdp.forget

# Rule MDP.2: Minimum transistor channel width. is 4µm
logger.info("Executing rule MDP.2")
mdp2_l1  = poly2.and(comp).inside(ldmos_xtor).inside(dualgate).edges.not(mvpsd).interacting(mvpsd).width(4.um, euclidian).polygons(0.001)
mdp2_l1.output("MDP.2", "MDP.2 : Minimum transistor channel width. : 4µm")
mdp2_l1.forget

mdp3_1 = ldpmos.or(mvpsd).or(mdp_source).not_interacting(ncomp.holes).inside(dualgate).inside(ldmos_xtor)
mdp3_2 = ncomp.holes.not_interacting(ncomp.interacting(mdp_source)).not_interacting(mvpsd,1,1).inside(dualgate).inside(ldmos_xtor)
# Rule MDP.3: Each LDPMOS shall be surrounded by non-broken Nplus guard ring inside DNWELL
logger.info("Executing rule MDP.3")
mdp3_l1 = mdp3_1.or(mdp3_2)
mdp3_l1.output("MDP.3", "MDP.3 : Each LDPMOS shall be surrounded by non-broken Nplus guard ring inside DNWELL")
mdp3_l1.forget

ncomp_mdp3ai = ncomp.not_interacting(pcomp).inside(ldmos_xtor).inside(dualgate)
# Rule MDP.3ai: Min NCOMP (Nplus AND COMP) space to MVPSD (source and body tap non-butted). NCOMP (Nplus AND COMP) intercept with MVPSD is not allowed.
logger.info("Executing rule MDP.3ai")
mdp3ai_l1 = ncomp_mdp3ai.separation(mvpsd, 1.um, euclidian).polygons(0.001).or(mvpsd.interacting(ncomp_mdp3ai))
mdp3ai_l1.output("MDP.3ai", "MDP.3ai : Min NCOMP (Nplus AND COMP) space to MVPSD (source and body tap non-butted). NCOMP (Nplus AND COMP) intercept with MVPSD is not allowed.")
mdp3ai_l1.forget

ncomp_mdp3ai.forget

ncomp_mdp3aii = ncomp.interacting(pcomp).inside(ldmos_xtor).inside(dualgate)
# Rule MDP.3aii: Min NCOMP (Nplus AND COMP) space to MVPSD (source and body tap butted). NCOMP (Nplus AND COMP) intercept with MVPSD is not allowed.
logger.info("Executing rule MDP.3aii")
mdp3aii_l1 = ncomp_mdp3aii.separation(mvpsd, 0.92.um, euclidian).polygons(0.001).or(mvpsd.interacting(ncomp_mdp3aii))
mdp3aii_l1.output("MDP.3aii", "MDP.3aii : Min NCOMP (Nplus AND COMP) space to MVPSD (source and body tap butted). NCOMP (Nplus AND COMP) intercept with MVPSD is not allowed.")
mdp3aii_l1.forget

ncomp_mdp3aii.forget

ncomp_mdp3b = ncomp.inside(ldmos_xtor).inside(dualgate)
pcomp_mdp3b = pcomp.inside(dnwell).inside(ldmos_xtor).inside(dualgate)
# Rule MDP.3b: Min NCOMP (Nplus AND COMP) space to PCOMP in DNWELL (Pplus AND COMP AND DNWELL). Use butted source and DNWELL contacts otherwise and that is best for Latch-up immunity as well. is 0.4µm
logger.info("Executing rule MDP.3b")
mdp3b_l1  = ncomp_mdp3b.not(poly2).not(mvpsd).separation(pcomp_mdp3b.not(poly2).not(mvpsd), 0.4.um, euclidian).polygons(0.001)
mdp3b_l1.output("MDP.3b", "MDP.3b : Min NCOMP (Nplus AND COMP) space to PCOMP in DNWELL (Pplus AND COMP AND DNWELL). Use butted source and DNWELL contacts otherwise and that is best for Latch-up immunity as well. : 0.4µm")
mdp3b_l1.forget

ncomp_mdp3b.forget

pcomp_mdp3b.forget

# Rule MDP.3c: Maximum distance of the nearest edge of the DNWELL tab (NCOMP inside DNWELL) from PCOMP edge (PCOMP inside DNWELL). is 15µm
logger.info("Executing rule MDP.3c")
mdp3c_l1 = ncomp.inside(dnwell).inside(ldmos_xtor).inside(dualgate).not_interacting(ncomp.inside(dnwell).drc(separation(pcomp.inside(dnwell)) <= 15.um).first_edges,4)
mdp3c_l1.output("MDP.3c", "MDP.3c : Maximum distance of the nearest edge of the DNWELL tab (NCOMP inside DNWELL) from PCOMP edge (PCOMP inside DNWELL). : 15µm")
mdp3c_l1.forget

# Rule MDP.3d: The metal connection for the Nplus guard ring recommended to be continuous. The maximum gap between this metal if broken. Note: To put maximum number of contact under metal for better manufacturability and reliability. is 10µm
logger.info("Executing rule MDP.3d")
mdp3d_l1 = ncomp.interacting(ldmos_xtor.interacting(mvpsd)).interacting(dualgate).not(metal1).edges.not(metal1).with_length(10.001.um, nil)
mdp3d_l1.output("MDP.3d", "MDP.3d : The metal connection for the Nplus guard ring recommended to be continuous. The maximum gap between this metal if broken. Note: To put maximum number of contact under metal for better manufacturability and reliability. : 10µm")
mdp3d_l1.forget

mdp4_metal = pcomp.not_interacting(mvpsd).interacting(ldmos_xtor.interacting(mvpsd)).interacting(dualgate).not(metal1).edges.not(metal1).with_length(10.001.um, nil)
# Rule MDP.4: DNWELL covering LDPMOS shall be surrounded by non broken Pplus guard. The metal connection for the Pplus guard ring recommended to be continuous, The maximum gap between this metal if broken. Note: To put maximum number of contact under metal for better manufacturability and reliability.
logger.info("Executing rule MDP.4")
mdp4_l1 = pcomp.interacting(metal1).not_interacting(pcomp.holes).edges.and(ldmos_xtor).and(dualgate).or(mdp4_metal)
mdp4_l1.output("MDP.4", "MDP.4 : DNWELL covering LDPMOS shall be surrounded by non broken Pplus guard. The metal connection for the Pplus guard ring recommended to be continuous, The maximum gap between this metal if broken. Note: To put maximum number of contact under metal for better manufacturability and reliability.")
mdp4_l1.forget

mdp4_metal.forget

# Rule MDP.4a: Min PCOMP (Pplus AND COMP) space to DNWELL. is 2.5µm
logger.info("Executing rule MDP.4a")
mdp4a_l1  = pcomp.inside(ldmos_xtor).inside(dualgate).separation(dnwell.inside(ldmos_xtor).inside(dualgate), 2.5.um, euclidian).polygons(0.001)
mdp4a_l1.output("MDP.4a", "MDP.4a : Min PCOMP (Pplus AND COMP) space to DNWELL. : 2.5µm")
mdp4a_l1.forget

mdp4b_dnwell_edges = dnwell.inside(ldmos_xtor).inside(dualgate).edges.centers(0, 0.99)
mdp4b_not_error = dnwell.drc(separation(pcomp.inside(ldmos_xtor.interacting(mvpsd)).inside(dualgate).not_interacting(mvpsd), euclidian) <= 15.um).polygons(0.001)
# Rule MDP.4b: Maximum distance of the nearest edge of the DNWELL from the PCOMP Guard ring outside DNWELL. is 15µm
logger.info("Executing rule MDP.4b")
mdp4b_l1 = mdp4b_dnwell_edges.not_interacting(mdp4b_not_error).and(pcomp.holes).extended(0, 0, 0.001, 0.001)
mdp4b_l1.output("MDP.4b", "MDP.4b : Maximum distance of the nearest edge of the DNWELL from the PCOMP Guard ring outside DNWELL. : 15µm")
mdp4b_l1.forget

mdp4b_dnwell_edges.forget

mdp4b_not_error.forget

# Rule MDP.5: Each LDPMOS shall be covered by Dualgate layer.
logger.info("Executing rule MDP.5")
mdp5_l1 = pcomp.not(poly2).not(mvpsd).or(pgate.not(mvpsd)).or(pcomp.and(mvpsd)).inside(ldmos_xtor).not_inside(dualgate)
mdp5_l1.output("MDP.5", "MDP.5 : Each LDPMOS shall be covered by Dualgate layer.")
mdp5_l1.forget

# Rule MDP.5a: Minimum Dualgate enclose Plus guarding ring PCOMP (Pplus AND COMP). is 0.5µm
logger.info("Executing rule MDP.5a")
mdp5a_l1 = dualgate.interacting(ldmos_xtor).enclosing(pcomp.inside(ldmos_xtor), 0.5.um, euclidian).polygons(0.001)
mdp5a_l2 = pcomp.inside(ldmos_xtor).not_outside(dualgate.interacting(ldmos_xtor)).not(dualgate.interacting(ldmos_xtor))
mdp5a_l  = mdp5a_l1.or(mdp5a_l2)
mdp5a_l.output("MDP.5a", "MDP.5a : Minimum Dualgate enclose Plus guarding ring PCOMP (Pplus AND COMP). : 0.5µm")
mdp5a_l1.forget
mdp5a_l2.forget
mdp5a_l.forget

# Rule MDP.6: Each LDPMOS shall be covered by LDMOS_XTOR (GDS#226) layer.
logger.info("Executing rule MDP.6")
mdp6_l1 = mvpsd.not_inside(ldmos_xtor)
mdp6_l1.output("MDP.6", "MDP.6 : Each LDPMOS shall be covered by LDMOS_XTOR (GDS#226) layer.")
mdp6_l1.forget

# Rule MDP.6a: Minimum LDMOS_XTOR enclose Dualgate.
logger.info("Executing rule MDP.6a")
mdp6a_l1 = ldmos_xtor.not_covering(dualgate)
mdp6a_l1.output("MDP.6a", "MDP.6a : Minimum LDMOS_XTOR enclose Dualgate.")
mdp6a_l1.forget

# Rule MDP.7: Minimum LDMOS_XTOR layer space to Nwell outside LDMOS_XTOR. is 2µm
logger.info("Executing rule MDP.7")
mdp7_l1  = ldmos_xtor.separation(nwell.outside(ldmos_xtor), 2.um, euclidian).polygons(0.001)
mdp7_l1.output("MDP.7", "MDP.7 : Minimum LDMOS_XTOR layer space to Nwell outside LDMOS_XTOR. : 2µm")
mdp7_l1.forget

# Rule MDP.8: Minimum LDMOS_XTOR layer space to NCOMP outside LDMOS_XTOR. is 1.5µm
logger.info("Executing rule MDP.8")
mdp8_l1  = ldmos_xtor.separation(ncomp.outside(ldmos_xtor), 1.5.um, euclidian).polygons(0.001)
mdp8_l1.output("MDP.8", "MDP.8 : Minimum LDMOS_XTOR layer space to NCOMP outside LDMOS_XTOR. : 1.5µm")
mdp8_l1.forget

# Rule MDP.9a: Min LDPMOS POLY2 width. is 1.2µm
logger.info("Executing rule MDP.9a")
mdp9a_l1  = poly2.inside(dnwell.and(dualgate).and(ldmos_xtor)).width(1.2.um, euclidian).polygons(0.001)
mdp9a_l1.output("MDP.9a", "MDP.9a : Min LDPMOS POLY2 width. : 1.2µm")
mdp9a_l1.forget

mdp9b_1 = poly2.inside(dnwell.and(dualgate).and(ldmos_xtor)).edges.interacting(mvpsd).not(mvpsd).enclosing(comp.edges,0.4.um).edges
mdp9b_2 = poly2.inside(dnwell.and(dualgate).and(ldmos_xtor)).edges.interacting(mvpsd).not(mvpsd).interacting(pcomp)
# Rule MDP.9b: Min POLY2 extension beyond COMP in the width direction of the transistor (other than the LDMOS drain direction). is 0.4µm
logger.info("Executing rule MDP.9b")
mdp9b_l1 = mdp9b_1.or(mdp9b_2).extended(0,0,0.001,0.001)
mdp9b_l1.output("MDP.9b", "MDP.9b : Min POLY2 extension beyond COMP in the width direction of the transistor (other than the LDMOS drain direction). : 0.4µm")
mdp9b_l1.forget

mdp9b_1.forget

mdp9b_2.forget

# Rule MDP.9c: Min/Max POLY2 extension beyond COMP on the field towards LDPMOS drain (MVPSD AND COMP AND Pplus NOT POLY2) direction.
logger.info("Executing rule MDP.9c")
mdp9c_l1 = poly2.edges.in(poly2.inside(dnwell.and(dualgate).and(ldmos_xtor)).edges.inside_part(mvpsd)).not_interacting(poly2.drc(enclosing(comp,projection) == 0.2.um))
mdp9c_l1.output("MDP.9c", "MDP.9c : Min/Max POLY2 extension beyond COMP on the field towards LDPMOS drain (MVPSD AND COMP AND Pplus NOT POLY2) direction.")
mdp9c_l1.forget

# Rule MDP.9d: Min/Max POLY2 on field to LDPMOS drain COMP (MVPSD AND COMP AND Pplus NOT POLY2) space.
logger.info("Executing rule MDP.9d")
mdp9d_l1 = poly2.inside(dualgate).inside(ldmos_xtor).overlapping(mvpsd.and(pcomp).not(poly2).sized(0.16.um)).or(poly2.inside(dualgate).inside(ldmos_xtor.interacting(mvpsd)).not_interacting(mvpsd.and(pcomp).not(poly2).sized(0.16.um)))
mdp9d_l1.output("MDP.9d", "MDP.9d : Min/Max POLY2 on field to LDPMOS drain COMP (MVPSD AND COMP AND Pplus NOT POLY2) space.")
mdp9d_l1.forget

ldpmos_poly2_gate = poly2.interacting(pgate.and(dualgate).not(mvpsd))
ncomp_not_butted = ncomp.not(pplus).not_interacting(pcomp.not(nplus)).or(ncomp.not(pplus).overlapping(pcomp.not(nplus)))
mdp9ei_1         = ldpmos_poly2_gate.inside(dualgate).inside(ldmos_xtor).separation(ncomp_not_butted, 0.4.um).polygons(0.001)
mdp9ei_2         = ldpmos_poly2_gate.inside(dualgate).inside(ldmos_xtor).and(ncomp_not_butted)
# Rule MDP.9ei: Min LDMPOS gate Poly2 space to Nplus guardring (source and body tap non-butted).
logger.info("Executing rule MDP.9ei")
mdp9ei_l1 = mdp9ei_1.or(mdp9ei_2)
mdp9ei_l1.output("MDP.9ei", "MDP.9ei : Min LDMPOS gate Poly2 space to Nplus guardring (source and body tap non-butted).")
mdp9ei_l1.forget

ncomp_not_butted.forget

mdp9ei_1.forget

mdp9ei_2.forget

ncomp_butted = ncomp.not(pplus).interacting(pcomp.not(nplus)).not_overlapping(pcomp.not(nplus))
mdp9eii_1    = ldpmos_poly2_gate.inside(dualgate).inside(ldmos_xtor).separation(ncomp_butted, 0.32.um).polygons(0.001)
mdp9eii_2    = ldpmos_poly2_gate.inside(dualgate).inside(ldmos_xtor).and(ncomp_butted)
# Rule MDP.9eii: Min LDMPOS gate Poly2 space to Nplus guardring (source and body tap butted).
logger.info("Executing rule MDP.9eii")
mdp9eii_l1 = mdp9eii_1.or(mdp9eii_2)
mdp9eii_l1.output("MDP.9eii", "MDP.9eii : Min LDMPOS gate Poly2 space to Nplus guardring (source and body tap butted).")
mdp9eii_l1.forget

ncomp_butted.forget

mdp9eii_1.forget

mdp9eii_2.forget

# Rule MDP.9f: Poly2 interconnect is not allowed in LDPMOS region (LDMOS_XTOR marked region). is -µm
logger.info("Executing rule MDP.9f")
mdp9f_l1 = poly2.not(pplus).inside(dualgate).inside(ldmos_xtor).interacting(poly2.and(pplus).inside(dualgate).inside(ldmos_xtor),2)
mdp9f_l1.output("MDP.9f", "MDP.9f : Poly2 interconnect is not allowed in LDPMOS region (LDMOS_XTOR marked region). : -µm")
mdp9f_l1.forget

# Rule MDP.10: Min/Max MVPSD overlap onto the channel (LDMOS_XTOR AND COMP AND POLY2 AND Pplus).
logger.info("Executing rule MDP.10")
mdp10_l1 = mvpsd.inside(dualgate).inside(ldmos_xtor).not_interacting(mvpsd.drc(overlap(ldmos_xtor.and(comp).and(poly2).and(pplus),projection) == 0.4))
mdp10_l1.output("MDP.10", "MDP.10 : Min/Max MVPSD overlap onto the channel (LDMOS_XTOR AND COMP AND POLY2 AND Pplus).")
mdp10_l1.forget

if CONNECTIVITY_RULES
logger.info("CONNECTIVITY_RULES section")

connected_mdp_10b, unconnected_mdp_10a = conn_space(mvpsd, 1, 2, euclidian)

# Rule MDP.10a: Min MVPSD space within LDMOS_XTOR marking [diff potential]. is 2µm
logger.info("Executing rule MDP.10a")
mdp10a_l1  = unconnected_mdp_10a
mdp10a_l1.output("MDP.10a", "MDP.10a : Min MVPSD space within LDMOS_XTOR marking [diff potential]. : 2µm")
mdp10a_l1.forget

# Rule MDP.10b: Min MVPSD space [same potential]. Merge if space less than 1um. is 1µm
logger.info("Executing rule MDP.10b")
mdp10b_l1  = connected_mdp_10b
mdp10b_l1.output("MDP.10b", "MDP.10b : Min MVPSD space [same potential]. Merge if space less than 1um. : 1µm")
mdp10b_l1.forget

else
logger.info("CONNECTIVITY_RULES disabled section")

# Rule MDP.10a: Min MVPSD space within LDMOS_XTOR marking [diff potential]. is 2µm
logger.info("Executing rule MDP.10a")
mdp10a_l1  = mvpsd.space(2.um, euclidian).polygons(0.001)
mdp10a_l1.output("MDP.10a", "MDP.10a : Min MVPSD space within LDMOS_XTOR marking [diff potential]. : 2µm")
mdp10a_l1.forget

end #CONNECTIVITY_RULES

# Rule MDP.11: Min MVPSD enclosing PCOMP in the drain (MVPSD AND COMP NOT POLY2) direction and in the direction along the transistor width.
logger.info("Executing rule MDP.11")
mdp11_l1 = mvpsd.edges.not_interacting(pcomp.edges).enclosing(pcomp.edges, 0.8.um, euclidian).polygons(0.001).or(mvpsd.interacting(mvpsd.edges.and(pcomp.edges)))
mdp11_l1.output("MDP.11", "MDP.11 : Min MVPSD enclosing PCOMP in the drain (MVPSD AND COMP NOT POLY2) direction and in the direction along the transistor width.")
mdp11_l1.forget

# Rule MDP.12: Min DNWELL enclose Nplus guard ring (NCOMP). is 0.66µm
logger.info("Executing rule MDP.12")
mdp12_l1 = dnwell.inside(dualgate).inside(ldmos_xtor).enclosing(ncomp.inside(dualgate).inside(ldmos_xtor), 0.66.um, euclidian).polygons(0.001)
mdp12_l2 = ncomp.inside(dualgate).inside(ldmos_xtor).not_outside(dnwell.inside(dualgate).inside(ldmos_xtor)).not(dnwell.inside(dualgate).inside(ldmos_xtor))
mdp12_l  = mdp12_l1.or(mdp12_l2)
mdp12_l.output("MDP.12", "MDP.12 : Min DNWELL enclose Nplus guard ring (NCOMP). : 0.66µm")
mdp12_l1.forget
mdp12_l2.forget
mdp12_l.forget

# rule MDP.13 is not a DRC check

# Rule MDP.13a: Max single finger width. is 50µm
logger.info("Executing rule MDP.13a")
mdp13a_l1 = poly2.and(pcomp).not(mvpsd).inside(dualgate).inside(ldmos_xtor).edges.with_length(50.001.um,nil).extended(0, 0, 0.001, 0.001)
mdp13a_l1.output("MDP.13a", "MDP.13a : Max single finger width. : 50µm")
mdp13a_l1.forget

# Rule MDP.13b: Layout shall have alternative source & drain.
logger.info("Executing rule MDP.13b")
mdp13b_l1 = ldpmos.not_interacting(mdp_source,1,1).or(ldpmos.not_interacting(mvpsd,1,1)).or(mdp_source.interacting(mvpsd))
mdp13b_l1.output("MDP.13b", "MDP.13b : Layout shall have alternative source & drain.")
mdp13b_l1.forget

mdp_13c_source_side = ldpmos.interacting(mdp_source.interacting(ldpmos, 2, 2).or(mdp_source.interacting(ncomp.interacting(mdp_source, 2, 2))))
# Rule MDP.13c: Both sides of the transistor shall be terminated by source.
logger.info("Executing rule MDP.13c")
mdp13c_l1 = mvpsd.covering(pcomp.not_interacting(poly2)).interacting(pcomp, 2, 2).interacting(mdp_13c_source_side)
mdp13c_l1.output("MDP.13c", "MDP.13c : Both sides of the transistor shall be terminated by source.")
mdp13c_l1.forget

mdp_13c_source_side.forget

# rule MDP.14 is not a DRC check

# Rule MDP.15: Min DNWELL enclosing MVPSD to any DNWELL spacing. is 6µm
logger.info("Executing rule MDP.15")
mdp15_l1  = dnwell.separation(dnwell.covering(mvpsd).inside(dualgate).inside(ldmos_xtor), 6.um, euclidian).polygons(0.001)
mdp15_l1.output("MDP.15", "MDP.15 : Min DNWELL enclosing MVPSD to any DNWELL spacing. : 6µm")
mdp15_l1.forget

# Rule MDP.16a: Min LDPMOS drain COMP width. is 0.22µm
logger.info("Executing rule MDP.16a")
mdp16a_l1  = comp.inside(mvpsd).inside(dualgate).inside(ldmos_xtor).width(0.22.um, euclidian).polygons(0.001)
mdp16a_l1.output("MDP.16a", "MDP.16a : Min LDPMOS drain COMP width. : 0.22µm")
mdp16a_l1.forget

# Rule MDP.16b: Min LDPMOS drain COMP enclose contact. is 0µm
logger.info("Executing rule MDP.16b")
mdp16b_l1 = contact.interacting(pcomp.inside(mvpsd).inside(dualgate).inside(ldmos_xtor)).not_inside(pcomp.inside(mvpsd))
mdp16b_l1.output("MDP.16b", "MDP.16b : Min LDPMOS drain COMP enclose contact. : 0µm")
mdp16b_l1.forget

mdp17_a1 = mvpsd.inside(dnwell).inside(ldmos_xtor)
mdp17_a2 = ncomp.outside(dnwell).outside(nwell)
# Rule MDP.17a: For better latch up immunity, it is necessary to put DNWELL guard ring between MVPSD Inside DNWELL covered by LDMOS_XTOR and NCOMP (outside DNWELL and outside Nwell) when spacing between them is less than 40um.
logger.info("Executing rule MDP.17a")
mdp17a_l1 = mdp17_a1.separation(mdp17_a2,transparent,40.um).polygons(0.001).not_interacting(ncomp.and(dnwell).holes)
mdp17a_l1.output("MDP.17a", "MDP.17a : For better latch up immunity, it is necessary to put DNWELL guard ring between MVPSD Inside DNWELL covered by LDMOS_XTOR and NCOMP (outside DNWELL and outside Nwell) when spacing between them is less than 40um.")
mdp17a_l1.forget

mdp17_a1.forget

mdp17_a2.forget

# Rule MDP.17c: DNWELL guard ring shall have NCOMP tab to be connected to highest potential
logger.info("Executing rule MDP.17c")
mdp17c_l1 = dnwell.with_holes.not_covering(ncomp)
mdp17c_l1.output("MDP.17c", "MDP.17c : DNWELL guard ring shall have NCOMP tab to be connected to highest potential")
mdp17c_l1.forget

#================================================
#--------------------YMTP_MK---------------------
#================================================

# Rule Y.NW.2b_3.3V: Min. Nwell Space (Outside DNWELL, Inside YMTP_MK) [Different potential]. is 1µm
logger.info("Executing rule Y.NW.2b_3.3V")
ynw2b_l1  = nwell.outside(dnwell).inside(ymtp_mk).space(1.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
ynw2b_l1.output("Y.NW.2b_3.3V", "Y.NW.2b_3.3V : Min. Nwell Space (Outside DNWELL, Inside YMTP_MK) [Different potential]. : 1µm")
ynw2b_l1.forget

# Rule Y.NW.2b_5V: Min. Nwell Space (Outside DNWELL, Inside YMTP_MK) [Different potential]. is 1µm
logger.info("Executing rule Y.NW.2b_5V")
ynw2b_l1  = nwell.outside(dnwell).inside(ymtp_mk).space(1.um, euclidian).polygons(0.001).overlapping(dualgate)
ynw2b_l1.output("Y.NW.2b_5V", "Y.NW.2b_5V : Min. Nwell Space (Outside DNWELL, Inside YMTP_MK) [Different potential]. : 1µm")
ynw2b_l1.forget

# rule Y.DF.4d_3.3V is not a DRC check

# rule Y.DF.4d_5V is not a DRC check

# Rule Y.DF.6_5V: Min. COMP extend beyond gate (it also means source/drain overhang) inside YMTP_MK. is 0.15µm
logger.info("Executing rule Y.DF.6_5V")
ydf6_l1 = comp.not(otp_mk).inside(ymtp_mk).enclosing(poly2.inside(ymtp_mk), 0.15.um, euclidian).polygons(0.001).overlapping(dualgate)
ydf6_l1.output("Y.DF.6_5V", "Y.DF.6_5V : Min. COMP extend beyond gate (it also means source/drain overhang) inside YMTP_MK. : 0.15µm")
ydf6_l1.forget

# Rule Y.DF.16_3.3V: Min. space from (Nwell outside DNWELL) to (unrelated NCOMP outside Nwell and DNWELL) (inside YMTP_MK). is 0.27µm
logger.info("Executing rule Y.DF.16_3.3V")
ydf16_l1  = ncomp.outside(nwell).outside(dnwell).separation(nwell.outside(dnwell), 0.27.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
ydf16_l1.output("Y.DF.16_3.3V", "Y.DF.16_3.3V : Min. space from (Nwell outside DNWELL) to (unrelated NCOMP outside Nwell and DNWELL) (inside YMTP_MK). : 0.27µm")
ydf16_l1.forget

# Rule Y.DF.16_5V: Min. space from (Nwell outside DNWELL) to (unrelated NCOMP outside Nwell and DNWELL) (inside YMTP_MK). is 0.23µm
logger.info("Executing rule Y.DF.16_5V")
ydf16_l1  = ncomp.outside(nwell).outside(dnwell).separation(nwell.outside(dnwell), 0.23.um, euclidian).polygons(0.001).overlapping(dualgate)
ydf16_l1.output("Y.DF.16_5V", "Y.DF.16_5V : Min. space from (Nwell outside DNWELL) to (unrelated NCOMP outside Nwell and DNWELL) (inside YMTP_MK). : 0.23µm")
ydf16_l1.forget

# Rule Y.PL.1_3.3V: Interconnect Width (inside YMTP_MK). is 0.13µm
logger.info("Executing rule Y.PL.1_3.3V")
ypl1_l1  = poly2.outside(plfuse).and(ymtp_mk).width(0.13.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
ypl1_l1.output("Y.PL.1_3.3V", "Y.PL.1_3.3V : Interconnect Width (inside YMTP_MK). : 0.13µm")
ypl1_l1.forget

# Rule Y.PL.1_5V: Interconnect Width (inside YMTP_MK). This rule is currently not applicable for 5V.
logger.info("Executing rule Y.PL.1_5V")
ypl1_l1 = poly2.outside(plfuse).and(ymtp_mk).overlapping(dualgate)
ypl1_l1.output("Y.PL.1_5V", "Y.PL.1_5V : Interconnect Width (inside YMTP_MK). This rule is currently not applicable for 5V.")
ypl1_l1.forget

# Rule Y.PL.2_3.3V: Gate Width (Channel Length) (inside YMTP_MK). is 0.13µm
logger.info("Executing rule Y.PL.2_3.3V")
ypl2_l1  = poly2.edges.and(tgate.edges).not(otp_mk).and(ymtp_mk).width(0.13.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
ypl2_l1.output("Y.PL.2_3.3V", "Y.PL.2_3.3V : Gate Width (Channel Length) (inside YMTP_MK). : 0.13µm")
ypl2_l1.forget

# Rule Y.PL.2_5V: Gate Width (Channel Length) (inside YMTP_MK). is 0.47µm
logger.info("Executing rule Y.PL.2_5V")
ypl2_l1  = poly2.edges.and(tgate.edges).not(otp_mk).and(ymtp_mk).width(0.47.um, euclidian).polygons(0.001).overlapping(dualgate)
ypl2_l1.output("Y.PL.2_5V", "Y.PL.2_5V : Gate Width (Channel Length) (inside YMTP_MK). : 0.47µm")
ypl2_l1.forget

# Rule Y.PL.4_5V: Poly2 extension beyond COMP to form Poly2 end cap (inside YMTP_MK). is 0.16µm
logger.info("Executing rule Y.PL.4_5V")
ypl4_l1 = poly2.and(ymtp_mk).enclosing(comp.and(ymtp_mk), 0.16.um, euclidian).polygons(0.001).overlapping(dualgate)
ypl4_l1.output("Y.PL.4_5V", "Y.PL.4_5V : Poly2 extension beyond COMP to form Poly2 end cap (inside YMTP_MK). : 0.16µm")
ypl4_l1.forget

# Rule Y.PL.5a_3.3V: Space from field Poly2 to unrelated COMP (inside YMTP_MK). Space from field Poly2 to Guard-ring (inside YMTP_MK). is 0.04µm
logger.info("Executing rule Y.PL.5a_3.3V")
ypl5a_l1  = poly2.and(ymtp_mk).separation(comp.and(ymtp_mk), 0.04.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
ypl5a_l1.output("Y.PL.5a_3.3V", "Y.PL.5a_3.3V : Space from field Poly2 to unrelated COMP (inside YMTP_MK). Space from field Poly2 to Guard-ring (inside YMTP_MK). : 0.04µm")
ypl5a_l1.forget

# Rule Y.PL.5a_5V: Space from field Poly2 to unrelated COMP (inside YMTP_MK). Space from field Poly2 to Guard-ring (inside YMTP_MK). is 0.2µm
logger.info("Executing rule Y.PL.5a_5V")
ypl5a_l1  = poly2.and(ymtp_mk).separation(comp.and(ymtp_mk), 0.2.um, euclidian).polygons(0.001).overlapping(dualgate)
ypl5a_l1.output("Y.PL.5a_5V", "Y.PL.5a_5V : Space from field Poly2 to unrelated COMP (inside YMTP_MK). Space from field Poly2 to Guard-ring (inside YMTP_MK). : 0.2µm")
ypl5a_l1.forget

# Rule Y.PL.5b_3.3V: Space from field Poly2 to related COMP (inside YMTP_MK). is 0.04µm
logger.info("Executing rule Y.PL.5b_3.3V")
ypl5b_l1  = poly2.and(ymtp_mk).separation(comp.and(ymtp_mk), 0.04.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
ypl5b_l1.output("Y.PL.5b_3.3V", "Y.PL.5b_3.3V : Space from field Poly2 to related COMP (inside YMTP_MK). : 0.04µm")
ypl5b_l1.forget

# Rule Y.PL.5b_5V: Space from field Poly2 to related COMP (inside YMTP_MK). is 0.2µm
logger.info("Executing rule Y.PL.5b_5V")
ypl5b_l1  = poly2.and(ymtp_mk).separation(comp.and(ymtp_mk), 0.2.um, euclidian).polygons(0.001).overlapping(dualgate)
ypl5b_l1.output("Y.PL.5b_5V", "Y.PL.5b_5V : Space from field Poly2 to related COMP (inside YMTP_MK). : 0.2µm")
ypl5b_l1.forget

# rule Y.PL.6_3.3V is not a DRC check

# rule Y.PL.6_5V is not a DRC check

# rule Y.LU.3_3.3V is not yet implemented

# rule Y.LU.3_5V is not yet implemented

#================================================
#--------------------5V SRAM---------------------
#================================================

# Rule S.DF.4c_MV: Min. (Nwell overlap of PCOMP) outside DNWELL. is 0.45µm
logger.info("Executing rule S.DF.4c_MV")
sdf4c_l1 = nwell.outside(dnwell).inside(sramcore).enclosing(pcomp.outside(dnwell).inside(sramcore), 0.45.um, euclidian).polygons(0.001)
sdf4c_l2 = pcomp.outside(dnwell).inside(sramcore).not_outside(nwell.outside(dnwell).inside(sramcore)).not(nwell.outside(dnwell).inside(sramcore))
sdf4c_l  = sdf4c_l1.or(sdf4c_l2).overlapping(v5_xtor).overlapping(dualgate)
sdf4c_l.output("S.DF.4c_MV", "S.DF.4c_MV : Min. (Nwell overlap of PCOMP) outside DNWELL. : 0.45µm")
sdf4c_l1.forget
sdf4c_l2.forget
sdf4c_l.forget

# Rule S.DF.6_MV: Min. COMP extend beyond gate (it also means source/drain overhang). is 0.32µm
logger.info("Executing rule S.DF.6_MV")
sdf6_l1 = comp.inside(sramcore).enclosing(poly2.inside(sramcore), 0.32.um, euclidian).polygons(0.001).overlapping(v5_xtor).overlapping(dualgate)
sdf6_l1.output("S.DF.6_MV", "S.DF.6_MV : Min. COMP extend beyond gate (it also means source/drain overhang). : 0.32µm")
sdf6_l1.forget

# Rule S.DF.7_MV: Min. (LVPWELL Spacer to PCOMP) inside DNWELL. is 0.45µm
logger.info("Executing rule S.DF.7_MV")
sdf7_l1  = pcomp.inside(dnwell).inside(sramcore).separation(lvpwell.inside(dnwell).inside(sramcore), 0.45.um, euclidian).polygons(0.001).overlapping(v5_xtor).overlapping(dualgate)
sdf7_l1.output("S.DF.7_MV", "S.DF.7_MV : Min. (LVPWELL Spacer to PCOMP) inside DNWELL. : 0.45µm")
sdf7_l1.forget

# Rule S.DF.8_MV: Min. (LVPWELL overlap of NCOMP) Inside DNWELL. is 0.45µm
logger.info("Executing rule S.DF.8_MV")
sdf8_l1 = lvpwell.inside(dnwell).inside(sramcore).enclosing(ncomp.inside(dnwell).inside(sramcore), 0.45.um, euclidian).polygons(0.001)
sdf8_l2 = ncomp.inside(dnwell).inside(sramcore).not_outside(lvpwell.inside(dnwell).inside(sramcore)).not(lvpwell.inside(dnwell).inside(sramcore))
sdf8_l  = sdf8_l1.or(sdf8_l2).overlapping(v5_xtor).overlapping(dualgate)
sdf8_l.output("S.DF.8_MV", "S.DF.8_MV : Min. (LVPWELL overlap of NCOMP) Inside DNWELL. : 0.45µm")
sdf8_l1.forget
sdf8_l2.forget
sdf8_l.forget

# Rule S.DF.16_MV: Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). is 0.45µm
logger.info("Executing rule S.DF.16_MV")
sdf16_l1  = ncomp.outside(nwell).outside(dnwell).inside(sramcore).separation(nwell.outside(dnwell).inside(sramcore), 0.45.um, euclidian).polygons(0.001).overlapping(v5_xtor).overlapping(dualgate)
sdf16_l1.output("S.DF.16_MV", "S.DF.16_MV : Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). : 0.45µm")
sdf16_l1.forget

# Rule S.PL.5a_MV: Space from field Poly2 to unrelated COMP Spacer from field Poly2 to Guard-ring. is 0.12µm
logger.info("Executing rule S.PL.5a_MV")
spl5a_l1  = poly2.inside(sramcore).separation(comp.inside(sramcore), 0.12.um, euclidian).polygons(0.001).overlapping(v5_xtor).overlapping(dualgate)
spl5a_l1.output("S.PL.5a_MV", "S.PL.5a_MV : Space from field Poly2 to unrelated COMP Spacer from field Poly2 to Guard-ring. : 0.12µm")
spl5a_l1.forget

# Rule S.PL.5b_MV: Space from field Poly2 to related COMP. is 0.12µm
logger.info("Executing rule S.PL.5b_MV")
spl5b_l1  = poly2.inside(sramcore).separation(comp.inside(sramcore), 0.12.um, euclidian).polygons(0.001).overlapping(v5_xtor).overlapping(dualgate)
spl5b_l1.output("S.PL.5b_MV", "S.PL.5b_MV : Space from field Poly2 to related COMP. : 0.12µm")
spl5b_l1.forget

# Rule S.CO.4_MV: COMP overlap of contact. is 0.04µm
logger.info("Executing rule S.CO.4_MV")
sco4_l1 = comp.inside(sramcore).and(v5_xtor).enclosing(contact.inside(sramcore).and(v5_xtor), 0.04.um, euclidian).polygons(0.001)
sco4_l2 = contact.inside(sramcore).and(v5_xtor).not_outside(comp.inside(sramcore).and(v5_xtor)).not(comp.inside(sramcore).and(v5_xtor))
sco4_l  = sco4_l1.or(sco4_l2)
sco4_l.output("S.CO.4_MV", "S.CO.4_MV : COMP overlap of contact. : 0.04µm")
sco4_l1.forget
sco4_l2.forget
sco4_l.forget

#================================================
#-------------------3.3V SRAM--------------------
#================================================

# Rule S.DF.4c_LV: Min. (Nwell overlap of PCOMP) outside DNWELL. is 0.4µm
logger.info("Executing rule S.DF.4c_LV")
sdf4c_l1 = nwell.outside(dnwell).inside(sramcore).enclosing(pcomp.outside(dnwell).inside(sramcore), 0.4.um, euclidian).polygons(0.001)
sdf4c_l2 = pcomp.outside(dnwell).inside(sramcore).not_outside(nwell.outside(dnwell).inside(sramcore)).not(nwell.outside(dnwell).inside(sramcore))
sdf4c_l  = sdf4c_l1.or(sdf4c_l2).not_interacting(v5_xtor).not_interacting(dualgate)
sdf4c_l.output("S.DF.4c_LV", "S.DF.4c_LV : Min. (Nwell overlap of PCOMP) outside DNWELL. : 0.4µm")
sdf4c_l1.forget
sdf4c_l2.forget
sdf4c_l.forget

# Rule S.DF.16_LV: Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). is 0.4µm
logger.info("Executing rule S.DF.16_LV")
sdf16_l1  = ncomp.outside(nwell).outside(dnwell).inside(sramcore).separation(nwell.outside(dnwell).inside(sramcore), 0.4.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
sdf16_l1.output("S.DF.16_LV", "S.DF.16_LV : Min. space from (Nwell outside DNWELL) to (NCOMP outside Nwell and DNWELL). : 0.4µm")
sdf16_l1.forget

# Rule S.CO.3_LV: Poly2 overlap of contact. is 0.04µm
logger.info("Executing rule S.CO.3_LV")
sco3_l1 = poly2.inside(sramcore).enclosing(contact.inside(sramcore), 0.04.um, euclidian).polygons(0.001)
sco3_l2 = contact.inside(sramcore).not_outside(poly2.inside(sramcore)).not(poly2.inside(sramcore))
sco3_l  = sco3_l1.or(sco3_l2).not_interacting(v5_xtor).not_interacting(dualgate)
sco3_l.output("S.CO.3_LV", "S.CO.3_LV : Poly2 overlap of contact. : 0.04µm")
sco3_l1.forget
sco3_l2.forget
sco3_l.forget

# Rule S.CO.4_LV: COMP overlap of contact. is 0.03µm
logger.info("Executing rule S.CO.4_LV")
sco4_l1 = comp.inside(sramcore).enclosing(contact.inside(sramcore), 0.03.um, euclidian).polygons(0.001)
sco4_l2 = contact.inside(sramcore).not_outside(comp.inside(sramcore)).not(comp.inside(sramcore))
sco4_l  = sco4_l1.or(sco4_l2).not_interacting(v5_xtor).not_interacting(dualgate)
sco4_l.output("S.CO.4_LV", "S.CO.4_LV : COMP overlap of contact. : 0.03µm")
sco4_l1.forget
sco4_l2.forget
sco4_l.forget

# Rule S.CO.6_ii_LV: (ii) If Metal1 overlaps contact by < 0.04um on one side, adjacent metal1 edges overlap
logger.info("Executing rule S.CO.6_ii_LV")
sco6_l1 = metal1.and(sramcore).enclosing(contact.inside(sramcore), 0.02.um, euclidian).polygons(0.001).or(contact.inside(sramcore).not_inside(metal1.inside(sramcore)).not(metal1.inside(sramcore))).not_interacting(v5_xtor).not_interacting(dualgate)
sco6_l1.output("S.CO.6_ii_LV", "S.CO.6_ii_LV : (ii) If Metal1 overlaps contact by < 0.04um on one side, adjacent metal1 edges overlap")
sco6_l1.forget

# Rule S.M1.1_LV: min. metal1 width is 0.22µm
logger.info("Executing rule S.M1.1_LV")
sm11_l1  = metal1.and(sramcore).width(0.22.um, euclidian).polygons(0.001).not_interacting(v5_xtor).not_interacting(dualgate)
sm11_l1.output("S.M1.1_LV", "S.M1.1_LV : min. metal1 width : 0.22µm")
sm11_l1.forget

end # BEOL_EXTEND   # previously unconditional top-level block, now rolled into BEOL

#================================================
#-----------------GEOMETRY RULES-----------------
#================================================

if OFFGRID
logger.info("OFFGRID-ANGLES section")

logger.info("Executing rule comp_OFFGRID")
comp.ongrid(0.005).output("comp_OFFGRID", "OFFGRID : OFFGRID vertex on comp")
comp.with_angle(0 .. 45).output("comp_angle", "ACUTE : non 45 degree angle comp")

logger.info("Executing rule dnwell_OFFGRID")
dnwell.ongrid(0.005).output("dnwell_OFFGRID", "OFFGRID : OFFGRID vertex on dnwell")
dnwell.with_angle(0 .. 45).output("dnwell_angle", "ACUTE : non 45 degree angle dnwell")

logger.info("Executing rule nwell_OFFGRID")
nwell.ongrid(0.005).output("nwell_OFFGRID", "OFFGRID : OFFGRID vertex on nwell")
nwell.with_angle(0 .. 45).output("nwell_angle", "ACUTE : non 45 degree angle nwell")

logger.info("Executing rule lvpwell_OFFGRID")
lvpwell.ongrid(0.005).output("lvpwell_OFFGRID", "OFFGRID : OFFGRID vertex on lvpwell")
lvpwell.with_angle(0 .. 45).output("lvpwell_angle", "ACUTE : non 45 degree angle lvpwell")

logger.info("Executing rule dualgate_OFFGRID")
dualgate.ongrid(0.005).output("dualgate_OFFGRID", "OFFGRID : OFFGRID vertex on dualgate")
dualgate.with_angle(0 .. 45).output("dualgate_angle", "ACUTE : non 45 degree angle dualgate")

logger.info("Executing rule poly2_OFFGRID")
poly2.ongrid(0.005).output("poly2_OFFGRID", "OFFGRID : OFFGRID vertex on poly2")
poly2.with_angle(0 .. 45).output("poly2_angle", "ACUTE : non 45 degree angle poly2")

logger.info("Executing rule nplus_OFFGRID")
nplus.ongrid(0.005).output("nplus_OFFGRID", "OFFGRID : OFFGRID vertex on nplus")
nplus.with_angle(0 .. 45).output("nplus_angle", "ACUTE : non 45 degree angle nplus")

logger.info("Executing rule pplus_OFFGRID")
pplus.ongrid(0.005).output("pplus_OFFGRID", "OFFGRID : OFFGRID vertex on pplus")
pplus.with_angle(0 .. 45).output("pplus_angle", "ACUTE : non 45 degree angle pplus")

logger.info("Executing rule sab_OFFGRID")
sab.ongrid(0.005).output("sab_OFFGRID", "OFFGRID : OFFGRID vertex on sab")
sab.with_angle(0 .. 45).output("sab_angle", "ACUTE : non 45 degree angle sab")

logger.info("Executing rule esd_OFFGRID")
esd.ongrid(0.005).output("esd_OFFGRID", "OFFGRID : OFFGRID vertex on esd")
esd.with_angle(0 .. 45).output("esd_angle", "ACUTE : non 45 degree angle esd")

logger.info("Executing rule contact_OFFGRID")
contact.ongrid(0.005).output("contact_OFFGRID", "OFFGRID : OFFGRID vertex on contact")
contact.with_angle(0 .. 45).output("contact_angle", "ACUTE : non 45 degree angle contact")

logger.info("Executing rule metal1_OFFGRID")
metal1.ongrid(0.005).output("metal1_OFFGRID", "OFFGRID : OFFGRID vertex on metal1")
metal1.with_angle(0 .. 45).output("metal1_angle", "ACUTE : non 45 degree angle metal1")

logger.info("Executing rule via1_OFFGRID")
via1.ongrid(0.005).output("via1_OFFGRID", "OFFGRID : OFFGRID vertex on via1")
via1.with_angle(0 .. 45).output("via1_angle", "ACUTE : non 45 degree angle via1")

logger.info("Executing rule metal2_OFFGRID")
metal2.ongrid(0.005).output("metal2_OFFGRID", "OFFGRID : OFFGRID vertex on metal2")
metal2.with_angle(0 .. 45).output("metal2_angle", "ACUTE : non 45 degree angle metal2")

logger.info("Executing rule via2_OFFGRID")
via2.ongrid(0.005).output("via2_OFFGRID", "OFFGRID : OFFGRID vertex on via2")
via2.with_angle(0 .. 45).output("via2_angle", "ACUTE : non 45 degree angle via2")

logger.info("Executing rule metal3_OFFGRID")
metal3.ongrid(0.005).output("metal3_OFFGRID", "OFFGRID : OFFGRID vertex on metal3")
metal3.with_angle(0 .. 45).output("metal3_angle", "ACUTE : non 45 degree angle metal3")

logger.info("Executing rule via3_OFFGRID")
via3.ongrid(0.005).output("via3_OFFGRID", "OFFGRID : OFFGRID vertex on via3")
via3.with_angle(0 .. 45).output("via3_angle", "ACUTE : non 45 degree angle via3")

logger.info("Executing rule metal4_OFFGRID")
metal4.ongrid(0.005).output("metal4_OFFGRID", "OFFGRID : OFFGRID vertex on metal4")
metal4.with_angle(0 .. 45).output("metal4_angle", "ACUTE : non 45 degree angle metal4")

logger.info("Executing rule via4_OFFGRID")
via4.ongrid(0.005).output("via4_OFFGRID", "OFFGRID : OFFGRID vertex on via4")
via4.with_angle(0 .. 45).output("via4_angle", "ACUTE : non 45 degree angle via4")

logger.info("Executing rule metal5_OFFGRID")
metal5.ongrid(0.005).output("metal5_OFFGRID", "OFFGRID : OFFGRID vertex on metal5")
metal5.with_angle(0 .. 45).output("metal5_angle", "ACUTE : non 45 degree angle metal5")

logger.info("Executing rule via5_OFFGRID")
via5.ongrid(0.005).output("via5_OFFGRID", "OFFGRID : OFFGRID vertex on via5")
via5.with_angle(0 .. 45).output("via5_angle", "ACUTE : non 45 degree angle via5")

logger.info("Executing rule metaltop_OFFGRID")
metaltop.ongrid(0.005).output("metaltop_OFFGRID", "OFFGRID : OFFGRID vertex on metaltop")
metaltop.with_angle(0 .. 45).output("metaltop_angle", "ACUTE : non 45 degree angle metaltop")

logger.info("Executing rule pad_OFFGRID")
pad.ongrid(0.005).output("pad_OFFGRID", "OFFGRID : OFFGRID vertex on pad")
pad.with_angle(0 .. 45).output("pad_angle", "ACUTE : non 45 degree angle pad")

logger.info("Executing rule resistor_OFFGRID")
resistor.ongrid(0.005).output("resistor_OFFGRID", "OFFGRID : OFFGRID vertex on resistor")
resistor.with_angle(0 .. 45).output("resistor_angle", "ACUTE : non 45 degree angle resistor")

logger.info("Executing rule fhres_OFFGRID")
fhres.ongrid(0.005).output("fhres_OFFGRID", "OFFGRID : OFFGRID vertex on fhres")
fhres.with_angle(0 .. 45).output("fhres_angle", "ACUTE : non 45 degree angle fhres")

logger.info("Executing rule fusetop_OFFGRID")
fusetop.ongrid(0.005).output("fusetop_OFFGRID", "OFFGRID : OFFGRID vertex on fusetop")
fusetop.with_angle(0 .. 45).output("fusetop_angle", "ACUTE : non 45 degree angle fusetop")

logger.info("Executing rule fusewindow_d_OFFGRID")
fusewindow_d.ongrid(0.005).output("fusewindow_d_OFFGRID", "OFFGRID : OFFGRID vertex on fusewindow_d")
fusewindow_d.with_angle(0 .. 45).output("fusewindow_d_angle", "ACUTE : non 45 degree angle fusewindow_d")

logger.info("Executing rule polyfuse_OFFGRID")
polyfuse.ongrid(0.005).output("polyfuse_OFFGRID", "OFFGRID : OFFGRID vertex on polyfuse")
polyfuse.with_angle(0 .. 45).output("polyfuse_angle", "ACUTE : non 45 degree angle polyfuse")

logger.info("Executing rule mvsd_OFFGRID")
mvsd.ongrid(0.005).output("mvsd_OFFGRID", "OFFGRID : OFFGRID vertex on mvsd")
mvsd.with_angle(0 .. 45).output("mvsd_angle", "ACUTE : non 45 degree angle mvsd")

logger.info("Executing rule mvpsd_OFFGRID")
mvpsd.ongrid(0.005).output("mvpsd_OFFGRID", "OFFGRID : OFFGRID vertex on mvpsd")
mvpsd.with_angle(0 .. 45).output("mvpsd_angle", "ACUTE : non 45 degree angle mvpsd")

logger.info("Executing rule nat_OFFGRID")
nat.ongrid(0.005).output("nat_OFFGRID", "OFFGRID : OFFGRID vertex on nat")
nat.with_angle(0 .. 45).output("nat_angle", "ACUTE : non 45 degree angle nat")

logger.info("Executing rule comp_dummy_OFFGRID")
comp_dummy.ongrid(0.005).output("comp_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on comp_dummy")
comp_dummy.with_angle(0 .. 45).output("comp_dummy_angle", "ACUTE : non 45 degree angle comp_dummy")

logger.info("Executing rule poly2_dummy_OFFGRID")
poly2_dummy.ongrid(0.005).output("poly2_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on poly2_dummy")
poly2_dummy.with_angle(0 .. 45).output("poly2_dummy_angle", "ACUTE : non 45 degree angle poly2_dummy")

logger.info("Executing rule metal1_dummy_OFFGRID")
metal1_dummy.ongrid(0.005).output("metal1_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on metal1_dummy")
metal1_dummy.with_angle(0 .. 45).output("metal1_dummy_angle", "ACUTE : non 45 degree angle metal1_dummy")

logger.info("Executing rule metal2_dummy_OFFGRID")
metal2_dummy.ongrid(0.005).output("metal2_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on metal2_dummy")
metal2_dummy.with_angle(0 .. 45).output("metal2_dummy_angle", "ACUTE : non 45 degree angle metal2_dummy")

logger.info("Executing rule metal3_dummy_OFFGRID")
metal3_dummy.ongrid(0.005).output("metal3_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on metal3_dummy")
metal3_dummy.with_angle(0 .. 45).output("metal3_dummy_angle", "ACUTE : non 45 degree angle metal3_dummy")

logger.info("Executing rule metal4_dummy_OFFGRID")
metal4_dummy.ongrid(0.005).output("metal4_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on metal4_dummy")
metal4_dummy.with_angle(0 .. 45).output("metal4_dummy_angle", "ACUTE : non 45 degree angle metal4_dummy")

logger.info("Executing rule metal5_dummy_OFFGRID")
metal5_dummy.ongrid(0.005).output("metal5_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on metal5_dummy")
metal5_dummy.with_angle(0 .. 45).output("metal5_dummy_angle", "ACUTE : non 45 degree angle metal5_dummy")

logger.info("Executing rule metaltop_dummy_OFFGRID")
metaltop_dummy.ongrid(0.005).output("metaltop_dummy_OFFGRID", "OFFGRID : OFFGRID vertex on metaltop_dummy")
metaltop_dummy.with_angle(0 .. 45).output("metaltop_dummy_angle", "ACUTE : non 45 degree angle metaltop_dummy")

logger.info("Executing rule comp_label_OFFGRID")
comp_label.ongrid(0.005).output("comp_label_OFFGRID", "OFFGRID : OFFGRID vertex on comp_label")
comp_label.with_angle(0 .. 45).output("comp_label_angle", "ACUTE : non 45 degree angle comp_label")

logger.info("Executing rule poly2_label_OFFGRID")
poly2_label.ongrid(0.005).output("poly2_label_OFFGRID", "OFFGRID : OFFGRID vertex on poly2_label")
poly2_label.with_angle(0 .. 45).output("poly2_label_angle", "ACUTE : non 45 degree angle poly2_label")

logger.info("Executing rule metal1_label_OFFGRID")
metal1_label.ongrid(0.005).output("metal1_label_OFFGRID", "OFFGRID : OFFGRID vertex on metal1_label")
metal1_label.with_angle(0 .. 45).output("metal1_label_angle", "ACUTE : non 45 degree angle metal1_label")

logger.info("Executing rule metal2_label_OFFGRID")
metal2_label.ongrid(0.005).output("metal2_label_OFFGRID", "OFFGRID : OFFGRID vertex on metal2_label")
metal2_label.with_angle(0 .. 45).output("metal2_label_angle", "ACUTE : non 45 degree angle metal2_label")

logger.info("Executing rule metal3_label_OFFGRID")
metal3_label.ongrid(0.005).output("metal3_label_OFFGRID", "OFFGRID : OFFGRID vertex on metal3_label")
metal3_label.with_angle(0 .. 45).output("metal3_label_angle", "ACUTE : non 45 degree angle metal3_label")

logger.info("Executing rule metal4_label_OFFGRID")
metal4_label.ongrid(0.005).output("metal4_label_OFFGRID", "OFFGRID : OFFGRID vertex on metal4_label")
metal4_label.with_angle(0 .. 45).output("metal4_label_angle", "ACUTE : non 45 degree angle metal4_label")

logger.info("Executing rule metal5_label_OFFGRID")
metal5_label.ongrid(0.005).output("metal5_label_OFFGRID", "OFFGRID : OFFGRID vertex on metal5_label")
metal5_label.with_angle(0 .. 45).output("metal5_label_angle", "ACUTE : non 45 degree angle metal5_label")

logger.info("Executing rule metaltop_label_OFFGRID")
metaltop_label.ongrid(0.005).output("metaltop_label_OFFGRID", "OFFGRID : OFFGRID vertex on metaltop_label")
metaltop_label.with_angle(0 .. 45).output("metaltop_label_angle", "ACUTE : non 45 degree angle metaltop_label")

logger.info("Executing rule metal1_slot_OFFGRID")
metal1_slot.ongrid(0.005).output("metal1_slot_OFFGRID", "OFFGRID : OFFGRID vertex on metal1_slot")
metal1_slot.with_angle(0 .. 45).output("metal1_slot_angle", "ACUTE : non 45 degree angle metal1_slot")

logger.info("Executing rule metal2_slot_OFFGRID")
metal2_slot.ongrid(0.005).output("metal2_slot_OFFGRID", "OFFGRID : OFFGRID vertex on metal2_slot")
metal2_slot.with_angle(0 .. 45).output("metal2_slot_angle", "ACUTE : non 45 degree angle metal2_slot")

logger.info("Executing rule metal3_slot_OFFGRID")
metal3_slot.ongrid(0.005).output("metal3_slot_OFFGRID", "OFFGRID : OFFGRID vertex on metal3_slot")
metal3_slot.with_angle(0 .. 45).output("metal3_slot_angle", "ACUTE : non 45 degree angle metal3_slot")

logger.info("Executing rule metal4_slot_OFFGRID")
metal4_slot.ongrid(0.005).output("metal4_slot_OFFGRID", "OFFGRID : OFFGRID vertex on metal4_slot")
metal4_slot.with_angle(0 .. 45).output("metal4_slot_angle", "ACUTE : non 45 degree angle metal4_slot")

logger.info("Executing rule metal5_slot_OFFGRID")
metal5_slot.ongrid(0.005).output("metal5_slot_OFFGRID", "OFFGRID : OFFGRID vertex on metal5_slot")
metal5_slot.with_angle(0 .. 45).output("metal5_slot_angle", "ACUTE : non 45 degree angle metal5_slot")

logger.info("Executing rule metaltop_slot_OFFGRID")
metaltop_slot.ongrid(0.005).output("metaltop_slot_OFFGRID", "OFFGRID : OFFGRID vertex on metaltop_slot")
metaltop_slot.with_angle(0 .. 45).output("metaltop_slot_angle", "ACUTE : non 45 degree angle metaltop_slot")

logger.info("Executing rule ubmpperi_OFFGRID")
ubmpperi.ongrid(0.005).output("ubmpperi_OFFGRID", "OFFGRID : OFFGRID vertex on ubmpperi")
ubmpperi.with_angle(0 .. 45).output("ubmpperi_angle", "ACUTE : non 45 degree angle ubmpperi")

logger.info("Executing rule ubmparray_OFFGRID")
ubmparray.ongrid(0.005).output("ubmparray_OFFGRID", "OFFGRID : OFFGRID vertex on ubmparray")
ubmparray.with_angle(0 .. 45).output("ubmparray_angle", "ACUTE : non 45 degree angle ubmparray")

logger.info("Executing rule ubmeplate_OFFGRID")
ubmeplate.ongrid(0.005).output("ubmeplate_OFFGRID", "OFFGRID : OFFGRID vertex on ubmeplate")
ubmeplate.with_angle(0 .. 45).output("ubmeplate_angle", "ACUTE : non 45 degree angle ubmeplate")

logger.info("Executing rule schottky_diode_OFFGRID")
schottky_diode.ongrid(0.005).output("schottky_diode_OFFGRID", "OFFGRID : OFFGRID vertex on schottky_diode")
schottky_diode.with_angle(0 .. 45).output("schottky_diode_angle", "ACUTE : non 45 degree angle schottky_diode")

logger.info("Executing rule zener_OFFGRID")
zener.ongrid(0.005).output("zener_OFFGRID", "OFFGRID : OFFGRID vertex on zener")
zener.with_angle(0 .. 45).output("zener_angle", "ACUTE : non 45 degree angle zener")

logger.info("Executing rule res_mk_OFFGRID")
res_mk.ongrid(0.005).output("res_mk_OFFGRID", "OFFGRID : OFFGRID vertex on res_mk")
res_mk.with_angle(0 .. 45).output("res_mk_angle", "ACUTE : non 45 degree angle res_mk")

logger.info("Executing rule opc_drc_OFFGRID")
opc_drc.ongrid(0.005).output("opc_drc_OFFGRID", "OFFGRID : OFFGRID vertex on opc_drc")
opc_drc.with_angle(0 .. 45).output("opc_drc_angle", "ACUTE : non 45 degree angle opc_drc")

logger.info("Executing rule ndmy_OFFGRID")
ndmy.ongrid(0.005).output("ndmy_OFFGRID", "OFFGRID : OFFGRID vertex on ndmy")
ndmy.with_angle(0 .. 45).output("ndmy_angle", "ACUTE : non 45 degree angle ndmy")

logger.info("Executing rule pmndmy_OFFGRID")
pmndmy.ongrid(0.005).output("pmndmy_OFFGRID", "OFFGRID : OFFGRID vertex on pmndmy")
pmndmy.with_angle(0 .. 45).output("pmndmy_angle", "ACUTE : non 45 degree angle pmndmy")

logger.info("Executing rule v5_xtor_OFFGRID")
v5_xtor.ongrid(0.005).output("v5_xtor_OFFGRID", "OFFGRID : OFFGRID vertex on v5_xtor")
v5_xtor.with_angle(0 .. 45).output("v5_xtor_angle", "ACUTE : non 45 degree angle v5_xtor")

logger.info("Executing rule cap_mk_OFFGRID")
cap_mk.ongrid(0.005).output("cap_mk_OFFGRID", "OFFGRID : OFFGRID vertex on cap_mk")
cap_mk.with_angle(0 .. 45).output("cap_mk_angle", "ACUTE : non 45 degree angle cap_mk")

logger.info("Executing rule mos_cap_mk_OFFGRID")
mos_cap_mk.ongrid(0.005).output("mos_cap_mk_OFFGRID", "OFFGRID : OFFGRID vertex on mos_cap_mk")
mos_cap_mk.with_angle(0 .. 45).output("mos_cap_mk_angle", "ACUTE : non 45 degree angle mos_cap_mk")

logger.info("Executing rule ind_mk_OFFGRID")
ind_mk.ongrid(0.005).output("ind_mk_OFFGRID", "OFFGRID : OFFGRID vertex on ind_mk")
ind_mk.with_angle(0 .. 45).output("ind_mk_angle", "ACUTE : non 45 degree angle ind_mk")

logger.info("Executing rule diode_mk_OFFGRID")
diode_mk.ongrid(0.005).output("diode_mk_OFFGRID", "OFFGRID : OFFGRID vertex on diode_mk")
diode_mk.with_angle(0 .. 45).output("diode_mk_angle", "ACUTE : non 45 degree angle diode_mk")

logger.info("Executing rule drc_bjt_OFFGRID")
drc_bjt.ongrid(0.005).output("drc_bjt_OFFGRID", "OFFGRID : OFFGRID vertex on drc_bjt")
drc_bjt.with_angle(0 .. 45).output("drc_bjt_angle", "ACUTE : non 45 degree angle drc_bjt")

logger.info("Executing rule lvs_bjt_OFFGRID")
lvs_bjt.ongrid(0.005).output("lvs_bjt_OFFGRID", "OFFGRID : OFFGRID vertex on lvs_bjt")
lvs_bjt.with_angle(0 .. 45).output("lvs_bjt_angle", "ACUTE : non 45 degree angle lvs_bjt")

logger.info("Executing rule mim_l_mk_OFFGRID")
mim_l_mk.ongrid(0.005).output("mim_l_mk_OFFGRID", "OFFGRID : OFFGRID vertex on mim_l_mk")
mim_l_mk.with_angle(0 .. 45).output("mim_l_mk_angle", "ACUTE : non 45 degree angle mim_l_mk")

logger.info("Executing rule latchup_mk_OFFGRID")
latchup_mk.ongrid(0.005).output("latchup_mk_OFFGRID", "OFFGRID : OFFGRID vertex on latchup_mk")
latchup_mk.with_angle(0 .. 45).output("latchup_mk_angle", "ACUTE : non 45 degree angle latchup_mk")

logger.info("Executing rule guard_ring_mk_OFFGRID")
guard_ring_mk.ongrid(0.005).output("guard_ring_mk_OFFGRID", "OFFGRID : OFFGRID vertex on guard_ring_mk")
guard_ring_mk.with_angle(0 .. 45).output("guard_ring_mk_angle", "ACUTE : non 45 degree angle guard_ring_mk")

logger.info("Executing rule otp_mk_OFFGRID")
otp_mk.ongrid(0.005).output("otp_mk_OFFGRID", "OFFGRID : OFFGRID vertex on otp_mk")
otp_mk.with_angle(0 .. 45).output("otp_mk_angle", "ACUTE : non 45 degree angle otp_mk")

logger.info("Executing rule mtpmark_OFFGRID")
mtpmark.ongrid(0.005).output("mtpmark_OFFGRID", "OFFGRID : OFFGRID vertex on mtpmark")
mtpmark.with_angle(0 .. 45).output("mtpmark_angle", "ACUTE : non 45 degree angle mtpmark")

logger.info("Executing rule neo_ee_mk_OFFGRID")
neo_ee_mk.ongrid(0.005).output("neo_ee_mk_OFFGRID", "OFFGRID : OFFGRID vertex on neo_ee_mk")
neo_ee_mk.with_angle(0 .. 45).output("neo_ee_mk_angle", "ACUTE : non 45 degree angle neo_ee_mk")

logger.info("Executing rule sramcore_OFFGRID")
sramcore.ongrid(0.005).output("sramcore_OFFGRID", "OFFGRID : OFFGRID vertex on sramcore")
sramcore.with_angle(0 .. 45).output("sramcore_angle", "ACUTE : non 45 degree angle sramcore")

logger.info("Executing rule lvs_rf_OFFGRID")
lvs_rf.ongrid(0.005).output("lvs_rf_OFFGRID", "OFFGRID : OFFGRID vertex on lvs_rf")
lvs_rf.with_angle(0 .. 45).output("lvs_rf_angle", "ACUTE : non 45 degree angle lvs_rf")

logger.info("Executing rule lvs_drain_OFFGRID")
lvs_drain.ongrid(0.005).output("lvs_drain_OFFGRID", "OFFGRID : OFFGRID vertex on lvs_drain")
lvs_drain.with_angle(0 .. 45).output("lvs_drain_angle", "ACUTE : non 45 degree angle lvs_drain")

## dup: logger.info("Executing rule ind_mk_OFFGRID")
## dup: ind_mk.ongrid(0.005).output("ind_mk_OFFGRID", "OFFGRID : OFFGRID vertex on ind_mk")
## dup: ind_mk.with_angle(0 .. 45).output("ind_mk_angle", "ACUTE : non 45 degree angle ind_mk")

logger.info("Executing rule hvpolyrs_OFFGRID")
hvpolyrs.ongrid(0.005).output("hvpolyrs_OFFGRID", "OFFGRID : OFFGRID vertex on hvpolyrs")
hvpolyrs.with_angle(0 .. 45).output("hvpolyrs_angle", "ACUTE : non 45 degree angle hvpolyrs")

logger.info("Executing rule lvs_io_OFFGRID")
lvs_io.ongrid(0.005).output("lvs_io_OFFGRID", "OFFGRID : OFFGRID vertex on lvs_io")
lvs_io.with_angle(0 .. 45).output("lvs_io_angle", "ACUTE : non 45 degree angle lvs_io")

logger.info("Executing rule probe_mk_OFFGRID")
probe_mk.ongrid(0.005).output("probe_mk_OFFGRID", "OFFGRID : OFFGRID vertex on probe_mk")
probe_mk.with_angle(0 .. 45).output("probe_mk_angle", "ACUTE : non 45 degree angle probe_mk")

logger.info("Executing rule esd_mk_OFFGRID")
esd_mk.ongrid(0.005).output("esd_mk_OFFGRID", "OFFGRID : OFFGRID vertex on esd_mk")
esd_mk.with_angle(0 .. 45).output("esd_mk_angle", "ACUTE : non 45 degree angle esd_mk")

logger.info("Executing rule lvs_source_OFFGRID")
lvs_source.ongrid(0.005).output("lvs_source_OFFGRID", "OFFGRID : OFFGRID vertex on lvs_source")
lvs_source.with_angle(0 .. 45).output("lvs_source_angle", "ACUTE : non 45 degree angle lvs_source")

logger.info("Executing rule well_diode_mk_OFFGRID")
well_diode_mk.ongrid(0.005).output("well_diode_mk_OFFGRID", "OFFGRID : OFFGRID vertex on well_diode_mk")
well_diode_mk.with_angle(0 .. 45).output("well_diode_mk_angle", "ACUTE : non 45 degree angle well_diode_mk")

logger.info("Executing rule ldmos_xtor_OFFGRID")
ldmos_xtor.ongrid(0.005).output("ldmos_xtor_OFFGRID", "OFFGRID : OFFGRID vertex on ldmos_xtor")
ldmos_xtor.with_angle(0 .. 45).output("ldmos_xtor_angle", "ACUTE : non 45 degree angle ldmos_xtor")

logger.info("Executing rule plfuse_OFFGRID")
plfuse.ongrid(0.005).output("plfuse_OFFGRID", "OFFGRID : OFFGRID vertex on plfuse")
plfuse.with_angle(0 .. 45).output("plfuse_angle", "ACUTE : non 45 degree angle plfuse")

logger.info("Executing rule efuse_mk_OFFGRID")
efuse_mk.ongrid(0.005).output("efuse_mk_OFFGRID", "OFFGRID : OFFGRID vertex on efuse_mk")
efuse_mk.with_angle(0 .. 45).output("efuse_mk_angle", "ACUTE : non 45 degree angle efuse_mk")

logger.info("Executing rule mcell_feol_mk_OFFGRID")
mcell_feol_mk.ongrid(0.005).output("mcell_feol_mk_OFFGRID", "OFFGRID : OFFGRID vertex on mcell_feol_mk")
mcell_feol_mk.with_angle(0 .. 45).output("mcell_feol_mk_angle", "ACUTE : non 45 degree angle mcell_feol_mk")

logger.info("Executing rule ymtp_mk_OFFGRID")
ymtp_mk.ongrid(0.005).output("ymtp_mk_OFFGRID", "OFFGRID : OFFGRID vertex on ymtp_mk")
ymtp_mk.with_angle(0 .. 45).output("ymtp_mk_angle", "ACUTE : non 45 degree angle ymtp_mk")

logger.info("Executing rule dev_wf_mk_OFFGRID")
dev_wf_mk.ongrid(0.005).output("dev_wf_mk_OFFGRID", "OFFGRID : OFFGRID vertex on dev_wf_mk")
dev_wf_mk.with_angle(0 .. 45).output("dev_wf_mk_angle", "ACUTE : non 45 degree angle dev_wf_mk")

logger.info("Executing rule metal1_blk_OFFGRID")
metal1_blk.ongrid(0.005).output("metal1_blk_OFFGRID", "OFFGRID : OFFGRID vertex on metal1_blk")
metal1_blk.with_angle(0 .. 45).output("metal1_blk_angle", "ACUTE : non 45 degree angle metal1_blk")

logger.info("Executing rule metal2_blk_OFFGRID")
metal2_blk.ongrid(0.005).output("metal2_blk_OFFGRID", "OFFGRID : OFFGRID vertex on metal2_blk")
metal2_blk.with_angle(0 .. 45).output("metal2_blk_angle", "ACUTE : non 45 degree angle metal2_blk")

logger.info("Executing rule metal3_blk_OFFGRID")
metal3_blk.ongrid(0.005).output("metal3_blk_OFFGRID", "OFFGRID : OFFGRID vertex on metal3_blk")
metal3_blk.with_angle(0 .. 45).output("metal3_blk_angle", "ACUTE : non 45 degree angle metal3_blk")

logger.info("Executing rule metal4_blk_OFFGRID")
metal4_blk.ongrid(0.005).output("metal4_blk_OFFGRID", "OFFGRID : OFFGRID vertex on metal4_blk")
metal4_blk.with_angle(0 .. 45).output("metal4_blk_angle", "ACUTE : non 45 degree angle metal4_blk")

logger.info("Executing rule metal5_blk_OFFGRID")
metal5_blk.ongrid(0.005).output("metal5_blk_OFFGRID", "OFFGRID : OFFGRID vertex on metal5_blk")
metal5_blk.with_angle(0 .. 45).output("metal5_blk_angle", "ACUTE : non 45 degree angle metal5_blk")

logger.info("Executing rule metalt_blk_OFFGRID")
metalt_blk.ongrid(0.005).output("metalt_blk_OFFGRID", "OFFGRID : OFFGRID vertex on metalt_blk")
metalt_blk.with_angle(0 .. 45).output("metalt_blk_angle", "ACUTE : non 45 degree angle metalt_blk")

logger.info("Executing rule pr_bndry_OFFGRID")
pr_bndry.ongrid(0.005).output("pr_bndry_OFFGRID", "OFFGRID : OFFGRID vertex on pr_bndry")
pr_bndry.with_angle(0 .. 45).output("pr_bndry_angle", "ACUTE : non 45 degree angle pr_bndry")

logger.info("Executing rule mdiode_OFFGRID")
mdiode.ongrid(0.005).output("mdiode_OFFGRID", "OFFGRID : OFFGRID vertex on mdiode")
mdiode.with_angle(0 .. 45).output("mdiode_angle", "ACUTE : non 45 degree angle mdiode")

logger.info("Executing rule metal1_res_OFFGRID")
metal1_res.ongrid(0.005).output("metal1_res_OFFGRID", "OFFGRID : OFFGRID vertex on metal1_res")
metal1_res.with_angle(0 .. 45).output("metal1_res_angle", "ACUTE : non 45 degree angle metal1_res")

logger.info("Executing rule metal2_res_OFFGRID")
metal2_res.ongrid(0.005).output("metal2_res_OFFGRID", "OFFGRID : OFFGRID vertex on metal2_res")
metal2_res.with_angle(0 .. 45).output("metal2_res_angle", "ACUTE : non 45 degree angle metal2_res")

logger.info("Executing rule metal3_res_OFFGRID")
metal3_res.ongrid(0.005).output("metal3_res_OFFGRID", "OFFGRID : OFFGRID vertex on metal3_res")
metal3_res.with_angle(0 .. 45).output("metal3_res_angle", "ACUTE : non 45 degree angle metal3_res")

logger.info("Executing rule metal4_res_OFFGRID")
metal4_res.ongrid(0.005).output("metal4_res_OFFGRID", "OFFGRID : OFFGRID vertex on metal4_res")
metal4_res.with_angle(0 .. 45).output("metal4_res_angle", "ACUTE : non 45 degree angle metal4_res")

logger.info("Executing rule metal5_res_OFFGRID")
metal5_res.ongrid(0.005).output("metal5_res_OFFGRID", "OFFGRID : OFFGRID vertex on metal5_res")
metal5_res.with_angle(0 .. 45).output("metal5_res_angle", "ACUTE : non 45 degree angle metal5_res")

# no flag to use: logger.info("Executing rule metal6_res_OFFGRID")
#   metal6_res.ongrid(0.005).output("metal6_res_OFFGRID", "OFFGRID : OFFGRID vertex on metal6_res")
#   metal6_res.with_angle(0 .. 45).output("metal6_res_angle", "ACUTE : non 45 degree angle metal6_res")

logger.info("Executing rule border_OFFGRID")
border.ongrid(0.005).output("border_OFFGRID", "OFFGRID : OFFGRID vertex on border")
border.with_angle(0 .. 45).output("border_angle", "ACUTE : non 45 degree angle border")

end #OFFGRID-ANGLES

if   File.readable?("/proc/self/status")
  puts File.foreach("/proc/self/status").grep(/^(VmPeak|VmHWM)/)
end #VmPeak

exec_end_time = Time.now
run_time = exec_end_time - exec_start_time
logger.info("DRC Total Run time %f seconds" % [run_time])

logger.info("DRC Total program errors: %d" % [$errs])
exit $errs
