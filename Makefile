# Copyright 2023 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Yvan Tortorella <yvan.tortorella@unibo.it>
#
# Top-level Makefile

# Paths to folders
RootDir    := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))
TargetDir  := $(RootDir)target
SimDir     := $(TargetDir)/sim
ScriptsDir := $(RootDir)scripts
VerilatorPath := target/sim/verilator
VsimPath      := target/sim/vsim
SW         ?= $(RootDir)sw
BUILD_DIR  ?= $(SW)/build
SIM_DIR    ?= $(RootDir)vsim
Bender     ?= $(CargoInstallDir)/bin/bender
Gcc        ?= $(GccInstallDir)/bin/
ISA        ?= riscv
ARCH       ?= rv
XLEN       ?= 32
XTEN       ?= imc_zicsr
PYTHON     ?= python3

target ?= verilator
TargetPath := $(SimDir)/$(target)

# Useful Parameters
gui      ?= 0
ipstools ?= 0
P_STALL  ?= 0.0
UseXif   ?= 0

# Included makefrags
include bender_common.mk
include bender_sim.mk
include bender_synth.mk
include $(TargetPath)/$(target).mk

compile_script_synth ?= $(RootDir)scripts/synth_compile.tcl

INI_PATH  = $(RootDir)modelsim.ini
WORK_PATH = $(SIM_DIR)/work

TEST_SRCS := $(SW)/redmule.c

ifeq ($(UseXif),1)
  FLAGS += -DCOMPLEX_OFFLOADER
endif

ifeq ($(verbose),1)
	FLAGS += -DVERBOSE
endif

ifeq ($(debug),1)
	FLAGS += -DDEBUG
endif

# MX format enable flag
MX_ENABLE ?= 0
ifeq ($(MX_ENABLE),1)
	FLAGS += -DMX_ENABLE
endif

# Include directories
INC += -I$(SW)
INC += -I$(SW)/inc
INC += -I$(SW)/utils

BOOTSCRIPT := $(SW)/kernel/crt0.S
LINKSCRIPT := $(SW)/kernel/link.ld

CC=$(Gcc)$(ISA)$(XLEN)-unknown-elf-gcc
LD=$(CC)
OBJDUMP=$(Gcc)$(ISA)$(XLEN)-unknown-elf-objdump
CC_OPTS=-march=$(ARCH)$(XLEN)$(XTEN) -mabi=ilp32 -D__$(ISA)__ -O2 -g -Wextra -Wall -Wno-unused-parameter -Wno-unused-variable -Wno-unused-function -Wundef -fdata-sections -ffunction-sections -MMD -MP
LD_OPTS=-march=$(ARCH)$(XLEN)$(XTEN) -mabi=ilp32 -D__$(ISA)__ -MMD -MP -nostartfiles -nostdlib -Wl,--gc-sections

# Setup build object dirs
CRT=$(BUILD_DIR)/crt0.o
OBJ=$(BUILD_DIR)/verif.o
BIN=$(BUILD_DIR)/verif
DUMP=$(BUILD_DIR)/verif.dump
STIM_INSTR=$(BUILD_DIR)/stim_instr.txt
STIM_DATA=$(BUILD_DIR)/stim_data.txt
STACK_INIT=$(BUILD_DIR)/stack_init.txt

# MX header generation variables (must be defined before $(OBJ) rule)
MX_GEN_SCRIPT := $(RootDir)golden-model/MX/gen_mx_test_vectors.py
MX_NUM_LANES  := 32
MX_BLOCK_SIZE := 32
X_INPUT_H   := $(SW)/inc/x_input.h
W_INPUT_H   := $(SW)/inc/w_input.h
X_MX_H      := $(SW)/inc/x_input_mx.h
W_MX_H      := $(SW)/inc/w_input_mx.h
X_EXP_MX_H  := $(SW)/inc/x_exp_mx.h
W_EXP_MX_H  := $(SW)/inc/w_exp_mx.h
GOLDEN_MX_H := $(SW)/inc/golden_mx.h

# Build implicit rules
$(STIM_INSTR) $(STIM_DATA) $(STACK_INIT): $(BIN)
	objcopy --srec-len 1 --output-target=srec $(BIN) $(BIN).s19
	$(PYTHON) scripts/parse_s19.py < $(BIN).s19 > $(BIN).txt
	$(PYTHON) scripts/s19tomem.py $(BIN).txt $(STIM_INSTR) $(STIM_DATA)
	$(PYTHON) scripts/stack_init.py $(STACK_INIT)

$(BIN): $(CRT) $(OBJ)
	$(LD) $(LD_OPTS) -o $(BIN) $(CRT) $(OBJ) -T$(LINKSCRIPT)

$(CRT): $(BUILD_DIR)
	$(CC) $(CC_OPTS) -c $(BOOTSCRIPT) -o $(CRT)

# When MX_ENABLE=1, object file depends on MX headers being generated first
ifeq ($(MX_ENABLE),1)
$(OBJ): $(BUILD_DIR) $(TEST_SRCS) $(X_MX_H) $(W_MX_H) $(X_EXP_MX_H) $(W_EXP_MX_H)
	$(CC) $(CC_OPTS) -c $(TEST_SRCS) $(FLAGS) $(INC) -o $(OBJ)
else
$(OBJ): $(BUILD_DIR) $(TEST_SRCS)
	$(CC) $(CC_OPTS) -c $(TEST_SRCS) $(FLAGS) $(INC) -o $(OBJ)
endif

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

SHELL := /bin/bash

