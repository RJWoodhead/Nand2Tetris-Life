//
// Conway's Game of Life in Hack Assembly language -- https://en.wikipedia.org/wiki/Conway's_Game_of_Life
//
// (C)2023 Robert Woodhead - trebor@animeigo.com / @madoverlord - Creative Commons Attribution License
//
// I am indebted to http://www.conwaylife.com/wiki/Main_Page, the LifeWiki, which is a great resource
// for finding interesting Life Patterns.
//
// Notes on implementation:
//
// Game Board: a 64x32 matrix of cells, wrapping around at the edges, so the board is effectively a torus.
// This maps onto the display screen with each cell taking up 8x8 pixels. The game board is stored as a
// 66x34 matrix with guard cells around the edges that are used to both simplify the code and implement
// the wrapping feature.
//
// Typical implementations of Life store multiple cells per word and use clever bit-banging techniques
// to update them in parallel to minimize the number of operations (especially memory fetches on machines
// where those are expensive). However, the Hack machine architecture is not well suited to these techniques
// so each cell is implemented as a full word; the sign bit contains the state of the cell in the current
// generation (so live = 1000 ... 0000 and dead = 0000 ... 0000). In the first pass, each cell has 1 added
// to it for each live neighbor. Then in a second pass, a table lookup is used to convert the neighbor count
// into the new value for the cell.
//
// Question: Currently the sign bit is used to indicate a live cell. This means we can check its status
// by simply loading the cell and branching based on the sign bit. If we use a simpler encoding scheme
// (say Lnnn, where L is the Live bit and nnn are the neighbor count) then we pay a cost of 2 instructions
// to mask off the Live bit when doing the neighbor count loop, but we don't need to have alternate branches
// for the update loop, we can just do a straight table lookup, which saves us more than 2. So it's a win.
// We can us Lnnn encoding because if we start with 1000 and have 8 neighbors, we get to 10000 which we can
// encode as a dead cell, and the L bit won't flip to 0 until after we've tested it and incremented
// the neighbor cells.
//
// Question: If above is true, can we pack 2 cells in a word and get efficiency of update? Maybe use LSbits
// of field as live bit? Answer: No, because we don't have good shift instructions. But if we used table
// lookup to get the update masks for left and right? Again, no; the gain from being able to do two
// cells at a time is offset by the difficulty of the update (table lookups, adds instead of simple increments)
//
// Keyboard commands:
//
// 0-9		Load prestored board (0 = logo board)
// Space 	Compute Next Generation
// Return 	Free-run until another key pressed
// Arrows 	Move editing cursor up/down/right/left
// Q W E 	8-way cursor movement
// A   D
// Z X C
// ` or S 	Toggle current cell
// DEL 		Clear board
// < or ,	Save board in temp buffer (2 levels)
// > or . 	Restore board from temp buffer (2 levels)
//
// Note: HACK CPU emulator returns uppercase keyboard keys regardless of state of SHIFT or CAPSLOCK keys!

// Key program variables

$Life.x=32
$Life.y=16
$Life.key.repeat=0
$Life.blink=1
$Life.speed=32767

// Update tables for live and dead cells, giving new state for each number of neighbors

$LiveTable(9)=0x0000,0x0000,0x8000,0x8000,0x0000,0x0000,0x0000,0x0000,0x0000
$DeadTable(9)=0x0000,0x0000,0x0000,0x8000,0x0000,0x0000,0x0000,0x0000,0x0000

// Divide-by-2 table, because HACK doesn't have a shift-right :(

$Div2(64)=0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,\
    16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,26,26,27,27,28,28,29,29,30,30,31,31

// Table of bitmaps used to blink the cursor (2 cells per word in SCREEN memory)

$BlinkMask(2)=0b0000000000111100,0b0011110000000000

// Table of addresses of starting cells in each row

$Board.Row(32)=Board+67,Board+133,Board+199,Board+265,Board+331,Board+397,Board+463,Board+529,\
  Board+595,Board+661,Board+727,Board+793,Board+859,Board+925,Board+991,Board+1057,Board+1123,\
  Board+1189,Board+1255,Board+1321,Board+1387,Board+1453,Board+1519,Board+1585,Board+1651,\
  Board+1717,Board+1783,Board+1849,Board+1915,Board+1981,Board+2047,Board+2113

// Board data storage (and undo buffers)

$Board(66*34)
$Undo(66*34)
$Undo2(66*34)

// Predefined boards are defined at end of file

	@SCREEN 		// SP = SCREEN - 1
	D = A - 1
	@SP
	M = D

// Initial Logo Load (ILL) will set up the board

	@ILL.Ret		// D = ILL return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Logo.Board 	// D = Address of the compressed board image
	D = A

	@Load_Board 	// Load_Board()
	0 ; JMP

(ILL.Ret)			// Return from Load_Board here

// Initialize cursor location and state

	@KBD 			// Life.key = [KBD]
	D = M
	@Key.Pressed
	M = D

	@Key.Up 		// Skip to end of key processing loop if we have a key
	D ; JNE 		// This handles issue of stale key on program start

// Loop processing keys, blinking cursor while waiting

(Key.Down) 			// Loop until key pressed

	@KBD 			// D = [KBD]
	D = M

	@Key.Pressed 	// if a key has been pressed, process it
	D ; JNE

	D = D 			// NOP instructions to slow down this loop
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D
	D = D

	@Life.blink 	// if --Life.blink == 0, blink cursor
	MD = M - 1
	@Key.Down
	D ; JNE

// Blink the cursor

(Blink)

	@Life.speed 	// Life.blink = Life.speed (resets blink count)
	D = M
	@Life.blink
	M = D

// Compute the location in the screen buffer of the current cursor position.
// There are 32 bytes per row, and 8 rows per cell. 32*8 = 256. We also skip
// 2 rows because we only modify the central 4x4 pixels of a cell. We could
// use a table for *256 but speed isn't needed here.

	@Life.y 		// Blink.row = (Life.y * 256) + SCREEN + 64
	AD = M          // we can get a little clever here by storing the results
	AD = D + A      // in both A and D, and then adding them together.
	AD = D + A
	AD = D + A
	AD = D + A
	AD = D + A
	AD = D + A
	AD = D + A
	AD = D + A
	@SCREEN+64      // Skip the two rows
	D = D + A
	@Blink.row
	M = D

// Each word in the screen buffer holds the bits for two adjacent cells. Do a
// table lookup to get the desired bitmap.

	D = 1			// D = the low bit of Life.x
	@Life.x
	D = D & M
	@BlinkMask		// D = BlinkMask[D]
	A = D + A
	D = M

	@Blink.mask 	// Blink.mask = XOR mask of bits to flip
	M = D

	@Life.x 		// Blink.row = Blink.row + Div.2[Life.x]
	D = M 			// Since we don't have a shift-right instruction
	@Div2 			// we use a lookup table
	A = D + A
	D = M

	@Blink.row 		// Also save Blink.row in A, so M then points
	AM = D + M 		// to the first word in screem memory we want to alter

	D = M 			// Blink.word = [Blink.row]
	@Blink.word
	M = D

	@Blink.mask 	// Blink.new = Blink.word XOR Blink.mask
	D = D | M 		// XOR(A,B) = (A|B) & !(A&B)
	@Blink.or
	M = D

	@Blink.word
	D = M
	@Blink.mask
	D = D & M
	D = !D

	@Blink.or
	D = D & M

	@Blink.new
	M = D

	@Blink.row 		// [Blink.row] = Blink.new
	A = M
	M = D

	@Blink.row 		// [Blink.row += 32] = Blink.new
	D = M
	@32
	D = D + A
	@Blink.row
	M = D

	@Blink.new
	D = M

	@Blink.row
	A = M
	M = D

	@Blink.row 		// [Blink.row += 32] = Blink.new
	D = M
	@32
	D = D + A
	@Blink.row
	M = D

	@Blink.new
	D = M

	@Blink.row
	A = M
	M = D

	@Blink.row 		// [Blink.row += 32] = Blink.new
	D = M
	@32
	D = D + A
	@Blink.row
	M = D

	@Blink.new
	D = M

	@Blink.row
	A = M
	M = D

	@Key.Down 		// Resume looking for a key
	0 ; JMP

