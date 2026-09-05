#!/usr/bin/env perl
# Tiny 6502 ROM tracer for apple2e.hex (Verilog hex format).
use strict; use warnings;

open my $f, "<", "rtl/roms/apple2e.hex" or die "open: $!";
my @w;
while (my $line = <$f>) {
  for my $t (split(/\s+/, $line)) {
    push @w, hex($t) if $t =~ /^\$?[0-9a-fA-F]{1,2}$/;
  }
}
close $f;
die "bad ROM size: ".scalar(@w)." words" unless @w == 16384;
my $rom = join("", map { chr($_) } @w);

sub rd8 { my ($a) = @_; $a = ($a - 0xC000) & 0x3FFF; return ord(substr($rom, $a, 1)); }
sub rd16 { my ($a) = @_; return rd8($a) | (rd8($a+1) << 8); }
sub rel8 { my ($a) = @_; my $v = rd8($a); return ($v & 0x80) ? $v - 256 : $v; }

my %OP = (
  0x00 => ["BRK","0"], 0x01 => ["ORA","zpx"], 0x03 => ["SLO","z"], 0x05 => ["ORA","z"], 0x06 => ["SLO","zpx"],
  0x08 => ["PHP","0"], 0x09 => ["ORA","i"],  0x0A => ["ASL","a"], 0x0D => ["ORA","a"], 0x0E => ["SLO","apx"],
  0x10 => ["BPL","r"], 0x11 => ["ORA","aay"], 0x13 => ["SLO","aay"], 0x15 => ["ORA","apx"], 0x16 => ["SLO","apx"],
  0x18 => ["CLC","0"], 0x1A => ["INX","0"], 0x1D => ["ORA","aay"], 0x1E => ["SLO","aay"],
  0x20 => ["JMP","ai"], 0x21 => ["AND","zpx"], 0x23 => ["ROL","z"], 0x25 => ["AND","z"], 0x26 => ["ROL","zpx"],
  0x28 => ["PLA","0"], 0x29 => ["AND","i"],  0x2A => ["ROL","a"], 0x2D => ["AND","a"], 0x2E => ["ROL","apx"],
  0x30 => ["BMI","r"], 0x31 => ["AND","aay"], 0x33 => ["ROL","aay"], 0x35 => ["AND","apx"], 0x36 => ["ROL","apx"],
  0x38 => ["SEC","0"], 0x3A => ["INY","0"], 0x3D => ["AND","aay"], 0x3E => ["ROL","aay"],
  0x40 => ["RTI","0"], 0x41 => ["EOR","zpx"], 0x43 => ["RLR","z"], 0x45 => ["EOR","z"], 0x46 => ["RLR","zpx"],
  0x48 => ["PHA","0"], 0x49 => ["EOR","i"],  0x4A => ["ROR","a"], 0x4C => ["JMP","ab"], 0x4D => ["EOR","a"],
  0x4E => ["RLR","apx"], 0x50 => ["BVC","r"], 0x51 => ["EOR","aay"], 0x53 => ["RLR","aay"], 0x55 => ["EOR","apx"],
  0x56 => ["RLR","apx"], 0x58 => ["CLI","0"], 0x5A => ["DEY","0"], 0x5D => ["EOR","aay"], 0x5E => ["RLR","aay"],
  0x60 => ["RTS","0"], 0x61 => ["ADC","zpx"], 0x63 => ["RLA","z"], 0x65 => ["ADC","z"], 0x66 => ["RLA","zpx"],
  0x68 => ["PLA","0"], 0x69 => ["ADC","i"],  0x6A => ["ROR","a"], 0x6C => ["JMP","ind"], 0x6D => ["ADC","a"],
  0x6E => ["RLA","apx"], 0x70 => ["BVS","r"], 0x71 => ["ADC","aay"], 0x73 => ["RLA","aay"], 0x74 => ["STZ","z"],
  0x75 => ["ADC","apx"], 0x76 => ["RLA","apx"], 0x78 => ["SEI","0"], 0x7D => ["ADC","aay"], 0x7E => ["RLA","aay"],
  0x80 => ["BRA","r"], 0x81 => ["STA","zpx"], 0x84 => ["STY","z"], 0x85 => ["STA","z"], 0x86 => ["STX","z"],
  0x88 => ["DEX","0"], 0x89 => ["STA","i"],  0x8A => ["TXA","0"], 0x8C => ["STY","a"], 0x8D => ["STA","a"],
  0x8E => ["STX","a"], 0x90 => ["BCC","r"], 0x91 => ["STA","aay"], 0x94 => ["STY","apx"], 0x95 => ["STA","apx"],
  0x96 => ["STX","apy"], 0x98 => ["TYA","0"], 0x99 => ["STA","ai"], 0x9A => ["TXS","0"], 0x9D => ["STA","ai"],
  0xA0 => ["LDY","i"], 0xA1 => ["LDX","zpx"], 0xA2 => ["LDX","i"], 0xA4 => ["LDY","z"], 0xA5 => ["LDA","z"],
  0xA6 => ["LDX","z"], 0xA8 => ["TAY","0"], 0xA9 => ["LDA","i"], 0xAA => ["TAX","0"], 0xAC => ["LDY","a"],
  0xAD => ["LDA","a"], 0xAE => ["LDX","a"], 0xB0 => ["BCS","r"], 0xB1 => ["LDA","aay"], 0xB4 => ["LDY","apx"],
  0xB5 => ["LDA","apx"], 0xB6 => ["LDX","apy"], 0xB8 => ["CLV","0"], 0xB9 => ["LDA","ai"],
  0xBA => ["TSX","0"], 0xBC => ["LDY","ai"], 0xBD => ["LDA","ai"], 0xBE => ["LDX","ai"],
  0xC0 => ["CPY","i"], 0xC1 => ["SBC","zpx"], 0xC4 => ["CPY","z"], 0xC5 => ["CMP","z"],
  0xC8 => ["INY","0"], 0xC9 => ["CMP","i"], 0xCA => ["DEX","0"], 0xCC => ["CPY","a"],
  0xCD => ["CMP","a"], 0xD0 => ["BNE","r"], 0xD1 => ["SBC","aay"], 0xD5 => ["SBC","apx"],
  0xD8 => ["CLD","0"], 0xD9 => ["CMP","ai"], 0xDD => ["SBC","ai"], 0xE0 => ["CPX","i"], 0xE1 => ["SBC","zpx"],
  0xE4 => ["CPX","z"], 0xE5 => ["SBC","z"], 0xE8 => ["INX","0"],
  0xE9 => ["SBC","i"], 0xEA => ["NOP","0"], 0xEC => ["CPX","a"], 0xED => ["SBC","a"],
  0xF0 => ["BEQ","r"], 0xF1 => ["SBC","aay"], 0xF5 => ["SBC","apx"], 0xF8 => ["SED","0"], 0xF9 => ["SBC","ai"],
);

