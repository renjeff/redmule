#!/bin/bash
# Helper to set up environment and run make commands
export VsimFlags=''
export Questa="questa-2023.4"
export LD_LIBRARY_PATH="/scratch2/msc25h32/redmule/vendor/install/riscv/lib:$LD_LIBRARY_PATH"
exec "$@"