(Key.Pressed)

	@Life.key 		// @Life.key = D
	M = D

	// Arrow keys

	@Life.key 		// Up
	D = M
	@KBD_UPARROW
	D = D - A
	@Key.MoveUp
	D ; JEQ

	@Life.key 		// Down
	D = M
	@KBD_DOWNARROW
	D = D - A
	@Key.MoveDown
	D ; JEQ

	@Life.key 		// Right
	D = M
	@KBD_RIGHTARROW
	D = D - A
	@Key.MoveRight
	D ; JEQ

	@Life.key 		// Left
	D = M
	@KBD_LEFTARROW
	D = D - A
	@Key.MoveLeft
	D ; JEQ

	// 8-way keys

	@Life.key 		// W = Up
	D = M
	@"W"
	D = D - A
	@Key.MoveUp
	D ; JEQ

	@Life.key 		// X = Down
	D = M
	@"X"
	D = D - A
	@Key.MoveDown
	D ; JEQ

	@Life.key 		// D = Right
	D = M
	@"D"
	D = D - A
	@Key.MoveRight
	D ; JEQ

	@Life.key 		// A = Left
	D = M
	@"A"
	D = D - A
	@Key.MoveLeft
	D ; JEQ

	@Life.key 		// Q = Up-Left
	D = M
	@"Q"
	D = D - A
	@Key.MoveUpLeft
	D ; JEQ

	@Life.key 		// E = Up-Right
	D = M
	@"E"
	D = D - A
	@Key.MoveUpRight
	D ; JEQ

	@Life.key 		// Z = Down-Left
	D = M
	@"Z"
	D = D - A
	@Key.MoveDownLeft
	D ; JEQ

	@Life.key 		// C = Down-Right
	D = M
	@"C"
	D = D - A
	@Key.MoveDownRight
	D ; JEQ

	@Life.key 		// Space bar?
	D = M
	@KBD_SPACE 			
	D = D - A
	@Key.Space 			
	D ; JEQ

	@Life.key 		// Enter
	D = M
	@KBD_NEWLINE
	D = D - A
	@Key.Enter
	D ; JEQ

	@Life.key 		// DEL
	D = M
	@KBD_BACKSPACE
	D = D - A
	@Key.Clear
	D ; JEQ

	@Life.key 		// ` = Toggle cell
	D = M
	@96
	D = D - A
	@Key.Toggle
	D ; JEQ

	@Life.key 		// S = Toggle cell
	D = M
	@"S"
	D = D - A
	@Key.Toggle
	D ; JEQ

	@Life.key 		// < = Save buffer
	D = M
	@"<"
	D = D - A
	@Key.Save
	D ; JEQ

	@Life.key 		// > = Restore buffer
	D = M
	@">"
	D = D - A
	@Key.Restore
	D ; JEQ

	@Life.key 		// , = Save buffer
	D = M
	@","
	D = D - A
	@Key.Save
	D ; JEQ

	@Life.key 		// . = Restore buffer
	D = M
	@"."
	D = D - A
	@Key.Restore
	D ; JEQ

	// other keys here

	// Last thing we check is loading prestored patterns. First, we
	// prepare for an eventual function call to Load_Board(), with
	// a direct return to the end of our keyboard handler

	@Key.Up
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	// Next, we look for a pattern key and set the D register with the
	// address of the board. The simple way is to subtract "0" from
    // the key, and then keep decrementing it until we get a 0 result
    // (or fall off the end)

	@Life.key
	D = M
	@"0"
	D = D - A

	@Key.Pattern0
	D ; JEQ

	D = D - 1
	@Key.Pattern1
	D ; JEQ

	D = D - 1
	@Key.Pattern2
	D ; JEQ

	D = D - 1
	@Key.Pattern3
	D ; JEQ

	D = D - 1
	@Key.Pattern4
	D ; JEQ

	D = D - 1
	@Key.Pattern5
	D ; JEQ

	D = D - 1
	@Key.Pattern6
	D ; JEQ

	D = D - 1
	@Key.Pattern7
	D ; JEQ

	D = D - 1
	@Key.Pattern8
	D ; JEQ

	D = D - 1
	@Key.Pattern9
	D ; JEQ

	// Room for more patterns if and when needed

(Key.Pattern6)
(Key.Pattern7)
(Key.Pattern8)
(Key.Pattern9)

	// If we get to here, we don't have a valid board, so we need
	// to restore the SP

	@SP 			// Pop the un-needed return address off stack
	M = M + 1

	@Key.Up 		// And skip to the bottom of the handler
	0 ; JMP

(Key.Pattern0)
	
	@Logo.Board
	D = A
	@Load_Board 	// Load_Board() will return to Key.Up
	0 ; JMP

(Key.Pattern1)

	@Oscillator.Board
	D = A
	@Load_Board 	// Load_Board() will return to Key.Up
	0 ; JMP

(Key.Pattern2)

	@Gliders.Board
	D = A
	@Load_Board 	// Load_Board() will return to Key.Up
	0 ; JMP

(Key.Pattern3)

	@Gosper.Glider.Gun
	D = A
	@Load_Board 	// Load_Board() will return to Key.Up
	0 ; JMP

(Key.Pattern4)

	@Beacon.Maker
	D = A
	@Load_Board 	// Load_Board() will return to Key.Up
	0 ; JMP

(Key.Pattern5)

	@Blinker.Puffer
	D = A
	@Load_Board 	// Load_Board() will return to Key.Up
	0 ; JMP

// Space bar - run a generation

(Key.Space)

	@Key.Space.Ret	// D = Generation return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Generation 	// Generation()
	0 ; JMP

(Key.Space.Ret)

	@Key.Up
	0 ; JMP

// C - clear the board

(Key.Clear)

	@Key.Change		// D = return directly to Key.Change handler below
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Clear_Board 	// Clear_Board()
	0 ; JMP

// S - save the board (two levels of save)

(Key.Save)

	@Key.Save.2		// D = return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Undo-1 		// Copy Undo buffer to Undo-2 buffer
	D = A           // Use address-1 for efficiency
	@Key.Board.From
	M = D

	@Undo2-1
	D = A
	@Key.Board.To
	M = D

	@Key.Buffer.Copy
	0 ; JMP

(Key.Save.2)

	@Key.Change		// D = return directly to Key.Change handler below
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Board-1 		// Copy Board to Undo buffer
	D = A
	@Key.Board.From
	M = D

	@Undo-1
	D = A
	@Key.Board.To
	M = D

	@Key.Buffer.Copy
	0 ; JMP

// R - Restore the board

(Key.Restore)

	@Key.Restore.2	// D = return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Board-1        // Copy Undo buffer to Board
	D = A
	@Key.Board.To
	M = D

	@Undo-1
	D = A
	@Key.Board.From
	M = D

	@Key.Buffer.Copy
	0 ; JMP

(Key.Restore.2)

	@Key.Change		// D = return directly to Key.Change handler below
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Undo-1         // Copy Undo2 buffer to Undo buffer
	D = A
	@Key.Board.To
	M = D

	@Undo2-1
	D = A
	@Key.Board.From
	M = D

	// fall through to copy

(Key.Buffer.Copy)

	@2244 				// Key.Board.Count = 2244 (Board Size)
	D = A
	@Key.Board.Count
	M = D

