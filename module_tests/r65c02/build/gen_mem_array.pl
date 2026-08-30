#!/usr/bin/perl
# gen_mem_array.pl — R65C02 equivalence harness memory generator (engine).
#
# Single source of truth for the directed test program lives in
# program_table.pl (array @P). This script assembles it into one 64K image:
#   base pattern + program + vectors, and emits:
#     build/r65_mem_init.hex    : 64K image, 16 bytes/line (Verilog $readmemh)
#     build/r65_mem_array.vhd   : VHDL package with MEM_INIT constant (GHDL)
#     build/program_listing.md  : annotated listing for review
#     build/coverage_report.txt : per-mnemonic coverage assertion
#
# Run from the Apple-II-Verilog_MiSTer repo root:
#   perl module_tests/r65c02/build/gen_mem_array.pl

use strict; use warnings;

# Populated by eval of program_table.pl (declares our @PROG / our %FIXED).
our @PROG; our %FIXED;

my $BUILD = 'module_tests/r65c02/build';
mkdir $BUILD unless -d $BUILD;

# ---------------------------------------------------------------------------
# Opcode encoding map (from the verified opcode census — positional indices,
# NOT comment labels; see build/opcode_census.txt). Only modes used by the
# program are listed. Mode suffixes: i=implied? no: i=immediate, A=accumulator,
# z=zp, zx=zp,X, zy=zp,Y, a=abs, ax=abs,X, ay=abs,Y, ix=(zp,X), iy=(abs),Y.
# ---------------------------------------------------------------------------
my %OP = (
   'LDA.i'=>0xA9,'LDA.z'=>0xA5,'LDA.zx'=>0xB5,'LDA.a'=>0xAD,'LDA.ax'=>0xBD,
   'LDA.ay'=>0xB9,'LDA.ix'=>0xA1,'LDA.iy'=>0xB1,
   'LDX.i'=>0xA2,'LDX.z'=>0xA6,'LDX.zy'=>0xB6,'LDX.a'=>0xAE,'LDX.ay'=>0xBE,
   'LDY.i'=>0xA0,'LDY.z'=>0xA4,'LDY.zx'=>0xB4,'LDY.a'=>0xAC,'LDY.ax'=>0xBC,
   'ORA.i'=>0x09,'AND.i'=>0x29,'EOR.i'=>0x49,'ADC.i'=>0x69,'SBC.i'=>0xE9,
   'CMP.i'=>0xC9,'CMP.z'=>0xC5,'CMP.a'=>0xCD,
   'CPX.i'=>0xE0,'CPX.z'=>0xE4,'CPX.a'=>0xEC,
   'CPY.i'=>0xC0,'CPY.z'=>0xC4,'CPY.a'=>0xCC,
   'BIT.i'=>0x89,'BIT.z'=>0x24,'BIT.a'=>0x2C,
   'STA.z'=>0x85,'STA.zx'=>0x95,'STA.a'=>0x8D,'STA.ax'=>0x9D,'STA.ay'=>0x99,
   'STA.ix'=>0x81,
   'STX.z'=>0x86,'STX.zy'=>0x96,'STX.a'=>0x8E,
   'STY.z'=>0x84,'STY.zx'=>0x94,'STY.a'=>0x8C,
   'STZ.z'=>0x64,'STZ.zx'=>0x74,'STZ.a'=>0x9C,'STZ.ax'=>0x9E,
   'ASL.A'=>0x0A,'ASL.z'=>0x06,'ASL.zx'=>0x16,'ASL.a'=>0x0E,'ASL.ax'=>0x1E,
   'LSR.A'=>0x4A,'LSR.z'=>0x46,'LSR.zx'=>0x56,'LSR.a'=>0x4E,'LSR.ax'=>0x5E,
   'ROL.A'=>0x2A,'ROL.z'=>0x26,'ROL.zx'=>0x36,'ROL.a'=>0x2E,'ROL.ax'=>0x3E,
   'ROR.A'=>0x6A,'ROR.z'=>0x66,'ROR.zx'=>0x76,'ROR.a'=>0x6E,'ROR.ax'=>0x7E,
   'INC.A'=>0x1A,'INC.z'=>0xE6,'INC.zx'=>0xF6,'INC.a'=>0xEE,'INC.ax'=>0xFE,
   'DEC.A'=>0x3A,'DEC.z'=>0xC6,'DEC.zx'=>0xD6,'DEC.a'=>0xCE,'DEC.ax'=>0xDE,
   'TSB.z'=>0x04,'TSB.a'=>0x0C,
   'TRB.z'=>0x14,'TRB.a'=>0x1C,
   'BEQ'=>0xF0,'BNE'=>0xD0,'BCS'=>0xB0,'BCC'=>0x90,'BMI'=>0x30,'BPL'=>0x10,
   'BVC'=>0x50,'BVS'=>0x70,'BRA'=>0x80,
   'JMP.a'=>0x4C,'JMP.i'=>0x6C,'JMP.ix'=>0x7C,'JSR'=>0x20,'RTS'=>0x60,
   'PHA'=>0x48,'PLA'=>0x68,'PHP'=>0x08,'PLP'=>0x28,
   'PHX'=>0xDA,'PLX'=>0xFA,'PHY'=>0x5A,'PLY'=>0x7A,
   'TAX'=>0xAA,'TAY'=>0xA8,'TXA'=>0x8A,'TYA'=>0x98,'TSX'=>0xBA,'TXS'=>0x9A,
   'INX'=>0xE8,'DEX'=>0xCA,'INY'=>0xC8,'DEY'=>0x88,
   'CLC'=>0x18,'SEC'=>0x38,'CLI'=>0x58,'SEI'=>0x78,
   'CLV'=>0xB8,'SED'=>0xF8,'CLD'=>0xD8,
   'NOP'=>0xEA,
);

