# https://www.klayout.de/forum/discussion/2319/coding-a-path-via-python
# https://www.klayout.de/forum/discussion/comment/9854#Comment_9854

import pya  # Klayout Python API
from pprint import pprint


def drawer(func):
    """
    This decorator runs the drawing logic.
    """
    layout_view = pya.Application.instance().main_window().current_view()
    cell_view = layout_view.active_cellview()
    layout = cell_view.layout()
    viewed_cell = cell_view.cell

    cell = cell_view.cell

    def runner():
        cell.clear()

        func(layout, viewed_cell, cell)

        layout_view.add_missing_layers()

    return runner


@drawer
def test1(layout, viewed_cell, cell):
    """
    Using pya drawing capabilities
    """

    layer = layout.layer(4, 0)

    point1 = pya.DPoint(0.0, 0.0)
    point2 = pya.DPoint(15.0, 20.0)
    point3 = pya.DPoint(30.0, 30.0)
    point4 = pya.DPoint(45.0, 70.0)

    viewed_cell.shapes(layer).insert(pya.DPath([point1, point2, point3, point4], 1.0))


@drawer
def test2(layout, viewed_cell, cell):
    """
    Using gdsfactory drawing capabilities to generate gds and drawing with pya
    """

    import gdsfactory as gf
    from cells.draw_fet import draw_pfet

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
    cell.flatten(1)


@drawer
def test3(layout, viewed_cell, cell):
    """
    Verify types and methods of values returned by pdk pcells
    """

    import gdsfactory as gf
    from cells.draw_fet import draw_nfet

    nfet = draw_nfet(layout=layout, l_gate=0.4, w_gate=5)

    pprint(nfet)  # <pya.Cell object at 0x7f06ea5e9630>
    pprint(type(nfet))  # <class 'pya.Cell'>
    pprint(dir(nfet))

    #  'add_meta_info',
    #  'basic_name',
    #  'bbox',
    #  'bbox_per_layer',
    #  'begin_instances_rec',
    #  'begin_instances_rec_overlapping',
    #  'begin_instances_rec_touching',
    #  'begin_shapes_rec',
    #  'begin_shapes_rec_overlapping',
    #  'begin_shapes_rec_touching',
    #  'called_cells',
    #  'caller_cells',
    #  'cell_index',
    #  'change_pcell_parameter',
    #  'change_pcell_parameters',
    #  'child_cells',
    #  'child_instances',
    #  'clear',
    #  'clear_insts',
    #  'clear_meta_info',
    #  'clear_shapes',
    #  'copy',
    #  'copy_instances',
    #  'copy_shapes',
    #  'copy_tree',
    #  'copy_tree_shapes',
    #  'create',
    #  'dbbox',
    #  'dbbox_per_layer',
    #  'delete',
    #  'delete_property',
    #  'destroy',
    #  'destroyed',
    #  'display_title',
    #  'dump_mem_statistics',
    #  'dup',
    #  'each_child_cell',
    #  'each_inst',
    #  'each_meta_info',
    #  'each_overlapping_inst',
    #  'each_overlapping_shape',
    #  'each_parent_cell',
    #  'each_parent_inst',
    #  'each_shape',
    #  'each_touching_inst',
    #  'each_touching_shape',
    #  'erase',
    #  'fill_region',
    #  'fill_region_multi',
    #  'flatten',
    #  'ghost_cell',
    #  'has_prop_id',
    #  'hierarchy_levels',
    #  'insert',
    #  'is_const_object',
    #  'is_empty',
    #  'is_ghost_cell',
    #  'is_leaf',
    #  'is_library_cell',
    #  'is_pcell_variant',
    #  'is_proxy',
    #  'is_top',
    #  'is_valid',
    #  'layout',
    #  'library',
    #  'library_cell_index',
    #  'meta_info',
    #  'meta_info_value',
    #  'move',
    #  'move_instances',
    #  'move_shapes',
    #  'move_tree',
    #  'move_tree_shapes',
    #  'name',
    #  'new',
    #  'parent_cells',
    #  'pcell_declaration',
    #  'pcell_id',
    #  'pcell_library',
    #  'pcell_parameter',
    #  'pcell_parameters',
    #  'pcell_parameters_by_name',
    #  'prop_id',
    #  'property',
    #  'prune_cell',
    #  'prune_subcells',
    #  'qname',
    #  'read',
    #  'refresh',
    #  'remove_meta_info',
    #  'replace',
    #  'replace_prop_id',
    #  'set_property',
    #  'shapes',
    #  'swap',
    #  'transform',
    #  'transform_into',
    #  'write'


@drawer
def test4(layout, viewed_cell, cell):
    """
    Use existing draw_* functions and generate gf.Components with their gds
    See how to get internal structures
    """
    import gdsfactory as gf
    from cells.draw_fet import draw_pfet

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
    cell.flatten(1)


# =========================================
# Test Execution

# test1()
# test2()
# test3()

# =========================================
# PROBLEM: test 2 creates a lots of transistors one over another.
# There should be a method that removes all memory allocated on cells


# =========================================
# PDK Pcells use Gdsfactory to draw polygons, but then turns it into a pya.cell.
# I'm not sure if this is a good pattern to mix pya logic with gdsfactory logic

# We need to evaluate if our layout generation will use gdsfactory or pya.

# If we only use pya, we have to identify this limitations and advantages over
# gdsfactory. Maybe we can use gdsfactory in components that don't rely on pdk ones.

# If we want to use gdsfactory with all components, we had to make a wrapper
# adapter over relevant pdk pcells. Maybe we can add minor logic to:
# - connect fingers.
# - add ports, and use them to connect different cells.
