# program_table.pl — R65C02 directed test program (v1).
# Loaded by gen_mem_array.pl. See that script for entry/operand syntax.
#
# v1 covers all 63 non-NOP mnemonics except BRK and RTI (deferred to v2).
# Interrupts (IRQ + NMI) are exercised via external pulses during the NOP
# sleds; handlers at fixed addresses return with explicit JMPs.

our @PROG = (
[ '================ Block A: prologue + flags + ALU imm + transfers ================'],
['LDA','#05'],['LDX','#FD'],['LDY','#A0'],
['define S on both DUTs (VHDL S is meta until now)'],['TXS',''],
['CLV',''],['CLC',''],['SED',''],['CLD',''],
['SEI/CLI pair covers both I-flag setters; end unmasked for the IRQ test'],
['SEI',''],['CLI',''],
[ '--- ALU immediate ---'],
['SBC','#FF'],['ADC','#01'],['EOR','#0F'],['AND','#0F'],['ORA','#F0'],
[ '--- transfers ---'],
['TAX',''],['TAY',''],['TXA',''],['TYA',''],['TSX',''],
['INX',''],['DEX',''],['INY',''],['DEY',''],
[ '--- re-establish known flags: N=0 Z=0 V=0 C=1 I=0 D=0 ---'],
['LDA','#7F'],['SEC',''],
[ '================ Branch coverage ================='],
[ 'taken test: BR +5 skips [NOP NOP sentinel]; a wrong not-take walks into the'],
[ 'sentinel -> ERRPARK. not-taken test: backward BR to an earlier sentinel slot;'],
[ 'a wrong take jumps back into it -> ERRPARK. Each sentinel JMP ERRPARK serves'],
[ 'both roles (multi-label lines where two not-taken tests share one sentinel).'],
# --- Z flag ---
['LDA','#00'],                       # Z=1
['BEQ','b_eq_t'],['NOP',''],['NOP',''],
['b_eq_s:'=>'','JMP.a','ERRPARK'],   # (S1) BEQ-taken trap + BEQ-not-taken target
['b_eq_t:'=>'','LDA','#01'],          # Z=0
['BEQ','b_eq_s'],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['BNE','b_ne_t'],                     # Z=0 -> taken
['NOP',''],['NOP',''],
['b_ne_s:'=>'','JMP.a','ERRPARK'],   # (S2) BNE-taken trap + BNE-not-taken target
['b_ne_t:'=>'','LDA','#00'],          # Z=1
['BNE','b_ne_s'],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
# --- C flag ---
['SEC',''],                           # C=1
['BCS','b_cs_t'],['NOP',''],['NOP',''],
['b_cc_s:'=>'','JMP.a','ERRPARK'],   # (S3) BCS-taken trap + BCC-not-taken target
['b_cs_t:'=>'','CLC',''],              # C=0
['BCC','b_cc_t'],['NOP',''],['NOP',''],['JMP.a','ERRPARK'],  # (S4) BCC-taken trap
['b_cc_t:'=>'','SEC',''],              # C=1
['BCC','b_cc_s'],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
# --- N flag ---
['LDA','#80'],                        # N=1
['BMI','b_mi_t'],['NOP',''],['NOP',''],
['b_pl_s:'=>'','JMP.a','ERRPARK'],   # (S5) BMI-taken trap + BPL-not-taken target
['b_mi_t:'=>'','LDA','#7F'],           # N=0
['BPL','b_pl_t'],['NOP',''],['NOP',''],
['b_mi_s:'=>'','JMP.a','ERRPARK'],   # (S6) BPL-taken trap + BMI-not-taken target
['b_pl_t:'=>'','LDA','#80'],           # N=1
['BPL','b_pl_s'],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['LDA','#7F'],                        # N=0
['BMI','b_mi_s'],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
[ '--- V flag via ADC overflow: 7F + 01 with C=1 -> 81 (V=1 N=1 Z=0 C=0) ---'],
['LDA','#7F'],['SEC',''],['ADC','#01'],
['BVS','b_vs_t'],['NOP',''],['NOP',''],
['b_vc_s:'=>'','b_vs_s:'=>'','JMP.a','ERRPARK'],  # (S7) BVS trap + BVC/BVS not-taken targets
['b_vs_t:'=>'','BVC','b_vc_s'],        # V=1 -> not taken; wrong take -> S7
['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['CLV',''],                           # V=0
['BVS','b_vs_s'],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['BVC','b_vc_t'],['NOP',''],['NOP',''],['JMP.a','ERRPARK'],  # (S8) BVC-taken trap
['b_vc_t:'=>'','LDA','#7F'],           # re-establish N=0 Z=0
['SEC',''],['CLV',''],
[ '================ Block B: stack ================='],
['PHA/PLA round trip'],['LDA','#5A'],['PHA',''],['PLA',''],
['PHX/PLX round trip'],['LDX','#33'],['PHX',''],['PLX',''],
['PHY/PLY round trip'],['LDY','#77'],['PHY',''],['PLY',''],
['PHP/PLP (PLP has a C/Z swap quirk — re-establish flags after)'],
['PHP',''],['PLP',''],
['CLV',''],['SEC',''],['CLI',''],
['JSR/RTS pair'],['LDA','#11'],['JSR','SUB1'],
['resume point after RTS'],['LDA','#22'],
[ '================ Block C: memory reads + compares ================='],
[ '--- seed scratch ---'],
['ZP data $80 = 3C'],['LDA','#3C'],['STA.z','$80'],
['abs data $0A00 = 78'],['LDA','#78'],['STA.a','$0A00'],
['index registers for the indexed modes'],['LDX','#10'],['LDY','#20'],
['pointer A at $00E0 -> $0A40 ((zp,X) with operand $D0: D+X = E0)'],
['LDA','#40'],['STA.z','$00E0'],
['LDA','#0A'],['STA.z','$00E1'],
['seed indirect target $0A40 = 55'],['LDA','#55'],['STA.a','$0A40'],
['pointer B at $00F0 -> TJMP1 (JMP (abs) [6C] target setup)'],
['LDA','#lo(TJMP1)'],['STA.z','$00F0'],
['LDA','#hi(TJMP1)'],['STA.z','$00F1'],
['pointer C at $00E8 -> TJMP2 (JMP (abs,X) [7C]; X forced to 0 at use)'],
['LDA','#lo(TJMP2)'],['STA.z','$00E8'],
['LDA','#hi(TJMP2)'],['STA.z','$00E9'],
['pointer D at $0A50 -> $0A60 ((abs),Y with Y=20 -> $0A80)'],
['LDA','#60'],['STA.a','$0A50'],
['LDA','#0A'],['STA.a','$0A51'],
[ '--- LDA all modes ---'],
['LDA.z','$80'],
['LDA.zx','$80'],                     # effective $90
['LDA.a','$0A00'],
['LDA.ax','$0A00'],                   # effective $0A10
['LDA.ay','$0A00'],                   # effective $0A20
['LDA.ix','$D0'],                     # ptr at $00E0 -> $0A40
['LDA.iy','$0A50'],                   # ptr at $0A50 -> $0A60, +Y(20) = $0A80
[ '--- LDX / LDY remaining modes ---'],
['LDX.z','$82'],['LDX.a','$0A10'],['LDX.zy','$84'],   # effective $94
['LDY.z','$83'],['LDY.a','$0A12'],['LDY.zx','$85'],   # effective $95
[ '--- CMP / CPX / CPY (imm, zp, abs) ---'],
['LDA','#3C'],
['CMP.i','#3C'],['CMP.z','$80'],['CMP.a','$0A00'],
['LDX','#78'],
['CPX.i','#78'],['CPX.z','$80'],['CPX.a','$0A00'],
['LDY','#55'],
['CPY.i','#55'],['CPY.z','$80'],['CPY.a','$0A00'],
[ '--- BIT (imm, zp, abs) ---'],
['BIT.i','#40'],['BIT.z','$80'],['BIT.a','$0A00'],
[ '================ Block D: memory writes + shifts ================='],
[ '--- seed targets ---'],
['LDA','#01'],['STA.z','$80'],
['LDA','#02'],['STA.a','$0A00'],
[ '--- TSB / TRB (zp, abs) ---'],
['LDA','#40'],['TSB.z','$80'],['LDA','#FF'],['TRB.z','$80'],
['LDA','#80'],['TSB.a','$0A00'],['LDA','#FF'],['TRB.a','$0A00'],
[ '--- shifts/rotates: A, zp, zp,X, abs, abs,X ---'],
['LDA','#01'],
['ASL.A',''],['ROL.A',''],['LSR.A',''],['ROR.A',''],
['ASL.z','$80'],['ROL.z','$80'],['LSR.z','$80'],['ROR.z','$80'],
['ASL.zx','$90'],['ROL.zx','$90'],['LSR.zx','$90'],['ROR.zx','$90'],
['ASL.a','$0A00'],['ROL.a','$0A00'],['LSR.a','$0A00'],['ROR.a','$0A00'],
['ASL.ax','$0A00'],['ROL.ax','$0A00'],['LSR.ax','$0A00'],['ROR.ax','$0A00'],
[ '--- INC / DEC: A, zp, zp,X, abs, abs,X ---'],
['INC.A',''],['DEC.A',''],
['INC.z','$80'],['DEC.z','$80'],
['INC.zx','$90'],['DEC.zx','$90'],
['INC.a','$0A00'],['DEC.a','$0A00'],
['INC.ax','$0A00'],['DEC.ax','$0A00'],
[ '--- remaining STA modes ---'],
['LDA','#A1'],['STA.zx','$80'],       # effective $90
['LDA','#A2'],['STA.ay','$0A50'],     # ptr $0A50 -> $0A60 +Y(20) = $0A80
['LDA','#A3'],['STA.ix','$D0'],       # ptr at $00E0 -> $0A40
['LDA','#A4'],['STA.ax','$0A00'],     # effective $0A10
[ '--- STX / STY ---'],
['STX.z','$82'],['STX.a','$0A10'],['STX.zy','$84'],   # effective $94
['STY.z','$83'],['STY.a','$0A12'],['STY.zx','$85'],   # effective $95
[ '--- STZ ---'],
['STZ.z','$86'],['STZ.zx','$87'],     # effective $97
['STZ.a','$0A20'],['STZ.ax','$0A00'], # effective $0A10
[ '================ Tail: indirect jumps, interrupts, park ================='],
[ '--- indirect jump tests (X must be 0 for the 7C special-case ambiguity) ---'],
['LDX','#00'],
['JMP.i','$00F0'],                    # [6C] via pointer -> TJMP1
['NOP',''],['NOP',''],                # fall-through only if 6C did not jump
['jmp1_s:'=>'','JMP.a','ERRPARK'],    # sentinel
['TJMP1:'=>'','LDA','#B1'],           # A=0xB1 landing marker
['JMP.ix','$00E8'],                   # [7C] via pointer+X -> TJMP2 (X=0)
['NOP',''],['NOP',''],                # fall-through only if 7C did not jump
['jmp2_s:'=>'','JMP.a','ERRPARK'],    # sentinel
['TJMP2:'=>'','LDA','#B2'],           # A=0xB2 landing marker
['JMP.a','SLED1'],                    # enter IRQ window
[ '--- IRQ window: 32-NOP sled; IRQ pulse lands here, handler -> CONT1 ---'],
['SLED1:'=>'','NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
[ '--- NMI window: 16-NOP sled; NMI pulse lands here, handler -> TAIL2 ---'],
['CONT1:'=>'','NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],['NOP',''],
[ '--- page-crossing BRA: at $08FD target $0905 crosses the $08FF/$0900 page ---'],
['TAIL2:'=>'','PADTO','$08FD'],
['BRA','PAGE2'],                     # $08FD-$08FE, next PC = $08FF
['NOP',''],['NOP',''],['NOP',''],    # fall-through $08FF..$0901 crosses the page
['JMP.a','ERRPARK'],                 # $0902 sentinel: only reached if BRA not taken
['PAGE2:'=>'','JMP.a','PARK'],       # $0905, offset +6
[ '================ Park / error park ================='],
['PARK:'=>'','JMP.a','PARK'],         # normal park (3-cycle self loop)
['ERRPARK:'=>'','JMP.a','ERRPARK'],   # error park (must never be reached)
[ 'Handlers live in %FIXED below (fixed addresses, outside program flow).' ],
[ '================ Subroutine ================='],
['SUB1:'=>'','LDA','#33'],
['PHA',''],
['PLA',''],
['RTS',''],
);

# Handlers are placed at fixed addresses (not in program flow): the generator
# copies IRQH/NMIH code there. Keep these small — they run with whatever
# register state the interrupt found.
our %FIXED = (
   'IRQH' => { addr => 0x1020, bytes => [
      ['LDA','#22'],['STA.z','$90'],['JMP.a','CONT1'] ] },
   'NMIH' => { addr => 0x1030, bytes => [
      ['LDA','#33'],['STA.z','$91'],['JMP.a','TAIL2'] ] },
);
