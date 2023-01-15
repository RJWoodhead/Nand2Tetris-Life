# NAND2Tetris-Life

This is an implementation of Conway's Game of Life for the [NAND2Tetris](https://www.nand2tetris.org) HACK machine, written in HACK assembly language. It plays the game on a 64x32 grid with wrap-around, has a simple editor with 2-level undo, and includes several stored sample grids.

Also included is an improved HACK assembler.

# User Interface

* Arrow keys or QWE/A D/ZXC to move cursor
* ` or S to set/reset a cell
* SPACE to step to next generation
* RETURN to free-run (until key is pressed)
* < or , to save current board into 2 level undo buffer
* \> or . to pop board from the undo buffer
* DEL to erase the entire board
* 0-4 to load sample boards

# Files

* life.asm is the source code for the game written in my improved version of HACK assembly language; it can be assembled using assembler.py; life.hack is the assembled output that can be run in the NAND2Tetris CPU Emulator
* assembler.py is an improved version of the HACK assembler that makes it much easier to write large HACK assembly programs (see below)
* boardmaker.py is a utility that generates compressed boards and miscellaneous tables that are copied into the Life program
* boarddump.py is a utility for extracting board info from HACK memory dumps, so boards can be designed using the program and then added to it as sample boards
* life-original.asm is my original 2016 version of Life, written in basic HACK assembler.

# The Assembler

The original HACK assembler is fine for the small programs typically written during the NAND2Tetris course, but it lacks some features that are useful when writing larger programs. My improved assembler adds the following functionality:

* 0b,0x,0o (boolean,hex,octal) and 'x' character constants.

* Simple expression arithmetic using constants and symbols w/parenthesis for precedence (but note that it doesn't handle */ vs +- operator precedence, it's first come first served).

* $symbol to declare a variable before use (allocates a variable slot for it).

* $symbol(size) to declare an array (allocates to next var slot + size-1 addrs).

* $symbol=[value] declares a variable and initializes it.

* $symbol(size)=Values,Values, ... ,Values does the same thing for an array.

* If the symbol is \_ (ie: $\_) an anonymous variable or variable block is allocated, so you can do stuff like $_(5)=1,2,3,4,5.

* #symbol=[value] defines a constant (doesn't allocate memory).

* As memory can't be initialized on program load, the assembler automatically creates the code to do any needed initializations and inserts a call to it at the top of your code!

* Checks for overflow on @instrs.

* Alternate operator for NOT (~) can be used in place of ! if so desired.

* Support for the undocumented NAND (^) and NOR (_) operators, as well as the -2 operation.

  Unfortunately, the CPU emulator does not emulate these extra instructions. :(

* Alternate format for comp section that gives precise control over alu bits.

  {AMD}:={0,-1,D,!D}{+,&}{0,-1,A,!A,M,!M}{;JMP}

  {AMD}:=!({0,-1,D,!D}{+,&}{0,-1,A,!A,M,!M}){;JMP}

  Similar to above, the CPU emulator only implements the bit patterns that are defined in the course documentation, so alternate alu settings that generate the same result as documented bit patterns don't work. But hope springs eternal.

* \ line continuation character (handy for defining large blocks of data).

* Can produce handy symbol tables that make debugging a bit easier.

* Note: internally generated symbols are prefaced by __ (dunder) characters; this prefix should be avoided in programs.
