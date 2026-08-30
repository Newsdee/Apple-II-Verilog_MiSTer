# Standalone VGA color tester build.
#
# Verilates only the VGA controller and its pass-through top, then links the
# local C++ harness (which provides main). No full-machine sources, no
# Quartus files.
#
#   build.bat            (or: bash build.sh)
#   build.bat clean
#   run.bat [options]

V       ?= verilator
TOP     := vga_color_test_top
OBJDIR  := obj_dir
EXE     := $(OBJDIR)/V$(TOP)

RTL_SRCS := rtl/vga_color_test_top.sv rtl/vga_controller.v
CPP_SRCS := $(wildcard src/*.cpp)

# Phase 3 will add the ImGui sources and SDL2 here.
# $(CURDIR) is expanded at rule-parse time so the absolute path survives the
# `cd obj_dir` that Verilator's generated .mk performs.
CFLAGS_APP := -O2 -Isrc -I$(CURDIR)

VOUT := $(OBJDIR)/V$(TOP).cpp

all: $(EXE)

$(VOUT): $(RTL_SRCS) $(CPP_SRCS) Makefile
	$(V) -cc -exe --timing -Wno-fatal --top-module $(TOP) --Mdir $(OBJDIR) \
	    -CFLAGS "$(CFLAGS_APP)" \
	    $(CPP_SRCS) $(RTL_SRCS)

$(EXE): $(VOUT)
	cd $(OBJDIR) && $(MAKE) -f V$(TOP).mk

run: $(EXE)
	./$(EXE) $(RUN_ARGS)

clean:
	rm -rf $(OBJDIR)

.PHONY: all run clean
