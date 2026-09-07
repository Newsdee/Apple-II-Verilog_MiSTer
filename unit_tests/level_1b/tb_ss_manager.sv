`timescale 1ns / 1ps

module tb_ss_manager;
  reg clk = 1'b0;
  always #1 clk = ~clk;

  reg reset = 1'b1;
  reg request_save = 1'b0;
  reg request_load = 1'b0;
  reg cpu_type = 1'b0;
  reg cpu_frozen = 1'b0;
  wire stall, machine_ce, busy, done, error, locked_cpu_type;
  wire [9:0] ss_addr;
  wire [63:0] ss_wdata;
  wire ss_wren;
  reg [63:0] live_regs [0:10];
  wire [63:0] ss_rdata = live_regs[ss_addr[3:0]];
  wire ram_bank, ram_rd, ram_wr;
  wire [15:0] ram_addr;
  wire [7:0] ram_wdata;
  reg [7:0] ram_rdata;
  reg [7:0] memory [0:131071];
  wire [14:0] slot_addr;
  wire slot_rd, slot_wr;
  wire [63:0] slot_wdata;
  reg [63:0] slot_rdata;
  reg slot_ready = 1'b0;
  reg [63:0] slots [0:16415];
  reg pending = 1'b0;
  reg cooldown = 1'b0;
  reg pending_read = 1'b0;
  reg [14:0] pending_addr;
  reg [63:0] pending_wdata;
  reg [2:0] delay_count;
  reg [7:0] lfsr = 8'h5A;
  integer index;
  integer errors = 0;
  integer slot_reads = 0;
  integer slot_writes = 0;
  integer ram_writes = 0;
  integer reg_writes = 0;
  reg saw_register_restore_early = 1'b0;
  reg completion_error = 1'b0;

  savestate_manager_l1b dut (
    .clk(clk), .reset(reset), .request_save(request_save), .request_load(request_load),
    .cpu_type(cpu_type), .cpu_frozen(cpu_frozen), .stall(stall),
    .machine_ce(machine_ce), .busy(busy), .done(done), .error(error),
    .locked_cpu_type(locked_cpu_type), .ss_addr(ss_addr), .ss_wdata(ss_wdata),
    .ss_wren(ss_wren), .ss_rdata(ss_rdata), .ram_bank(ram_bank),
    .ram_addr(ram_addr), .ram_rd(ram_rd), .ram_wr(ram_wr),
    .ram_wdata(ram_wdata), .ram_rdata(ram_rdata), .slot_addr(slot_addr),
    .slot_rd(slot_rd), .slot_wr(slot_wr), .slot_wdata(slot_wdata),
    .slot_rdata(slot_rdata), .slot_ready(slot_ready)
  );

  always @(posedge clk) begin
    if (done)
      completion_error <= error;
    cpu_frozen <= stall;
    ram_rdata <= memory[{ram_bank, ram_addr}];
    slot_ready <= 1'b0;
    lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

    if (cooldown) begin
      cooldown <= 1'b0;
    end else if (!pending && (slot_rd || slot_wr)) begin
      pending <= 1'b1;
      pending_read <= slot_rd;
      pending_addr <= slot_addr;
      pending_wdata <= slot_wdata;
      delay_count <= {1'b0, lfsr[1:0]};
    end else if (pending) begin
      if (delay_count != 0) begin
        delay_count <= delay_count - 1'b1;
      end else begin
        pending <= 1'b0;
        cooldown <= 1'b1;
        slot_ready <= 1'b1;
        if (pending_read) begin
          slot_rdata <= slots[pending_addr];
          slot_reads <= slot_reads + 1;
        end else begin
          slots[pending_addr] <= pending_wdata;
          slot_writes <= slot_writes + 1;
        end
      end
    end

    if (ram_wr) begin
      memory[{ram_bank, ram_addr}] <= ram_wdata;
      ram_writes <= ram_writes + 1;
    end
    if (ss_wren) begin
      live_regs[ss_addr[3:0]] <= ss_wdata;
      reg_writes <= reg_writes + 1;
      if (ram_writes != 131072)
        saw_register_restore_early <= 1'b1;
    end
  end

  task pulse_save;
    begin
      completion_error = 1'b0;
      @(negedge clk); request_save = 1'b1;
      @(negedge clk); request_save = 1'b0;
    end
  endtask

  task pulse_load;
    begin
      completion_error = 1'b0;
      @(negedge clk); request_load = 1'b1;
      @(negedge clk); request_load = 1'b0;
    end
  endtask

  task wait_done;
    integer timeout;
    begin
      timeout = 0;
      while (!done && timeout < 1500000) begin
        @(posedge clk);
        timeout = timeout + 1;
      end
      if (!done) begin
        $display("ERROR: manager timeout");
        errors = errors + 1;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    for (index = 0; index < 11; index = index + 1)
      live_regs[index] = 64'h1000000000000000 + {32'd0, index[31:0]};
    for (index = 0; index < 131072; index = index + 1)
      memory[index] = index[7:0] ^ index[15:8] ^ {7'd0, index[16]};
    for (index = 0; index < 16416; index = index + 1)
      slots[index] = 64'd0;
    ram_rdata = 8'd0;
    slot_rdata = 64'd0;

    repeat (3) @(posedge clk);
    reset = 1'b0;
    pulse_save();
    wait_done();

    if (completion_error || slot_writes != 16411) begin
      $display("ERROR: save status/error count writes=%0d error=%0b", slot_writes, completion_error);
      errors = errors + 1;
    end
    if (slots[0] !== 64'h41324C3101004020 || slots[1] !== 64'h0000000100010100) begin
      $display("ERROR: header words %016h %016h", slots[0], slots[1]);
      errors = errors + 1;
    end
    for (index = 0; index < 11; index = index + 1)
      if (slots[16 + index] !== (64'h1000000000000000 + {32'd0, index[31:0]})) errors = errors + 1;
    if (slots[32] !== 64'h0706050403020100 || slots[16415] !== 64'h0100030205040706) begin
      $display("ERROR: RAM boundary words %016h %016h", slots[32], slots[16415]);
      errors = errors + 1;
    end

    for (index = 0; index < 11; index = index + 1) live_regs[index] = 64'd0;
    for (index = 0; index < 131072; index = index + 1) memory[index] = 8'd0;
    slot_reads = 0;
    ram_writes = 0;
    reg_writes = 0;
    saw_register_restore_early = 1'b0;
    pulse_load();
    wait_done();

    if (completion_error || slot_reads != 16397 || ram_writes != 131072 || reg_writes != 11) begin
      $display("ERROR: load counts reads=%0d ram=%0d regs=%0d error=%0b",
               slot_reads, ram_writes, reg_writes, completion_error);
      errors = errors + 1;
    end
    if (saw_register_restore_early) begin
      $display("ERROR: registers restored before RAM completed");
      errors = errors + 1;
    end
    for (index = 0; index < 11; index = index + 1)
      if (live_regs[index] !== (64'h1000000000000000 + {32'd0, index[31:0]})) errors = errors + 1;
    for (index = 0; index < 131072; index = index + 1)
      if (memory[index] !== (index[7:0] ^ index[15:8] ^ {7'd0, index[16]})) begin
        if (errors < 4) $display("ERROR: RAM[%0d]=%02h", index, memory[index]);
        errors = errors + 1;
      end

    slots[0] = 64'd0;
    slot_reads = 0;
    ram_writes = 0;
    reg_writes = 0;
    pulse_load();
    wait_done();
    if (!completion_error || slot_reads != 2 || ram_writes != 0 || reg_writes != 0) begin
      $display("ERROR: invalid header rejection error=%0b reads=%0d ram=%0d regs=%0d",
               completion_error, slot_reads, ram_writes, reg_writes);
      errors = errors + 1;
    end

    slots[0] = 64'h41324C3101004020;
    slots[1][0] = 1'b1;
    slot_reads = 0;
    ram_writes = 0;
    reg_writes = 0;
    pulse_load();
    wait_done();
    if (!completion_error || slot_reads != 2 || ram_writes != 0 || reg_writes != 0) begin
      $display("ERROR: CPU mismatch rejection error=%0b reads=%0d ram=%0d regs=%0d",
               completion_error, slot_reads, ram_writes, reg_writes);
      errors = errors + 1;
    end

    if (errors == 0)
      $display("L1B MANAGER PASS save_writes=16411 load_reads=16397 ram_bytes=131072");
    else
      $display("L1B MANAGER FAIL errors=%0d", errors);
    $finish;
  end
endmodule