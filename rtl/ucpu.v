///////////////////////////////////////////////////////////////////////
//
// Minimalistic Harvard architecture uCPU with reduced instruction set
// (C) 2022, Stanislav Maslovski <stanislav.maslovski@gmail.com>
//
// Features:
//
//      - 12-bit instructions (4 bit opcode / 8 bit imm data or addr)
//      - 8-bit program counter (programs up to 256 instructions long)
//      - 8-bit accumulator with carry and zero flags
//      - up to 250 8-bit externally addressed data registers (RAM)
//      - two index registers with autoincrement / decrement
//      - executes 1 instruction per cycle
//
// Instruction word format:
//
//        ,--------------.
//        |  1         0 |
//        | 109876543210 |
//        +--------------+
//        | cccixxxxxxxx |
//        '--------------´
//
// where c - opcode bits, i - reg/imm bit, x - data or reg/addr bits.
//
// Instruction set mnemonics / encoding table:
//
//    ,-----+---------+---------+------------------------------+-----+-------.
//    | ccc |  i = 0  |  i = 1  |          Description         | Flg |  hex  |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 000 | ANA reg | ANI imm | Acc & reg/imm to Acc         |  Z  | 0 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 001 | XRA reg | XRI imm | Acc ^ reg/imm to Acc         |  Z  | 2 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 010 | ADA reg | ADI imm | Acc + reg/imm to Acc         | C,Z | 4 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 011 | SBA reg | CPI imm | Acc - reg/imm to Acc or none | C,Z | 6 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 100 | BNC adr | BNZ adr | Branch to address if C/Z = 0 |     | 8 + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 101 | JPR reg | JMP adr | Jump to address in reg / adr |     | A + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 110 | LDA reg | LDI imm | Load accum from reg / imm    |     | C + i |
//    +-----+---------+---------+------------------------------+-----+-------+
//    | 111 | STA reg | ******* | Store accum to reg           |     | E + i |
//    `-----+---------+---------+------------------------------+-----+-------´
//
// Combination ccci = 1111 is reserved for extensions.
//
// Accessing registers F8 - FF invokes special addressing modes.
//
// Regs F8 / F9 are shadow index registers aliased IX / IY with support
// for autoincrement and decrement operation.
//
// Actual addressing modes when the reg field is in the range F8 - FF:
//
//    ,------+----+----+------+------+-------+-------+-------+-------.
//    |  reg | F8 | F9 |  FA  |  FB  |  FC   |  FD   |   FE  |   FF  |
//    +------+----+----+------+------+-------+-------+-------+-------+
//    | mode | IX | IY | (IX) | (IY) | (IX)+ | (IY)+ | -(IX) | -(IY) |
//    '------+----+----+------+------+-------+-------+-------+-------'
//
///////////////////////////////////////////////////////////////////////

module uCPU (clk, rom_addr, rom_data, ram_addr, ram_data, wr_en, rst);

input  wire        clk, rst;
input  wire [11:0] rom_data;
inout  wire  [7:0] ram_data;
output wire        wr_en;
output wire  [7:0] rom_addr, ram_addr;

reg [7:0]  PC;      // program counter
reg [7:0]  IX, IY;  // index registers
reg [7:0]  Acc;     // accumulator
reg        CF, ZF;  // flags

wire [11:0] ID;      // internal instruction data bus
wire  [7:0] abus;    // internal RAM address bus
wire  [7:0] dbus;    // internal RAM data bus

assign rom_addr = PC;
assign ID       = rom_data;
assign ram_addr = abus;
assign ram_data = dbus;
//assign wr_en    = sta_op;

/////// extension: STX instruction ///////
assign wr_en    = sta_op | ext_op;
//////////////////////////////////////////

// instruction code fields

wire [2:0]      op = ID[11:9];
wire       imm_bit = ID[8];
wire [7:0] imm_dat = ID[7:0];

// instruction decoder

