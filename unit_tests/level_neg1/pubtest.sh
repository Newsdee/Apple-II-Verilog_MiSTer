#!/usr/bin/env bash
set -e
export PATH=/c/msys64/ucrt64/bin:$PATH
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
cd /c/msys64/tmp
rm -rf pubtest && mkdir pubtest && cd pubtest
cat > tb_top.sv <<'EOF'
module tb_top;
  reg clk = 0;
  reg [15:0] errors = 0;
  always #5 clk = ~clk;
  initial begin
    #100 errors = errors + 1;
    $finish;
  end
endmodule
EOF
verilator_bin --cc --timing -exe -O3 -Wno-fatal -public --top-module tb_top tb_top.sv 2>&1 | tail -5
echo "--- grep errors in header:"
grep -c 'errors' obj_dir/Vtb_top.h || true
echo "--- help dump: public/flat lines:"
verilator_bin --help 2>&1 | grep -iE 'public|flat' || echo "(none)"
verilator_bin --help -v 2>&1 | grep -iE 'public|flat' || echo "(none in -v)"
