import gf180
import gdsfactory as gf


@gf.cell
def drawTransistor(
    typeTransistor: str = "Nmos",  #  opcion de Nmos y Pmos
    w_gate: float = 2,
    folding: int = 1,
) -> gf.Component:
    # desde el origen (0.0) el primer source esta a la izquierda (-)

    # ej. foldding = 2, W = 4, x = 2     donde x es la cantida de finger a usar

    params = {
        "l_gate": 0.28,
        "w_gate": (w_gate / folding if folding > 1 else w_gate),
        "sd_con_col": 1,  # numero de columnas de contacto en la difusion
        "inter_sd_l": 0.52,  # largo del canal entre finger
        "nf": (folding if folding > 1 else 1),
        "grw": 0.38,
        "volt": "3.3V",
        "bulk": "None",
        "con_bet_fin": 1,
        "gate_con_pos": "top",  # alternating   #bottom
        "interdig": 1,
        "patt": "",
        "deepnwell": 0,
        "pcmpgr": 0,
        "label": 0,
        "sub_label": "",
        "patt_label": 0,
        "metal_s": "metal1",
        "width_metal1_conection": 0.38,
        "DistanceFisrt_metal1_conection": -0.375,
        "min_distance_between_m1": 0.26,
        "bulk_plus": ("pplus" if typeTransistor == "Nmos" else "nplus"),
        "typeTransistor": typeTransistor,
    }

    transistor = gf.Component(typeTransistor)

    _add_fets(transistor, params)
    _add_source(transistor, params)
    _add_drain(transistor, params)
    _add_poly_connect(transistor, params)
    _add_bulk_contacts(transistor, params)
    _add_bulk(transistor, params)

    return transistor


def _add_fets(transistor, params):
    typeTransistor = params["typeTransistor"]

    transistor_parameters = {
        "l_gate": params["l_gate"],
        "w_gate": params["w_gate"],
        "sd_con_col": params["sd_con_col"],
        "inter_sd_l": params["inter_sd_l"],
        "nf": params["nf"],
        "grw": params["grw"],
        "volt": params["volt"],
        "bulk": params["bulk"],
        "con_bet_fin": params["con_bet_fin"],
        "gate_con_pos": params["gate_con_pos"],
        "interdig": params["interdig"],
        "patt": params["patt"],
        "deepnwell": params["deepnwell"],
        "pcmpgr": params["pcmpgr"],
        "label": params["label"],
        "sub_label": params["sub_label"],
        "patt_label": params["patt_label"],
    }

    if typeTransistor == "Nmos":
        transistor << gf180.nfet(**transistor_parameters)

    else:
        transistor << gf180.pfet(**transistor_parameters)


def _add_source(transistor, params):
    nf = params["nf"]
    l_gate = params["l_gate"]
    inter_sd_l = params["inter_sd_l"]

    metal_s = params["metal_s"]
    width_metal1_conection = params["width_metal1_conection"]
    DistanceFisrt_metal1_conection = params["DistanceFisrt_metal1_conection"]
    min_distance_between_m1 = params["min_distance_between_m1"]

    if nf >= 2:
        # Add one horizontal source
        ###########################

        # nf par -> sources = nf -1  and drain = nf -2      |   nf impar -> sources = nf -1  and drain = nf -1       #cantidad de sources y drains al hacer foldding

        temp_nf = nf if nf % 2 == 0 else nf - 1

        horizontal_fet_source = transistor << gf.components.rectangle(
            size=(
                2 * (inter_sd_l - 0.07) + (temp_nf - 1) * inter_sd_l + temp_nf * l_gate,
                width_metal1_conection,
            ),
            layer=metal_s,
        )  # 3.72
        horizontal_fet_source.movex(DistanceFisrt_metal1_conection)
        # 0.06 pq me falto un poco y era más facil asi al igual que en el for
        horizontal_fet_source.movey(
            -1 * width_metal1_conection - min_distance_between_m1 + 0.06
        )

        # Add multiple vertical sources
        ###############################

        # agregando el bulk del lado izquierdo
        vertical_fet_source = gf.components.rectangle(
            size=(0.38, min_distance_between_m1), layer=metal_s
        )

        # Number of sources with folding
        vertical_source_total = 2 + (nf - 2) // 2

        for i in range(vertical_source_total):
            source = transistor << vertical_fet_source

            firstM = 0 if i == 0 else 0.07
            secondM = 0.07 if i > 1 else 0

            source_dx = (
                DistanceFisrt_metal1_conection
                + firstM
                + secondM * (i - 1)
                + i * (width_metal1_conection + 0.07 + inter_sd_l)
                + 2 * i * l_gate
            )
            source_dy = -min_distance_between_m1 + 0.06
            source.move(
                [
                    source_dx,
                    source_dy,
                ]
            )

    else:
        # Add one vertical source
        #########################

        fet_source_vertical = transistor << gf.components.rectangle(
            size=(0.38, 0.64), layer=metal_s
        )
        fet_source_vertical.move([DistanceFisrt_metal1_conection, -0.58])