# ---------------------------------------------------------------------------
# Load the program table.
# Entry forms:  ['comment']            — listing comment only
#               ['LABEL:'=>'','MN',...] — label at current address + instruction
#               ['MN', operand...]      — instruction
# Operand forms: '#xx' immediate hex, '#lo(LABEL)' / '#hi(LABEL)' label byte,
#                '$xxxx' absolute, '$xx' zero page, 'LABEL' branch/jump target,
#                '+N' relative offset from next instruction (for not-taken
#                branches; lands harmlessly).
# ---------------------------------------------------------------------------
my $tbl = "$BUILD/program_table.pl";
open my $tf, '<', $tbl or die "open $tbl: $!";
my $tcode = do { local $/; <$tf> };
close $tf;
eval $tcode;
die "program_table.pl failed: $@" if $@;
my @P = @PROG;

# ---------------------------------------------------------------------------
# Pass 1: assign addresses (labels + instruction sizes).
# ---------------------------------------------------------------------------
my %SIZE = ('i'=>2,'z'=>2,'zx'=>2,'zy'=>2,'a'=>3,'ax'=>3,'ay'=>3,'ix'=>2,'iy'=>3,'A'=>1);
# Full-key size overrides where a mode suffix is reused with a different
# length (JMP indirect forms take a 3-byte absolute pointer, not 2).
my %SIZE_KEY = ('JMP.i'=>3, 'JMP.ix'=>3);