# MX header generation rules
$(X_MX_H) $(X_EXP_MX_H) $(GOLDEN_MX_H): $(X_INPUT_H) $(MX_GEN_SCRIPT)
	@echo "[MX] Generating MX-encoded X matrix headers (compact 8-bit exponents)..."
	$(PYTHON) $(MX_GEN_SCRIPT) \
		--input $(X_INPUT_H) \
		--output-mx-header $(X_MX_H) \
		--output-exp-header $(X_EXP_MX_H) \
		--mx-array-name x_inp \
		--exp-array-name x_exp \
		--num-lanes $(MX_NUM_LANES) \
		--block-size $(MX_BLOCK_SIZE) \
		--pack-fp8 \
		--exp-format compact-8bit \
		--golden-input $(SW)/inc/golden.h \
		--golden-output-header $(GOLDEN_MX_H) \
		--golden-array-name golden_mx

$(W_MX_H) $(W_EXP_MX_H): $(W_INPUT_H) $(MX_GEN_SCRIPT)
	@echo "[MX] Generating MX-encoded W matrix headers (compact 32-bit exponents)..."
	$(PYTHON) $(MX_GEN_SCRIPT) \
		--input $(W_INPUT_H) \
		--output-mx-header $(W_MX_H) \
		--output-exp-header $(W_EXP_MX_H) \
		--mx-array-name w_inp \
		--exp-array-name w_exp \
		--num-lanes $(MX_NUM_LANES) \
		--block-size $(MX_BLOCK_SIZE) \
		--pack-fp8 \
		--exp-format compact-32bit

mx-headers: $(X_MX_H) $(W_MX_H) $(X_EXP_MX_H) $(W_EXP_MX_H) $(GOLDEN_MX_H)
	@echo "[MX] MX-encoded headers are up to date"

# Generate instructions and data stimuli
# Only generate MX headers when MX_ENABLE=1
ifeq ($(MX_ENABLE),1)
sw-build: mx-headers $(STIM_INSTR) $(STIM_DATA) $(STACK_INIT) dis
else
sw-build: $(STIM_INSTR) $(STIM_DATA) $(STACK_INIT) dis
endif

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

synth-ips:
	$(Bender) update
	$(Bender) script synopsys      \
	$(common_targs) $(common_defs) \
	$(synth_targs) $(synth_defs)   \
	> ${compile_script_synth}

sw-clean:
	rm -rf $(BUILD_DIR)
	rm -f $(X_MX_H) $(W_MX_H) $(X_EXP_MX_H) $(W_EXP_MX_H) $(GOLDEN_MX_H)

dis:
	$(OBJDUMP) -d $(BIN) > $(DUMP)

OP     ?= gemm
fp_fmt ?= FP16
M      ?= 12
N      ?= 16
K      ?= 16

golden: golden-clean
	$(MAKE) -C golden-model $(OP) SW=$(SW)/inc M=$(M) N=$(N) K=$(K) fp_fmt=$(fp_fmt)

golden-clean:
	$(MAKE) -C golden-model golden-clean

clean-all: sw-clean
	rm -rf $(RootDir).bender
	rm -rf $(compile_script)

sw-all: sw-clean sw-build

# Install tools
CXX ?= g++
NumCores := $(shell nproc)
NumCoresHalf := $(shell echo "$$(($(NumCores) / 2))")
VendorDir ?= $(RootDir)vendor
InstallDir ?= $(VendorDir)/install
# Verilator
VerilatorVersion ?= v5.028
VerilatorInstallDir := $(InstallDir)/verilator
# GCC
GccInstallDir := $(InstallDir)/riscv
RiscvTarDir := riscv.tar.gz
GccUrl := https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2024.08.28/riscv32-elf-ubuntu-20.04-gcc-nightly-2024.08.28-nightly.tar.gz
# Bender
RustupInit := $(ScriptsDir)/rustup-init.sh
CargoInstallDir := $(InstallDir)/cargo
RustupInstallDir := $(InstallDir)/rustup
Cargo := $(CargoInstallDir)/bin/cargo

verilator: $(InstallDir)/bin/verilator

$(InstallDir)/bin/verilator:
	rm -rf $(VendorDir)/verilator
	mkdir -p $(VendorDir) && cd $(VendorDir) && git clone https://github.com/verilator/verilator.git
	# Checkout the right version
	cd $(VendorDir)/verilator && git reset --hard && git fetch && git checkout $(VerilatorVersion)
	# Compile verilator
	sudo apt install libfl-dev help2man
	mkdir -p $(VerilatorInstallDir) && cd $(VendorDir)/verilator && git clean -xfdf && autoconf && \
	./configure --prefix=$(VerilatorInstallDir) CXX=$(CXX) && make -j$(NumCoresHalf)  && make install

riscv32-gcc: $(GccInstallDir)

$(GccInstallDir):
	rm -rf $(GccInstallDir) $(VendorDir)/$(RiscvTarDir)
	mkdir -p $(InstallDir)
	cd $(VendorDir) && \
	wget $(GccUrl) -O $(RiscvTarDir) && \
	tar -xzvf $(RiscvTarDir) -C $(InstallDir) riscv

bender: $(CargoInstallDir)/bin/bender

$(CargoInstallDir)/bin/bender:
	curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf > $(RustupInit)
	mkdir -p $(InstallDir)
	export CARGO_HOME=$(CargoInstallDir) && export RUSTUP_HOME=$(RustupInstallDir) && \
	chmod +x $(RustupInit); source $(RustupInit) -y && \
	$(Cargo) install bender
	rm -rf $(RustupInit)

tools: bender riscv32-gcc
