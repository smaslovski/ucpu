----------------------------------------------------------------------------------
--
-- Minimalistic Harvard architecture uCPU with reduced instruction set
-- (C) 2022, Stanislav Maslovski <stanislav.maslovski@gmail.com>
--
-- Features:
--
--      - 12-bit instructions (4 bit opcode / 8 bit imm data or addr)
--      - 8-bit program counter (programs up to 256 instructions long)
--      - 8-bit accumulator with carry and zero flags
--      - up to 250 8-bit externally addressed data registers (RAM)
--      - two index registers with autoincrement / decrement
--      - executes 1 instruction per cycle
--
-- Instruction word format:
--
--        ,--------------.
--        |  1         0 |
--        | 109876543210 |
--        +--------------+
--        | cccixxxxxxxx |
--        '--------------'
--
-- where c - opcode bits, i - reg/imm bit, x - data or reg/addr bits.
--
-- Instruction set mnemonics / encoding table:
--
--    ,-----+---------+---------+------------------------------+-----+-------.
--    | ccc |  i = 0  |  i = 1  |          Description         | Flg |  hex  |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 000 | ANA reg | ANI imm | Acc & reg/imm to Acc         |  Z  | 0 + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 001 | XRA reg | XRI imm | Acc ^ reg/imm to Acc         |  Z  | 2 + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 010 | ADA reg | ADI imm | Acc + reg/imm to Acc         | C,Z | 4 + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 011 | SBA reg | CPI imm | Acc - reg/imm to Acc or none | C,Z | 6 + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 100 | BNC adr | BNZ adr | Branch to address if C/Z = 0 |     | 8 + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 101 | JPR reg | JMP adr | Jump to address in reg / adr |     | A + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 110 | LDA reg | LDI imm | Load accum from reg / imm    |     | C + i |
--    +-----+---------+---------+------------------------------+-----+-------+
--    | 111 | STA reg | ******* | Store accum to reg           |     | E + i |
--    `-----+---------+---------+------------------------------+-----+-------'
--
-- Combination ccci = 1111 is reserved for extensions.
--
-- Accessing registers F8 - FF invokes special addressing modes.
--
-- Regs F8 / F9 are shadow index registers aliased IX / IY with support
-- for autoincrement and decrement operation.
--
-- Actual addressing modes when the reg field is in the range F8 - FF:
--
--    ,------+----+----+------+------+-------+-------+-------+-------.
--    |  reg | F8 | F9 |  FA  |  FB  |  FC   |  FD   |   FE  |   FF  |
--    +------+----+----+------+------+-------+-------+-------+-------+
--    | mode | IX | IY | (IX) | (IY) | (IX)+ | (IY)+ | -(IX) | -(IY) |
--    '------+----+----+------+------+-------+-------+-------+-------'
--
-------------------------------------------------------------------------------

library ieee;
context ieee.ieee_std_context;
use work.uCPUtypes.all;

entity uCPU is
  port (
    rst, clk : in    logic;
    rom_addr : out   unsigned_byte;
    rom_data : in    code_word;
    ram_addr : out   unsigned_byte;
    ram_data : inout unsigned_byte;
    wr_en    : out   logic
  );
end entity uCPU;

architecture RTL of uCPU is

  -- opcode fields
  alias op      : unsigned(2 downto 0) is rom_data(11 downto 9);  -- opcode
  alias imm_bit : logic is rom_data(8);                           -- reg/imm bit
  alias imm_dat : unsigned_byte is rom_data(7 downto 0);          -- imm data

  -- uCPU registers
  signal PC     : unsigned_byte;  -- program counter
  signal IX, IY : unsigned_byte;  -- index registers
  signal Acc    : unsigned_byte;  -- accumulator
  signal CF, ZF : logic;          -- flags

  -- control signals
  signal alu_op, cpa_op, bnc_op, bnz_op, jmp_op, lda_op, sta_op, ext_op : logic;
  signal sta_ix, sta_iy : logic;
  signal ind_mod, inc_dec, dec_mod, inc_mod : logic;
  signal pc_wr, acc_wr, ix_wr, iy_wr, zf_wr, cf_wr : logic;

  -- other internal signals
  signal next_pc : unsigned_byte;
  signal idx, idx_new : unsigned_byte;
  signal alu_arg, alu_res, acc_mux : unsigned_byte;
  signal alu_c : logic;

begin

--------------- combination logic ----------------

-- bus signals

rom_addr <= PC;

ram_addr <= imm_dat when not ind_mod else
            idx_new when dec_mod else
            idx;

ram_data <= Acc when sta_op else x"ZZ";
wr_en    <= sta_op;

-- instruction decoder signals

alu_op <= not op(2);
cpa_op <= alu_op and (and op(1 downto 0)) and     imm_bit;
bnc_op <=  op(2) and (nor op(1 downto 0)) and not imm_bit;
bnz_op <=  op(2) and (nor op(1 downto 0)) and     imm_bit;
jmp_op <=  op(2) and  not op(1)           and     op(0);

lda_op <= (and op(2 downto 1)) and not op(0);
sta_op <= (and op(2 downto 0)) and not imm_bit;
ext_op <= (and op(2 downto 0)) and     imm_bit;

sta_ix <= '1' when sta_op = '1' and imm_dat = x"f8" else '0';
sta_iy <= '1' when sta_op = '1' and imm_dat = x"f9" else '0';

-- register write control signals

pc_wr  <= jmp_op or (bnc_op and not CF) or (bnz_op and not ZF);
acc_wr <= lda_op or (alu_op and not cpa_op);

ix_wr <= (sta_ix or inc_dec) and not imm_dat(0);
iy_wr <= (sta_iy or inc_dec) and imm_dat(0);

zf_wr <=  alu_op;
cf_wr <=  alu_op and op(1);

-- indirect addressing and autoincrement/decrement logic

ind_mod <= not imm_bit and not bnc_op and (and imm_dat(7 downto 3)) and (or imm_dat(2 downto 1));

inc_dec <= ind_mod and     imm_dat(2);
dec_mod <= inc_dec and     imm_dat(1);
inc_mod <= inc_dec and not imm_dat(1);

idx <= IY when imm_dat(0) else IX;

idx_new <= idx + 1 when inc_mod else
           idx - 1 when dec_mod else
           Acc     when sta_ix or sta_iy else
           idx;

-- ALU logic

alu_arg <= imm_dat when imm_bit else ram_data;

with op(1 downto 0) select
  (alu_c, alu_res) <= '0' & (Acc and alu_arg) when "00",
                      '0' & (Acc xor alu_arg) when "01",
                      ('0' & Acc) + alu_arg   when "10",
                      ('0' & Acc) - alu_arg   when "11",
                      ('X', x"XX")            when others;  -- meanigfull only for simulation

-- Accumulator input multiplexer

acc_mux <= alu_res when not lda_op else
           imm_dat when imm_bit else
           ram_data;

-- next PC value logic

next_pc <= PC + 1   when not pc_wr else
           imm_dat  when imm_bit or bnc_op else
           ram_data;

--------------- sequential logic -----------------

uCPU_state: process (clk)
begin
  if rising_edge(clk) then
    if rst then
      PC  <= (others => '0');
      IX  <= (others => '0');
      IY  <= (others => '0');
      Acc <= (others => '0');
      CF  <= '0';
      ZF  <= '0';
    else
      PC  <= next_pc;
      Acc <= acc_mux       when acc_wr else unaffected;
      IX  <= idx_new       when ix_wr  else unaffected;
      IY  <= idx_new       when iy_wr  else unaffected;
      ZF  <= (nor alu_res) when zf_wr  else unaffected;
      CF  <= alu_c         when cf_wr  else unaffected;
    end if;
  end if;
end process uCPU_state;

end architecture RTL;