#
# python3 script to generate Life.asm tables for the 128x64 version.
#

from typing import List

#
# Utility functions for generating other tables needed by the Life program.
#

def wrap(f:int ,t: int) -> None:

	print(f'\t@Board+{f}')
	print('\tD = M')
	print('\tM = 0')
	print(f'\t@Board+{t}')
	print('\tM = M + D')
	print('')

# Main level

if __name__ == '__main__':
	print('# Guard cell update code')
	print('#')
	print('# 0000 0001 ..... 0128 0129')
	print('# 0130 0131 ..... 0258 0259')
	print('#   .    .          .    . ')
	print('#   .    .          .    . ')
	print('# 8320 8321 ..... 8448 8449')
	print('# 8450 8451 ..... 8578 8579')
	print('')

	wrap(0,8448)
	wrap(129,8321)
	wrap(8450,258)
	wrap(8579,131)

	for i in range(1,129):
		wrap(0+i,8320+i)
		wrap(8450+i,130+i)

	for i in range(1,65):
		wrap(0+130*i,128+130*i)
		if i != 64:
			wrap(129+130*i,1+130*i)

	# Cell 8449 is the temporary guard cell, so it requires special handling.

	print('// This is the cell we set to the End-of-board mark.')
	print('')
	print('\t@Board+8449')
	print('\tD = M')
	print('\tM = -1\t\t\t// Mark this cell as the end-of-board (for Phase 3)')
	print('\t@3\t\t\t\t// Since it started at -3, we need to add 3')
	print('\tD = D + A\t\t// to get the actual neighbor count.')
	print('\t@Board+8321')
	print('\tM = M + D')
	print('')

	print('# Row Offset Table into Board (manually wrap this in assembler file)')
	print('')
	print('$Board.Row(64)=' + ','.join([f'Board+{r*130+131}' for r in range(0,64)]))