wire alu_op =   ~op[2];
wire cpa_op =   alu_op &  &op[1:0] &  imm_bit;
wire bnc_op =    op[2] & ~|op[1:0] & ~imm_bit;
wire bnz_op =    op[2] & ~|op[1:0] &  imm_bit;
wire jmp_op =    op[2] &    ~op[1] &    op[0];
wire lda_op = &op[2:1] &    ~op[0];
wire sta_op = &op[2:0] &  ~imm_bit;
wire ext_op = &op[2:0] &   imm_bit;

wire sta_ix =   sta_op & (imm_dat == 8'hF8);
wire sta_iy =   sta_op & (imm_dat == 8'hF9);

// register write control

wire pc_wr  = jmp_op | (bnc_op & ~CF) | (bnz_op & ~ZF);
wire acc_wr = lda_op | (alu_op & ~cpa_op);

wire ix_wr  = (sta_ix | inc_dec) & ~imm_dat[0];
wire iy_wr  = (sta_iy | inc_dec) &  imm_dat[0];

// flags write control

wire zf_wr =  alu_op;
wire cf_wr =  alu_op & op[1];

// indirect addressing and autoincrement/decrement logic

wire ind_mod = ~imm_bit & &imm_dat[7:3] & |imm_dat[2:1];
wire inc_dec =  ind_mod &  imm_dat[2];
wire dec_mod =  inc_dec &  imm_dat[1];
wire inc_mod =  inc_dec & ~imm_dat[1];

wire [7:0] idx = imm_dat[0] ? IY : IX;
reg  [7:0] idx_new;

always @*
  begin
    idx_new = idx;
    if (sta_ix | sta_iy)
      idx_new = Acc;
    if (inc_mod)
      idx_new = idx + 1'b1;
    if (dec_mod)
      idx_new = idx - 1'b1;
  end

// bus control

assign abus = ind_mod ? ( dec_mod ? idx_new : idx ) : imm_dat;

//assign dbus =  sta_op ? Acc : 8'bz;

/////////////// extension: STX instruction /////////////////
reg [7:0] X; // last used RAM data
wire x_en = ~imm_bit & ~bnc_op & ~sta_op;

always @(posedge clk)
  if (x_en)
    X <= ram_data;

assign dbus =  sta_op ? Acc : (ext_op ? X : 8'bz);
////////////////////////////////////////////////////////////

// ALU logic

wire [7:0] alu_arg = imm_bit ? imm_dat : ram_data;
reg  [7:0] alu_res;
reg        alu_c;

always @*
begin
  alu_c = 1'b0;
  case ( op[1:0] )
    2'b00: alu_res = Acc & alu_arg;
    2'b01: alu_res = Acc ^ alu_arg;
    2'b10: {alu_c, alu_res} = Acc + alu_arg;
    2'b11: {alu_c, alu_res} = Acc - alu_arg;
  endcase
end

// Accumulator input multiplexer

wire [7:0] acc_mux = lda_op ? ( imm_bit ? imm_dat : ram_data ) : alu_res;

// next PC value logic

reg [7:0] next_pc;

always @*
  begin
    next_pc = PC + 1'b1;
    if (pc_wr)
      next_pc = (imm_bit | bnc_op) ? imm_dat : ram_data;
  end

// update uCPU state

always @(posedge clk)
begin
  if (rst)
    begin
      PC <= 8'b0;
      IX <= 8'b0;
      IY <= 8'b0;
      Acc <= 8'b0;
      {CF, ZF} <= 2'b0;
    end
  else
    begin
      PC <= next_pc;
      if (acc_wr)
        Acc <= acc_mux;
      if (ix_wr)
        IX  <= idx_new;
      if (iy_wr)
        IY  <= idx_new;
      if (zf_wr)
        ZF  <= ~|alu_res;
      if (cf_wr)
        CF  <= alu_c;
    end
end

endmodule
