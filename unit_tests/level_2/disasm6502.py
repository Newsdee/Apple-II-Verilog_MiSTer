import sys
# 6502 formats: im=immediate, zp=zero-page, abs=absolute, zpX, zpY, absX, absY, indX=(zp,X), indY=(zp),Y, br=branch, acc, jmp, jmpind
F = {
 0x00:('BRK','im',0),0x01:('ORA','indX',0),0x05:('ORA','zp',0),0x06:('ASL','zp',0),0x08:('PHP','acc',0),0x09:('ORA','im',0),0x0A:('ASL','acc',0),0x0B:('ORA','zpY',1),0x0C:('CMP','abs',0),0x0D:('CMP','abs',0),0x0E:('CMP','abs',0),
 0x10:('BPL','br',0),0x11:('ORA','indY',0),0x15:('ORA','zpX',0),0x16:('ASL','zpX',0),0x18:('CLC','acc',0),0x19:('ORA','absY',0),0x1A:('NOP','acc',0),0x1B:('ORA','zpY',1),0x1C:('NOP','abs',1),0x1D:('CMP','absX',0),0x1E:('CMP','absX',0),
 0x20:('JSR','jmp',0),0x21:('AND','indX',1),0x24:('BIT','zp',0),0x25:('AND','zp',0),0x26:('ROL','zp',0),0x28:('PLP','acc',0),0x29:('AND','im',0),0x2A:('ROL','acc',0),0x2B:('AND','zpY',1),0x2C:('BIT','abs',0),0x2D:('BIT','abs',0),0x2E:('BIT','abs',0),
 0x30:('BMI','br',0),0x31:('AND','indY',0),0x35:('AND','zpX',0),0x36:('ROL','zpX',0),0x38:('SEC','acc',0),0x39:('AND','absY',0),0x3A:('NOP','acc',0),0x3B:('AND','zpY',1),0x3C:('NOP','abs',1),0x3D:('CMP','absX',0),0x3E:('CMP','absX',0),
 0x40:('RTI','acc',0),0x41:('EOR','indX',1),0x42:('JMP*','jmpind',1),0x44:('NOP','zp',1),0x45:('EOR','zp',0),0x46:('ROR','zp',0),0x48:('PHA','acc',0),0x49:('EOR','im',0),0x4A:('ROR','acc',0),0x4B:('EOR','zpY',1),0x4C:('JMP','jmp',0),0x4D:('EOR','abs',0),0x4E:('EOR','abs',0),
 0x50:('BVC','br',0),0x51:('EOR','indY',0),0x55:('EOR','zpX',0),0x56:('ROR','zpX',0),0x58:('CLI','acc',0),0x59:('EOR','absY',0),0x5A:('NOP','acc',0),0x5B:('EOR','zpY',1),0x5C:('NOP','abs',1),0x5D:('EOR','absX',0),0x5E:('EOR','absX',0),
 0x60:('RTS','acc',0),0x61:('ADC','indX',1),0x62:('JMP*','jmpind',1),0x64:('NOP','zp',1),0x65:('ADC','zp',0),0x66:('ROR','zp',0),0x68:('PLA','acc',0),0x69:('ADC','im',0),0x6A:('ROR','acc',0),0x6B:('ADC','zpY',1),0x6C:('JMP','jmpind',0),0x6D:('ADC','abs',0),0x6E:('ADC','abs',0),
 0x70:('BVS','br',0),0x71:('ADC','indY',0),0x75:('ADC','zpX',0),0x76:('ROR','zpX',0),0x78:('SEI','acc',0),0x79:('ADC','absY',0),0x7A:('NOP','acc',0),0x7B:('ADC','zpY',1),0x7C:('NOP','abs',1),0x7D:('ADC','absX',0),0x7E:('ADC','absX',0),
 0x80:('BRA','br',0),0x81:('STA','indX',1),0x84:('STY','zp',0),0x85:('STA','zp',0),0x86:('STX','zp',0),0x88:('DEY','acc',0),0x89:('STA','im',1),0x8A:('DEX','acc',0),0x8C:('STY','abs',0),0x8D:('STA','abs',0),0x8E:('STX','abs',0),
 0x90:('BCC','br',0),0x91:('STA','indY',0),0x95:('STA','zpX',0),0x96:('STX','zpY',0),0x98:('TYA','acc',0),0x99:('STA','absY',0),0x9A:('NOP','acc',0),0x9B:('STA','zpY',1),0x9C:('NOP','abs',1),0x9D:('STA','absX',0),0x9E:('STA','absX',0),
 0xA0:('LDY','im',0),0xA1:('LDX','indX',1),0xA2:('LDX','im',0),0xA4:('LDY','zp',0),0xA5:('LDA','zp',0),0xA6:('LDX','zp',0),0xA8:('LDY','acc',0),0xA9:('LDA','im',0),0xAA:('LDX','acc',0),0xAB:('LDX','zpY',1),0xAC:('LDY','abs',0),0xAD:('LDA','abs',0),0xAE:('LDX','abs',0),
 0xB0:('BCS','br',0),0xB1:('LDX','indY',0),0xB4:('LDY','zpX',0),0xB5:('LDX','zpX',0),0xB6:('LDY','zpY',0),0xB8:('CLV','acc',0),0xB9:('LDX','absY',0),0xBA:('NOP','acc',0),0xBB:('LDX','zpY',1),0xBC:('LDY','absX',0),0xBD:('LDA','absX',0),0xBE:('LDX','absX',0),
 0xC0:('CPY','im',0),0xC1:('CMP','indX',1),0xC2:('LDX','im',1),0xC4:('CPY','zp',0),0xC5:('CPA','zp',0),0xC6:('DEC','zp',0),0xC8:('INY','acc',0),0xC9:('CMP','im',0),0xCA:('DEX','acc',0),0xCC:('CPY','abs',0),0xCD:('CMP','abs',0),0xCE:('CMP','abs',0),
 0xD0:('BNE','br',0),0xD1:('CMP','indY',0),0xD4:('NOP','zp',1),0xD5:('CMP','zpX',0),0xD6:('DEC','zpX',0),0xD8:('CLD','acc',0),0xD9:('CMP','absY',0),0xDA:('NOP','acc',0),0xDB:('CMP','zpY',1),0xDC:('NOP','abs',1),0xDD:('CMP','absX',0),0xDE:('CMP','absX',0),
 0xE0:('CPX','im',0),0xE1:('SBC','indX',1),0xE2:('LDX','im',1),0xE4:('CPX','zp',0),0xE5:('CPA','zp',0),0xE6:('INC','zp',0),0xE8:('INX','acc',0),0xE9:('CMP','im',0),0xEA:('NOP','acc',0),0xEB:('CMP','zpY',1),0xEC:('CPX','abs',0),0xED:('CMP','abs',0),0xEE:('CMP','abs',0),
 0xF0:('BEQ','br',0),0xF1:('SBC','indY',0),0xF4:('NOP','zp',1),0xF5:('SBC','zpX',0),0xF6:('INC','zpX',0),0xF8:('SED','acc',0),0xF9:('SBC','absY',0),0xFA:('NOP','acc',0),0xFB:('SBC','zpY',1),0xFC:('NOP','abs',1),0xFD:('SBC','absX',0),0xFE:('SBC','absX',0),
}
SIZES = {'im':1,'zp':1,'abs':2,'zpX':1,'zpY':1,'absX':2,'absY':2,'indX':1,'indY':1,'br':1,'jmp':2,'jmpind':2,'acc':0}
data = open(sys.argv[1],'rb').read()
base = int(sys.argv[2],16) if len(sys.argv)>2 else 0
start = int(sys.argv[3],0) if len(sys.argv)>3 else 0
end = int(sys.argv[4],0) if len(sys.argv)>4 else len(data)
i = start
while i < min(end, len(data)):
    op = data[i]; a = base + i
    if op not in F:
        print('$%04X:  %02X ??' % (a, op)); i += 1; continue
    name, fmt, illegal = F[op]
    n = SIZES[fmt]
    if fmt in ('acc','br','jmp','jmpind','im','zp','zpX','zpY','indX','indY'):
        pass
    args = ''
    if fmt == 'im':
        args = '#$%02X' % data[i+1]
    elif fmt == 'zp':
        args = '$%02X' % data[i+1]
    elif fmt == 'zpX':
        args = '$%02X,X' % data[i+1]
    elif fmt == 'zpY':
        args = '$%02X,Y' % data[i+1]
    elif fmt in ('indX','indY'):
        z = data[i+1]
        args = '($%02X%s)' % (z, ',X' if fmt=='indX' else '),Y')
    elif fmt == 'abs':
        args = '$%02X%02X' % (data[i+2],data[i+1])
    elif fmt in ('absX','absY'):
        args = '$%02X%02X%s' % (data[i+2],data[i+1], ',X' if fmt=='absX' else ',Y')
    elif fmt == 'br':
        off = data[i+1]
        args = '$%04X' % (a + 2 + (off - 256 if off >= 128 else off))
    elif fmt in ('jmp','jmpind'):
        t = '$%02X%02X' % (data[i+2],data[i+1])
        args = ('(' + t + ')') if fmt=='jmpind' and op==0x6C else t
    flag = ' ; ILLEGAL' if illegal else ''
    print('$%04X:  %s %-10s %s%s' % (a, op, name, args, flag))
    i += 1 + n
