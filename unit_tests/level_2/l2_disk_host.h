// ============================================================================
// unit_tests/level_2/l2_disk_host.h
//
// level_2 shared host-side block device (PLAN.md v6, "Block-device protocol
// repair").  Replaces the old read-only, single-disk DiskHost.
//
//   * two drive channels: ch0 = ft1 (drive 1), ch1 = ft2 (drive 2)
//   * each channel binds its own .nib image through the shared BlkDevEngine
//     (verilator/sim/sim_blkdev_engine.h - the same engine the full Vemu
//     machine and the module-level floppy_track test use)
//   * the img_* notification latch mirrors sim.v / Apple-II.sv exactly:
//     on the one-cycle img_mounted pulse ->
//        disk_mount[ch]   = (img_size != 0)
//        disk_change[ch] ^= 1            (persistent bit; the RTL resyncs
//                                         on either polarity)
//        disk_protect[ch] = img_readonly (machine-side WP for drive_ii;
//                                         the engine ALSO refuses host-side
//                                         writes to RO images with no ack)
//   * reads past EOF return zeros; writes to unbound/RO/over-size images
//     are rejected loudly and held until reset (machine-visible)
//   * a boot gate (2000 cycles after reset release, Vemu parity) holds the
//     engine so a queued mount pulse is never emitted under reset
//
// Both the headless harness (main_l2.cpp) and the GUI harness
// (gui/main_gui.cpp) use this class.
//
// The including translation unit MUST include the generated "Vtb_l2.h"
// (with its obj_dir include path) BEFORE this header: tick() dereferences
// the Vtb_l2* (top->rootp -> tb_l2__DOT__h_* signals).
// ============================================================================
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sim_blkdev_engine.h"

class Vtb_l2;   // defined by the generated header the includer includes first

class L2DiskHost {
public:
    // cycles of engine hold after reset release before the first tick
    // (Vemu SimBlockDevice parity: kBootGate = 2000)
    static const int BOOT_GATE_CYCLES = 2000;

    explicit L2DiskHost(int latency = BlkDevEngine::kDefaultLatency)
        : eng_(2, latency) {
        m_mount_ = 0;
        m_change_ = 0;
        m_protect_ = 0;
        gate_ = BOOT_GATE_CYCLES;
    }

    // Queue a mount/replace for a drive (emits one img_mounted pulse on a
    // later tick).  readonly=false tries a writable open and falls back to
    // read-only (reported as img_readonly=1, machine WP set).
    bool mountDrive(int drive, const char *path, bool readonly = false) {
        if (drive < 0 || drive > 1) {
            std::fprintf(stderr, "[l2host] ERROR: drive %d out of range (0..1)\n", drive);
            return false;
        }
        const bool ok = eng_.mountFile(drive, path, readonly);
        if (ok) {
            path_[drive] = path;
            imgValid_[drive] = true;
        }
        return ok;
    }

    void ejectDrive(int drive) {
        if (drive < 0 || drive > 1) {
            std::fprintf(stderr, "[l2host] ERROR: eject drive %d out of range (0..1)\n", drive);
            return;
        }
        eng_.eject(drive);
        path_[drive].clear();
        imgValid_[drive] = false;
    }

    // ---- image oracle access (for the post-run dpram-vs-.nib compare; the
    // engine itself reads through its own fd, this is a fresh on-demand read
    // so it reflects any writes persisted since the mount)
    bool imageLoaded(int drive) const { return imgValid_[drive]; }
    const char *imagePath(int drive) const { return path_[drive].c_str(); }

