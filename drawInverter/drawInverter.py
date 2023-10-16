import gf180
import gdsfactory as gf

from .drawTransistor import drawTransistor


@gf.cell
def drawInverter(
    w_gate_Nmos: float = 2,
    folding_Nmos: int = 1,
    w_gate_Pmos: float = 2,
    folding_Pmos: int = 1,
) -> gf.Component:
    top = gf.Component("TOP")

    folding = folding_Nmos
    if folding > 1:
        w_gate_folding = w_gate_Nmos / folding
        nf = folding
    else:
        w_gate_folding = w_gate_Nmos
        nf = 1

    folding_P = folding_Pmos
    if folding_P > 1:
        w_gate_folding_P = w_gate_Pmos / folding_P
        nf_P = folding_P
    else:
        w_gate_folding_P = w_gate_Pmos
        nf_P = 1

    inter_sd_l = 0.52
    l_gate = 0.28

    metal_s = "metal1"
    width_metal1_conection = 0.38

    # Nmos  pull_down
    pull_down = drawTransistor("Nmos", w_gate_Nmos, folding_Nmos)
    pull_up = drawTransistor("Pmos", w_gate_Pmos, folding_Pmos)

    pull_up = top << pull_up
    pull_down = top << pull_down
    pull_up.mirror_y(y0=w_gate_folding_P / 2)
    pull_up.movey(w_gate_folding + 2)

    # out
    drain_out = gf.components.rectangle(
        size=(0.38, 0.84), layer=metal_s
    )  # 0.84 es la distania en las que quedas los m1
    drain_out = top.add_ref(drain_out)
    drain_out.movex(0.075 + 0.07 + l_gate)
    drain_out.movey(w_gate_folding + 0.58)

    out_m1_nf = nf if nf >= nf_P else nf_P
    drain_out2 = gf.components.rectangle(
        size=((out_m1_nf + 3) * inter_sd_l, 0.38), layer=metal_s
    )  # 0.84 es la distania en las que quedas los m1
    drain_out2 = top.add_ref(drain_out2)
    drain_out2.movex(0.075 + 0.07 + l_gate + 0.38)
    drain_out2.movey(w_gate_folding + 0.81)

    # In
    poly_in = gf.components.rectangle(
        size=(0.38, 0.8), layer="poly2"
    )  # 0.84 es la distania en las que quedas los m1
    poly_in = top.add_ref(poly_in)
    poly_in.movex(0.025)
    poly_in.movey(w_gate_folding + 0.6)

    poly_in2 = gf.components.rectangle(
        size=(2, 0.38), layer="poly2"
    )  # 0.84 es la distania en las que quedas los m1
    poly_in2 = top.add_ref(poly_in2)
    poly_in2.movex(0.025 - 2)
    poly_in2.movey(w_gate_folding + 0.8)

    # contact
    contactPoly = gf.components.rectangle(
        size=(width_metal1_conection, width_metal1_conection), layer=metal_s
    )
    contactPoly = top.add_ref(contactPoly)
    contactPoly.movex(0.025 - 2)
    contactPoly.movey(w_gate_folding + 0.8)

    contactP_m1 = gf.components.rectangle(size=(0.22, 0.22), layer="contact")
    contactP_m1 = top.add_ref(contactP_m1)
    contactP_m1.movex(0.025 - 2 + 0.08)
    contactP_m1.movey(w_gate_folding + 0.8 + 0.08)

    return top
