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
			$(RTL)/keyboard.v $(RTL)/rom.v $(RTL)/ramcard.v
ROMS := $(RTL)/roms/apple2e.hex $(RTL)/roms/video2.hex

.PHONY: all run coordinator manager ram hotkeys ui gui clean
all: $(EXE)

COORDOUT := $(OUT)/coord_obj_dir
COORDEXE := $(COORDOUT)/Vtb_ss_regs.exe

coordinator: $(COORDEXE)

MANAGEROUT := $(OUT)/manager_obj_dir
MANAGEREXE := $(MANAGEROUT)/Vtb_ss_manager.exe

manager: $(MANAGEREXE)

RAMOUT := $(OUT)/ram_obj_dir
RAMEXE := $(RAMOUT)/Vtb_ss_ram.exe

ram: $(RAMEXE)

HOTKEYOUT := $(OUT)/hotkey_obj_dir
HOTKEYEXE := $(HOTKEYOUT)/Vtb_savestate_hotkeys.exe

hotkeys: $(HOTKEYEXE)

UIOUT := $(OUT)/ui_obj_dir
UIEXE := $(UIOUT)/Vtb_savestate_ui.exe

ui: $(UIEXE)

GUIOUT := $(OUT)/gui_obj_dir
GUIEXE := $(GUIOUT)/Vtb_l1b_gui.exe
GUI_SRC := gui/main_gui_l1b.cpp \
	gui/imgui/imgui.cpp gui/imgui/imgui_draw.cpp gui/imgui/imgui_tables.cpp \
	gui/imgui/imgui_widgets.cpp gui/imgui/backends/imgui_impl_sdl2.cpp \
	gui/imgui/backends/imgui_impl_opengl3.cpp
SDL_INC ?= C:/msys64/ucrt64/include/SDL2
GUI_CFLAGS := -I$(LEVELDIR)/gui/imgui -I$(LEVELDIR)/gui/imgui/backends -I$(SDL_INC)
GUI_LDFLAGS := -lSDL2 -lopengl32

gui: $(GUIEXE)

$(EXE): tb_cpu_ss.sv main_cpu_ss.cpp $(MACH_SRC) $(CPU_SRC) $(ROMS)
	@mkdir -p $(OUT)/obj_dir
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe -O3 --x-assign fast --x-initial fast -public --trace \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_cpu_ss \
		-Mdir $(OUT)/obj_dir main_cpu_ss.cpp tb_cpu_ss.sv $(MACH_SRC) $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(OUT)/obj_dir -f Vtb_cpu_ss.mk
	@echo "built $@"

run: all
	$(EXE) +cpu=0
	$(EXE) +cpu=1

$(COORDEXE): tb_ss_regs.sv savestate_regs_l1b.sv
	@mkdir -p $(COORDOUT)
	VERILATOR_ROOT=$(VROOT) $(V) --binary --timing -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_ss_regs \
		-Mdir $(COORDOUT) tb_ss_regs.sv savestate_regs_l1b.sv
	@echo "built $@"

$(MANAGEREXE): tb_ss_manager.sv savestate_manager_l1b.sv
	@mkdir -p $(MANAGEROUT)
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing --exe --main -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_ss_manager \
		-Mdir $(MANAGEROUT) tb_ss_manager.sv savestate_manager_l1b.sv
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(MANAGEROUT) -f Vtb_ss_manager.mk
	@echo "built $@"

$(RAMEXE): tb_ss_ram.sv savestate_ram_l1b.sv
	@mkdir -p $(RAMOUT)
	VERILATOR_ROOT=$(VROOT) $(V) --binary --timing -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_ss_ram \
		-Mdir $(RAMOUT) tb_ss_ram.sv savestate_ram_l1b.sv
	@echo "built $@"

$(HOTKEYEXE): tb_savestate_hotkeys.sv $(RTL)/savestate_hotkeys.sv
	@mkdir -p $(HOTKEYOUT)
	VERILATOR_ROOT=$(VROOT) $(V) --binary --timing -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_savestate_hotkeys \
		-Mdir $(HOTKEYOUT) tb_savestate_hotkeys.sv $(RTL)/savestate_hotkeys.sv
	@echo "built $@"

$(UIEXE): tb_savestate_ui.sv savestate_ui.sv
	@mkdir -p $(UIOUT)
	VERILATOR_ROOT=$(VROOT) $(V) --binary --timing -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_savestate_ui \
		-Mdir $(UIOUT) tb_savestate_ui.sv savestate_ui.sv
	@echo "built $@"

$(GUIEXE): tb_l1b_gui.sv $(GUI_SRC) $(MACH_SRC) $(CPU_SRC)
	@mkdir -p $(GUIOUT)
	VERILATOR_ROOT=$(VROOT) $(V) --cc --timing -exe -O3 --x-assign fast --x-initial fast -public --trace \
		-Wno-fatal -Wno-TIMESCALEMOD --top-module tb_l1b_gui \
		-CFLAGS "$(GUI_CFLAGS)" -LDFLAGS "$(GUI_LDFLAGS)" \
		-Mdir $(GUIOUT) $(GUI_SRC) tb_l1b_gui.sv $(MACH_SRC) $(CPU_SRC)
	VERILATOR_ROOT=$(VROOT) $(MAKE) -C $(GUIOUT) -f Vtb_l1b_gui.mk
	@echo "built $@"

clean:
	rm -rf $(OUT)
