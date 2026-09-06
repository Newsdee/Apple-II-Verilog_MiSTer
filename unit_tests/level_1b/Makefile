LEVELDIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO := $(abspath $(LEVELDIR)/../..)
RTL := $(REPO)/rtl
V ?= verilator_bin
VROOT ?= /c/msys64/ucrt64/share/verilator
OUT := $(LEVELDIR)/build
EXE := $(OUT)/obj_dir/Vtb_cpu_ss.exe

CPU_SRC := $(RTL)/cpu/nmos6502/cpu_65c02.sv $(RTL)/cpu/nmos6502/cpu_alu.sv \
           $(RTL)/cpu/wdc65c02/cpu_65c02.sv $(RTL)/cpu/wdc65c02/cpu_alu.sv
MACH_SRC := $(RTL)/apple2.v $(RTL)/timing_generator.v $(RTL)/video_generator.v \
            $(RTL)/rom.v $(RTL)/ramcard.v
ROMS := $(RTL)/roms/apple2e.hex $(RTL)/roms/video2.hex

.PHONY: all run clean
all: $(EXE)

$(EXE): tb_cpu_ss.sv main_cpu_ss.cpp $(MACH_SRC) $(CPU_SRC) $(ROMS)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_cpu_ss \
		-Mdir $(OUT)/obj_dir main_cpu_ss.cpp tb_cpu_ss.sv $(MACH_SRC) $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(OUT)/obj_dir -f Vtb_cpu_ss.mk
	@echo "built $@"

run: all
	$(EXE) +cpu=0
	$(EXE) +cpu=1

clean:
	rm -rf $(OUT)
