/*
 * Assembler for uCPU, version 0.1, 2022-06-22.
 * (C) 2022, Stanislav Maslovski <stanislav.maslovski@gmail.com>
 *
 * Source line BNF syntax:
 *
 * <source-line>   ::= <opt-label> <mnemonic> <operand> <opt-comment> | <opt-label> ";" <opt-comment> | <opt-label> | ""
 * <opt-label>     ::= <$-prefixed-dec> | ""
 * <mnemonic>      ::= "ANA" | "ANI" | "XRA" | "XRI" | "ADA" | "ADI" | "SBA" | "SBI" | "BNC" | "BNZ" | "JPR" | "JMP" | "LDA" | "LDI" | "STA" | "STX"
 * <operand>       ::= <two-hex> | <%-prefixed-two-hex> | "%IX" | "%IY" | <$-prefixed-dec> | <indir-modes>
 * <indir-modes>   ::= "@IX" | "@IY" | "@IX+" | "@IY+" | "@-IX" | "@-IY"
 * <opt-comment>   ::= <comment-text> | ""
 *
 * All tokens must be separated by white space. The syntax is case-insensitive.
 * <$-prefixed-dec> is an "$" followed by a positive decimal number with up to 4 digits. $1, $01, $001, etc., are all the same. Even $+01!
 * <two-hex> is a two digit hexadecimal number in the range 00 - FF, and <%-prefixed-two-hex> is the same prefixed by "%".
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>

#define LINE_WIDTH 256
#define LST_LINE_WIDTH (2*LINE_WIDTH)
#define INVALID ((unsigned)-1)

typedef enum {REG, IMM, LAB, IND} operand_t;

typedef struct {
    char *name;
    unsigned code;
    operand_t type;
} token_t;

const token_t token[18] = {
    /* instructions */
    {"ANA", 0x0, REG},
    {"ANI", 0x1, IMM},
    {"XRA", 0x2, REG},
    {"XRI", 0x3, IMM},
    {"ADA", 0x4, REG},
    {"ADI", 0x5, IMM},
    {"SBA", 0x6, REG},
    {"SBI", 0x7, IMM},
    {"BNC", 0x8, LAB},
    {"BNZ", 0x9, LAB},
    {"JPR", 0xA, REG},
    {"JMP", 0xB, LAB},
    {"LDA", 0xC, REG},
    {"LDI", 0xD, IMM},
    {"STA", 0xE, REG},
    {"STX", 0xF, REG},
#define ORG 0x10
    /* directives */
    {"ORG", ORG, IMM},
    {NULL,  INVALID, INVALID}
};

typedef struct {
    char *name;
    unsigned code;
} indreg_t;

const indreg_t indreg[9] = {
    {"%IX",  0xf8},
    {"%IY",  0xf9},
    {"@IX",  0xfa},
    {"@IY",  0xfb},
    {"@IX+", 0xfc},
    {"@IY+", 0xfd},
    {"@-IX", 0xfe},
    {"@-YY", 0xff},
    {NULL, INVALID}
};

void str_toupper(char *p) {
    while (!*p) {
	*p = toupper(*p);
	++p;
    }
}

unsigned parse_label(char *p, int base, unsigned max_width, unsigned max_val)
{
    char *q;
    unsigned lnum;

    lnum = strtoul(p, &q, base);
    if (lnum <= max_val && q - p <= max_width && !*q)
	return lnum;
    else
	return INVALID;
}

int putatpos(char *strbuf, int pos, ...)
{
    static char *buf;
    static int end;
    char *fmt;
    va_list ap;

    va_start(ap, pos);

    if (strbuf != NULL) {
	buf = strbuf;
	end = pos;
    } else {
	if (pos > end)
	    buf[end] = ' ';
	fmt = va_arg(ap, char *);
	pos += vsprintf(&buf[pos], fmt, ap);
	if (pos < end)
	    buf[pos] = ' ';
	else
	    end = pos;
    }

    va_end(ap);

    return pos;
}

