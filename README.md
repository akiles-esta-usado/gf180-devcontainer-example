# GF180 Dev Environment

Based on [Patricio](https://github.com/P-coryan/gf180-automated-design) work, this 
example shows how to use DevContainer to develop ic layout with Klayout.

The project is structured as a python package, and uses GdsFactory. All dependencies
should be solved in the docker container, except klayout plugins.

## Klayout Plugins

Only Klive plugin is required. Open Klayout and in the **Tools** toolbar, search and download 
klive plugin on **Manage Package** menu.
