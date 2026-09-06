#include "sim_blkdevice.h"
#include <cstdio>

namespace
{
	bool bit(uint32_t v, int i) { return (v >> i) & 1u; }
}

bool SimBlockDevice::MountDisk(const std::string& path, int index)
{
	if (index < 0 || index >= kChannels) {
		std::fprintf(stderr, "[blkdev] ERROR: channel %d out of range (0..%d)\n",
		             index, kChannels - 1);
		return false;
	}
	if (!eng_.mountFile(index, path)) {
		std::fprintf(stderr, "[blkdev] ERROR: mount failed: %s (ch%d)\n", path.c_str(), index);
		return false;
	}
	std::fprintf(stderr, "[blkdev] mounted ch%d: %s (%llu bytes%s)\n",
	             index, path.c_str(),
	             (unsigned long long)eng_.deviceSize(index),
	             eng_.deviceReadonly(index) ? ", readonly" : "");
	return true;
}

void SimBlockDevice::BeforeEval(int cycles)
{
	cycles_ = cycles;

	BlkDevEngine::In in;
	BlkDevEngine::Out out;

	uint32_t lba[kChannels];
	bool rdA[kChannels];
	bool wrA[kChannels];
	bool ackA[kChannels] = { false, false, false };
	uint8_t din[kChannels];
	uint32_t rd = sd_rd ? (uint32_t)*sd_rd : 0u;
	uint32_t wr = sd_wr ? (uint32_t)*sd_wr : 0u;
	for (int i = 0; i < kChannels; i++) {
		lba[i] = sd_lba[i] ? (uint32_t)*sd_lba[i] : 0u;
		rdA[i] = bit(rd, i);
		wrA[i] = bit(wr, i);
		din[i] = sd_buff_din[i] ? (uint8_t)*sd_buff_din[i] : 0;
	}
	in.lba = lba;
	in.sd_rd = rdA;
	in.sd_wr = wrA;
	in.sd_buff_din = din;
	in.reset = ext_reset;

	uint32_t addr = 0, mnt = 0;
	uint8_t dout = 0;
	bool bw = false, mro = false;
	uint64_t sz = 0;
	out.sd_ack = ackA;
	out.sd_buff_addr = &addr;
	out.sd_buff_dout = &dout;
	out.sd_buff_wr = &bw;
	out.img_mounted = &mnt;
	out.img_readonly = &mro;
	out.img_size = &sz;

	if (cycles_ < kBootGate) {
		// Boot gate: the machine is in reset during this window; keep the
		// SD bus idle and defer the queued mount pulses (same policy as
		// the old host).  Outputs below stay at the idle defaults.
	} else {
		eng_.tick(in, out);
	}

	uint32_t ack = 0;
	for (int i = 0; i < kChannels; i++)
		if (ackA[i]) ack |= 1u << i;
	if (sd_ack)       *sd_ack = (SData)ack;
	if (sd_buff_addr) *sd_buff_addr = (SData)addr;  // 9-bit port
	if (sd_buff_dout) *sd_buff_dout = (CData)dout;
	if (sd_buff_wr)   *sd_buff_wr = (CData)(bw ? 1 : 0);
	if (img_mounted)  *img_mounted = (SData)mnt;
	if (img_readonly) *img_readonly = (CData)(mro ? 1 : 0);
	if (img_size)     *img_size = (QData)sz;
}