(Key.Buffer.Copy.Top)	// repeat [++Key.Board.To] = [++Key.Board.From] until (--Key.Board.Count == 0)

	@Key.Board.From 	// D = [++Key.Board.From]
	AM = M + 1
	D = M

	@Key.Board.To 		// [++Key.Board.To] = D
	AM = M + 1
	M = D

	@Key.Board.Count 	// Loop
	MD = M - 1
	@Key.Buffer.Copy.Top
	D ; JNE

	// return to caller

	@SP 			// Jump to [++SP]
	AM = M + 1
	A = M
	0 ; JMP

// UpLeft - move cursor

(Key.MoveUpLeft)

	@63 		// Life.x = (Life.x-1) & 03F (63)
	D = A 		// then fall through to move up
	@Life.x
	M = M - 1
	M = D & M

// Up - move cursor

(Key.MoveUp)

	@31 		// Life.y = (Life.y-1) & 01F (31)
	D = A
	@Life.y
	M = M - 1
	M = D & M

	@Key.Change
	0 ; JMP

// DownRight - move cursor

(Key.MoveDownRight)

	@63 		// Life.x = (Life.x+1) & 03F (63)
	D = A 		// then fall through to move down
	@Life.x
	M = M + 1
	M = D & M

// Down - move cursor

(Key.MoveDown)

	@31 		// Life.y = (Life.y+1) & 01F (31)
	D = A
	@Life.y
	M = M + 1
	M = D & M

	@Key.Change
	0 ; JMP

// DownLeft - move cursor

(Key.MoveDownLeft)

	@31 		// Life.y = (Life.y+1) & 01F (31)
	D = A 		// then fall through to move left
	@Life.y
	M = M + 1
	M = D & M

// Left - move cursor

(Key.MoveLeft)

	@63 		// Life.x = (Life.x-1) & 03F (63)
	D = A
	@Life.x
	M = M - 1
	M = D & M

	@Key.Change
	0 ; JMP

// UpRight - move cursor

(Key.MoveUpRight)

	@31 		// Life.y = (Life.y-1) & 01F (31)
	D = A 		// then fall through to move right
	@Life.y
	M = M - 1
	M = D & M

// Right - move cursor

(Key.MoveRight)

	@63 		// Life.x = (Life.x+1) & 03F (63)
	D = A
	@Life.x
	M = M + 1
	M = D & M

	@Key.Change
	0 ; JMP

// toggle current cell

(Key.Toggle)

	@Life.y         // Cell Address = Board.Row[Life.y] + Life.x
	D = M
	@Board.Row
	A = A + D
    D = M

 	@Life.x         // Add in X value to get the address
	D = D + M       // of the cell we want to toggle

    @Cur.Cell       // Save it for later and move to
    AM = D          // A register so we can look at it

    D = M           // Get value of cell

    @Key.Flip.Dead  // If dead, make alive, and vice-versa
    D ; JEQ

(Key.Flip.Alive)
    D = 0           // Dead = 0
    @Cur.Cell       // Address of current cell
    A = M
    M = D           // Update value
	@Key.Change     // And return
	0 ; JMP

(Key.Flip.Dead)
    @0x4000         // Alive = 0x8000, but we can't load that value
    D = A           // so we load 0x4000 and add it twice.
    D = D + A
    @Cur.Cell       // Address of current cell
    A = M
    M = D           // Update value
	@Key.Change     // And return
	0 ; JMP

// Enter - run generations until another key pressed

(Key.Enter)

	@Key.Enter.Ret	// D = Generation return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Generation 	// Generation()
	0 ; JMP

(Key.Enter.Ret)

	@KBD 			// Do another generation if KBD == Life.key (either 128 or 0)
	D = M
	@Life.key
	D = D - M
	@Key.Enter
	D ; JEQ

	@Life.key 		// Reset the current key (so we will catch "no key" just above, but now Enter will stop us)
	M = 0

	@KBD 			// If no key, we can loop
	D = M
	@Key.Enter
	D ; JEQ

	@Life.key 		// Restore Life.key to current key, so it'll be debounced below
	M = D

	@Key.Up 		// Terminate looping
	0 ; JMP

// Handle changes in state by repainting the screen (and jump to Key.Up handler on return)

(Key.Change)

	@Key.Up			// D = return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Paint_Board 	// Paint_Board()
	0 ; JMP

// Bottom of key processing loop

(Key.Up)			// Loop until KBD no longer Life.key (either new key or key up)

	@Life.key
	D = M
	@KBD
	D = D - M
	@Key.Up
	D ; JEQ

	@Key.Down 		// Return to checking for new key
	0 ; JMP

// Done infinite loop (not actually reachable)

	@DONE
(DONE)
	0 ; JMP

// Generation: runs a single generation of Life, then updates the board display

(Generation)
(G)

	// Phase 1: for each living cell (not counting the guard cells), increment all
	// the neighbors, so they have a count of how many neighbors they have. Note that
	// we can plow through all the guard cells on left and right because they will
	// always be dead, and it's faster to do this than do a double-loop with skip.

	@Board+67 		// G.cell = Address of the first real cell
	D = A
	@G.cell
	M = D

(G.1.Top) 			// repeat check_cell until ++G.cell == Board+2177 (1 past last cell)

	@G.cell 		// if [G.cell] >= 0, skip to bottom of loop (it's dead)
	A = M
	D = M
	@G.1.Bottom
	D ; JGE

	@G.cell 		// [G.cell-67]++ (top-left neighbor)
	D = M
	@67
	A = D - A
	M = M + 1

	A = A + 1 		// [G.cell-66]++ (top neighbor)
	M = M + 1

	A = A + 1 		// [G.cell-65]++ (top-right neighbor)
	M = M + 1

	D = A 			// [G.cell-1]++ (left neighbor)
	@64
	A = D + A
	M = M + 1

	A = A + 1 		// [G.cell+1]++ (right neighbor)
	A = A + 1
	M = M + 1

	D = A 			// [G.cell+65]++ (bottom-left neighbor)
	@64
	A = D + A
	M = M + 1

	A = A + 1 		// [G.cell+66]++ (bottom neighbor)
	M = M + 1

	A = A + 1 		// [G.cell+67]++ (bottom-right neighbor)
	M = M + 1

