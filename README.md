# GF180 Dev Environment

Based on [Sebastian](https://github.com/P-coryan/gf180-automated-design) work, this 
example shows how to use DevContainer to develop ic layout with Klayout.

The project is structured as a python package, and is based on GdsFactory. All de dependencies
should be resolved in the docker container, except klayout plugins.

## Klayout Plugins

Only Klive plugin is required. Open Klayout and in the **Tools** toolbar, search and download 
klive plugin on **Manage Package** menu.