# Map a mnemonic + first operand to an %OP key. Explicit mode suffixes pass
# through; bare mnemonics infer the mode from the operand form.
sub resolve_key {
   my ($mn, $op) = @_;
   return $mn if $mn =~ /\./;                  # explicit mode
   return 'JSR' if $mn eq 'JSR';               # abs target, no mode suffix
   if (defined $op && $op ne '') {
      if    ($op =~ /^#/)                   { return "$mn.i"; }  # immediate
      elsif ($op =~ /^\$[0-9A-Fa-f]{2}$/i)  { return "$mn.z"; }  # zero page
      else                                  { return "$mn.a"; }  # abs / label
   }
   return $mn;                                 # implied, 1 byte
}

sub insn_size {
   my ($mn, @ops) = @_;
   if ($mn eq 'PADTO') {                       # pad with NOPs up to target
      my $t = hex($ops[0] =~ s/^\$//r);
      die "PADTO needs address" unless defined $t;
      return [$t];                             # special: returns target addr as array ref
   }
   if ($mn =~ /^(BEQ|BNE|BCS|BCC|BMI|BPL|BVC|BVS|BRA)$/) { return 2; }
   my $key = resolve_key($mn, $ops[0]);
   return 3 if $key eq 'JSR';                  # JSR abs
   return $SIZE_KEY{$key} if exists $SIZE_KEY{$key};
   return 1 if $key !~ /\./;                   # implied
   my $mode = $key; $mode =~ s/.*\.//;
   my $s = $SIZE{$mode} // die "no size for mode $mode ($key)";
   return $s;
}

# Normalize a table entry. Returns (label_hashref_or_undef, mnemonic, ops) or
# undef for comment-only entries. Convention: a 1-element entry is a comment;
# otherwise the instruction starts at [0], or at [1] if [0] is a label hash.
sub norm {
   my ($e) = @_;
   return () if !ref $e || @$e < 2;
   if (ref $e->[0] eq 'HASH') { return ($e->[0], $e->[1], [@{$e}[2..$#$e]]); }
   # Leading flat label pairs: ['L1:'=>'','L2:'=>'', MN, OPS...] (=> in an
   # array literal does not build a hash). Multiple labels may share one line.
   my $i = 0; my %lbl;
   while ($i + 1 <= $#$e && $e->[$i] =~ /:$/ && $e->[$i+1] eq '') {
      $lbl{ $e->[$i] } = ''; $i += 2;
   }
   my @rest = @{$e}[$i..$#$e];
   return () if !@rest;                  # comment-only (or label-only) line
   if (keys %lbl) { return ({ %lbl }, $rest[0], [@rest[1..$#rest]]); }
   return (undef, $rest[0], [@rest[1..$#rest]]);
}

my %addr;          # label -> address
my @flat;          # flattened instruction entries with addresses
my $pc = 0x0500;
for my $e (@P) {
   my @n = norm($e); next unless @n;               # comment-only
   my ($lbl, $mn, $ops) = @n;
   if ($lbl) {                                    # label keys carry a trailing ':'
      for my $k (keys %$lbl) { $addr{ $k =~ s/:$//r } = $pc; }
   }
   push @flat, { pc => $pc, mn => $mn, ops => $ops, entry => $e };
   my $sz = insn_size($mn, @$ops);
   if (ref $sz) {                                  # PADTO: advance to target
      die "PADTO backwards at $pc" if $sz->[0] < $pc;
      $pc = $sz->[0];
   } else {
      $pc += $sz;
   }
}
die "program overflow: ends at $pc" if $pc > 0x0A00;

# ---------------------------------------------------------------------------
# Pass 2: encode bytes.
# ---------------------------------------------------------------------------
my %mem;           # addr -> byte (overrides only)
my %putwho;
my $putcur = '?';
sub put { my ($a, $b) = @_;
          if (exists $mem{$a}) {
            die "byte collision at $a: '$putcur' vs '$putwho{$a}'";
          }
          $mem{$a} = $b & 0xFF; $putwho{$a} = $putcur; }

for my $f (@flat) {
   my ($pcx, $mn, $ops) = @{$f}{qw(pc mn ops)};
   $putcur = sprintf('%s@%04X', $mn, $pcx);
   if ($mn eq 'PADTO') {                           # fill NOPs up to target
      my $t = hex($ops->[0] =~ s/^\$//r);
      put($_, 0xEA) for $pcx .. ($t - 1);
      next;
   }
   my @o = @$ops;
   my $op0 = @o ? $o[0] : undef;
   if ($mn =~ /^(BEQ|BNE|BCS|BCC|BMI|BPL|BVC|BVS|BRA)$/) {
      my $t = shift @o;
      my $raw;
      if ($t =~ /^\+(-?\d+)$/) { $raw = hex($1); }
      elsif (exists $addr{$t}) { $raw = $addr{$t} - ($pcx + 2); }
      else { die "unresolved branch target '$t' at $pcx"; }
      die "branch offset out of range at $pcx" if $raw < -128 || $raw > 127;
      my $off = $raw & 0xFF;
      put($pcx, $OP{$mn});
      put($pcx + 1, $off);
      next;
   }
   encode_insn($pcx, $mn, @o);
}

# Shared non-branch instruction encoder (used by the main pass and handlers).
sub encode_insn {
   my ($pcx, $mn, @o) = @_;
   my $key = resolve_key($mn, @o ? $o[0] : undef);
   die "unknown opcode key '$key' at $pcx" unless exists $OP{$key};
   put($pcx, $OP{$key});
   my $op = shift @o;
   return unless defined $op && $op ne '';
   (my $mode = $key) =~ s/.*\.//;              # '' for implied / JSR
   my $is_abs = ($key eq 'JMP.i' || $key eq 'JMP.ix' || $key eq 'JSR')
              || grep({ $_ eq $mode } qw(a ax ay iy));
   if ($is_abs) {
      # absolute family: two bytes (JMP indirect / JSR take a pointer addr)
      if    ($op =~ /^\$([0-9A-Fa-f]{1,4})$/) { put($pcx+1, hex($1)&0xFF); put($pcx+2, (hex($1)>>8)&0xFF); }
      elsif (exists $addr{$op})               { put($pcx+1, $addr{$op}&0xFF); put($pcx+2, ($addr{$op}>>8)&0xFF); }
      else { die "bad abs operand '$op' for $mn at $pcx"; }
   } elsif ($mode eq 'i') {
      if    ($op =~ /^#([0-9A-Fa-f]{1,2})$/)  { put($pcx+1, hex($1)); }
      elsif ($op =~ /^#lo\((\w+)\)$/)         { put($pcx+1, $addr{$1} & 0xFF); }
      elsif ($op =~ /^#hi\((\w+)\)$/)         { put($pcx+1, ($addr{$1} >> 8) & 0xFF); }
      else { die "bad immediate operand '$op' for $mn at $pcx"; }
   } else {
      # zero-page family (z, zx, zy, ix): one byte
      my $v;
      if    ($op =~ /^#([0-9A-Fa-f]{1,2})$/)  { $v = hex($1); }
      elsif ($op =~ /^\$([0-9A-Fa-f]{1,4})$/) { $v = hex($1) & 0xFF; }
      else { die "bad zp operand '$op' for $mn at $pcx"; }
      put($pcx+1, $v);
   }
}

# Assemble the fixed-address handlers (outside program flow) BEFORE the
# %mem -> @IMG copy below, so their bytes reach the image.
for my $h (keys %FIXED) {
   my $hp = $FIXED{$h}{addr};
   for my $b (@{ $FIXED{$h}{bytes} }) {
      my ($mn, @o) = @$b;
      $putcur = sprintf('%s@%04X[%s]', $mn, $hp, $h);
      encode_insn($hp, $mn, @o);
      $hp += insn_size($mn, @o);
   }
}

# ---------------------------------------------------------------------------
# Build the full 64K image: pattern base + program overrides + vectors.
# ---------------------------------------------------------------------------
my @IMG; @IMG[0..65535] = (0) x 65536;
for my $i (0..65535) { $IMG[$i] = ($i + int($i / 16) + 60) % 256; }
for my $a (keys %mem) { $IMG[$a] = $mem{$a}; }

# Vectors: reset/boot -> $0500; IRQ/BRK -> IRQH; NMI -> NMIH.
$IMG[0xFFFC] = 0x00; $IMG[0xFFFD] = 0x05;   # boot (phantom jumpAbs reads these)
$IMG[0xFFFE] = ($FIXED{IRQH}{addr} & 0xFF); $IMG[0xFFFF] = ($FIXED{IRQH}{addr} >> 8) & 0xFF;
$IMG[0xFFFA] = ($FIXED{NMIH}{addr} & 0xFF); $IMG[0xFFFB] = ($FIXED{NMIH}{addr} >> 8) & 0xFF;

# ---------------------------------------------------------------------------
# Coverage: every v1 mnemonic (census non-NOP minus BRK/RTI) must be used.
# ---------------------------------------------------------------------------
my %used;
for my $f (@flat) {
   next if $f->{mn} eq 'PADTO';
   (my $bare = $f->{mn}) =~ s/\..*$//;             # LDA.z -> LDA
   $used{$bare}++;
}
# fixed-address handlers count for coverage too
for my $h (keys %FIXED) {
   for my $b (@{ $FIXED{$h}{bytes} }) {
      (my $bare = $b->[0]) =~ s/\..*$//;
      $used{$bare}++ unless $bare eq 'JMP';
      $used{JMP}++ if $bare eq 'JMP';
   }
}
open my $cf, '<', "$BUILD/opcode_census.txt" or die "open census: $!";
my (%census, @mnems);
while (<$cf>) {
   my ($op, $mn) = /^([0-9A-F]{2})\s+(\w+)/ or next;
   push @mnems, $mn if !grep({ $_ eq $mn } @mnems);
}
close $cf;
my %skip = (BRK => 1, RTI => 1);    # v2 additions
open my $cov, '>', "$BUILD/coverage_report.txt" or die $!;
print $cov "R65C02 v1 coverage (BRK and RTI deferred to v2)\n";
my $missing = 0;
for my $m (@mnems) {
   next if $m eq 'NOP' || $skip{$m};
   my $n = $used{$m} // 0;
   printf $cov "%-6s %s (%d)\n", $m, ($n ? 'OK' : 'MISSING'), $n;
   $missing++ unless $n;
}
printf $cov "mnemonics required=%d covered=%d missing=%d\n",
   scalar(grep { !($skip{$_} || $_ eq 'NOP') } @mnems),
   scalar(grep { ($used{$_} // 0) && !$skip{$_} && $_ ne 'NOP' } @mnems), $missing;
close $cov;
die "coverage failure — see coverage_report.txt" if $missing;

# ---------------------------------------------------------------------------
# Emit artifacts.
# ---------------------------------------------------------------------------
# 1) Verilog hex (16 bytes/line)
open my $hf, '>', "$BUILD/r65_mem_init.hex" or die $!;
for my $i (0..65535) {
   printf $hf "%s%02X", ($i % 16 ? ' ' : ''), $IMG[$i];
   print $hf "\n" if $i % 16 == 15;
}
close $hf;

# 2) VHDL package (16 words/line)
open my $vf, '>', "$BUILD/r65_mem_array.vhd" or die $!;
print $vf "library ieee;\nuse ieee.std_logic_1164.all;\n\n";
print $vf "-- Generated by module_tests/r65c02/build/gen_mem_array.pl.\n";
print $vf "-- Do not edit by hand; re-run the generator instead.\n";
print $vf "package r65_mem_array is\n";
print $vf "  type mem_vec_t is array (0 to 65535) of std_logic_vector(7 downto 0);\n";
print $vf "  constant MEM_INIT : mem_vec_t := (\n";
for my $i (0..65535) {
   next unless $i % 16 == 0;
   my @parts;
   for my $j (0..15) { push @parts, sprintf('x"%02X"', $IMG[$i + $j]); }
   print $vf "    " . join(', ', @parts) . ($i + 16 < 65536 ? ',' : '') . "\n";
}
print $vf "  );\nend package r65_mem_array;\n";
close $vf;

# 3) Program listing
open my $lf, '>', "$BUILD/program_listing.md" or die $!;
print $lf "# R65C02 directed test program (v1)\n\n";
print $lf "Boot vector \$FFFC/\$FFFD -> \$0500. IRQ handler at \$",
          sprintf('%04X', $FIXED{IRQH}{addr}), ", NMI handler at \$",
          sprintf('%04X', $FIXED{NMIH}{addr}), ".\n\n";
print $lf "```text\n";
for my $e (@P) {
   my @n = norm($e);
   if (!@n) { print $lf "; ", $e->[0], "\n"; next; }
   my ($lbl, $mn, $ops) = @n;
   my $prefix = $lbl ? ((keys %$lbl)[0] . ' ') : '';
   if ($mn eq 'PADTO') {
      printf $lf "%s\$%04X  ; pad with NOPs to \$%s\n", $prefix,
         (grep { $_->{entry} == $e } @flat)[0]->{pc}, $ops->[0];
      next;
   }
   my $f = (grep { $_->{entry} == $e } @flat)[0];
   next unless $f;
   printf $lf "%s\$%04X  %s\n", $prefix, $f->{pc}, join(' ', $mn, @$ops);
}
print $lf "```\n";
close $lf;

printf "program: \$0500-\$%04X (%d instructions)\n", $pc - 1, scalar @flat;
printf "vectors: boot=0500 IRQ=%04X NMI=%04X\n",
   $FIXED{IRQH}{addr}, $FIXED{NMIH}{addr};
print "coverage OK (see $BUILD/coverage_report.txt)\n";
print "wrote $BUILD/r65_mem_init.hex, r65_mem_array.vhd, program_listing.md\n";