(G.1.Bottom)

	@G.cell 		// D,G.cell = G.cell + 1
	MD = M + 1
	@Board+2177 			// if (G.cell != First Guard Cell) goto G.1.Top
	D = D - A
	@G.1.Top
	D ; JNE

	// Phase 2: add the counts in the guard cells to their respective border cells
	// on the opposite edge, and clear the guard cells. Here is a map of the guard
	// cells and the edge cells
	//
	// 0000 0001 ..... 0064 0065
	// 0066 0067 ..... 0130 0131
	//   .    .          .    .
	//   .    .          .    .
	// 2112 2113 ..... 2176 2177
	// 2178 2179 ..... 2242 2243
	//
	// The following code was auto-generated by boardmaker.py. This is a case where
	// unrolling the loops is a big win because we don't have to do address arithmetic.

	@Board+0
	D = M
	M = 0
	@Board+2176
	M = M + D

	@Board+65
	D = M
	M = 0
	@Board+2113
	M = M + D

	@Board+2178
	D = M
	M = 0
	@Board+130
	M = M + D

	@Board+2243
	D = M
	M = 0
	@Board+67
	M = M + D

	@Board+1
	D = M
	M = 0
	@Board+2113
	M = M + D

	@Board+2179
	D = M
	M = 0
	@Board+67
	M = M + D

	@Board+2
	D = M
	M = 0
	@Board+2114
	M = M + D

	@Board+2180
	D = M
	M = 0
	@Board+68
	M = M + D

	@Board+3
	D = M
	M = 0
	@Board+2115
	M = M + D

	@Board+2181
	D = M
	M = 0
	@Board+69
	M = M + D

	@Board+4
	D = M
	M = 0
	@Board+2116
	M = M + D

	@Board+2182
	D = M
	M = 0
	@Board+70
	M = M + D

	@Board+5
	D = M
	M = 0
	@Board+2117
	M = M + D

	@Board+2183
	D = M
	M = 0
	@Board+71
	M = M + D

	@Board+6
	D = M
	M = 0
	@Board+2118
	M = M + D

	@Board+2184
	D = M
	M = 0
	@Board+72
	M = M + D

	@Board+7
	D = M
	M = 0
	@Board+2119
	M = M + D

	@Board+2185
	D = M
	M = 0
	@Board+73
	M = M + D

	@Board+8
	D = M
	M = 0
	@Board+2120
	M = M + D

	@Board+2186
	D = M
	M = 0
	@Board+74
	M = M + D

	@Board+9
	D = M
	M = 0
	@Board+2121
	M = M + D

	@Board+2187
	D = M
	M = 0
	@Board+75
	M = M + D

	@Board+10
	D = M
	M = 0
	@Board+2122
	M = M + D

	@Board+2188
	D = M
	M = 0
	@Board+76
	M = M + D

	@Board+11
	D = M
	M = 0
	@Board+2123
	M = M + D

	@Board+2189
	D = M
	M = 0
	@Board+77
	M = M + D

	@Board+12
	D = M
	M = 0
	@Board+2124
	M = M + D

	@Board+2190
	D = M
	M = 0
	@Board+78
	M = M + D

	@Board+13
	D = M
	M = 0
	@Board+2125
	M = M + D

	@Board+2191
	D = M
	M = 0
	@Board+79
	M = M + D

	@Board+14
	D = M
	M = 0
	@Board+2126
	M = M + D

	@Board+2192
	D = M
	M = 0
	@Board+80
	M = M + D

	@Board+15
	D = M
	M = 0
	@Board+2127
	M = M + D

	@Board+2193
	D = M
	M = 0
	@Board+81
	M = M + D

	@Board+16
	D = M
	M = 0
	@Board+2128
	M = M + D

	@Board+2194
	D = M
	M = 0
	@Board+82
	M = M + D

	@Board+17
	D = M
	M = 0
	@Board+2129
	M = M + D

	@Board+2195
	D = M
	M = 0
	@Board+83
	M = M + D

	@Board+18
	D = M
	M = 0
	@Board+2130
	M = M + D

	@Board+2196
	D = M
	M = 0
	@Board+84
	M = M + D

	@Board+19
	D = M
	M = 0
	@Board+2131
	M = M + D

	@Board+2197
	D = M
	M = 0
	@Board+85
	M = M + D

	@Board+20
	D = M
	M = 0
	@Board+2132
	M = M + D

	@Board+2198
	D = M
	M = 0
	@Board+86
	M = M + D

	@Board+21
	D = M
	M = 0
	@Board+2133
	M = M + D

	@Board+2199
	D = M
	M = 0
	@Board+87
	M = M + D

	@Board+22
	D = M
	M = 0
	@Board+2134
	M = M + D

	@Board+2200
	D = M
	M = 0
	@Board+88
	M = M + D

	@Board+23
	D = M
	M = 0
	@Board+2135
	M = M + D

	@Board+2201
	D = M
	M = 0
	@Board+89
	M = M + D

	@Board+24
	D = M
	M = 0
	@Board+2136
	M = M + D

	@Board+2202
	D = M
	M = 0
	@Board+90
	M = M + D

	@Board+25
	D = M
	M = 0
	@Board+2137
	M = M + D

	@Board+2203
	D = M
	M = 0
	@Board+91
	M = M + D

	@Board+26
	D = M
	M = 0
	@Board+2138
	M = M + D

	@Board+2204
	D = M
	M = 0
	@Board+92
	M = M + D

	@Board+27
	D = M
	M = 0
	@Board+2139
	M = M + D

	@Board+2205
	D = M
	M = 0
	@Board+93
	M = M + D

	@Board+28
	D = M
	M = 0
	@Board+2140
	M = M + D

	@Board+2206
	D = M
	M = 0
	@Board+94
	M = M + D

	@Board+29
	D = M
	M = 0
	@Board+2141
	M = M + D

	@Board+2207
	D = M
	M = 0
	@Board+95
	M = M + D

	@Board+30
	D = M
	M = 0
	@Board+2142
	M = M + D

	@Board+2208
	D = M
	M = 0
	@Board+96
	M = M + D

	@Board+31
	D = M
	M = 0
	@Board+2143
	M = M + D

	@Board+2209
	D = M
	M = 0
	@Board+97
	M = M + D

	@Board+32
	D = M
	M = 0
	@Board+2144
	M = M + D

	@Board+2210
	D = M
	M = 0
	@Board+98
	M = M + D

	@Board+33
	D = M
	M = 0
	@Board+2145
	M = M + D

	@Board+2211
	D = M
	M = 0
	@Board+99
	M = M + D

	@Board+34
	D = M
	M = 0
	@Board+2146
	M = M + D

	@Board+2212
	D = M
	M = 0
	@Board+100
	M = M + D

	@Board+35
	D = M
	M = 0
	@Board+2147
	M = M + D

	@Board+2213
	D = M
	M = 0
	@Board+101
	M = M + D

	@Board+36
	D = M
	M = 0
	@Board+2148
	M = M + D

	@Board+2214
	D = M
	M = 0
	@Board+102
	M = M + D

	@Board+37
	D = M
	M = 0
	@Board+2149
	M = M + D

	@Board+2215
	D = M
	M = 0
	@Board+103
	M = M + D

	@Board+38
	D = M
	M = 0
	@Board+2150
	M = M + D

	@Board+2216
	D = M
	M = 0
	@Board+104
	M = M + D

	@Board+39
	D = M
	M = 0
	@Board+2151
	M = M + D

	@Board+2217
	D = M
	M = 0
	@Board+105
	M = M + D

	@Board+40
	D = M
	M = 0
	@Board+2152
	M = M + D

	@Board+2218
	D = M
	M = 0
	@Board+106
	M = M + D

	@Board+41
	D = M
	M = 0
	@Board+2153
	M = M + D

	@Board+2219
	D = M
	M = 0
	@Board+107
	M = M + D

	@Board+42
	D = M
	M = 0
	@Board+2154
	M = M + D

	@Board+2220
	D = M
	M = 0
	@Board+108
	M = M + D

	@Board+43
	D = M
	M = 0
	@Board+2155
	M = M + D

	@Board+2221
	D = M
	M = 0
	@Board+109
	M = M + D

	@Board+44
	D = M
	M = 0
	@Board+2156
	M = M + D

	@Board+2222
	D = M
	M = 0
	@Board+110
	M = M + D

	@Board+45
	D = M
	M = 0
	@Board+2157
	M = M + D

	@Board+2223
	D = M
	M = 0
	@Board+111
	M = M + D

	@Board+46
	D = M
	M = 0
	@Board+2158
	M = M + D

	@Board+2224
	D = M
	M = 0
	@Board+112
	M = M + D

	@Board+47
	D = M
	M = 0
	@Board+2159
	M = M + D

	@Board+2225
	D = M
	M = 0
	@Board+113
	M = M + D

	@Board+48
	D = M
	M = 0
	@Board+2160
	M = M + D

	@Board+2226
	D = M
	M = 0
	@Board+114
	M = M + D

	@Board+49
	D = M
	M = 0
	@Board+2161
	M = M + D

	@Board+2227
	D = M
	M = 0
	@Board+115
	M = M + D

	@Board+50
	D = M
	M = 0
	@Board+2162
	M = M + D

	@Board+2228
	D = M
	M = 0
	@Board+116
	M = M + D

	@Board+51
	D = M
	M = 0
	@Board+2163
	M = M + D

	@Board+2229
	D = M
	M = 0
	@Board+117
	M = M + D

	@Board+52
	D = M
	M = 0
	@Board+2164
	M = M + D

	@Board+2230
	D = M
	M = 0
	@Board+118
	M = M + D

	@Board+53
	D = M
	M = 0
	@Board+2165
	M = M + D

	@Board+2231
	D = M
	M = 0
	@Board+119
	M = M + D

	@Board+54
	D = M
	M = 0
	@Board+2166
	M = M + D

	@Board+2232
	D = M
	M = 0
	@Board+120
	M = M + D

	@Board+55
	D = M
	M = 0
	@Board+2167
	M = M + D

	@Board+2233
	D = M
	M = 0
	@Board+121
	M = M + D

	@Board+56
	D = M
	M = 0
	@Board+2168
	M = M + D

	@Board+2234
	D = M
	M = 0
	@Board+122
	M = M + D

	@Board+57
	D = M
	M = 0
	@Board+2169
	M = M + D

	@Board+2235
	D = M
	M = 0
	@Board+123
	M = M + D

	@Board+58
	D = M
	M = 0
	@Board+2170
	M = M + D

	@Board+2236
	D = M
	M = 0
	@Board+124
	M = M + D

	@Board+59
	D = M
	M = 0
	@Board+2171
	M = M + D

	@Board+2237
	D = M
	M = 0
	@Board+125
	M = M + D

	@Board+60
	D = M
	M = 0
	@Board+2172
	M = M + D

	@Board+2238
	D = M
	M = 0
	@Board+126
	M = M + D

	@Board+61
	D = M
	M = 0
	@Board+2173
	M = M + D

	@Board+2239
	D = M
	M = 0
	@Board+127
	M = M + D

	@Board+62
	D = M
	M = 0
	@Board+2174
	M = M + D

	@Board+2240
	D = M
	M = 0
	@Board+128
	M = M + D

	@Board+63
	D = M
	M = 0
	@Board+2175
	M = M + D

	@Board+2241
	D = M
	M = 0
	@Board+129
	M = M + D

	@Board+64
	D = M
	M = 0
	@Board+2176
	M = M + D

	@Board+2242
	D = M
	M = 0
	@Board+130
	M = M + D

	@Board+66
	D = M
	M = 0
	@Board+130
	M = M + D

	@Board+131
	D = M
	M = 0
	@Board+67
	M = M + D

	@Board+132
	D = M
	M = 0
	@Board+196
	M = M + D

	@Board+197
	D = M
	M = 0
	@Board+133
	M = M + D

	@Board+198
	D = M
	M = 0
	@Board+262
	M = M + D

	@Board+263
	D = M
	M = 0
	@Board+199
	M = M + D

	@Board+264
	D = M
	M = 0
	@Board+328
	M = M + D

	@Board+329
	D = M
	M = 0
	@Board+265
	M = M + D

	@Board+330
	D = M
	M = 0
	@Board+394
	M = M + D

	@Board+395
	D = M
	M = 0
	@Board+331
	M = M + D

	@Board+396
	D = M
	M = 0
	@Board+460
	M = M + D

	@Board+461
	D = M
	M = 0
	@Board+397
	M = M + D

	@Board+462
	D = M
	M = 0
	@Board+526
	M = M + D

	@Board+527
	D = M
	M = 0
	@Board+463
	M = M + D

	@Board+528
	D = M
	M = 0
	@Board+592
	M = M + D

	@Board+593
	D = M
	M = 0
	@Board+529
	M = M + D

	@Board+594
	D = M
	M = 0
	@Board+658
	M = M + D

	@Board+659
	D = M
	M = 0
	@Board+595
	M = M + D

	@Board+660
	D = M
	M = 0
	@Board+724
	M = M + D

	@Board+725
	D = M
	M = 0
	@Board+661
	M = M + D

	@Board+726
	D = M
	M = 0
	@Board+790
	M = M + D

	@Board+791
	D = M
	M = 0
	@Board+727
	M = M + D

	@Board+792
	D = M
	M = 0
	@Board+856
	M = M + D

	@Board+857
	D = M
	M = 0
	@Board+793
	M = M + D

	@Board+858
	D = M
	M = 0
	@Board+922
	M = M + D

	@Board+923
	D = M
	M = 0
	@Board+859
	M = M + D

	@Board+924
	D = M
	M = 0
	@Board+988
	M = M + D

	@Board+989
	D = M
	M = 0
	@Board+925
	M = M + D

	@Board+990
	D = M
	M = 0
	@Board+1054
	M = M + D

	@Board+1055
	D = M
	M = 0
	@Board+991
	M = M + D

	@Board+1056
	D = M
	M = 0
	@Board+1120
	M = M + D

	@Board+1121
	D = M
	M = 0
	@Board+1057
	M = M + D

	@Board+1122
	D = M
	M = 0
	@Board+1186
	M = M + D

	@Board+1187
	D = M
	M = 0
	@Board+1123
	M = M + D

	@Board+1188
	D = M
	M = 0
	@Board+1252
	M = M + D

	@Board+1253
	D = M
	M = 0
	@Board+1189
	M = M + D

	@Board+1254
	D = M
	M = 0
	@Board+1318
	M = M + D

	@Board+1319
	D = M
	M = 0
	@Board+1255
	M = M + D

	@Board+1320
	D = M
	M = 0
	@Board+1384
	M = M + D

	@Board+1385
	D = M
	M = 0
	@Board+1321
	M = M + D

	@Board+1386
	D = M
	M = 0
	@Board+1450
	M = M + D

	@Board+1451
	D = M
	M = 0
	@Board+1387
	M = M + D

	@Board+1452
	D = M
	M = 0
	@Board+1516
	M = M + D

	@Board+1517
	D = M
	M = 0
	@Board+1453
	M = M + D

	@Board+1518
	D = M
	M = 0
	@Board+1582
	M = M + D

	@Board+1583
	D = M
	M = 0
	@Board+1519
	M = M + D

	@Board+1584
	D = M
	M = 0
	@Board+1648
	M = M + D

	@Board+1649
	D = M
	M = 0
	@Board+1585
	M = M + D

	@Board+1650
	D = M
	M = 0
	@Board+1714
	M = M + D

	@Board+1715
	D = M
	M = 0
	@Board+1651
	M = M + D

	@Board+1716
	D = M
	M = 0
	@Board+1780
	M = M + D

	@Board+1781
	D = M
	M = 0
	@Board+1717
	M = M + D

	@Board+1782
	D = M
	M = 0
	@Board+1846
	M = M + D

	@Board+1847
	D = M
	M = 0
	@Board+1783
	M = M + D

	@Board+1848
	D = M
	M = 0
	@Board+1912
	M = M + D

	@Board+1913
	D = M
	M = 0
	@Board+1849
	M = M + D

	@Board+1914
	D = M
	M = 0
	@Board+1978
	M = M + D

	@Board+1979
	D = M
	M = 0
	@Board+1915
	M = M + D

	@Board+1980
	D = M
	M = 0
	@Board+2044
	M = M + D

	@Board+2045
	D = M
	M = 0
	@Board+1981
	M = M + D

	@Board+2046
	D = M
	M = 0
	@Board+2110
	M = M + D

	@Board+2111
	D = M
	M = 0
	@Board+2047
	M = M + D

	// Phase 3: use the previous generation state and the count of neighbors to update
	// the cells.

	@Board+67 			// G.cell = first possible active cell
	D = A
	@G.cell
	M = D

