-- tb_keyb.vhd - misterkeyboard key-event capture (rtl/mister_keyboard.vhd)
--
-- hps_io changes ps2_key (code, extended, press, toggle) together in clk_sys; the
-- keyboard runs on the gated clk_48, whose clock arrives ~6.7 ns late, so in hardware
-- any bit may be captured one clock earlier or later than the others. This test drives
-- every ordering of toggle and data around a clock edge (toggle a clock early, data a
-- clock early, both together, mid-cycle) and checks each press and release lands on
-- the right key in the matrix, and that nothing else changes.
--
-- Run (GHDL):
--   ghdl -a --std=08 ../../rtl/mister_keyboard.vhd tb_keyb.vhd
--   ghdl -e --std=08 tb_keyb && ghdl -r --std=08 tb_keyb

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_keyb is
end entity;

architecture sim of tb_keyb is
    constant TCLK : time := 20.833 ns;   -- 48 MHz
    signal clk    : std_logic := '0';
    signal nrst   : std_logic := '0';
    signal key    : std_logic_vector(10 downto 0) := (others => '0');
    signal col    : std_logic_vector(3 downto 0) := (others => '0');
    signal row    : std_logic_vector(2 downto 0) := (others => '0');
    signal kp, intr, brk : std_logic;
    signal done   : boolean := false;

    type entry is record code : integer; c : integer; r : integer; end record;
    type table is array (natural range <>) of entry;
    -- scan code -> (column, row) as decoded by mister_keyboard.vhd
    constant KEYS : table := (
        (16#15#, 0, 1),  -- Q
        (16#76#, 0, 7),  -- ESCAPE
        (16#1C#, 1, 4),  -- A
        (16#29#, 2, 6),  -- SPACE
        (16#2C#, 3, 2),  -- T
        (16#3A#, 5, 6),  -- M
        (16#4D#, 7, 3),  -- P
        (16#05#, 1, 7),  -- F1
        (16#12#, 0, 0)   -- SHIFT
    );
begin
    clk <= not clk after TCLK / 2 when not done;

    dut: entity work.misterkeyboard port map (
        CLOCK => clk, nRESET => nrst, CLKEN_1MHZ => '0', MISTER_KEY => key,
        AUTOSCAN => '0', COLUMN => col, ROW => row,
        KEYPRESS => kp, INT => intr, BREAK_OUT => brk, DIP_SWITCH => x"00");

    stim: process
        variable tog   : std_logic := '0';
        variable nerr  : integer := 0;
        variable ntest : integer := 0;
        variable v     : std_logic;

        procedure probe(c, r : integer; v : out std_logic) is
        begin
            col <= std_logic_vector(to_unsigned(c, 4));
            row <= std_logic_vector(to_unsigned(r, 3));
            wait until rising_edge(clk);   -- col register follows COLUMN
            wait until rising_edge(clk);
            wait for 1 ns;
            v := kp;
        end procedure;

        -- key idx must read want; every other key in the table must be up
        procedure check_all(name : string; idx : integer; want : std_logic) is
            variable v : std_logic;
        begin
            ntest := ntest + 1;
            for i in KEYS'range loop
                probe(KEYS(i).c, KEYS(i).r, v);
                if i = idx and v /= want then
                    report name & ": key " & integer'image(i) & " reads " & std_logic'image(v) &
                           ", expected " & std_logic'image(want) severity error;
                    nerr := nerr + 1;
                elsif i /= idx and v /= '0' then
                    report name & ": unrelated key " & integer'image(i) & " is down" severity error;
                    nerr := nerr + 1;
                end if;
            end loop;
        end procedure;

        -- send one event. mode: 0 all bits together just after an edge,
        -- 1 toggle one clock BEFORE the data (worst case), 2 data one clock before toggle,
        -- 3 all together mid-cycle, 4 toggle just before an edge and data just after it
        procedure send(code : integer; press : std_logic; mode : integer) is
            variable d : std_logic_vector(9 downto 0);
        begin
            d := press & '0' & std_logic_vector(to_unsigned(code, 8));
            tog := not tog;
            wait until rising_edge(clk);
            case mode is
                when 0 => wait for 0.1 ns; key <= tog & d;
                when 1 => wait for 0.1 ns; key(10) <= tog;
                          wait until rising_edge(clk); wait for 0.1 ns; key(9 downto 0) <= d;
                when 2 => wait for 0.1 ns; key(9 downto 0) <= d;
                          wait until rising_edge(clk); wait for 0.1 ns; key(10) <= tog;
                when 3 => wait for TCLK / 2; key <= tog & d;
                when others =>
                          wait for TCLK - 0.1 ns; key(10) <= tog;
                          wait for 0.2 ns; key(9 downto 0) <= d;
            end case;
            for i in 1 to 10 loop wait until rising_edge(clk); end loop;
        end procedure;

        type names is array (0 to 4) of string(1 to 14);
        constant MODE_NAME : names := ("together      ", "toggle early  ", "data early    ",
                                       "mid-cycle     ", "split at edge ");
    begin
        wait for 5 * TCLK;
        nrst <= '1';
        wait for 5 * TCLK;
        check_all("after reset", -1, '0');

        for m in 0 to 4 loop
            for i in KEYS'range loop
                send(KEYS(i).code, '1', m);
                check_all(MODE_NAME(m) & " press", i, '1');
                send(KEYS(i).code, '0', m);
                check_all(MODE_NAME(m) & " release", i, '0');
            end loop;
            report "mode " & MODE_NAME(m) & ": done";
        end loop;

        -- rapid events: press A, then press Q only 4 clocks later (hps_io events are
        -- milliseconds apart); both must register
        wait until rising_edge(clk); wait for 0.1 ns;
        tog := not tog; key <= tog & "10" & x"1C";
        for i in 1 to 4 loop wait until rising_edge(clk); end loop; wait for 0.1 ns;
        tog := not tog; key <= tog & "10" & x"15";
        for i in 1 to 10 loop wait until rising_edge(clk); end loop;
        ntest := ntest + 1;
        probe(1, 4, v);
        if v /= '1' then report "rapid: A not down" severity error; nerr := nerr + 1; end if;
        probe(0, 1, v);
        if v /= '1' then report "rapid: Q not down" severity error; nerr := nerr + 1; end if;
        send(16#1C#, '0', 0);
        send(16#15#, '0', 0);
        check_all("rapid release", -1, '0');

        if nerr = 0 then
            report "ALL TESTS PASSED (" & integer'image(ntest) & " checks)";
        else
            report integer'image(nerr) & " ERRORS" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end architecture;
