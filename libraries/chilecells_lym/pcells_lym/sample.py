import pya

import pya
import math

from cells.draw_fet import draw_nfet

"""
This sample PCell implements a library called "MyLib" with a single PCell that
draws a circle. It demonstrates the basic implementation techniques for a PCell
and how to use the "guiding shape" feature to implement a handle for the circle
radius.

NOTE: after changing the code, the macro needs to be rerun to install the new
implementation. The macro is also set to "auto run" to install the PCell
when KLayout is run.
"""


class Sample(pya.PCellDeclarationHelper):
    """
    The PCell declaration for the circle
    """

    def __init__(self):
        # Important: initialize the super class
        super(Sample, self).__init__()

        # declare the parameters
        self.param("l", self.TypeLayer, "Layer")
        self.param("s", self.TypeShape, "", default=pya.DPoint(0, 0))
        self.param("r", self.TypeDouble, "Radius", default=0.1)
        self.param("n", self.TypeInt, "Number of points", default=64)
        # this hidden parameter is used to determine whether the radius has changed
        # or the "s" handle has been moved
        self.param("ru", self.TypeDouble, "Radius", default=0.0, hidden=True)
        self.param("rd", self.TypeDouble, "Double radius", readonly=True)

    def display_text_impl(self):
        # Provide a descriptive text for the cell
        return "Sample(L=" + str(self.l) + ",R=" + ("%.3f" % self.r) + ")"

    def coerce_parameters_impl(self):
        # We employ coerce_parameters_impl to decide whether the handle or the
        # numeric parameter has changed (by comparing against the effective
        # radius ru) and set ru to the effective radius. We also update the
        # numerical value or the shape, depending on which on has not changed.
        rs = None
        if isinstance(self.s, pya.DPoint):
            # compute distance in micron
            rs = self.s.distance(pya.DPoint(0, 0))
        if rs != None and abs(self.r - self.ru) < 1e-6:
            self.ru = rs
            self.r = rs

        else:
            self.ru = self.r
            self.s = pya.DPoint(-self.r, 0)

        self.rd = 2 * self.r

        # n must be larger or equal than 4
        if self.n <= 4:
            self.n = 4

    def can_create_from_shape_impl(self):
        # Implement the "Create PCell from shape" protocol: we can use any shape which
        # has a finite bounding box
        return self.shape.is_box() or self.shape.is_polygon() or self.shape.is_path()

    def parameters_from_shape_impl(self):
        # Implement the "Create PCell from shape" protocol: we set r and l from the shape's
        # bounding box width and layer
        self.r = self.shape.bbox().width() * self.layout.dbu / 2
        self.l = self.layout.get_info(self.layer)

    def transformation_from_shape_impl(self):
        # Implement the "Create PCell from shape" protocol: we use the center of the shape's
        # bounding box to determine the transformation
        return pya.Trans(self.shape.bbox().center())

    def produce_impl(self):
        # This is the main part of the implementation: create the layout

        instance = draw_nfet(layout=self.layout, l_gate=0.7, w_gate=10)

        write_cells = pya.CellInstArray(
            instance.cell_index(),
            pya.Trans(pya.Point(0, 0)),
            pya.Vector(0, 0),
            pya.Vector(0, 0),
            1,
            1,
        )
        self.cell.insert(write_cells)
        self.cell.flatten(1)