(G.3.Top) 			// repeat ... until ++G.cell = Board+2177 (guard cell after last live cell)

	@G.cell 		// D = [G.cell]
	A = M
	D = M

	@G.3.Live 		// if D < 0 it's a live cell
	D ; JLT

(G.3.Dead)

	@G.3.Next 		// if D == 0 break (efficiency hack; costs 2 instructions, saves 8 if dead
	D ; JEQ 		// cell has no neighbors. A win if this is the case > 25% of the time)

	@DeadTable 			// D = DeadTable[D]
	A = A + D
	D = M

	@G.3.Set 		// Jump down to setter
	0 ; JMP

(G.3.Live)

	@15 			// D = LiveTable[D & 1111] (we need to mask off the sign bit)
	D = D & A
	@LiveTable
	A = A + D
	D = M

(G.3.Set)

	@G.cell 		// [G.cell] = D
	A = M
	M = D

(G.3.Next)

	@G.cell 		// D = ++G.cell
	MD = M + 1

	@Board+2177 			// if G.cell < Guard Cell loop
	D = D - A
	@G.3.Top
	D ; JLT

	// Jump directly to Paint_Board() without pushing return
	// address on stack. It will return to my caller!

	@Paint_Board
	0 ; JMP

// Load_Board (LB) function. Expects address of board data loader code in D. Clears the board, unpacks the data,
// and sets up the cells.

