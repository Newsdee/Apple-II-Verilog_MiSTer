#pragma once

#include <string>
#include "verilated.h"
#include "sim_console.h"
#include "sim_blkdev_engine.h"

// Host side of the Apple II floppy/HDD "SD" protocol for the FULL Verilator
// machine: a thin adapter that binds the emu-level datapointers to the
// shared BlkDevEngine (verilator/sim/sim_blkdev_engine.h) - the same
// transaction code the level_2 harnesses run through L2DiskHost.
//
// Three channels, matching sim.v's port bits:
//   0 = floppy drive 1, 1 = HDD, 2 = floppy drive 2
//
// Boot policy (defer the first mount pulses until the machine is out of
// reset) lives here, NOT in the engine.  A single img_mounted pulse is
// emitted per queued mount/replace/eject (the old host held the bit high
// for ~1200 cycles per mount; the sim.v/hdd wrapper latches either way).
class SimBlockDevice
{
public:
	static const int kChannels = 3;
	static const int kBootGate = 2000;   // cycles before the first mount pulse

	explicit SimBlockDevice(DebugConsole& con) : con_(con) {}

	// emu-level ports (sim_main assigns once before the main loop)
	// (widths follow sim.v's emu ports: sd_lba[3] are 32-bit per channel,
	// the packed 10-bit channel words are SData, sd_buff_addr is 9-bit)
	IData* sd_lba[kChannels] = {};
	SData* sd_rd = nullptr;
	SData* sd_wr = nullptr;
	SData* sd_ack = nullptr;
	SData* sd_buff_addr = nullptr;
	CData* sd_buff_dout = nullptr;
	CData* sd_buff_din[kChannels] = {};
	CData* sd_buff_wr = nullptr;
	SData* img_mounted = nullptr;
	CData* img_readonly = nullptr;
	QData* img_size = nullptr;

	// top->reset, sampled per frame by sim_main so the engine can drop an
	// in-flight transaction across a hard reset (protocol test: reset
	// mid-transfer leaves the bus idle).
	bool ext_reset = false;

	bool MountDisk(const std::string& path, int index);
	void BeforeEval(int cycles);
	void AfterEval() {}

	// diagnostics (engine counters)
	uint64_t readSectors()  const { return eng_.readSectors(); }
	uint64_t writeSectors() const { return eng_.writeSectors(); }
	uint64_t failedWrites() const { return eng_.failedWrites(); }
	uint64_t eofBytes()     const { return eng_.eofBytes(); }

private:
	DebugConsole& con_;
	BlkDevEngine eng_{kChannels};
	int cycles_ = 0;
};
