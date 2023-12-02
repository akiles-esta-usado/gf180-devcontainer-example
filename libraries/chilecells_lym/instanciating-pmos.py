# https://www.klayout.de/forum/discussion/2319/coding-a-path-via-python
# https://www.klayout.de/forum/discussion/comment/9854#Comment_9854

import pya  # Klayout Python API
from pprint import pprint
import gdsfactory as gf
from cells.draw_fet import draw_pfet

# SET ENVIRONMENT
#################

layout_view = pya.Application.instance().main_window().current_view()
cell_view = layout_view.active_cellview()
layout = cell_view.layout()
cell = cell_view.cell

cell.clear()

# DRAW A PATH
#############

# point1 = pya.DPoint(0.0, 0.0)
# point2 = pya.DPoint(15.0, 20.0)
# point3 = pya.DPoint(30.0, 30.0)
# point4 = pya.DPoint(45.0, 70.0)

# layer = layout.layer(4, 0)
# cell.shapes(layer).insert(pya.DPath([point1, point2, point3, point4], 1.0))

# DRAW PFET
###########

instance = draw_pfet(layout=layout, l_gate=0.7, w_gate=5)

write_cells = pya.CellInstArray(
    instance.cell_index(),
    pya.Trans(pya.Point(0, 0)),
    pya.Vector(0, 0),
    pya.Vector(0, 0),
    1,
    1,
)
cell.insert(write_cells)
# cell.flatten(1)


layout_view.add_missing_layers()