(Load_Board)
(LB)

    @LB.board       // Save the new board's address
    M=D

	// Clear the board by calling Clear_Board (CB) function

	@LB.Ret2 		// D = Clear board return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Clear_Board 	// Clear_Board()
	0 ; JMP

(LB.Ret2)

	@Board+67 		// LB.cell = first real cell is at 1,1 = +66+1
	D = A
	@LB.cell
	M = D

	@32 			// LB.row = 32 (number of rows we need to read)
	D = A
	@LB.row
	M = D

(LB.forRow) 		// repeat Load_Board_Row() while (--LB.row > 0)

	@LB.forRow.Ret 	// D = Load_Board_Row return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Load_Board_Row // Load_Board_Row()
	0 ; JMP

(LB.forRow.Ret)

	@LB.row 		// LB.row,D = LB.row - 1
	MD = M - 1
	
	@LB.forRow 		// Loop if LB.row > 0
	D ; JGT

	// Paint the board by jumping directly to Paint_Board()
	// It will return to my caller.

	@Paint_Board
	0 ; JMP

// Load_Board_Row function. Load a single row from 4 words starting at LB.board into
// 64 cells starting at LB.cell, then move LB.cell to the first cell of the next row
// and LB.board to the first word of the next row of board information.

(Load_Board_Row)
(LBR)

	@4 					// LBR.word = 4
	D = A
	@LBR.word
	M = D

(LBR.forWord) 			// repeat Load_Board_Word while (--LBR.word > 0)

	@LBR.forWord.Ret 	// D = Load_Board_Row return address
	D = A

	@SP 				// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Load_Board_Word	// Load_Board_Word()
	0 ; JMP

(LBR.forWord.Ret)

	@LBR.word 			// LBR.word,D = LBR.word - 1
	MD = M - 1
	
	@LBR.forWord		// Loop if LB.row > 0
	D ; JGT

	@LB.cell 			// LB.cell = LB.cell + 2
	M = M + 1
	M = M + 1

	// return to caller

	@SP 			// Jump to [++SP]
	AM = M + 1
	A = M
	0 ; JMP

// Load_Board_Word(D): Use the 16 bits of [LB.board] to set the next
// D cells starting at [LB.cell]; increment LB.board and LB.cell.

(Load_Board_Word)
(LBW)

	@16 				// LBW.count = 16 (# of bits to transfer)
	D = A
	@LBW.count
	M = D

	@LB.board 			// @LBW.bits = [LB.board]
	A = M
	D = M
	@LBW.bits
	M = D

(LBW.forCell)			// repeat [LB.cell++] = Top bit of LBW.bits while (--LBW.count > 0)

	@LBW.bits 			// D = LBW.bits
	D = M

	M = D + M 			// LBW.bits = LBW.bits << 1

	@32767				// D = D & 1000 0000 0000 0000
	D = ! D 			// We have to be tricky to do this because we can't
	D = D | A 			// load a 16 bit constant. The end result is that the
	D = ! D 			// sign bit is preserved and everything else is 0!

	@LB.cell 			// [LB.cell] = D
	A = M
	M = D

	D = A + 1 			// LB.cell++
	@LB.cell
	M = D

	@LBW.count 			// LBW.Count,D = LBW.Count.i - 1
	MD = M - 1
	
	@LBW.forCell		// Loop if CB.i > 0
	D ; JGT

(LBW.incBoard)

	@LB.board 			// LB.board++ 
	M = M + 1

	// return to caller

	@SP 			// Jump to [++SP]
	AM = M + 1
	A = M
	0 ; JMP

// Clear_Board (CB) function. Clears all the cells including the border guard cells
// Should rewrite to not need the count variable. Lazy.

(Clear_Board)
(CB)

	@34*66			// There are 34*66 elements in the board = 2244
	D = A 			// CB.i is the loop counter
	@CB.i
	M = D

	@Board 			// CB.a = Board location
	D = A
	@CB.a
	M = D
	
(CB.Top)			// repeat Mem[CB.a++] = 0 while (--CB.i > 0) 

	@CB.a 			// [CB.a] = 0
	A = M
	M = 0
	
	D = A + 1 		// D = CB.a + 1
	@CB.a 			// CB.a = D
	M = D

	@CB.i 			// CB.i,D = CB.i - 1
	MD = M - 1
	
	@CB.Top 		// Loop if CB.i > 0
	D ; JGT

	// return to caller

	@SP 			// Jump to [++SP]
	AM = M + 1
	A = M
	0 ; JMP

// Paint_Board (PB) function; paints the current board onto the screen

(Paint_Board)
(PB)

	@20500

	@SCREEN 		// PB.board = Address of screen
	D = A
	@PB.board
	M = D

	@Board+67 		// PB.cell = First real cell of the board
	D = A
	@PB.cell
	M = D

	@32 			// PB.row = 32 (number of rows we need to paint)
	D = A
	@PB.row
	M = D

(PB.forRow) 		// repeat Paint_Board_Row() while (--PB.row > 0)

	@20012

	@PB.forRow.Ret 	// D = Paint_Board_Row return address
	D = A

	@SP 			// [SP--] = D (PUSH)
	A = M
	M = D
	@SP
	M = M - 1

	@Paint_Board_Row // Paint_Board_Row()
	0 ; JMP

(PB.forRow.Ret)

	@PB.row 		// PB.row,D = PB.row - 1
	MD = M - 1
	
	@PB.forRow 		// Loop if PB.row > 0
	D ; JGT

	// return to caller

	@SP 			// Jump to [++SP]
	AM = M + 1
	A = M
	0 ; JMP

// Paint_Board_Row(): Paint a single row (64 cells) onto the screen. We use an 8x8 matrix of pixels
// for each cell, so two cells fit into each word of pixels (16 pixels/word), and each row is
// replicated 8 times. On exit, PB.board points to the first word of pixels for the next row of
// cells, and PB.cell points to the first cell of the next row.

(Paint_Board_Row)
(PBR)

	@20600

	@32 				// PBR.pair = 32 (number of pairs of cells we need to paint)
	D = A
	@PBR.pair
	M = D

(PBR.forPair) 			// repeat Paint_Board_Pair() while (--PBR.pair > 0)

// Paint_Board_Pair(): paint a pair of cells [PB.cell],[PB.cell+1] onto the screen at word
// [PB.board]. Repeat for 8 screen rows, then update PB.cell and PB.board for the next
// iteration.
//
// This code is executed so much that all sorts of optimizations are warranted, including
// inserting it here as an inlined function call to avoid the call-return overhead. This
// sucks a bit for readability.