    std::vector<uint8_t> readImageBytes(int drive) const {
        std::vector<uint8_t> v;
        if (drive < 0 || drive > 1) return v;
        std::FILE *f = std::fopen(path_[drive].c_str(), "rb");
        if (!f) return v;
        if (std::fseek(f, 0, SEEK_END) != 0) {
            std::fclose(f);
            return v;
        }
        const long sz = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);
        v.resize((size_t)(sz > 0 ? sz : 0));
        if (!v.empty() && std::fread(v.data(), 1, v.size(), f) != v.size())
            v.clear();
        std::fclose(f);
        return v;
    }

    // One call per rising clk_14m edge, BEFORE top->eval() (same contract
    // as the old DiskHost::beforeEval and the Vemu BeforeEval).
    void tick(Vtb_l2 *top) {
        auto *r = top->rootp;

        // ---- idle host defaults (the engine re-asserts what it needs) ----
        top->sd_ack     = 0x00;
        top->sd_buff_wr = 0x00;

        // ---- boot gate: hold the engine while the DUT is in reset and for
        // BOOT_GATE_CYCLES after release (a queued mount pulse must not fire
        // under reset)
        if (r->tb_l2__DOT__reset_sync) {
            gate_ = BOOT_GATE_CYCLES;
            driveLevels(top);
            return;
        }
        if (gate_ > 0) {
            gate_--;
            driveLevels(top);
            return;
        }

        // ---- sample the DUT request state (TB one-cycle-registered
        // snapshots of the per-drive sd_* signals) ----
        lba_[0]  = r->tb_l2__DOT__h_sd_lba_a;
        lba_[1]  = r->tb_l2__DOT__h_sd_lba_b;
        rd_[0]   = (r->tb_l2__DOT__h_sd_rd & 0x1) != 0;
        rd_[1]   = (r->tb_l2__DOT__h_sd_rd & 0x2) != 0;
        wr_[0]   = (r->tb_l2__DOT__h_sd_wr & 0x1) != 0;
        wr_[1]   = (r->tb_l2__DOT__h_sd_wr & 0x2) != 0;
        din_[0]  = (uint8_t)(r->tb_l2__DOT__h_sd_buff_din_a & 0xFF);
        din_[1]  = (uint8_t)(r->tb_l2__DOT__h_sd_buff_din_b & 0xFF);
        in_.lba         = lba_;
        in_.sd_rd       = rd_;
        in_.sd_wr       = wr_;
        in_.sd_buff_din = din_;
        in_.reset          = false;   // reset_sync released above

        ack_[0] = ack_[1] = false;
        addr_ = dout_ = 0;
        bw_ = false;
        mnt_ = 0;
        mro_ = false;
        sz_ = 0;

        out_.sd_ack       = ack_;
        out_.sd_buff_addr = &addr_;
        out_.sd_buff_dout = &dout_;
        out_.sd_buff_wr   = &bw_;
        out_.img_mounted  = &mnt_;
        out_.img_readonly = &mro_;
        out_.img_size     = &sz_;

        eng_.tick(in_, out_);

        // ---- wrapper: latch the notification exactly like sim.v /
        // Apple-II.sv (one channel per pulse) ----
        if (mnt_) {
            const int ch = (mnt_ & 0x1) ? 0 : 1;
            const uint32_t bit = 1u << ch;
            m_mount_   = (m_mount_   & ~bit) | ((sz_ != 0) ? bit : 0u);
            m_change_ ^= bit;
            m_protect_ = (m_protect_ & ~bit) | ((mro_ ? 1u : 0u) << ch);
            std::fprintf(stderr, "[l2host] drive %d: %s (size=%llu readonly=%d)\n",
                         ch + 1, m_mount_ & bit ? "mounted" : "ejected",
                         (unsigned long long)sz_, (int)mro_);
        }

        // ---- drive the host outputs ----
        top->sd_ack       = (ack_[0] ? 0x1u : 0x0u) | (ack_[1] ? 0x2u : 0x0u);
        top->sd_buff_addr = addr_;
        top->sd_buff_dout = dout_;
        top->sd_buff_wr   = bw_ ? 1 : 0;
        driveLevels(top);
    }

    // ---- diagnostics ----
    BlkDevEngine &engine() { return eng_; }

    // one-line summary for the harness pass/fail reports
    void printStats(const char *tag) {
        const BlkDevEngine &e = eng_;
        std::fprintf(stderr,
                     "%s HOST: readSectors=%llu writeSectors=%llu failedWrites=%llu "
                     "eofBytes=%llu maxLba=%u active=%d\n",
                     tag,
                     (unsigned long long)e.readSectors(),
                     (unsigned long long)e.writeSectors(),
                     (unsigned long long)e.failedWrites(),
                     (unsigned long long)e.eofBytes(),
                     (unsigned)e.maxLba(),
                     e.activeChannel());
    }

private:
    void driveLevels(Vtb_l2 *top) {
        top->disk_mount   = m_mount_;
        top->disk_change  = m_change_;
        top->disk_protect = m_protect_;
    }

    BlkDevEngine eng_;

    // wrapper-latched media levels (2-bit, bit 0 = drive 1)
    uint32_t m_mount_;
    uint32_t m_change_;
    uint32_t m_protect_;

    // boot gate countdown
    int gate_;

    // per-tick engine scratch
    BlkDevEngine::In  in_;
    BlkDevEngine::Out out_;
    // In-pointer backing storage (In holds const pointers)
    uint32_t lba_[2];
    bool     rd_[2];
    bool     wr_[2];
    uint8_t  din_[2];
    bool     ack_[2];
    uint32_t addr_;
    uint8_t  dout_;
    bool     bw_;
    uint32_t mnt_;
    bool     mro_;
    uint64_t sz_;

    // image oracle bookkeeping
    std::string path_[2];
    bool        imgValid_[2] = { false, false };
};
