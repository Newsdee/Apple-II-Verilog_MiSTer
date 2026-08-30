#!/usr/bin/perl
use strict; use warnings;
# Parse Verilator dump
my (%P, @E);
open my $fh, '<', 'module_tests/r65c02/build/table_dump.txt' or die $!;
while (<$fh>) {
   if (/^E(\d{3}) ([0-9a-f]+)\s*$/) { $E[$1] = hex($2); }
   elsif (/^P (\S+)\s+([0-9a-fx]+)\s*$/) { my ($n,$v) = ($1,$2); $v =~ s/x/0/g; $P{$n} = hex($v); }
}
close $fh;

# Composite 10-bit aluMode params: name => [4bit part, 3bit part, low3 literal or undef(x->0)]
my %C = (
   aluInp=>['aluModeInp','aluModePss'], aluP=>['aluModeP','aluModePss'],
   aluInc=>['aluModeInc','aluModePss'], aluDec=>['aluModeDec','aluModePss'],
   aluFlg=>['aluModeFlg','aluModePss'], aluBit=>['aluModeBit','aluModeAnd'],
   aluRor=>['aluModeRor','aluModePss'], aluLsr=>['aluModeLsr','aluModePss'],
   aluRol=>['aluModeRol','aluModePss'], aluAsl=>['aluModeAsl','aluModePss'],
   aluTSB=>['aluModeTSB','aluModePss'], aluTRB=>['aluModeTRB','aluModePss'],
   aluCmp=>['aluModeInp','aluModeCmp',4], aluCpx=>['aluModeInp','aluModeCmp',2],
   aluCpy=>['aluModeInp','aluModeCmp',1], aluAdc=>['aluModeInp','aluModeAdc'],
   aluSbc=>['aluModeInp','aluModeSbc'], aluAnd=>['aluModeInp','aluModeAnd'],
   aluOra=>['aluModeInp','aluModeOra'], aluEor=>['aluModeInp','aluModeEor'],
);
my %extra = (aluModeBit=>0b0101, aluModeLsr=>0b1000, aluModeRor=>0b1001,
   aluModeAsl=>0b1010, aluModeRol=>0b1011, aluModeTSB=>0b1100, aluModeTRB=>0b1101,
   aluModePss=>0b000, aluInXXX=>0, aluXXX=>0, aluInSet=>0);
for my $k (keys %extra) { $P{$k} = $extra{$k} unless defined $P{$k}; }
sub val { my $n = shift; return 0 if $n eq 'aluXXX';
   if (defined $P{$n}) { return $P{$n}; }
   if (my $c = $C{$n}) { return (($P{$c->[0]} // -1) << 6) | (($P{$c->[1]} // -1) << 3) | ($c->[2] // 0); }
   warn "UNKNOWN PARAM $n\n"; return -1; }

# Parse source table rows: index -> (axys, nvdizc, addrName, aluinName, alumodeName)
my (%rows, %mnem, %cidx);
open my $sf, '<', 'rtl/R65Cx2.sv' or die $!;
my $pos = 0; my $in = 0;
while (<$sf>) {
   $in = 1 if /opcodeInfoTable\[256\] =/;
   last if $in && /^\s*\};/;
   next unless $in;
   if (/^\s*'?\{+4'b(\d{4}), 6'b(\d{6}), (\w+),\s*(\w+),\s*(\w+)\}+(?:,)?\s*\/\/ ([0-9A-F]{2}) (\w+)/) {
      $rows{$pos} = [$1, $2, $3, $4, $5];
      $mnem{$pos} = $7;
      $cidx{$pos} = hex($6);
      $pos++;
   }
}
close $sf;
warn "row count=$pos\n" if $pos != 256;

# For each row: expand expected under hypothesis H:
# entry = AXYS@[43:40] | NVDIZC@[39:34] | addr@[33:18] | aluin@[17:10] | alumode@[9:0]
my $bad = 0; my $checked = 0;
for my $i (sort { $a <=> $b } keys %rows) {
   my ($ax, $nv, $an, $in, $am) = @{$rows{$i}};
   my $exp = (oct("0b$ax") << 40) | (oct("0b$nv") << 34) | (val($an) << 18) | (val($in) << 10) | val($am);
   $exp &= (1 << 44) - 1;
   my $obs = $E[$i];
   $checked++;
   if ($exp != $obs) {
      $bad++;
      printf "MISMATCH pos=%03d(comment %02X) %-8s exp=%011x obs=%011x xor=%011x  addr=%s aluin=%s alumode=%s\n",
         $i, $cidx{$i}, $mnem{$i}, $exp, $obs, $exp ^ $obs, $an, $in, $am;
   }
}
printf "checked=%d mismatches=%d\n", $checked, $bad;

# Emit census: opcode, comment-hex, mnemonic, addrMode, aluIn, aluMode
open my $out, '>', 'module_tests/r65c02/build/opcode_census.txt' or die $!;
my (%mnemset);
for my $i (0..255) {
   next unless exists $rows{$i};
   my ($ax, $nv, $an, $in, $am) = @{$rows{$i}};
   printf $out "%02X  %-6s  AXYS=%s NVDIZC=%s  %-14s %-9s %s\n", $i, $mnem{$i}, $ax, $nv, $an, $in, $am;
   $mnemset{$mnem{$i}}++;
}
close $out;
printf "census written: %d mnemonics (%d non-NOP)\n", scalar(keys %mnemset), (scalar(keys %mnemset) - ($mnemset{NOP} ? 1 : 0));