(Paint_Board_Pair)
(PBP)

	// Convert cells into pixels. There are 4 possible cell combinations (00,01,10,11)
	// and thus 4 possible pixel values. Note however that two of them are 0000 ... 0000
	// and 1111 ... 1111, which are predefined constants available to the ALU. This means
	// for these two cases, we don't have to load the pixel value before storing in
	// the screen buffer.

	@PB.cell 			// D = [PB.cell] (will be negative if cell is alive; 0 if cell is dead
	A = M
	D = M

	@PBP.0X 			// Skip if top pixel is empty
	D ; JEQ

(PBP.1X) 				// Left pixel is set. What about Right pixel?

	@PB.cell 			// D = [++PB.cell] (the second cell in the pair)
	AM = M + 1
	D = M

	@PBP.10 			// Right pixel is empty
	D ; JEQ

(PBP.11)

	// Now we set both pixels in 8 words of the screen buffer

	@32 				// D = Screen buffer row width
	D = A

	@PB.board 			// A = PB.board (location of first screen word to bash)
	A = M

	M = -1 				// [A] = -1 -- row 1

	A = A + D 			// A = A + 32
	M = -1 				// Row 2
	
	A = A + D 			// A = A + 32
	M = -1 				// Row 3
	
	A = A + D 			// A = A + 32
	M = -1 				// Row 4
	
	A = A + D 			// A = A + 32
	M = -1 				// Row 5
	
	A = A + D 			// A = A + 32
	M = -1 				// Row 6
	
	A = A + D 			// A = A + 32
	M = -1 				// Row 7
	
	A = A + D 			// A = A + 32
	M = -1 				// Row 8
	
	@PB.board 			// PB.board = PB.board + 1
	M = M + 1

	@PB.cell 			// PB.cell = PB.cell + 1
	M = M + 1

	// return to caller

	@PBR.forPair.Ret 	// direct jump since this is an inline function call
	0 ; JMP

(PBP.0X) 				// Left pixel is clear. What about Right pixel?

	@PB.cell 			// D = [++PB.cell] (the second cell in the pair)
	AM = M + 1
	D = M

	@PBP.01 			// Right pixel is *not* empty
	D ; JNE

(PBP.00)

	// Now we clear both pixels in 8 words of the screen buffer

	@32 				// D = Screen buffer row width
	D = A

	@PB.board 			// A = PB.board (location of first screen word to bash)
	A = M

	M = 0 				// [A] = 0 -- row 1

	A = A + D 			// A = A + 32
	M = 0 				// Row 2
	
	A = A + D 			// A = A + 32
	M = 0 				// Row 3
	
	A = A + D 			// A = A + 32
	M = 0 				// Row 4
	
	A = A + D 			// A = A + 32
	M = 0 				// Row 5
	
	A = A + D 			// A = A + 32
	M = 0 				// Row 6
	
	A = A + D 			// A = A + 32
	M = 0 				// Row 7
	
	A = A + D 			// A = A + 32
	M = 0 				// Row 8
	
	@PB.board 			// PB.board = PB.board + 1
	M = M + 1

	@PB.cell 			// PB.cell = PB.cell + 1
	M = M + 1

	// return to caller

	@PBR.forPair.Ret 	// direct jump since this is an inline function call
	0 ; JMP

(PBP.10)

	@255 				// D = 00FF (remember, least significant bits in screen memory are the leftmost ones)
	D = A

	@PBP.Paint
	0 ; JMP

(PBP.01)

	@255 				// D = ! 00FF
	D = !A

(PBP.Paint)

	// Paint the pixels in D into 8 successive rows of the screen. Loop is unrolled for
	// efficiency.

	@PBP.pixels 		// Save our pixels
	M = D

	@PB.board 			// A = PB.board (location of first screen word to bash)
	A = M

	M = D 				// [PB.board] = PBP.pixels (still in D) -- row 1

	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 2
	D = M
	@PB.board
	A = M
	M = D


	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 3
	D = M
	@PB.board
	A = M
	M = D

	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 4
	D = M
	@PB.board
	A = M
	M = D

	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 5
	D = M
	@PB.board
	A = M
	M = D

	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 6
	D = M
	@PB.board
	A = M
	M = D

	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 7
	D = M
	@PB.board
	A = M
	M = D

	D = A 				// PB.board = PB.board + 32
	@32
	D = D + A
	@PB.board
	M = D

	@PBP.pixels 		// [PB.board] = PBP.pixels -- row 8
	D = M
	@PB.board
	A = M
	M = D

	// PB.board now contains an address in the 8th row. We need to go back to
	// the first row, then move forward to the next word. Since we moved 7 x 32
	// words, we simply subtract (7*32)-1. Similarly, we need to increment
	// PB.cell to move to the first cell of the next pair.

(PBP.NextPair)

	@223 				// PB.board = PB.board - 223
	D = A
	@PB.board
	M = M - D

	@PB.cell
	M = M + 1

	// return to caller (fall through)

	// end of inline function call

(PBR.forPair.Ret)

	@PBR.pair 			// PB.pair,D = PB.pair - 1
	MD = M - 1
	
	@PBR.forPair		// Loop if PBR.pair > 0
	D ; JGT

	// Update PB.cell and PB.board so they are correct for the next iteration

	@PB.cell 			// PB.cell = PB.cell + 2 (skips border cells)
	M = M + 1
	M = M + 1

	@224 				// PB.board = PB.board + 32 * 7 (skips 7 pixel rows)
	D = A
	@PB.board
	M = M + D

	// return to caller

	@SP 				// Jump to [++SP]
	AM = M + 1
	A = M
	0 ; JMP


// Logo board data storage. Boards are 64x32, so 4 words per row.

$Logo.Board(4*32)=\
  0b1111111111111111,0b1111111111111111,0b1111111111111111,0b1111111111111111,\
  0b1000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000001,\
  0b1001111000011111,0b0001100110011000,0b1100011111001100,0b0110010011111001,\
  0b1011001100110001,0b1001110110011000,0b1100110001101100,0b0110100110000001,\
  0b1011000000110001,0b1001111110011010,0b1100111111100111,0b1110000011111001,\
  0b1011001100110001,0b1001101110011111,0b1100110001100000,0b0110000000001101,\
  0b1001111000011111,0b0001100110001101,0b1000110001100111,0b1100000011111001,\
  0b1000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000001,\
  0b1001111000011111,0b0001110111001111,0b1100000000000001,0b1111000111111101,\
  0b1011001100110001,0b1001111111001100,0b0000000000000011,0b0001100110000001,\
  0b1011000000111111,0b1001101011001111,0b1100000000000011,0b0001100111110001,\
  0b1011001100110001,0b1001100011001100,0b0000000000000011,0b0001100110000001,\
  0b1001111100110001,0b1001100011001111,0b1100000000000001,0b1111000110000001,\
  0b1000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000001,\
  0b1000111100000000,0b0000111111110000,0b1111111111110000,0b1111111111110001,\
  0b1000111100000000,0b0000111111110000,0b1111111111110000,0b1111111111110001,\
  0b1000111100000000,0b0000111111110000,0b1111111111110000,0b1111111111110001,\
  0b1000111100000000,0b0000001111000000,0b1111000000000000,0b1111000000000001,\
  0b1000111100000000,0b0000001111000000,0b1111111100000000,0b1111111100000001,\
  0b1000111100000000,0b0000001111000000,0b1111111100000000,0b1111111100000001,\
  0b1000111100000000,0b0000001111000000,0b1111000000000000,0b1111000000000001,\
  0b1000111111111111,0b0000111111110000,0b1111000000000000,0b1111111111110001,\
  0b1000111111111111,0b0000111111110000,0b1111000000000000,0b1111111111110001,\
  0b1000111111111111,0b0000111111110000,0b1111000000000000,0b1111111111110001,\
  0b1000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000001,\
  0b1001111000000000,0b0000000000100000,0b0000000000000001,0b0000000000000101,\
  0b1010000100000000,0b0000000000100000,0b0000000000000001,0b0000000000000101,\
  0b1010110100000101,0b0001110011100110,0b0100010011001101,0b0011000110011101,\
  0b1010111100001010,0b1010010100101001,0b0010100110010001,0b0100101000100101,\
  0b1001000000001000,0b1001110011100110,0b0001000011010001,0b0011001000011101,\
  0b1000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000001,\
  0b1111111111111111,0b1111111111111111,0b1111111111111111,0b1111111111111111


