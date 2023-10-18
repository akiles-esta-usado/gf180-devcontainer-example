from drawInverter import drawTransistor

c = drawTransistor(w_gate_Nmos=10, folding_Nmos=10, w_gate_Pmos=6, folding_Pmos=3)

c.show(show_ports=True)
