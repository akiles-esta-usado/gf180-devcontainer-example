# GF180 Dev Environment

Based on [Patricio](https://github.com/P-coryan/gf180-automated-design) work, this 
example shows how to use DevContainer to develop ic layout with Klayout.

The project is structured as a python package, and uses GdsFactory. All dependencies
should be solved in the docker container, except klayout plugins.

## Klayout Plugins

Only Klive plugin is required. Open Klayout and in the **Tools** toolbar, search and download 
klive plugin on **Manage Package** menu.


## How to Link local PCells into Klayout

PCells are grouped in libraries, a library can be registered with a macro.

## How to reload a modified library

**TODO: This file is a bit oudated**


# FAQ

## Why not use PySpice instead of Ngspyce?

Because the PDK uses ngspice 41 and PySpice is not compatible with that.