sub disasm {
  my ($pc, $count, $indent) = @_;
  my $n = 0;
  while ($n < $count) {
    $pc &= 0xFFFF;
    my $op = rd8($pc);
    my ($mn, $mode) = @{ $OP{$op} || ["???", "0"] };
    my $len = 1; my $arg = "";
    if    ($mode eq "i")   { $len = 2; $arg = sprintf("\$%02X", rd8($pc+1)); }
    elsif ($mode eq "z")   { $len = 2; $arg = sprintf("\$%02X", rd8($pc+1)); }
    elsif ($mode eq "zpx") { $len = 2; $arg = sprintf("\$%02X,X", rd8($pc+1)); }
    elsif ($mode eq "apx") { $len = 2; $arg = sprintf("\$%04X,X", rd16($pc+1)); }
    elsif ($mode eq "aay") { $len = 2; $arg = sprintf("\$%04X,Y", rd16($pc+1)); }
    elsif ($mode eq "apy") { $len = 2; $arg = sprintf("\$%04X,Y", rd16($pc+1)); }
    elsif ($mode eq "ai")  { $len = 2; $arg = sprintf("(\\$%04X)", rd16($pc+1)); }
    elsif ($mode eq "ind") { $len = 2; $arg = sprintf("(\\$%04X)", rd16($pc+1)); }
    elsif ($mode eq "a")   { $len = 2; $arg = sprintf("\$%04X", rd16($pc+1)); }
    elsif ($mode eq "ab")  { $len = 3; $arg = sprintf("\$%04X", rd16($pc+1)); }
    elsif ($mode eq "r")   { $len = 2; my $rel = rel8($pc+1);
                             $arg = sprintf("\$%04X (%+d)", ($pc+2+$rel)&0xFFFF, $rel); }
    my $next = $pc;
    if    ($mode eq "r")  { $next = ($pc + 2 + rel8($pc+1)) & 0xFFFF; }
    elsif ($mode eq "ai") { my $t = rd16($pc+1); $next = (rd8($t) | (rd8(($t+1)&0xFFFF)<<8)) & 0xFFFF; }
    elsif ($mode eq "ind"){ my $t = rd16($pc+1); $next = (rd8($t) | (rd8(($t+1)&0xFFFF)<<8)) & 0xFFFF; }
    elsif ($mode eq "ab") { $next = rd16($pc+1); }
    elsif ($mode eq "a")  { $next = rd16($pc+1); }
    else                  { $next = ($pc + $len) & 0xFFFF; }
    my $tag = "";
    $tag = "  <=== branch/jmp target here" if $next == $pc;
    printf("%s\$%04X  %02X %-4s %-14s%s\n", $indent, $pc, $op, $mn, $arg, $tag);
    last if $op == 0x00;   # BRK ends the main context
    $n++;
    $pc = $next;
  }
  return $pc;
}

my $rv = rd16(0xFFFC);
my $nv = rd16(0xFFFA);
my $iv = rd16(0xFFFE);
printf "reset=\$%04X  nmi=\$%04X  irq=\$%04X\n", $rv, $nv, $iv;
printf "--- boot from reset vector \$%04X (%d instr) ---\n", $rv, ($ARGV[0] // 50);
my $pc = disasm($rv, ($ARGV[0] // 50), "");
printf "--- continued at \$%04X ---\n", $pc;
disasm($pc, ($ARGV[1] // 25), "   ");
