-- asynchronous ROM

library ieee;
context ieee.ieee_std_context;
use work.uCPUtypes.all;

entity ROM is
  port (
    abus : in  unsigned_byte;
    dbus : out code_word;
    en   : in  logic
  );
end entity ROM;

architecture RTL of ROM is
  type memory is array (0 to 255) of code_word;
  signal mem : memory := (
    x"D00", x"EF8", x"EF9", x"D01", x"EFD", x"EFB", x"CFC", x"4FD", x"EFB", x"806", x"B0A", others => x"000");
begin

dbus <= mem(to_integer(abus)) when en else x"ZZZ";

end architecture RTL;
