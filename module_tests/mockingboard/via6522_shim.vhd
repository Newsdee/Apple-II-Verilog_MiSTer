-- via6522_shim.vhd - GHDL-only helper for the via6522 equivalence harness.
--
-- The golden via6522.vhd uses Quartus-legal case/with-select choices on
-- std_logic_vector subjects. To normalize those to discrete (integer)
-- subjects without adding numeric_std (whose operators would overload the
-- file's existing std_logic_arith vector arithmetic), this shim provides a
-- self-contained binary-to-integer conversion. Analyzed before the golden
-- copy; the copy gains exactly one added use clause:
--     use work.via6522_shim.all;

library ieee;
use ieee.std_logic_1164.all;

package via6522_shim is
    function to_int_vec(v : std_logic_vector) return integer;
end package via6522_shim;

package body via6522_shim is
    function to_int_vec(v : std_logic_vector) return integer is
        variable r : integer := 0;
    begin
        for i in v'high downto v'low loop
            r := r * 2;
            if v(i) = '1' then
                r := r + 1;
            end if;
        end loop;
        return r;
    end function to_int_vec;
end package body via6522_shim;