int main(int argc, char *argv[])
{
    FILE *src_file, *lst_file, *hex_file;
    char line_buf[LINE_WIDTH];
    unsigned label[10000];
    unsigned rom[256];
    unsigned line_cnt;
    unsigned char pc;
    int i, j, second_pass = 0, syntax_error = 0, other_error = 0, warning = 0;

    if (argc != 4) {
	printf("Usage: %s <source> <listing> <hexdump>\n", argv[0]);
	return -1;
    }

    for (i = 0; i < 10000; ++i)
	label[i] = INVALID;

    src_file = fopen(argv[1], "r");
    lst_file = fopen(argv[2], "w");

    fprintf(lst_file, " ---- Source file: %s. Fist pass assembler listing. ----\n\n", argv[1]);

second_pass:

    pc = 0;
    line_cnt = 0;

    while (fgets(line_buf, LINE_WIDTH, src_file) != NULL) {
	char *p, *src_line, *lst_line, *msg, *comment = NULL, *name = NULL;
	unsigned lnum = INVALID, olnum = INVALID, optype = INVALID, opcode = INVALID;
	unsigned operand = 0;
        enum {LABEL, MNEMONIC, OPERAND, COMMENT} parser_state = LABEL;
	static const char *delim = " \t\n";
	static const char *format_str = "Syntax error: %s \"%s\". The source line is ignored.\n%4u:\t\t\t%s";

	src_line = strdup(line_buf);
	str_toupper(src_line);
	for (p = strtok(src_line, delim); p != NULL; p = strtok(NULL, delim)) {
	    switch (parser_state) {
		case LABEL:
		    if (*p == '$') {
			/* label present */
			lnum = parse_label(p + 1, 10, 4, 9999);
			if (!second_pass && lnum == INVALID) {
			    msg = "incorrect label";
			    goto syntax_error;
			}
			if (second_pass && label[lnum] != pc) {
			    ++warning;
			    fprintf(lst_file, "Warning: multiple definitions of label \"$%u\", the last definition wins.\n", lnum);
			}
			label[lnum] = pc;
			parser_state = MNEMONIC;
			continue;
		    }
		/* falling through if no label */
		case MNEMONIC:
		    if (*p == ';') {
			comment = p - src_line + line_buf;
			goto print_listing;
		    }
		    for (i = 0; token[i].name != NULL; ++i)
			if (memcmp(p, token[i].name, 3) == 0) {
			    name = token[i].name;
			    opcode = token[i].code;
			    optype = token[i].type;
			    break;
			}
		    if (!second_pass && name == NULL) {
			msg = "unexpected token";
			goto syntax_error;
		    }
		    if (opcode < ORG)
			rom[pc] = opcode << 8;
		    parser_state = OPERAND;
		    continue;
		case OPERAND:
		    if (*p == '$') {
			if (!second_pass && optype != LAB) {
			    msg = "incorrect operand";
			    goto syntax_error;
			}
			olnum = parse_label(p + 1, 10, 4, 9999);
			if (!second_pass && olnum == INVALID) {
			    msg = "incorrect label operand";
			    goto syntax_error;
			}
			if (label[olnum] == INVALID) {
			    if (second_pass) {
				++other_error;
				fprintf(lst_file, "Error: label \"$%u\" is not defined. Operand left uninitialized.\n", olnum);
			    }
			    break;
			}
			operand = label[olnum];
		    } else {
			for (i = 0; indreg[i].name != NULL; ++i)
			    if (strcmp(p, indreg[i].name) == 0) {
				operand = indreg[i].code;
				break;
			    }
			if (operand != 0) {
			    if (!second_pass && optype != REG)
			    {
				msg = "not allowed indexed mode operand";
				goto syntax_error;
			    }
			    goto set_operand;
			}
			if (*p == '%') {
			    if (!second_pass && optype != REG) {
				msg = "not allowed reg operand";
				goto syntax_error;
			    }
			    ++p;
			} else
			    if (!second_pass && optype == REG) {
				msg = "reg operand reguired, possibly add \"%%\" prefix to";
				goto syntax_error;
			    }
			operand = parse_label(p, 16, 2, 0xff);
			if (!second_pass && operand == INVALID) {
			    msg = "incorrect operand";
			    goto syntax_error;
			}
			if (opcode == ORG)
			    pc = operand;
		    }
set_operand:
		    if (opcode < ORG)
			rom[pc] |= operand;
		    parser_state = COMMENT;
		    continue;
		case COMMENT:
		    comment = p - src_line + line_buf;
		    goto print_listing;
	    }
	}

print_listing:

	lst_line = malloc(LST_LINE_WIDTH);
	memset(lst_line, ' ', LST_LINE_WIDTH);

	putatpos(lst_line, 0);

	putatpos(NULL, 0, "%4u:   %02X", line_cnt, pc);

	if (parser_state >= OPERAND && opcode < ORG)
    	    putatpos(NULL, 12, "%03X", rom[pc]);

	if (lnum != INVALID)
	    putatpos(NULL, 24, "$%u", lnum);

	if (parser_state >= OPERAND) {
	    putatpos(NULL, 32, "%s", name);
	    if (olnum != INVALID)
		putatpos(NULL, 40, "$%u", olnum);
	    else
		putatpos(NULL, 40, optype == REG ? "%%%02X" : "%3.02X", operand);

	    if (opcode < ORG)
		++pc;
	}

	if (comment != NULL)
	    putatpos(NULL, 48, "%s", comment);

	i = strlen(lst_line);
	if (lst_line[--i] != '\n') {
	    lst_line[++i] = '\n';
	    lst_line[++i] = 0;
	}

	fputs(lst_line, lst_file);
	free(lst_line);

	goto next_line;

syntax_error:

	++syntax_error;
	fprintf(lst_file, format_str, msg, p, line_cnt, line_buf);

next_line:

	free(src_line);
	++line_cnt;
    }

    /* do second pass */

    if (!syntax_error && !second_pass) {
        rewind(src_file);
	freopen(NULL, "w", lst_file);

	fprintf(lst_file, " ---- Source file: %s. Second pass assembler listing. ----\n\n", argv[1]);

	second_pass = 1;
	goto second_pass;
    }

    fclose(src_file);
    fclose(lst_file);

    if (syntax_error > 0) {
	fprintf(stderr, "There were %d syntax error(s), object file was not generated. Check listing file.\n", syntax_error);
	return 1;
    }

    if (other_error > 0 || warning > 0) {
	fprintf(stderr, "There were %d warning(s) and %d error(s). Check listing file.\n", warning, other_error);
    }


    hex_file = fopen(argv[3], "w");

    for (i = 0; i < 16; ++i) {
	for (j = 0; j < 16; ++j)
	    fprintf(hex_file, "%4.03X", rom[(i<<4)+j]);
	fputc('\n', hex_file);
    }

    fclose(hex_file);

    return 0;
}
