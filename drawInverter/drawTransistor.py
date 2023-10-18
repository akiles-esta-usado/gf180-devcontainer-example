import gf180
import gdsfactory as gf


def fingers_to_sources(F):
    if F >= 2:
        return 2 + (F - 2) // 2
    else:
        raise ValueError("F debe ser mayor o igual a 2")


def fingers_to_drains(F):
    if F >= 2:
        return (F + 1) // 2
    else:
        raise ValueError("F debe estar entre 2 y 12 inclusive.")


@gf.cell
def drawTransistor(
    typeTransistor: str = "Nmos",  #  opcion de Nmos y Pmos
    w_gate: float = 2,
    folding: int = 1,
) -> gf.Component:
    # desde el origen (0.0) el primer source esta a la izquierda (-)
    metal_parameters = {
        "metal_s": "metal1",
        "width_metal1_conection": 0.38,
        "DistanceFisrt_metal1_conection": -0.375,
        "min_distance_between_m1": 0.26,
    }

    bulk_parameters = {
        "bulk_plus": "pplus" if typeTransistor == "Nmos" else "nplus",
        "typeTransistor": typeTransistor,
    }

    # ej. foldding = 2, W = 4, x = 2     donde x es la cantida de finger a usar

    transistor_parameters = {
        "l_gate": 0.28,
        "w_gate": w_gate / folding if folding > 1 else w_gate,
        "sd_con_col": 1,  # numero de columnas de contacto en la difusion
        "inter_sd_l": 0.52,  # largo del canal entre finger
        "nf": folding if folding > 1 else 1,
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
    }

    transistor = gf.Component(typeTransistor)

    if typeTransistor == "Nmos":
        transistor << gf180.nfet(**transistor_parameters)

    else:
        transistor << gf180.pfet(**transistor_parameters)

    _add_source(transistor, transistor_parameters, metal_parameters)
    _add_drain(transistor, transistor_parameters, metal_parameters)
    _add_poly_connect(transistor, transistor_parameters, metal_parameters)
    _add_bulk_contacts(transistor, transistor_parameters, metal_parameters)
    _add_bulk(transistor, transistor_parameters, metal_parameters, bulk_parameters)

    return transistor


def _add_source(transistor, transistor_parameters, metal_parameters):
    nf = transistor_parameters["nf"]
    l_gate = transistor_parameters["l_gate"]
    inter_sd_l = transistor_parameters["inter_sd_l"]

    metal_s = metal_parameters["metal_s"]
    width_metal1_conection = metal_parameters["width_metal1_conection"]
    DistanceFisrt_metal1_conection = metal_parameters["DistanceFisrt_metal1_conection"]
    min_distance_between_m1 = metal_parameters["min_distance_between_m1"]

    if nf >= 2:
        # nf par -> sources = nf -1  and drain = nf -2      |   nf impar -> sources = nf -1  and drain = nf -1       #cantidad de sources y drains al hacer foldding

        # hace una if para saber si nf es par o impar y un else para caso impar
        if nf % 2 == 0:
            Length_horizontal_metal1_conection = (
                2 * (inter_sd_l - 0.07) + (nf - 1) * inter_sd_l + nf * l_gate
            )
        else:
            Length_horizontal_metal1_conection = (
                2 * (inter_sd_l - 0.07) + (nf - 2) * inter_sd_l + (nf - 1) * l_gate
            )

        sourceMOS_H = transistor << gf.components.rectangle(
            size=(Length_horizontal_metal1_conection, width_metal1_conection),
            layer=metal_s,
        )  # 3.72
        sourceMOS_H.movex(DistanceFisrt_metal1_conection)
        sourceMOS_H.movey(
            -1 * width_metal1_conection - min_distance_between_m1 + 0.06
        )  # 0.06 pq me falto un poco y era más facil asi al igual que en el for

        sources = []  # List to store the references
        sourceMOS_m1_y = gf.components.rectangle(
            size=(0.38, min_distance_between_m1), layer=metal_s
        )  # agregando el bulk del lado izquierdo
        sourceNP = fingers_to_sources(
            nf
        )  # cantidad de sources que hay al hacer el folding
        for i in range(sourceNP):
            sources.append(transistor << sourceMOS_m1_y)

        for i, source in enumerate(sources):  # Start from the 1st index
            firstM = 0 if i == 0 else 0.07
            secondM = secondM = 0.07 if i > 1 else 0
            source.move(
                [
                    DistanceFisrt_metal1_conection
                    + firstM
                    + secondM * (i - 1)
                    + i * (width_metal1_conection + 0.07 + inter_sd_l)
                    + 2 * i * l_gate,
                    -min_distance_between_m1 + 0.06,
                ]
            )  # Move the reference   izquierda
    else:
        sourceMOS_m1_y = transistor << gf.components.rectangle(
            size=(0.38, 0.64), layer=metal_s
        )
        sourceMOS_m1_y.move([DistanceFisrt_metal1_conection, -0.58])


