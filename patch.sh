#!/bin/bash

set -ex

function add-trusted-git() {
    git config --global --add safe.directory $PWD
}

function add-klive () {
    klayout -y klive
}

function remove-gf180 () {
    # I don't know why, but it seems that is possible to have a root and user version
    # of gf180, better remove both.

    sudo pip uninstall gf180 --break-system-packages -y
    pip uninstall gf180 --break-system-packages -y

    # rm -rf $KLAYOUT_HOME/pymacros/ce*
}

function add-gf180 () {
    git config --global --add safe.directory /workspaces/gf180-devcontainer-example/gf180
    git submodule update --init --recursive --remote

    # In this directory is the old annoying version
    # .local/lib/python3.11/site-packages/gf180 

    BASE_DIR=$PWD

    cd gf180
    sudo pip install -e . --break-system-packages

    cd $BASE_DIR
}

add-trusted-git
add-klive
remove-gf180
add-gf180
