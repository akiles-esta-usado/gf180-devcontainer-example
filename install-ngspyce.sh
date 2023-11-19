#!/bin/bash

set -e

# Important Variables

TOOLS=/tools
NGSPYCE_REPO_URL="https://github.com/ignamv/ngspyce"
NGSPYCE_REPO_COMMIT="154a2724080e3bf15827549bba9f315cd11984fe"
NGSPYCE_NAME="ngspyce"

REPO_COMMIT_SHORT=$(echo "$NGSPYCE_REPO_COMMIT" | cut -c 1-7)

# Clean previous installation

rm -rf "${TOOLS}/$NGSPYCE_NAME/$REPO_COMMIT_SHORT"

# Install

mkdir -p "$TOOLS"
git clone --filter=blob:none "$NGSPYCE_REPO_URL" "${TOOLS}/$NGSPYCE_NAME/$REPO_COMMIT_SHORT"
cd "${TOOLS}/$NGSPYCE_NAME/$REPO_COMMIT_SHORT" || exit 1
git checkout "$NGSPYCE_REPO_COMMIT"

#python3 setup.py install

pip3 install --break-system-packages "${TOOLS}/$NGSPYCE_NAME/$REPO_COMMIT_SHORT" --no-cache-dir
#pip3 install --break-system-packages . --prefix="${TOOLS}/$NGSPYCE_NAME/$REPO_COMMIT_SHORT" --no-cache-dir