def _add_drain(transistor, params):
    nf = params["nf"]
    l_gate = params["l_gate"]
    w_gate_folding = params["w_gate"]
    inter_sd_l = params["inter_sd_l"]

    metal_s = params["metal_s"]
    width_metal1_conection = params["width_metal1_conection"]
    min_distance_between_m1 = params["min_distance_between_m1"]

    firstM1_drain = 0.425

    if nf >= 3:
        # Add one horizontal drain
        ##########################

        _nf = nf - 1 if nf % 2 == 0 else nf

        drainMOS_H = transistor << gf.components.rectangle(
            size=(
                (inter_sd_l - 0.07)
                + (_nf - 1) * inter_sd_l
                + (_nf - 1) * l_gate
                - 0.07,
                width_metal1_conection,
            ),
            layer=metal_s,
        )  # 3.72
        drainMOS_H.movex(firstM1_drain)
        # 0.06 pq me falto un poco y era más facil asi al igual que en el for
        drainMOS_H.movey(w_gate_folding + min_distance_between_m1 - 0.06)

        # Add multiple vertical drains
        ###############################

        drainMOS_m1_y = gf.components.rectangle(
            size=(0.38, min_distance_between_m1), layer=metal_s
        )  # agregando el bulk del lado izquierdo
        vertical_drains_total = (nf + 1) // 2

        for i in range(vertical_drains_total):
            drain = transistor << drainMOS_m1_y

            drain.move(
                [
                    0.075 + 0.07 + l_gate + (2 * inter_sd_l + 2 * l_gate) * i,
                    w_gate_folding - 0.06,
                ]
            )

    else:
        # Add one vertical drain
        ########################

        drainMOS_m1_y = transistor << gf.components.rectangle(
            size=(0.38, 0.64), layer=metal_s
        )
        drainMOS_m1_y.move([0.075 + 0.07 + l_gate, w_gate_folding - 0.06])


def _add_poly_connect(transistor, params):
    nf = params["nf"]
    w_gate_folding = params["w_gate"]

    # poly conect
    poly_down = transistor << gf.components.rectangle(
        size=((nf - 1) * 0.42 + nf * 0.38, 0.38), layer="poly2"
    )
    poly_down.movex(0.025)
    poly_down.movey(0.22 + w_gate_folding)


