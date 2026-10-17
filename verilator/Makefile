#============================================================================
#  Sony SMC-777 Verilator simulation
#
#    make            # headless sim            -> ./obj_dir_headless/Vtop
#    make test       # regression tests (run_tests.sh)
#    make clean
#
#  The machine (rtl/smc777.sv) is SystemVerilog and goes to Verilator as is.
#  The CPU is the VHDL T80 (rtl/T80_v350, as SharpMZ2500_MiSTer), turned into a
#  Verilog netlist by "ghdl synth" with the generics of its instance fixed.
#
#  Requires: ghdl (5.x, synth built in), verilator (5.x), python3.
#============================================================================

V      = verilator
GHDL   = ghdl
RTL    = ../rtl
GEN    = gen
WORK   = ghdl_work

GHDL_FLAGS = --std=08 -fsynopsys -fexplicit -frelaxed -Wno-hide -Wno-shared -Wno-binding --workdir=$(WORK)

T80_SRC = $(RTL)/T80_v350/T80_ALU.vhd $(RTL)/T80_v350/T80_Reg.vhd $(RTL)/T80_v350/T80_MCode.vhd \
	$(RTL)/T80_v350/T80.vhd $(RTL)/T80_v350/T80s.vhd
GEN_V = $(GEN)/t80s.v

V_SRC = sim.v $(RTL)/smc777.sv $(RTL)/smc777_kbd.sv $(RTL)/smc777_fdc.sv $(RTL)/wd1793/wd1793.sv $(RTL)/wd1793/wd1793_mem.v $(GEN_V) $(RTL)/mc6845v/mc6845.v $(RTL)/sn76496/sn76496.v \
	$(RTL)/dpram.sv $(RTL)/spram.v

V_OPT = -O3 -I$(RTL) --x-assign fast --x-initial fast --noassert --savable \
	-Wno-fatal -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME -Wno-MULTIDRIVEN -Wno-LATCH \
	-Wno-TIMESCALEMOD -Wno-COMBDLY -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-CASEX

# EXTRA: more Verilator options
V_OPT += $(EXTRA)

CXXFLAGS = -O3 -std=c++17
HL_DIR   = obj_dir_headless
HL_EXE   = ./$(HL_DIR)/Vtop

all: headless

headless: $(HL_EXE)

# T80s as rtl/smc777.sv instantiates it: Mode 0 (Z80), T2Write 1, IOWait 1.
$(WORK)/.analysed: $(T80_SRC) Makefile
	@mkdir -p $(WORK)
	$(GHDL) -a $(GHDL_FLAGS) $(T80_SRC)
	@touch $@

$(GEN)/t80s.v: $(WORK)/.analysed fix_port_aliases.py
	@mkdir -p $(GEN)
	$(GHDL) synth $(GHDL_FLAGS) -gMode=0 -gT2Write=1 -gIOWait=1 --out=verilog T80s > $@.tmp
	$(GHDL) synth $(GHDL_FLAGS) -gMode=0 -gT2Write=1 -gIOWait=1 --out=vhdl T80s > $(GEN)/t80s_netlist.vhd
	python3 fix_port_aliases.py $@.tmp $(GEN)/t80s_netlist.vhd
	@# VHDL names that are (System)Verilog keywords.
	perl -pi -e 's/\b(do|config)\b/$${1}_v/g' $@.tmp
	@mv $@.tmp $@

netlist: $(GEN_V)

$(HL_EXE): $(V_SRC) $(RTL)/smc777_kbd_table.svh sim_headless.cpp ps2_keys.h Makefile
	$V -cc $(V_OPT) --exe --build -j 0 --Mdir $(HL_DIR) --top-module top \
		-CFLAGS "$(CXXFLAGS)" $(V_SRC) sim_headless.cpp -o Vtop

# Fast: clk_sys = the master clock (CLK_MUL 1), half the clocks per frame. Same machine timing (the CPU, CRTC and
# video run from the same enables), about twice as fast.
FAST_DIR = obj_dir_fast
FAST_EXE = ./$(FAST_DIR)/Vtop

fast: $(FAST_EXE)

$(FAST_EXE): $(V_SRC) $(RTL)/smc777_kbd_table.svh sim_headless.cpp ps2_keys.h Makefile
	$V -cc $(V_OPT) -DSMC_FAST_SIM --exe --build -j 0 --Mdir $(FAST_DIR) --top-module top \
		-CFLAGS "$(CXXFLAGS) -DSMC_FAST_SIM" $(V_SRC) sim_headless.cpp -o Vtop

test: headless
	./run_tests.sh

clean:
	rm -rf $(HL_DIR) $(FAST_DIR) $(GEN) $(WORK) out

.PHONY: all headless fast netlist test clean