def _add_drain(transistor, transistor_parameters, metal_parameters):
    nf = transistor_parameters["nf"]
    l_gate = transistor_parameters["l_gate"]
    w_gate_folding = transistor_parameters["w_gate"]
    inter_sd_l = transistor_parameters["inter_sd_l"]

    metal_s = metal_parameters["metal_s"]
    width_metal1_conection = metal_parameters["width_metal1_conection"]
    min_distance_between_m1 = metal_parameters["min_distance_between_m1"]

    # drain
    firstM1_drain = 0.425
    if nf >= 3:
        if nf % 2 == 0:
            Length_horizontal_metal1_conection = (
                (inter_sd_l - 0.07) + (nf - 2) * inter_sd_l + (nf - 2) * l_gate - 0.07
            )
        else:
            Length_horizontal_metal1_conection = (
                (inter_sd_l - 0.07) + (nf - 1) * inter_sd_l + (nf - 1) * l_gate - 0.07
            )

        drainMOS_H = transistor << gf.components.rectangle(
            size=(Length_horizontal_metal1_conection, width_metal1_conection),
            layer=metal_s,
        )  # 3.72
        drainMOS_H.movex(firstM1_drain)
        drainMOS_H.movey(
            w_gate_folding + min_distance_between_m1 - 0.06
        )  # 0.06 pq me falto un poco y era más facil asi al igual que en el for

        drains = []  # List to store the references
        drainMOS_m1_y = gf.components.rectangle(
            size=(0.38, min_distance_between_m1), layer=metal_s
        )  # agregando el bulk del lado izquierdo
        drainNP = fingers_to_drains(
            nf
        )  # cantidad de sources que hay al hacer el folding
        for i in range(drainNP):
            drains.append(transistor << drainMOS_m1_y)

        for i, drain in enumerate(drains):  # Start from the 1st index
            drain.move(
                [
                    0.075 + 0.07 + l_gate + (2 * inter_sd_l + 2 * l_gate) * i,
                    w_gate_folding - 0.06,
                ]
            )
    else:
        drainMOS_m1_y = gf.components.rectangle(size=(0.38, 0.64), layer=metal_s)
        drainMOS_m1_y = transistor << drainMOS_m1_y
        drainMOS_m1_y.move([0.075 + 0.07 + l_gate, w_gate_folding - 0.06])


def _add_poly_connect(transistor, transistor_parameters, metal_parameters):
    nf = transistor_parameters["nf"]
    w_gate_folding = transistor_parameters["w_gate"]

    # poly conect
    poly_down = transistor << gf.components.rectangle(
        size=((nf - 1) * 0.42 + nf * 0.38, 0.38), layer="poly2"
    )
    poly_down.movex(0.025)
    poly_down.movey(0.22 + w_gate_folding)


