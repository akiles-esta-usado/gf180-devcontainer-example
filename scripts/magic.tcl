proc debug { fname message } {
    puts "\[$fname\] $message"
}

proc load_layout { layout cellname } {
    debug "load_layout" ""
    if { [file extension $layout] == ".gds" } {
        gds read $layout

        getcell $cellname
        load $cellname

        box 0 0 0 0
    } else {
        load $layout
    }
}

proc generate_lvs_spice { cellname } {
    debug "generate_lvs_spice" ""

    extract
    ext2spice lvs
    ext2spice -o "./output/${cellname}_lay.spice"
}

proc generate_parasitic_spice { cellname } {
    debug "generate_parasitic_spice" ""
    # https://open-source-silicon.slack.com/archives/C016YSAP6TZ/p1675458850043459
    # If there's a "Bad Device...", thats because the circuit is not flatten.

    # https://open-source-silicon.slack.com/archives/C016YSAP6TZ/p1674967276129349
    # 
    flatten ${cellname}_flat
    load ${cellname}_flat
    box values 0 0 0 0
    #box 0 0 0 0

    extract all
    ext2sim labels on
    ext2sim
    extresist tolerance 10
    extresist all
    ext2spice lvs
    ext2spice extresist on
    ext2spice cthresh 0
    ext2spice -o "./output/${cellname}_parasitic.spice"

    # https://open-source-silicon.slack.com/archives/C016YSAP6TZ/p1675532194275949
    # Floating might be an implementation error... ?
}