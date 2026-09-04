V = verilator
COSIM = n

TOP = --top-module emu
RTL = ../rtl
OSK_DIR ?= $(RTL)/osk
V_INC = +incdir+$(RTL) 

#V_DEFINE = +define+debug=1 +define+SIMULATION=1 -CFLAGS "-I../sim/imgui -I../sim/vinc -I../sim/ -O3"  --timescale-override 1ps/1ps -Wno-TIMESCALEMOD  \
	-I../rtl \
	-I../rtl/tv80
V_DEFINE = +define+debug=1 +define+SIMULATION=1 -CFLAGS "-I../sim/imgui -I../sim/ -O3 -march=native -mtune=native"  --timescale-override 1ps/1ps -Wno-TIMESCALEMOD  \
	-I../rtl \
	-I../rtl/mouse/jt6805
#V_DEFINE = +define+debug=1 +define+SIMULATION=1 -CFLAGS "-g -I../sim/imgui -I../sim/vinc -I../sim/"  --timescale-override 1ps/1ps -Wno-TIMESCALEMOD  \
	-I../rtl \
	-I../rtl/tv80

#V_DEFINE += --converge-limit 2000 -Wno-WIDTH -Wno-IMPLICIT -Wno-MODDUP -Wno-UNSIGNED -Wno-CASEINCOMPLETE -Wno-CASEX -Wno-SYMRSVDWORD -Wno-COMBDLY -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-SELRANGE -Wno-CMPCONST -Wno-CASEOVERLAP -Wno-PINMISSING -Wno-MULTIDRIVEN
#V_DEFINE += --threads 8  # this slows it way down

# SIM_FAST=1: stub the slot peripherals (mockingboard x2, mouse x2,
# superserial, clock card, hdd) with tie-offs for faster interactive sim.
# SIM_FAST_HDD=1: same as SIM_FAST=1 but keeps the HDD (e.g. Total Replay).
# Default 0 = full machine. Switching requires a clean (handled by
# build_verilator_manual.sh).
SIM_FAST ?= 0
SIM_FAST_HDD ?= 0
ifeq ($(SIM_FAST_HDD),1)
V_DEFINE += +define+SIM_FAST +define+SIM_FAST_HDD
else
ifeq ($(SIM_FAST),1)
V_DEFINE += +define+SIM_FAST
endif
endif

# JOY_TO_KEY: enable the joystick->keystroke feature (rtl/osk/joy_to_key.v).
# 1 = on (default for testing), 0 = off (feature fully inert / bit-identical).
JOY_TO_KEY ?= 1
ifeq ($(JOY_TO_KEY),1)
V_DEFINE += +define+JOY_TO_KEY
endif

V_DEFINE +=

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin) #APPLE
	ECHO_MESSAGE = "Mac OS X"
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CXXFLAGS += -I/usr/local/include -I/opt/local/include 
	CFLAGS = $(CXXFLAGS) -Iimgui
endif

ifeq ($(UNAME_S), Linux) #LINUX
	ECHO_MESSAGE = "Linux"
	LIBS += -lGL -ldl `sdl2-config --libs`

	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif

ifneq ($(filter MINGW% MSYS%,$(UNAME_S)),)
	ECHO_MESSAGE = "MinGW"
	LIBS += -lgdi32 -lopengl32 -limm32 -lSDL2

	CXXFLAGS += -I`/ucrt64/bin/sdl2-config --prefix`/include/SDL2 -DSDL_MAIN_HANDLED
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS += $(CC_OPT) $(CC_DEFINE)
LDFLAGS = $(LIBS)
EXE = ./obj_dir/Vemu
V_OPT = -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal
CC_OPT = -O3