def _add_bulk(transistor, params):
    nf = params["nf"]
    l_gate = params["l_gate"]
    w_gate_folding = params["w_gate"]
    inter_sd_l = params["inter_sd_l"]

    metal_s = params["metal_s"]
    width_metal1_conection = params["width_metal1_conection"]
    DistanceFisrt_metal1_conection = params["DistanceFisrt_metal1_conection"]
    min_distance_between_m1 = params["min_distance_between_m1"]

    bulk_plus = params["bulk_plus"]
    typeTransistor = params["typeTransistor"]

    # COMP
    ######

    bulk_comp = gf.components.rectangle(size=(0.37, w_gate_folding), layer="comp")

    bulk_comp_left = transistor << bulk_comp
    bulk_comp_left.movex(-3 * (0.36 + 0.01))

    bulk_comp_right = transistor << bulk_comp
    bulk_comp_right.movex(nf * (l_gate + inter_sd_l) + 0.37)

    # METAL1
    ########

    bulk_m1 = gf.components.rectangle(
        size=(0.36, w_gate_folding - 2 * 0.08), layer="metal1"
    )

    bulk_m1_left = transistor << bulk_m1
    bulk_m1_left.movex(-3 * (0.36 + 0.01))
    bulk_m1_left.movey(0.08)

    bulk_m1_right = transistor << bulk_m1
    bulk_m1_right.movex(nf * (l_gate + inter_sd_l) + 0.37)
    bulk_m1_right.movey(0.08)

    # PLUS
    ######

    # agregando el bulk del lado derecho   0.87-0.28=0.59
    bulk_plus = gf.components.rectangle(
        size=(0.59 + 0.27, w_gate_folding + 2 * 0.23), layer=bulk_plus
    )

    bulk_plus_left = transistor << bulk_plus
    bulk_plus_left.movex(-1.11 - 0.27 - 0.01)
    bulk_plus_left.movey(-0.23)

    bulk_plus_right = transistor << bulk_plus
    bulk_plus_right.movex(nf * (l_gate + inter_sd_l) + 0.16)
    bulk_plus_right.movey(-0.23)

    # NWELL
    #######

    if typeTransistor == "Pmos":
        bulk_nwell = gf.components.rectangle(
            size=(0.59 + 0.27, w_gate_folding + 2 * 0.43), layer="nwell"
        )

        bulk_nwell_left = transistor << bulk_nwell
        bulk_nwell_left.movex(-1.38 - 0.27 - 0.01)
        bulk_nwell_left.movey(-0.43)

        bulk_nwell_right = transistor << bulk_nwell
        bulk_nwell_right.movex(nf * (l_gate + inter_sd_l) + 0.43)
        bulk_nwell_right.movey(-0.43)

    # CONNECTION BULK SOURCE
    ########################

    bulk_m1_template1 = gf.components.rectangle(
        size=(0.36, min_distance_between_m1 + 0.02), layer=metal_s
    )

    bulk_m1_left = transistor << bulk_m1_template1
    bulk_m1_left.move(
        [2 * DistanceFisrt_metal1_conection - 0.36, -min_distance_between_m1 + 0.06]
    )

    bulk_m1_right = transistor << bulk_m1_template1
    bulk_m1_right.move(
        [
            DistanceFisrt_metal1_conection
            + nf * l_gate
            + nf * inter_sd_l
            + width_metal1_conection
            + 0.365,
            -min_distance_between_m1 + 0.06,
        ]
    )

    # CONNECT
    #########

    # el lado derecho tiene 2 opciones dependiendo de si es par o impar
    m1_bulk_horizontal_length = 0.36 + 0.365
    _nf = nf
    if nf % 2 != 0:
        m1_bulk_horizontal_length += 0.07 * 2 + width_metal1_conection + l_gate
        _nf = nf - 1

    bulk_m1_left_conect = transistor << gf.components.rectangle(
        size=(0.375 + 0.36, 0.38), layer=metal_s
    )
    bulk_m1_left_conect.move(
        [
            2 * DistanceFisrt_metal1_conection - 0.36,
            -1 * width_metal1_conection - min_distance_between_m1 + 0.06,
        ]
    )

    bulk_m1_right_conect = transistor << gf.components.rectangle(
        size=(m1_bulk_horizontal_length, width_metal1_conection),
        layer=metal_s,
    )
    bulk_m1_right_conect.move(
        [
            DistanceFisrt_metal1_conection
            + _nf * l_gate
            + _nf * inter_sd_l
            + width_metal1_conection,
            -min_distance_between_m1 + 0.06 - width_metal1_conection,
        ]
    )


def _add_bulk_contacts(transistor, params):
    w_gate_folding = params["w_gate"]
    nf = params["nf"]
    l_gate = params["l_gate"]
    inter_sd_l = params["inter_sd_l"]
    numberContact = int(w_gate_folding / (0.22 + 0.28))

    # TODO: rewrite comment
    # cantidadda de contactos en la difusion viene dados por W_gate / (0.22 + 0.28)-> 0.22 ancho de contacto y 0.28 ceparacion entre contactos
    bulk_contact = gf.components.rectangle(size=(0.22, 0.22), layer="contact")

    for i in range(numberContact):
        ref1 = transistor << bulk_contact
        ref2 = transistor << bulk_contact

        ref1_dx = -1 * (0.72 + 0.085 + 0.22 + 0.01)
        ref1_dy = 0.28 * i + 0.22 * i + 0.14

        ref2_dx = nf * (l_gate + inter_sd_l) + 0.445
        ref2_dy = ref1_dy

        ref1.move([ref1_dx, ref1_dy])
        ref2.move([ref2_dx, ref2_dy])
