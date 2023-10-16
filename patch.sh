#!/bin/bash

set -ex

function add-trusted-git() {
    git config --global --add safe.directory $PWD
}

function add-klive () {
    klayout -y klive
}

function add-gf180 () {
    git submodule update --init --recursive --remote

    BASE_DIR=$PWD

    cd gf180
    pip install -e . --break-system-packages

    cd $BASE_DIR
}

add-trusted-git
add-klive
add-gf180
