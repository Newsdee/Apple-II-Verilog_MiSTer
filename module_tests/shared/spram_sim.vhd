-- Simulation-only replacement for work.spram (module_tests golden harnesses).
--
-- The real rtl/spram.vhd initializes its shared-variable RAM through the
-- ram_init_file attribute; GHDL does not honor that for the Quartus .mif
-- files used by this project, so golden simulations see an all-zero ROM.
--
-- This shim is behaviorally identical to spram.vhd (same generics, ports,
-- synchronous read, q <= data on write) and loads the ROM explicitly from a
-- plain hex file (whitespace-separated hex bytes, any wrapping):
--   "rtl/roms/video2.mif"  ->  "rtl/roms/video2.hex"
-- The .hex files in the Verilator repo rtl/roms/ were verified
-- byte-identical to the newsdee .mif sources (2026-08-28).
--
-- Harness runners must analyze THIS file into the work library INSTEAD OF
-- rtl/spram.vhd. Simulations run with CWD = Verilator repo root, so the
-- derived "rtl/roms/<name>.hex" path resolves. init_file must be non-empty.
--
-- Note: this GHDL build (6.0.0) has no resolvable file_open procedure, so
-- the file is opened with a VHDL-2008 open clause on a static name.
--
-- STATUS (2026-08-28): BLOCKED on a GHDL 6.0.0 codegen bug - signal
-- assignments are silently dropped when a case-based function call occurs
-- in the same loop (minimal repro: minrom5 works, minrom6 fails, same
-- code plus a nibble() case function). Workaround for the ROM-based
-- golden harnesses (video_generator/keyboard/apple2): generate the ROM
-- data as a VHDL constant array (the hdd_rom.vhd pattern) instead of
-- file I/O. See subagent_plan.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity spram is
    generic (
        addrbits  : integer := 9;
        databits  : integer := 7;
        init_file : string  := ""
    );
    port (
        address : in  std_logic_vector(addrbits-1 downto 0);
        clock   : in  std_logic := '1';
        data    : in  std_logic_vector(databits-1 downto 0);
        wren    : in  std_logic := '0';
        q       : out std_logic_vector(databits-1 downto 0)
    );
end entity spram;

architecture arch of spram is
    type ram_type is array(0 to (2**addrbits)-1) of std_logic_vector(databits-1 downto 0);
    signal mem : ram_type := (others => (others => '0'));

    impure function to_hex_path(f : in string) return string is
        variable slash, dot, n : integer;
        variable result : string(1 to f'length + 4);
    begin
        slash := 0;
        dot   := 0;
        for i in 1 to f'length loop
            if f(i) = '/' then slash := i; end if;
            if f(i) = '.' then dot   := i; end if;
        end loop;
        n := 0;
        if slash > 0 then
            for i in 1 to slash loop result(i) := f(i); end loop;
            n := slash;
        end if;
        if dot > slash then
            for i in slash+1 to dot-1 loop result(n + i - slash) := f(i); end loop;
            n := n + (dot - 1 - slash);
        else
            for i in slash+1 to f'length loop result(n + i - slash) := f(i); end loop;
            n := f'length;
        end if;
        result(n+1) := '.';
        result(n+2) := 'h';
        result(n+3) := 'e';
        result(n+4) := 'x';
        return result(1 to n+4);
    end function to_hex_path;

    constant hex_path : string := to_hex_path(init_file);

    impure function nibble(c : in character) return std_logic_vector is
    begin
        case c is
            when '0' => return "0000";
            when '1' => return "0001";
            when '2' => return "0010";
            when '3' => return "0011";
            when '4' => return "0100";
            when '5' => return "0101";
            when '6' => return "0110";
            when '7' => return "0111";
            when '8' => return "1000";
            when '9' => return "1001";
            when 'a' | 'A' => return "1010";
            when 'b' | 'B' => return "1011";
            when 'c' | 'C' => return "1100";
            when 'd' | 'D' => return "1101";
            when 'e' | 'E' => return "1110";
            when others    => return "1111";
        end case;
    end function nibble;
begin

    load : process
        file f : text open read_mode is hex_path;
        variable ln      : line;
        variable ch      : character;
        variable ok      : boolean;
        variable idx     : natural := 0;
        variable hi      : std_logic_vector(3 downto 0);
        variable have_hi : boolean := false;
        variable val     : std_logic_vector(7 downto 0);
    begin
        while (not endfile(f)) and (idx < mem'length) loop
            readline(f, ln);
            line_loop:
            loop
                read(ln, ch, ok);
                if not ok then
                    exit line_loop;
                end if;
                if (ch >= '0') and (ch <= '9') then
                    if not have_hi then
                        hi      := nibble(ch);
                        have_hi := true;
                    else
                        val     := hi & nibble(ch);
                        mem(idx) <= val;
                        idx      := idx + 1;
                        have_hi  := false;
                    end if;
                elsif (ch >= 'a') and (ch <= 'f') then
                    if not have_hi then
                        hi      := nibble(ch);
                        have_hi := true;
                    else
                        val     := hi & nibble(ch);
                        mem(idx) <= val;
                        idx      := idx + 1;
                        have_hi  := false;
                    end if;
                elsif (ch >= 'A') and (ch <= 'F') then
                    if not have_hi then
                        hi      := nibble(ch);
                        have_hi := true;
                    else
                        val     := hi & nibble(ch);
                        mem(idx) <= val;
                        idx      := idx + 1;
                        have_hi  := false;
                    end if;
                end if;
            end loop line_loop;
        end loop;
        -- Unconditional diagnostics: harnesses must be able to see the
        -- derived path and the word count even on a full load.
        report "spram shim: " & hex_path & " loaded " & integer'image(idx)
               & " of " & integer'image(mem'length) & " words" severity note;
        if idx /= mem'length then
            report "spram shim: INCOMPLETE LOAD " & hex_path & " (" &
                   integer'image(idx) & " of " & integer'image(mem'length)
                   & " words)" severity warning;
        end if;
        wait;
    end process load;

    process (clock)
    begin
        if (clock'event and clock = '1') then
            if wren = '1' then
                mem(to_integer(unsigned(address))) <= data;
                q <= data;
            else
                q <= mem(to_integer(unsigned(address)));
            end if;
        end if;
    end process;

end architecture arch;
