-- tb_mouse.vhd - mouse event capture (rtl/mouse/mister_quadrature_controller.vhd)
--
-- Same clock-crossing case as tb_keyb.vhd: hps_io changes ps2_mouse (buttons, sign
-- bits, X and Y movement, toggle) together in clk_sys, and the controller runs on the
-- gated clk_48. Each event is sent with the toggle and the data arriving in every
-- order around a clock edge; the buttons must latch the new values, and the X and Y
-- quadrature outputs must make exactly 2 edges per unit of movement, in the right
-- phase order for the sign.
--
-- Run (GHDL; the mouse files use the Synopsys std_logic_arith/unsigned packages):
--   ghdl -a --std=08 -fsynopsys ../../rtl/mouse/quadrature_fsm.vhd \
--        ../../rtl/mouse/mister_quadrature_controller.vhd tb_mouse.vhd
--   ghdl -e --std=08 -fsynopsys tb_mouse && ghdl -r --std=08 -fsynopsys tb_mouse

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mouse is
end entity;

architecture sim of tb_mouse is
    constant TCLK : time := 20.833 ns;   -- 48 MHz
    signal clk    : std_logic := '0';
    signal rst    : std_logic := '1';
    signal ms     : std_logic_vector(24 downto 0) := (others => '0');
    signal xa, xb, ya, yb, lb, mb, rb : std_logic;
    signal done   : boolean := false;
    signal nxa, nxb, nya, nyb : integer := 0;     -- output edge counts
    signal firstx, firsty : character := ' ';     -- which output moved first
    signal clr_first : boolean := false;
begin
    clk <= not clk after TCLK / 2 when not done;

    dut: entity work.quadrature_controller port map (
        clk => clk, rst => rst, ps2_mouse => ms,
        x_a => xa, x_b => xb, y_a => ya, y_b => yb,
        left => lb, middle => mb, right => rb);

    count: process(clk)
        variable pxa, pxb, pya, pyb : std_logic := '0';
    begin
        if rising_edge(clk) then
            if clr_first then firstx <= ' '; firsty <= ' '; end if;
            if xa /= pxa then nxa <= nxa + 1; if firstx = ' ' then firstx <= 'a'; end if; end if;
            if xb /= pxb then nxb <= nxb + 1; if firstx = ' ' then firstx <= 'b'; end if; end if;
            if ya /= pya then nya <= nya + 1; if firsty = ' ' then firsty <= 'a'; end if; end if;
            if yb /= pyb then nyb <= nyb + 1; if firsty = ' ' then firsty <= 'b'; end if; end if;
            pxa := xa; pxb := xb; pya := ya; pyb := yb;
        end if;
    end process;

    stim: process
        variable tog   : std_logic := '0';
        variable nerr  : integer := 0;
        variable ntest : integer := 0;
        variable x0, xb0, y0, yb0 : integer;

        -- buttons b(2:0) = middle, right, left (ps2_mouse bits 2,1,0)
        procedure send(btn : std_logic_vector(2 downto 0); dx, dy : integer; mode : integer) is
            variable d : std_logic_vector(23 downto 0) := (others => '0');
        begin
            d(2 downto 0) := btn;
            d(4) := '1' when dx < 0 else '0';
            d(5) := '1' when dy < 0 else '0';
            d(15 downto 8)  := std_logic_vector(to_signed(dx, 8));
            d(23 downto 16) := std_logic_vector(to_signed(dy, 8));
            tog := not tog;
            wait until rising_edge(clk);
            case mode is
                when 0 => wait for 0.1 ns; ms <= tog & d;
                when 1 => wait for 0.1 ns; ms(24) <= tog;
                          wait until rising_edge(clk); wait for 0.1 ns; ms(23 downto 0) <= d;
                when 2 => wait for 0.1 ns; ms(23 downto 0) <= d;
                          wait until rising_edge(clk); wait for 0.1 ns; ms(24) <= tog;
                when 3 => wait for TCLK / 2; ms <= tog & d;
                when others =>
                          wait for TCLK - 0.1 ns; ms(24) <= tog;
                          wait for 0.2 ns; ms(23 downto 0) <= d;
            end case;
        end procedure;

        procedure expect(name : string; got, want : integer) is
        begin
            if got /= want then
                report name & ": got " & integer'image(got) & ", expected " & integer'image(want)
                    severity error;
                nerr := nerr + 1;
            end if;
        end procedure;

        procedure expect_c(name : string; got, want : character) is
        begin
            if got /= want then
                report name & ": " & got & " moved first, expected " & want severity error;
                nerr := nerr + 1;
            end if;
        end procedure;

        type pat is array (0 to 4) of std_logic_vector(2 downto 0);
        constant BTN : pat := ("001", "010", "100", "111", "000");
        type mv is array (0 to 4) of integer;
        constant DX : mv := (3, -2, 1, -4, 0);
        constant DY : mv := (-1, 2, 0, 3, -3);
    begin
        wait for 5 * TCLK;
        rst <= '0';
        wait for 5 * TCLK;

        for m in 0 to 4 loop
            x0 := nxa; xb0 := nxb; y0 := nya; yb0 := nyb;
            clr_first <= true; wait until rising_edge(clk); clr_first <= false;
            send(BTN(m), DX(m), DY(m), m);
            -- each unit is two 16384-clk phases; allow for the longest move plus margin
            for i in 1 to 2 * 16384 * 4 + 1000 loop wait until rising_edge(clk); end loop;
            ntest := ntest + 1;
            expect("mode " & integer'image(m) & " left",   to_integer(unsigned'('0' & lb)), to_integer(unsigned'('0' & BTN(m)(0))));
            expect("mode " & integer'image(m) & " right",  to_integer(unsigned'('0' & rb)), to_integer(unsigned'('0' & BTN(m)(1))));
            expect("mode " & integer'image(m) & " middle", to_integer(unsigned'('0' & mb)), to_integer(unsigned'('0' & BTN(m)(2))));
            expect("mode " & integer'image(m) & " X a edges", nxa - x0, abs DX(m));
            expect("mode " & integer'image(m) & " X b edges", nxb - xb0, abs DX(m));
            expect("mode " & integer'image(m) & " Y a edges", nya - y0, abs DY(m));
            expect("mode " & integer'image(m) & " Y b edges", nyb - yb0, abs DY(m));
            if DX(m) > 0 then expect_c("mode " & integer'image(m) & " X phase", firstx, 'a'); end if;
            if DX(m) < 0 then expect_c("mode " & integer'image(m) & " X phase", firstx, 'b'); end if;
            if DY(m) > 0 then expect_c("mode " & integer'image(m) & " Y phase", firsty, 'a'); end if;
            if DY(m) < 0 then expect_c("mode " & integer'image(m) & " Y phase", firsty, 'b'); end if;
            report "mode " & integer'image(m) & ": done";
        end loop;

        if nerr = 0 then
            report "ALL TESTS PASSED (" & integer'image(ntest) & " events)";
        else
            report integer'image(nerr) & " ERRORS" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end architecture;
