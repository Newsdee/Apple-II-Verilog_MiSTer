# Standalone VGA color tester build.
#
# Verilates only the VGA controller and its pass-through top, then links the
# local C++ harness (which provides main) plus the ImGui/SDL2 GUI. No
# full-machine sources, no Quartus files.
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

# ImGui + SDL2 (Phase 3). ImGui is reused from the full harness via relative
# path (not copied). SDL2 flags follow the full harness's MinGW branch:
# -DSDL_MAIN_HANDLED keeps our own main() as the entry point (console app).
# Absolute: Verilator's generated .mk compiles from inside obj_dir/.
IMGUI_DIR  := $(abspath ../verilator/sim/imgui)
IMGUI_SRCS := $(IMGUI_DIR)/imgui.cpp \
              $(IMGUI_DIR)/imgui_draw.cpp \
              $(IMGUI_DIR)/imgui_tables.cpp \
              $(IMGUI_DIR)/imgui_widgets.cpp \
              $(IMGUI_DIR)/imgui_impl_sdl.cpp \
              $(IMGUI_DIR)/imgui_impl_opengl2.cpp

SDL2_PREFIX := $(shell sdl2-config --prefix 2>/dev/null)
ifneq ($(SDL2_PREFIX),)
GUI_SRCS    := $(IMGUI_SRCS)
GUI_CFLAGS  := -I$(IMGUI_DIR) -I$(SDL2_PREFIX)/include/SDL2 -DSDL_MAIN_HANDLED
GUI_LIBS    := -lgdi32 -lopengl32 -limm32 -lSDL2
else
GUI_SRCS    :=
GUI_CFLAGS  :=
GUI_LIBS    :=
$(warning sdl2-config not found in PATH - building headless only)
endif

# $(CURDIR) is expanded at rule-parse time so the absolute path survives the
# `cd obj_dir` that Verilator's generated .mk performs.
CFLAGS_APP := -O2 -Isrc -I$(CURDIR) $(GUI_CFLAGS)
LDFLAGS_APP := $(GUI_LIBS)

VOUT := $(OBJDIR)/V$(TOP).cpp

all: $(EXE)

$(VOUT): $(RTL_SRCS) $(CPP_SRCS) $(GUI_SRCS) Makefile
	$(V) -cc -exe --timing -Wno-fatal --top-module $(TOP) --Mdir $(OBJDIR) \
	    -CFLAGS "$(CFLAGS_APP)" -LDFLAGS "$(LDFLAGS_APP)" \
	    $(CPP_SRCS) $(GUI_SRCS) $(RTL_SRCS)

$(EXE): $(VOUT)
	cd $(OBJDIR) && $(MAKE) -f V$(TOP).mk

run: $(EXE)
	./$(EXE) $(RUN_ARGS)

clean:
	rm -rf $(OBJDIR)

.PHONY: all run clean