V_SRC = \
        sim.v \
		$(RTL)/bram.sv \
		$(RTL)/dpram.v \
		$(RTL)/joystick_input.sv \
		$(RTL)/drive_status_overlay.sv \
		$(RTL)/floppy_sound.sv \
		$(RTL)/ramcard.v \
		$(RTL)/rom.v \
		$(RTL)/timing_generator.v \
		$(RTL)/video_generator.v \
		$(RTL)/super_serial_card.v  \
		$(RTL)/t65/t65_alu.v  $(RTL)/t65/t65_mcode.v  $(RTL)/t65/t65_pack.v  $(RTL)/t65/t65.v \
		$(RTL)/hdd.v \
		$(RTL)/uart_6551.v \
		$(RTL)/6551tx.v \
		$(RTL)/6551rx.v \
		$(RTL)/cpu_65c02.sv  $(RTL)/cpu_alu.sv \
		$(RTL)/vga_controller.v  \
		$(RTL)/apple2_font_rom.v  \
		$(OSK_DIR)/virtual_keyboard_controller.sv  \
		$(OSK_DIR)/virtual_keyboard_overlay.sv  \
		$(RTL)/mockingboard/mockingboard.v  \
		$(RTL)/mockingboard/via6522.v  \
		$(RTL)/mockingboard/YM2149.sv  \
		$(RTL)/disk_ii.v  \
		$(RTL)/drive_ii.v  \
		$(RTL)/mouse/pia6821.v  \
		$(RTL)/mouse/applemouse.v  \
		$(RTL)/mouse/applemouse_rom.v  \
		$(RTL)/mouse/applemouse_mcu_rom.v  \
		$(RTL)/mouse/jt6805/jt6805.v  \
		$(RTL)/mouse/jt6805/jt6805_alu.v  \
		$(RTL)/mouse/jt6805/jt6805_ctrl.v  \
		$(RTL)/mouse/jt6805/jt6805_regs.v  \
		$(RTL)/mouse/jt6805/jtframe_6805mcu.v  \
		$(RTL)/floppy_track.sv  \
		$(RTL)/nsc_ticker.sv  \
		$(RTL)/no_slot_clock.sv  \
		$(RTL)/apple2_top.v  \
		$(RTL)/apple2.v  \
		$(RTL)/keyboard.v  \
		$(RTL)/osk/joy_to_key.v 


C_SRC = \
	sim_main.cpp  \
	sim/sim_bus.cpp sim/sim_blkdevice.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp sim/sim_input.cpp sim/sim_audio.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp sim/imgui/ImGuiFileDialog.cpp sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

all: $(EXE)

$(VOUT): $(V_SRC)  Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS) " -exe  --Mdir ./obj_dir $(V_DEFINE) $(V_INC) $(TOP) -CFLAGS "$(CFLAGS)" $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
#	(cd obj_dir; make OPT="-fauto-inc-dec -fdce -fdefer-pop -fdse -ftree-ccp -ftree-ch -ftree-fre -ftree-dce -ftree-dse" -f Vemu.mk)
	(cd obj_dir; make -f Vemu.mk)

fast:
	(cd obj_dir; rm -f *.o ; make OPT="-fcompare-elim -fcprop-registers -fguess-branch-probability -fauto-inc-dec -fif-conversion2 -fif-conversion -fipa-pure-const -fdce -fipa-profile -fipa-reference -fmerge-constants -fsplit-wide-types -fdefer-pop -fdse -ftree-ccp -ftree-ch -ftree-fre -ftree-dce -ftree-dse -ftree-builtin-call-dce -ftree-copyrename -ftree-dominator-opts -ftree-forwprop -ftree-phiprop -ftree-sra -ftree-pta -ftree-ter -funit-at-a-time -ftree-bit-ccp -falign-functions  -falign-jumps -falign-loops  -falign-labels -fcaller-saves -fcrossjumping -fcse-follow-jumps -fcse-skip-blocks -fdelete-null-pointer-checks -fdevirtualize -fexpensive-optimizations -fgcse  -fgcse-lm -finline-small-functions -findirect-inlining -fipa-sra -foptimize-sibling-calls -fpartial-inlining -fpeephole2 -fregmove -freorder-blocks  -freorder-functions -frerun-cse-after-loop -fsched-interblock  -fsched-spec -fschedule-insns -fschedule-insns2 -fstrict-aliasing -fstrict-overflow -ftree-switch-conversion -ftree-pre -ftree-vrp" -f Vemu.mk)

clean:
	rm -f obj_dir/*
