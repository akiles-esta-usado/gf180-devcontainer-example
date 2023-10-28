import gdsfactory as gf

from .drawTransistor import drawTransistor


@gf.cell
def drawInverter(
    layout,
    w_gate_Nmos: float = 2,
    folding_Nmos: int = 1,
    w_gate_Pmos: float = 2,
    folding_Pmos: int = 1,
) -> gf.Component:
    top = gf.Component("TOP")

    params = {
        "layout": layout,
        "w_gate_Nmos": w_gate_Nmos,
        "folding_Nmos": folding_Nmos,
        "w_gate_Pmos": w_gate_Pmos,
        "folding_Pmos": folding_Pmos,
        "w_gate_folding_N": (
            w_gate_Nmos / folding_Nmos if folding_Nmos > 1 else folding_Nmos
        ),
        "nf_N": (folding_Nmos if folding_Nmos > 1 else 1),
        "w_gate_folding_P": (
            w_gate_Pmos / folding_Pmos if folding_Pmos > 1 else w_gate_Pmos
        ),
        "nf_P": (folding_Pmos if folding_Pmos > 1 else 1),
        "inter_sd_l": 0.52,
        "l_gate": 0.28,
        "metal_s": "metal1",
        "width_metal1_conection": 0.38,
    }

    _add_transistors(top, params)

    _add_drain(top, params)

    _add_poly(top, params)

    _add_contact(top, params)

    return top


def _add_transistors(top, params):
    layout = params["layout"]
    w_gate_Nmos = params["w_gate_Nmos"]
    folding_Nmos = params["folding_Nmos"]
    w_gate_Pmos = params["w_gate_Pmos"]
    folding_Pmos = params["folding_Pmos"]
    w_gate_folding_N = params["w_gate_folding_N"]
    w_gate_folding_P = params["w_gate_folding_P"]

    # Nmos  pull_down
    pull_down = top << drawTransistor(layout, "Nmos", w_gate_Nmos, folding_Nmos)
    pull_up = top << drawTransistor(layout, "Pmos", w_gate_Pmos, folding_Pmos)

    pull_up.mirror_y(y0=w_gate_folding_P / 2)
    pull_up.movey(w_gate_folding_N + 2)


def _add_drain(top, params):
    w_gate_folding_N = params["w_gate_folding_N"]
    nf_N = params["nf_N"]
    nf_P = params["nf_P"]
    inter_sd_l = params["inter_sd_l"]
    l_gate = params["l_gate"]
    metal_s = params["metal_s"]

    # 0.84 es la distania en las que quedas los m1

    # out
    drain_out = top << gf.components.rectangle(size=(0.38, 0.84), layer=metal_s)
    drain_out.move([0.075 + 0.07 + l_gate, w_gate_folding_N + 0.58])

    out_m1_nf = nf_N if nf_N >= nf_P else nf_P

    drain_out2 = top << gf.components.rectangle(
        size=((out_m1_nf + 3) * inter_sd_l, 0.38), layer=metal_s
    )
    drain_out2.move([0.075 + 0.07 + l_gate + 0.38, w_gate_folding_N + 0.81])


def _add_poly(top, params):
    w_gate_folding_N = params["w_gate_folding_N"]

    # 0.84 es la distania en las que quedas los m1

    poly_in = top << gf.components.rectangle(size=(0.38, 0.8), layer="poly2")
    poly_in.move([0.025, w_gate_folding_N + 0.6])

    poly_in2 = top << gf.components.rectangle(size=(2, 0.38), layer="poly2")
    poly_in2.move([0.025 - 2, w_gate_folding_N + 0.8])


def _add_contact(top, params):
    w_gate_folding_N = params["w_gate_folding_N"]
    metal_s = params["metal_s"]
    width_metal1_conection = params["width_metal1_conection"]

    contactPoly = top << gf.components.rectangle(
        size=(width_metal1_conection, width_metal1_conection), layer=metal_s
    )
    contactPoly.move([0.025 - 2, w_gate_folding_N + 0.8])

    contactP_m1 = top << gf.components.rectangle(size=(0.22, 0.22), layer="contact")
    contactP_m1.move([0.025 - 2 + 0.08, w_gate_folding_N + 0.8 + 0.08])
