OBJS=$(patsubst %.c,%.o,$(wildcard *.c))

PROG=ucasm

fib.hex : fib.uca $(PROG)
	./$(PROG) fib.uca fib.lst fib.hex

$(PROG) : $(OBJS)

all : fib.hex

clean :
	rm -f $(OBJS) *.lst

dist-clean : clean
	rm -f $(PROG) *.hex

.PHONY: all clean dist-clean
