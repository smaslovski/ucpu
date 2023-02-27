library ieee;
context ieee.ieee_std_context;
use std.textio.all;
use std.env.all;
use work.uCPUtypes.all;

entity tb is end entity tb;

architecture behav of tb is
  signal rst, clk, wr_en : logic;
  signal rom_addr, ram_addr, ram_data : unsigned_byte;
  signal rom_data : code_word;
begin

CPU_instance: entity work.uCPU port map (rst, clk, rom_addr, rom_data, ram_addr, ram_data, wr_en);

ROM_instance: entity work.ROM port map (rom_addr, rom_data, '1');
RAM_instance: entity work.RAM port map (clk, ram_addr, ram_data, wr_en);

reset: rst <= '1', '0' after 20 ns;

clock: process
begin
  clk <= '0';
  wait for 10 ns;
  clk <= '1';
  wait for 10 ns;
end process clock;

write_log: postponed process (clk) is
  alias s is to_string [logic return string];
  alias s is to_string [unsigned_byte return string];
  alias h is to_hex_string [unsigned_byte return string];
  variable log_line : line;
begin
  swrite(log_line,
    "time: " & time'image(now) &
    ", rst: " & s(rst) & ", clk: " & s(clk) &
    ", rom_addr: " & h(rom_addr) & ", rom_data: " & s(rom_data) &
    ", ram_addr: " & h(ram_addr) & ", ram_data: " & h(ram_data) & ", wr_en: " & s(wr_en));
  writeline(output, log_line);
end postponed process write_log;

fin: process begin
  wait for 70*20 ns; finish;
end process fin;

end architecture behav;