def _add_bulk(
    transistor: gf.Component,
    transistor_parameters: dict,
    metal_parameters: dict,
    bulk_parameters: dict,
):
    nf = transistor_parameters["nf"]
    l_gate = transistor_parameters["l_gate"]
    w_gate_folding = transistor_parameters["w_gate"]
    inter_sd_l = transistor_parameters["inter_sd_l"]

    metal_s = metal_parameters["metal_s"]
    width_metal1_conection = metal_parameters["width_metal1_conection"]
    DistanceFisrt_metal1_conection = metal_parameters["DistanceFisrt_metal1_conection"]
    min_distance_between_m1 = metal_parameters["min_distance_between_m1"]

    bulk_plus = bulk_parameters["bulk_plus"]
    typeTransistor = bulk_parameters["typeTransistor"]

    # BULK
    # Agregando el bulk left
    bulk_comp_left = transistor << gf.components.rectangle(
        size=(0.37, w_gate_folding), layer="comp"
    )  # agregando el bulk del lado izquierdo
    bulk_comp_left.movex(-3 * (0.36 + 0.01))

    bulk_m1_left = transistor << gf.components.rectangle(
        size=(0.36, w_gate_folding - 2 * 0.08), layer="metal1"
    )  # agregando el bulk del lado izquierdo
    bulk_m1_left.movex(-3 * (0.36 + 0.01))
    bulk_m1_left.movey(0.08)

    bulk_plus_left = transistor << gf.components.rectangle(
        size=(0.59 + 0.27, w_gate_folding + 2 * 0.23), layer=bulk_plus
    )  # agregando el bulk del lado derecho   0.87-0.28=0.59
    bulk_plus_left.movex(-1.11 - 0.27 - 0.01)
    bulk_plus_left.movey(-0.23)

    ## agregar if de nwell de pmos
    if typeTransistor == "Pmos":
        bulk_nwell_left = transistor << gf.components.rectangle(
            size=(0.59 + 0.27, w_gate_folding + 2 * 0.43), layer="nwell"
        )
        bulk_nwell_left.movex(-1.38 - 0.27 - 0.01)
        bulk_nwell_left.movey(-0.43)

    # Agregando el bulk right
    bulk_comp_right = transistor << gf.components.rectangle(
        size=(0.37, w_gate_folding), layer="comp"
    )  # agregando el bulk del lado derecho
    bulk_comp_right.movex(nf * (l_gate + inter_sd_l) + 0.37)

    bulk_m1_right = transistor << gf.components.rectangle(
        size=(0.36, w_gate_folding - 2 * 0.08), layer="metal1"
    )  # agregando el bulk del derecho
    bulk_m1_right.movex(nf * (l_gate + inter_sd_l) + 0.37)
    bulk_m1_right.movey(0.08)

    bulk_plus_right = transistor << gf.components.rectangle(
        size=(0.59 + 0.27, w_gate_folding + 2 * 0.23), layer=bulk_plus
    )  # agregando el bulk del lado derecho   0.87-0.28=0.59
    bulk_plus_right.movex(nf * (l_gate + inter_sd_l) + 0.16)
    bulk_plus_right.movey(-0.23)

    if typeTransistor == "Pmos":
        bulk_nwell_right = transistor << gf.components.rectangle(
            size=(0.59 + 0.27, w_gate_folding + 2 * 0.43), layer="nwell"
        )
        bulk_nwell_right.movex(nf * (l_gate + inter_sd_l) + 0.43)
        bulk_nwell_right.movey(-0.43)
    # conect BULK and source
    bulk_m1_left = transistor << gf.components.rectangle(
        size=(0.36, min_distance_between_m1 + 0.02), layer=metal_s
    )  # agregando el bulk del lado izquierdo
    bulk_m1_left.movex(2 * DistanceFisrt_metal1_conection - 0.36)
    bulk_m1_left.movey(-min_distance_between_m1 + 0.06)

    bulk_m1_left_conect = transistor << gf.components.rectangle(
        size=(0.375 + 0.36, 0.38), layer=metal_s
    )  # agregando el bulk del lado izquierdo
    bulk_m1_left_conect.movex(2 * DistanceFisrt_metal1_conection - 0.36)
    bulk_m1_left_conect.movey(
        -1 * width_metal1_conection - min_distance_between_m1 + 0.06
    )

    # el lado derecho tiene 2 opciones dependiendo de si es par o impar
    if nf % 2 == 0:
        Length_horizontal_metal1_conection_bulk = 0.36 + 0.365
        N_b_m1 = nf
    else:
        Length_horizontal_metal1_conection_bulk = (
            0.07 * 2 + width_metal1_conection + 0.36 + 0.365 + l_gate
        )
        N_b_m1 = nf - 1

    bulk_m1_right_conect = transistor << gf.components.rectangle(
        size=(Length_horizontal_metal1_conection_bulk, width_metal1_conection),
        layer=metal_s,
    )  # agregando el bulk del lado izquierdo
    bulk_m1_right_conect.movex(
        DistanceFisrt_metal1_conection
        + N_b_m1 * l_gate
        + N_b_m1 * inter_sd_l
        + width_metal1_conection
    )
    bulk_m1_right_conect.movey(-min_distance_between_m1 + 0.06 - width_metal1_conection)

    bulk_m1_right = transistor << gf.components.rectangle(
        size=(0.36, min_distance_between_m1 + 0.02), layer=metal_s
    )  # agregando el bulk del lado izquierdo
    bulk_m1_right.movex(
        DistanceFisrt_metal1_conection
        + nf * l_gate
        + nf * inter_sd_l
        + width_metal1_conection
        + 0.365
    )
    bulk_m1_right.movey(-min_distance_between_m1 + 0.06)


def _add_bulk_contacts(transistor, transistor_parameters, metal_parameters):
    w_gate_folding = transistor_parameters["w_gate"]
    nf = transistor_parameters["nf"]
    l_gate = transistor_parameters["l_gate"]
    inter_sd_l = transistor_parameters["inter_sd_l"]

    # cantidadda de contactos en la difusion viene dados por W_gate / (0.22 + 0.28)-> 0.22 ancho de contacto y 0.28 ceparacion entre contactos
    refs = []  # List to store the references
    numberContact = int(w_gate_folding / (0.22 + 0.28))
    bulK_contact_left = gf.components.rectangle(
        size=(0.22, 0.22), layer="contact"
    )  # agregando el bulk del lado izquierdo
    for i in range(numberContact):
        refs.append(transistor << bulK_contact_left)

    for i, ref in enumerate(refs):  # Start from the 1st index
        ref.move(
            [-1 * (0.72 + 0.085 + 0.22 + 0.01), 0.28 * i + 0.22 * i + 0.14]
        )  # Move the reference   izquierda

    # contactos lado derecho
    refs2 = []  # List to store the references
    bulK_contact_right = gf.components.rectangle(
        size=(0.22, 0.22), layer="contact"
    )  # agregando el bulk del lado izquierdo
    for i in range(numberContact):
        refs2.append(transistor << bulK_contact_right)

    for i, ref in enumerate(refs2):  # Start from the 1st index
        ref.move(
            [nf * (l_gate + inter_sd_l) + 0.445, 0.28 * i + 0.22 * i + 0.14]
        )  # Move the reference   izquierda