$Oscillator.Board(4*32)=\
  0b0000011000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b1110010000001110,0b0000111000111000,0b0000000000000000,0b0000000000000000,\
  0b0000000010011100,0b0000000000000000,0b0000000000000000,0b0100000000000000,\
  0b0000000110000000,0b0010000101000010,0b0000000000000001,0b0100000000000000,\
  0b0000000000000000,0b0010000101000010,0b0000000000000010,0b1000000000000000,\
  0b0011000000000000,0b0010000101000010,0b0000000011000100,0b1000000000001100,\
  0b0000000000000000,0b0000111000111000,0b0000000011000010,0b1000000000001100,\
  0b1000100000000000,0b0000000000000000,0b0000000000000001,0b0100000000000000,\
  0b1000010000000000,0b0000111000111000,0b0000000000000000,0b0100000000000000,\
  0b0010101000000000,0b0010000101000010,0b0000000000000000,0b0000000000000000,\
  0b0001010100000000,0b0010000101000010,0b0000000000000000,0b0000000000000000,\
  0b0000100001000000,0b0010000101000010,0b0000000000000000,0b0000000000000000,\
  0b0000010001000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000111000111000,0b0000000000000000,0b0000000000000000,\
  0b0000001100000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0110000000000000,0b0000000000000000,\
  0b0000000000000000,0b1100000000000000,0b0101000000011000,0b0000000000000000,\
  0b0000000000000000,0b1100000000000000,0b0001000000011000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0111000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0111000000000000,0b0000000000000000,\
  0b0000000000000000,0b1100000000000000,0b0001000000000000,0b0000000000000000,\
  0b0000000000000000,0b1100000000000000,0b0101000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0110000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000


$Gliders.Board(4*32)=\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000010000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0001000100000000,0b0000000000000000,0b0000000000000000,0b0000000010000000,\
  0b0000000010000000,0b0000000000000000,0b0000000000000000,0b0000000001000000,\
  0b0001000010000000,0b0000000000000000,0b0000000000000000,0b0000000111000000,\
  0b0000111110000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000100000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000010000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0001110000001100,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000100001,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b1000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000100000,0b1000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000011111,0b1000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000111100000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0001111110000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000100000,0b0001111011000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000010000,0b0000000110000000,\
  0b0000000000000000,0b0000000000000000,0b0000000001110000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000001,0b1000000000000000,\
  0b0000001000000000,0b0000000000000000,0b0000000000000100,0b0000000000100000,\
  0b0000000100000000,0b0000000000000000,0b0000000000000000,0b0000000000010000,\
  0b0000011100000000,0b0000000000000000,0b0000000000000100,0b0000000000010000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000011,0b1111111111110000,\
  0b0000000000000000,0b0000000000000000,0b0010000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0001000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0111000000000000,0b0000111100000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0001111110000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0001111011000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000110000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000


$Gosper.Glider.Gun(4*32)=\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000001000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000101000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000110,0b0000011000000000,0b0001100000000000,0b0000000000000000,\
  0b0000000000001000,0b1000011000000000,0b0001100000000000,0b0000000000000000,\
  0b0110000000010000,0b0100011000000000,0b0000000000000000,0b0000000000000000,\
  0b0110000000010001,0b0110000101000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000010000,0b0100000001000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000001000,0b1000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000110,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000001100000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000001010000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000010000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000011000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000


$Beacon.Maker(4*32)=\
  0b0000000000000000,0b0000000000000001,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000010,0b0000000000000000,0b0000000000000011,\
  0b0000000000000000,0b0000000000000100,0b0000000000000000,0b0000000000000101,\
  0b0000000000000000,0b0000000000001000,0b0000000000000000,0b0000000000001000,\
  0b0000000000000000,0b0000000000010000,0b0000000000000000,0b0000000000010000,\
  0b0000000000000000,0b0000000000100000,0b0000000000000000,0b0000000000100000,\
  0b0000000000000000,0b0000000001000000,0b0000000000000000,0b0000000001000000,\
  0b0000000000000000,0b0000000010000000,0b0000000000000000,0b0000000010000000,\
  0b0000000000000000,0b0000000100000000,0b0000000000000000,0b0000000100000000,\
  0b0000000000000000,0b0000001000000000,0b0000000000000000,0b0000001000000000,\
  0b0000000000000000,0b0000010000000000,0b0000000000000000,0b0000010000000000,\
  0b0000000000000000,0b0000100000000000,0b0000000000000000,0b0000100000000000,\
  0b0000000000000000,0b0001000000000000,0b0000000000000000,0b0001000000000000,\
  0b0000000000000000,0b0010000000000000,0b0000000000000000,0b0010000000000000,\
  0b0000000000000000,0b0100000000000000,0b0000000000000000,0b0100000000000000,\
  0b0000000000000000,0b1000000000000000,0b0000000000000000,0b1000000000000000,\
  0b0000000000000001,0b0000000000000000,0b0000000000000001,0b0000000000000000,\
  0b0000000000000010,0b0000000000000000,0b0000000000000010,0b0000000000000000,\
  0b0000000000000100,0b0000000000000000,0b0000000000000100,0b0000000000000000,\
  0b0000000000001000,0b0000000000000000,0b0000000000001000,0b0000000000000000,\
  0b0000000000010000,0b0000000000000000,0b0000000000010000,0b0000000000000000,\
  0b0000000000100000,0b0000000000000000,0b0000000000100000,0b0000000000000000,\
  0b0000000001000000,0b0000000000000000,0b0000000001000000,0b0000000000000000,\
  0b0000000010000000,0b0000000000000000,0b0000000010000000,0b0000000000000000,\
  0b0000000100000000,0b0000000000000000,0b0000000100000000,0b0000000000000000,\
  0b0000001000000000,0b0000000000000000,0b0000001000000000,0b0000000000000000,\
  0b0000010000000000,0b0000000000000000,0b0000010000000000,0b0000000000000000,\
  0b0000100000000000,0b0000000000000000,0b0000100000000000,0b0000000000000000,\
  0b0111000000000000,0b0000000000000000,0b0001000000000000,0b0000000000000000,\
  0b0001000000000000,0b0000000000000000,0b0010000000000000,0b0000000000000000,\
  0b0001000000000000,0b0000000000000000,0b0100000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b1000000000000000,0b0000000000000000


$Blinker.Puffer(4*32)=\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000010000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000001000100000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000010000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000010000100000,0b0000000000000000,0b0000000000000000,0b0000000011000000,\
  0b0000011111000000,0b0000000000000000,0b0000000000000000,0b0000000110111100,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000011111100,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000001111000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000001100000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000011011100000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000001111000111,0b0111011101110111,0b0111011101110111,0b0111011101110000,\
  0b0000000110000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000110000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000010000100,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000100000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000100000100,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000111111000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000,\
  0b0000000000000000,0b0000000000000000,0b0000000000000000,0b0000000000000000

