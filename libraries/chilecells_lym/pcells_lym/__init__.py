import pya

import pya
import math

from .sample import Sample


class ChileCellsModuleLym(pya.Library):
    """
    Chile custom cells
    """

    def __init__(self):
        self.description = "ChileTeam with Lym module"

        self.layout().register_pcell("Sample", Sample())

        self.register("ChileTeamLym")


# ChileCellsModule()
