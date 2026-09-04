#!/usr/bin/env python3
"""One-shot patcher: add TB_INJ state-injection ports to the HUC6280 RTL copies
in module_tests/huc6280/rtl_tb (test-adapter copies; originals untouched).

Idempotent: skips a file if injection branches already present.
"""
import io, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rtl_tb')

def patch(path, subs):
    p = os.path.join(ROOT, path)
    with io.open(p, 'r', encoding='utf-8', newline='') as f:
        s = f.read()
    if "TB_INJ = '1'" in s:
        print(f'== {path}: already patched, skipping')
        return
    eol = '\r\n' if s.count('\r\n') > s.count('\n') - s.count('\r\n') else '\n'
    for old, new in subs:
        old = old.replace('\n', eol)
        new = new.replace('\n', eol)
        if old not in s:
            print(f'!! {path}: pattern not found (eol={eol!r}):\n{old!r}')
            sys.exit(1)
        if s.count(old) != 1:
            print(f'!! {path}: pattern not unique ({s.count(old)}x):\n{old!r}')
            sys.exit(1)
        s = s.replace(old, new)
    with io.open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)
    print(f'== {path}: patched ({len(subs)} sites, eol={eol!r})')

T = '\t'

# ---------------- HUC6280_CPU copy ----------------
cpu = [
# A/X/Y
(f"""{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}if MC.AXY_CTRL(0) = '1' then""",
 f"""{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}A <= INJ_A;
{T}{T}{T}{T}X <= INJ_X;
{T}{T}{T}{T}Y <= INJ_Y;
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}if MC.AXY_CTRL(0) = '1' then"""),
# T
(f"""{T}{T}{T}T <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then 
{T}{T}{T}{T}case MC.LOAD_T is""",
 f"""{T}{T}{T}T <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}T <= (others=>'0');
{T}{T}{T}elsif EN = '1' then 
{T}{T}{T}{T}case MC.LOAD_T is"""),
# SP
(f"""{T}{T}{T}SP <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}case MC.LOAD_SP is""",
 f"""{T}{T}{T}SP <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}SP <= INJ_SP;
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}case MC.LOAD_SP is"""),
# P
(f"""{T}{T}{T}P <= "00000100";
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}case MC.LOAD_P is""",
 f"""{T}{T}{T}P <= "00000100";
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}P <= INJ_P;
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}case MC.LOAD_P is"""),
# SH/DH/LH
(f"""{T}{T}{T}SH <= (others=>'0');
{T}{T}{T}DH <= (others=>'0');
{T}{T}{T}LH <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then""",
 f"""{T}{T}{T}SH <= (others=>'0');
{T}{T}{T}DH <= (others=>'0');
{T}{T}{T}LH <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}SH <= (others=>'0');
{T}{T}{T}{T}DH <= (others=>'0');
{T}{T}{T}{T}LH <= (others=>'0');
{T}{T}{T}elsif EN = '1' then"""),
# MPR (add MPR_LAST to reset)
(f"""{T}{T}if RST_N = '0' then
{T}{T}{T}MPR(0) <= (others=>'0');
{T}{T}{T}MPR(1) <= (others=>'0');""",
 f"""{T}{T}if RST_N = '0' then
{T}{T}{T}MPR_LAST <= (others=>'0');
{T}{T}{T}MPR(0) <= (others=>'0');
{T}{T}{T}MPR(1) <= (others=>'0');"""),
# MPR injection
(f"""{T}{T}{T}MPR(7) <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}if IR = x"53" and LAST_CYCLE = '1' then\t--TAMi""",
 f"""{T}{T}{T}MPR(7) <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}MPR_LAST <= (others=>'0');
{T}{T}{T}{T}for i in 0 to 7 loop
{T}{T}{T}{T}{T}MPR(i) <= (others=>'0');
{T}{T}{T}{T}end loop;
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}if IR = x"53" and LAST_CYCLE = '1' then\t--TAMi"""),
# DR
(f"""{T}{T}{T}DR <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}DR <= DI;""",
 f"""{T}{T}{T}DR <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}DR <= (others=>'0');
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}DR <= DI;"""),
# TALT
(f"""{T}{T}{T}TALT <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}if STATE = "01101" then""",
 f"""{T}{T}{T}TALT <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}TALT <= '0';
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}if STATE = "01101" then"""),
# NMI sync
(f"""{T}{T}{T}OLD_NMI_N <= '1';
{T}{T}{T}NMI_SYNC <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if RES_INT = '0' then""",
 f"""{T}{T}{T}OLD_NMI_N <= '1';
{T}{T}{T}NMI_SYNC <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}OLD_NMI_N <= '1';
{T}{T}{T}{T}NMI_SYNC <= '0';
{T}{T}{T}elsif RES_INT = '0' then"""),
# interrupt latches
(f"""{T}{T}{T}GOT_INT <= '1';
{T}{T}{T}NMI_ACTIVE <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if RDY = '1' and CE = '1' then""",
 f"""{T}{T}{T}GOT_INT <= '1';
{T}{T}{T}NMI_ACTIVE <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}RES_INT <= '0';  -- normal operation (RES_INT=1 blocks WE_N writes)
{T}{T}{T}{T}NMI_INT <= '0';
{T}{T}{T}{T}IRQ1_INT <= '0';
{T}{T}{T}{T}IRQ2_INT <= '0';
{T}{T}{T}{T}IRQT_INT <= '0';
{T}{T}{T}{T}GOT_INT <= '0';
{T}{T}{T}{T}NMI_ACTIVE <= '0';
{T}{T}{T}elsif RDY = '1' and CE = '1' then"""),
# CS
(f"""{T}{T}{T}CS <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if EN = '1' then""",
 f"""{T}{T}{T}CS <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}CS <= '1';
{T}{T}{T}elsif EN = '1' then"""),
# AG port map
(f"""{T}{T}PC     \t\t=> PC, 
{T}{T}AA     \t\t=> AA
{T});""",
 f"""{T}{T}PC     \t\t=> PC, 
{T}{T}AA     \t\t=> AA,
{T}{T}TB_INJ\t\t=> TB_INJ,
{T}{T}INJ_PC\t\t=> INJ_PC
{T});""")
,# ALU port map
(f"""{T}{T}RES\t\t=> ALU_OUT
{T});""",
 f"""{T}{T}RES\t\t=> ALU_OUT,
{T}{T}TB_INJ\t\t=> TB_INJ
{T});""")
]
patch('huc6280_cpu_tb.vhd', cpu)

