
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity quadrature_controller is
port(
    clk         : in std_logic;
    rst         : in std_logic;

	 ps2_mouse   : in std_logic_vector(24 downto 0);

    x_a         : out std_logic;
    x_b         : out std_logic;
    y_a         : out std_logic;
    y_b         : out std_logic;
    left        : out std_logic;
    middle      : out std_logic;
    right       : out std_logic
);
end quadrature_controller;

architecture Behavioral of quadrature_controller is

signal flg: std_logic;
signal ms_valid: std_logic;
signal ms_s: std_logic_vector(24 downto 0);   -- ps2_mouse captured from clk_sys
signal tog1, tog2: std_logic;


begin

	-- ps2_mouse comes from hps_io in clk_sys; clk is the gated clk_48, whose clock
	-- arrives ~6.7 ns late, so comparing flg with the live toggle could miss an event.
	-- Capture the whole word, then detect the toggle two clocks later, when every
	-- data bit has settled (as in mister_keyboard.vhd).
	ms_valid <= '1' when flg /= tog2 else '0';
	process(clk) begin
		if rising_edge(clk) then
			ms_s <= ps2_mouse;
			tog1 <= ms_s(24);
			tog2 <= tog1;
			flg  <= tog2;
		end if;
	end process;

    -- Instantiate seperate instances of the quadrature encoder state machine
    -- for X and Y directions
    quad_x_fsm: entity work.quadrature_fsm port map (clk, rst, ms_valid, ms_s(15 downto 8),  ms_s(4), x_a, x_b);
    quad_y_fsm: entity work.quadrature_fsm port map (clk, rst, ms_valid, ms_s(23 downto 16), ms_s(5), y_a, y_b);
              
    manage_fsm: process(clk,rst)
    begin
        if (rst = '1') then
            left   <= '0';
            middle <= '0';
            right  <= '0';
        elsif (rising_edge(clk)) then
            if ms_valid = '1' then
					left   <= ms_s(0);
					middle <= ms_s(2);
					right  <= ms_s(1);
				end if;
        end if;
    end process manage_fsm;

end Behavioral;
