# coding: utf-8

#
# Quick Python3 script to scan HACK memory dumps and output the stored boards.
# Works with the version 1 Life program with the 64h x 32v board size.
#

import sys
import os
import math

from typing import List

#
# Memory locations in LIFE program
#

SAVE2 = 4500
SAVE1 = 7000
BOARD = 10000
MAXRAM = 24577

#
# Extract a board from memory dump and print a python function call
# that can be used to encode it (in boardmaker.py)
#

def dumpboard(name:str, ram:List[int], addr:int) -> None:

	print(f'board_v1([\n\"{name}"')

	# Skip guard cells

	addr += 67

	# Export the rows of cells

	for i in range(0,32):
		line = ''.join(['*' if c == -32768 else ' ' for c in ram[addr:addr+64]])
		print(f'"{line}" ,')
		addr += 66

	print('])')
	print('')

if __name__ == '__main__':

	if (len(sys.argv) != 2):
		print('usage: python boarddump.py {hack dump file}')
		sys.exit(1)

	# Initialize ram

	ram:List[int] = [0] * MAXRAM

	# Read the memory dump

	lines = [line.strip() for line in open(sys.argv[1],'rU')]

	# Quick and Dirty parse

	for l in lines:
		if "\t" in l:
			addr, value = [int(i) for i in l.split("\t")]
			if 0 <= addr < MAXRAM:
				ram[addr] = value

	# Dump the various board buffers

	dumpboard("Save Buffer-2", ram, SAVE2)
	dumpboard("Save Buffer-1", ram, SAVE1)
	dumpboard("Live Board", ram, BOARD)