# ---------------- HUC6280_AG copy ----------------
ag = [
(f"""{T}{T}  PC\t\t\t\t: out std_logic_vector(15 downto 0);
        AA     \t\t: out std_logic_vector(15 downto 0)
    );
end HUC6280_AG;""",
 f"""{T}{T}  PC\t\t\t\t: out std_logic_vector(15 downto 0);
        AA     \t\t: out std_logic_vector(15 downto 0);

    -- Test-adapter injection port (module_tests/huc6280 benchmark)
    TB_INJ\t\t: in std_logic;
    INJ_PC\t\t: in std_logic_vector(15 downto 0)
    );
end HUC6280_AG;""")
,(f"""{T}{T}{T}PCr <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if CE = '1' then
{T}{T}{T}{T}PCr <= NextPC;""",
 f"""{T}{T}{T}PCr <= (others=>'0');
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}PCr <= INJ_PC;
{T}{T}{T}elsif CE = '1' then
{T}{T}{T}{T}PCr <= NextPC;"""),
(f"""{T}{T}{T}AAL <= (others=>'0');
{T}{T}{T}AAH <= (others=>'0');
{T}{T}{T}SavedCarry <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if CE = '1' then""",
 f"""{T}{T}{T}AAL <= (others=>'0');
{T}{T}{T}AAH <= (others=>'0');
{T}{T}{T}SavedCarry <= '0';
{T}{T}elsif rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}AAL <= (others=>'0');
{T}{T}{T}{T}AAH <= (others=>'0');
{T}{T}{T}{T}SavedCarry <= '0';
{T}{T}{T}elsif CE = '1' then"""),
]
patch('huc6280_ag_tb.vhd', ag)

# ---------------- ALU copy ----------------
alu = [
(f"""{T}{T}ZO\t\t: out std_logic; 
{T}{T}RES\t: out std_logic_vector(7 downto 0)
{T});
end ALU;""",
 f"""{T}{T}ZO\t\t: out std_logic; 
{T}{T}RES\t: out std_logic_vector(7 downto 0);

{T}{T}TB_INJ\t: in std_logic
{T});
end ALU;"""),
(f"""{T}{T}if rising_edge(CLK) then
{T}{T}{T}if EN = '1' then
{T}{T}{T}{T}SavedC <= AddCO;""",
 f"""{T}{T}if rising_edge(CLK) then
{T}{T}{T}if TB_INJ = '1' then
{T}{T}{T}{T}SavedC <= '0';
{T}{T}{T}elsif EN = '1' then
{T}{T}{T}{T}SavedC <= AddCO;"""),
]
patch('alu_tb.vhd', alu)

print('all patches applied')
