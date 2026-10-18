#!/usr/bin/env bash
# Installs what a fresh cloud session needs to rebuild the explorer (R + packages).
# Python 3 (standard library only) runs pipeline/fm.py.
set -euo pipefail
if command -v Rscript >/dev/null && Rscript -e 'for (p in c("dplyr","readr","jsonlite","V8")) library(p, character.only = TRUE)' >/dev/null 2>&1; then
  echo "R and packages already installed"; exit 0
fi
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO apt-get update -q >/dev/null 2>&1 || true      # some third-party lists may be blocked; that's fine
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q --no-install-recommends \
  r-base-core r-cran-dplyr r-cran-readr r-cran-jsonlite r-cran-v8 >/dev/null
Rscript -e 'for (p in c("dplyr","readr","jsonlite","V8")) library(p, character.only = TRUE); cat("R ready\n")'
