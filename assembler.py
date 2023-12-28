# coding: utf-8

#---------------------------------------------------------------------------------------
# (C)2023 Robert Woodhead. Creative Commons Attribution License
#---------------------------------------------------------------------------------------

# Usage: python3 assember.py [-s] {asm input file}
#
# Generates .hack output file of the same name; if -s switch is used,
# some handy symbol tables are produced.
#
# Improvements over base assembler implementation:
# 
# 0b,0x,0o (boolean,hex,octal) and "x" or 'x' character constants.
#
# Predefined constants for useful things like arrow and function keys.
#
# Simple expression arithmetic using constants and symbols w/parenthesis
# for precedence (but note that it doesn't handle */ vs +- operator
# precedence, it's first-come first-served).
#
# $symbol to declare a variable before use (allocates a variable slot for it).
#
# $symbol(size) to declare an array (allocates to next var slot + size-1 addrs).
#
# $symbol=value declares a variable and initializes it to value.
#
# $symbol@value declares symbol to be a variable aliased to value.
#
# $symbol(size)=Values,Values, ... ,Values does the same thing for an array.
#
# $symbol(*)=filename treats the specified file as a monochrome bitmap and extracts the size and
# initialization values from it. Gee, I wonder why this got implemented?
#
# If the symbol is \_ (ie: $\_) an anonymous variable or variable block is
# allocated, so you can do stuff like $_(5)=1,2,3,4,5.
#
# #symbol=value defines a constant (doesn't allocate memory).
#
# As memory can't be initialized on program load, the assembler automatically
# creates the code to do any needed initializations and inserts a call to it
# at the top of your code!
#
# Checks for overflow on @instrs.
#
# Alternate operator for NOT (~) can be used in place of ! if so desired.
#
# Support for the undocumented NAND (^) and NOR (_) operators, as well as the line_number operation.
#
#   Unfortunately, the CPU emulator does not emulate these extra instructions. :(
#
# Alternate format for comp section that gives precise control over alu bits.
#
#   {AMD}:={0,-1,D,!D}{+,&}{0,-1,A,!A,M,!M}{;JMP}
#   {AMD}:=!({0,-1,D,!D}{+,&}{0,-1,A,!A,M,!M}){;JMP}
#
#   Similar to above, the CPU emulator only implements the bit patterns that are defined
#   in the course documentation, so alternate alu settings that generate the same result
#   as documented bit patterns don't work. But hope springs eternal.
#
# \ line continuation character (handy for defining large blocks of data).
#
# Internal symbols are all prefixed by __ -- don't use them!
#

import os
import argparse
from typing import List, Dict, Tuple, Any
from PIL import Image

Values = Dict[str, int]     # Name:Values pairs, for example in symbol tables
Operation = Dict[str, Any]  # An assembler operation, typically one per non-comment line.
Line = Tuple[int, str, str] # Line number, line, original (unmunged) line

DEBUG = False               # Debug output flag
MAXRAM = 16384              # Limit of ram space
MAXROM = 32768              # Limit of rom space

# Various sets used in parsing.

SYMBOLCHARS = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$:')
DECIMALCHARS = set('0123456789')
OPERATORS = set('-+/*%&|~<>')
UNARYOPERATORS = set('-+~')
QUOTES = set('"\'')

# The global symbol table, initialized with all the default constants.

symbols: Values = {

    'R0': 0,
    'R1': 1,
    'R2': 2,
    'R3': 3,
    'R4': 4,
    'R5': 5,
    'R6': 6,
    'R7': 7,
    'R8': 8,
    'R9': 9,
    'R10': 10,
    'R11': 11,
    'R12': 12,
    'R13': 13,
    'R14': 14,
    'R15': 15,

    'SP': 0,
    'LCL': 1,
    'ARG': 2,
    'THIS': 3,
    'THAT': 4,

    'SCREEN': 16384,
    'KBD': 24576,

    'KBD_SPACE': 32,
    'KBD_NEWLINE': 128,
    'KBD_BACKSPACE': 129,
    'KBD_LEFTARROW': 130,
    'KBD_UPARROW': 131,
    'KBD_RIGHTARROW': 132,
    'KBD_DOWNARROW': 133,
    'KBD_HOME': 134,
    'KBD_END': 135,
    'KBD_PAGEUP': 136,
    'KBD_PAGEDOWN': 137,
    'KBD_INSERT': 138,
    'KBD_DELETE': 139,
    'KBD_ESC': 140,
    'KBD_F1': 141,
    'KBD_F2': 142,
    'KBD_F3': 143,
    'KBD_F4': 144,
    'KBD_F5': 145,
    'KBD_F6': 146,
    'KBD_F7': 147,
    'KBD_F8': 148,
    'KBD_F9': 149,
    'KBD_F10': 150,
    'KBD_F11': 151,
    'KBD_F12': 152,

}

# Keep some lists of symbols of particular types. This lets us print
# a nicely formatted symbol table at the end of assembly. We also
# do a case-insensitivity check to help check for typos.

predefined_symbols: List[str] = [k for k in symbols.keys()]
address_labels: List[str] = []
declared_values: List[str] = []
declared_variables: List[str] = []
implicit_variables: List[str] = []
ucase_symbols: List[str] = []

# Constants used in building instructions.

# C instruction template.

CINSTR = 0b1110000000000000

# Opcodes for jmps.

JMPS: Values = {

    'NULL': 0b000,
    'JGT':  0b001,
    'JEQ':  0b010,
    'JGE':  0b011,
    'JLT':  0b100,
    'JNE':  0b101,
    'JLE':  0b110,
    'JMP':  0b111

}

# Opcodes for destinations (3 lsbits for jmps). Variants added
# so destinations can be specified in any order.

DESTS: Values = {

    '':     0b000000,
    'NULL': 0b000000,
    'M':    0b001000,
    'D':    0b010000,
    'MD':   0b011000,
    'A':    0b100000,
    'AM':   0b101000,
    'AD':   0b110000,
    'AMD':  0b111000,
    'DM':   0b011000,   # Variant versions of above
    'MA':   0b101000, 
    'DA':   0b110000,
    'ADM':  0b111000,
    'MAD':  0b111000,
    'MDA':  0b111000,
    'DAM':  0b111000,
    'DMA':  0b111000,

}

# Opcodes for comps (6 lsbits for jmps and dests).

COMPS: Values = {

    '0':    0b0101010000000,
    '1':    0b0111111000000,
    '-1':   0b0111010000000,
    'D':    0b0001100000000,
    'A':    0b0110000000000,
    '!D':   0b0001101000000,
    '!A':   0b0110001000000,
    '-D':   0b0001111000000,
    '-A':   0b0110011000000,
    'D+1':  0b0011111000000,
    'A+1':  0b0110111000000,
    'D-1':  0b0001110000000,
    'A-1':  0b0110010000000,
    'D+A':  0b0000010000000,
    'D-A':  0b0010011000000,
    'A-D':  0b0000111000000,
    'D&A':  0b0000000000000,
    'D|A':  0b0010101000000,

    'A+D':  0b0000010000000,
    'A&D':  0b0000000000000,
    'A|D':  0b0010101000000,

    'M':    0b1110000000000,
    '!M':   0b1110001000000,
    '-M':   0b1110011000000,
    'M+1':  0b1110111000000,
    'M-1':  0b1110010000000,
    'D+M':  0b1000010000000,
    'D-M':  0b1010011000000,
    'M-D':  0b1000111000000,
    'D&M':  0b1000000000000,
    'D|M':  0b1010101000000,

    'M+D':  0b1000010000000,
    'M&D':  0b1000000000000,
    'M|D':  0b1010101000000,

    # Alternate not operator.

    '~D':   0b0001101000000,
    '~A':   0b0110001000000,
    '~M':   0b1110001000000,

    # Extra possibly useful instructions.

    '-2':   0b0111110000000,

    'D^A':  0b0000001000000,    # D nand A
    'A^D':  0b0000001000000,
    'D_A':  0b0010100000000,    # D nor A
    'A_D':  0b0010100000000,

    'D^M':  0b1000001000000,    # D nand M
    'M^D':  0b1000001000000,
    'D_M':  0b1010100000000,    # D nor M
    'M_D':  0b1010100000000,

    # Synonyms.

    '0XFFFF':   0b0111010000000,
    '0X0000':   0b0101010000000,
    '0X0001':   0b0111111000000,

}

# Precise ALU control variant format. Implementation note: The code that uses
# these dictionaries will fail if any entry in a dictionary has entries that
# have initial substrings that are the same as another entry in the same
# dictionary. IE: "DerfBork" and "Derf" conflict because the start of
# "DerfBork" is "Derf". This limitation lets us simply use .startswith()
# in our matching code.

XOPS: Values = {

    '0':    0b0100000000000,
    '-1':   0b0110000000000,
    'D':    0b0000000000000,
    '!D':   0b0010000000000,
    '~D':   0b0010000000000

}

YOPS: Values = {

    '0':    0b0001000000000,
    '-1':   0b0001100000000,
    'D':    0b0000000000000,
    '!D':   0b0000100000000,
    '~D':   0b0000100000000,
    'M':    0b1000000000000,
    '!M':   0b1000100000000,
    '~M':   0b1000100000000

}

FUNCS: Values = {

    '&':    0b0000000000000,
    '+':    0b0000010000000,

}

NOTALU = 0b0000001000000
ALU = 0b0000000000000

# Determine if a string meets the criteria for a symbol.

def is_symbol(s:str) -> bool:

    if s == '':
        return False
    elif s[0] in DECIMALCHARS:
        return False
    elif s[0] == '-':
        return False
    else:
        for c in s:
            if c not in SYMBOLCHARS:
                return False

    return True

# Evaluate the value of a character or numeric constant.

def constant(s:str) -> int:

    if s == '':
        return 0
    elif len(s) == 3 and s[0] in QUOTES and s[2] == s[0]:
        return ord(s[1])
    else:
        try:
            return int(s.lower(), 0)
        except ValueError:
            if s[0] == '0':
                return constant(s[1:])
            else:
                raise Exception(f'Invalid constant [{s}]')

# Determine if a string is a constant.

def is_constant(s: str) -> bool:

    if s == '':
        return False

    try:
        _ = constant(s)
        return True
    except Exception:
        return False

# Expression evaluator is a dumb left->right parser. If expression starts with an
# operator, it adds an implied constant to the lefthand side. If checkonly is True,
# then it uses a dummy value for as-yet undefined symbols, which allows it to do
# double-duty as a preliminary syntax checker and an evaluator.

def evaluate(s:str, checkonly: bool=False) -> int:

    # If we get here and there is nothing, then it's a unary negation in the
    # middle of the expression.

    if s == '':
        raise Exception('Unary negation can only be used as first element in an expression or parenthetical expression')

    # Handle parentheses by repeatedly reducing the rightmost parenthetical
    # expression. If the subexpression is valid, replace it with the Values
    # of the subexpression.

    ploc = s.rfind('(')
    while ploc != -1:
        ploc = s.rfind('(')
        pend = s.find(')', ploc)
        if pend == -1:
            raise Exception('No matching ) in expression')
        pval = evaluate(s[ploc+1:pend], checkonly)
        s = s[:ploc] + str(pval) + s[pend+1:]
        ploc = s.rfind('(')

    # Check for dangling ) and \ symbols.

    if s.find(')') != -1:
        raise Exception('Dangling ) in expression')

    if s.endswith('\\'):
        raise Exception('Dangling \\ in expression (probably in last line of file)')

    # Find the location of the *last* operator because recursion will evaluate
    # everything to the left of it first!

    oploc = max([s.rfind(c) for c in OPERATORS])
    
    # If we don't find an operator, we either have a constant or a symbol.

    if oploc != -1:

        # If we find a unary operator and it's not the first character of the string,
        # then either we have a case of a<op><b> or a<op><unary op><b>. In both cases,
        # we fall through and handle the non-unary operator, but in the latter case
        # we have to step back 1 character. Since this function is recursive, the
        # end result is that we'll only ever actually evaluate a unary operator
        # when it is the only operator (and first character in) the subexpression.

        if s[oploc] in UNARYOPERATORS:
            if oploc > 0:
                if s[oploc-1] in OPERATORS:
                    oploc -= 1
            else:
                uval = evaluate(s[1:], checkonly)

                match s[oploc]:

                    case '-':
                        return -uval

                    case '+':
                        return uval

                    case '~':
                        return ~uval

        # We only get here if it's a non-unary operator, so we can just evaluate both sides.

        p1 = evaluate(s[0:oploc], checkonly)
        p2 = evaluate(s[oploc+1:], checkonly)

        match s[oploc]:

            case '+':
                return p1 + p2

            case '-':
                return p1 - p2

            case '*':
                return p1 * p2

            case '/':
                return p1 // p2

            case '%':
                return p1 % p2

            case '&':
                return p1 & p2

            case '|':
                return p1 | p2

            case '<':
                return p1 << p2

            case '>':
                return p1 >> p2

            case other:
                raise Exception(f'Unimplemented expression operator [{s[oploc]}]')
    elif is_constant(s):
        return constant(s)
    elif is_symbol(s):
        if s in symbols:
            return symbols[s]
        elif checkonly:         # if checkonly is True, don't return undefined symbol errors
            return 1
        else:
            raise Exception(f'Undefined symbol [{s}] in expression')
    else:
        raise Exception(f'Cannot parse expression [{s}]')

# Wrapper for evaluate() that catches the exceptions and returns True if there wasn't one,
# converting evaluate() into a syntax checker.

def is_expression(s: str) -> bool:

    try:
        _ = evaluate(s, checkonly=True)
        return True
    except Exception as oops:
        return False

# Import a bitmap image, return size,data list tuple. Pack zeros as needed
# to fit rows into integer number of words.

def import_image(im: Image) -> Tuple[str, List[str]]:

    im = im.convert(mode='1')
    width, height = im.size
    word_width = (width+15) // 16
    words: List[str] = []

    for y in range(0,height):

		# pack 16 pixels into each word, format as binary.

        words = words + [ '0b' + ''.join(['1' if (x+16*w) < width and im.getpixel((x+16*w, y))<128 else '0' for x in range(0,16)]) for w in range(0,word_width)]

    return (str(word_width*height), words)

# Parse a line into an Operation dictionary. Rather than use a rigid class to hold all the
# information we glean from parsing, a name:value dictionary is used. It's more flexible and
# is good enough for the task at hand (and was easier to hack together quickly). Also, the
# original code was written before python types hints were a thing.
# 
# Operation cTypes are:
#
# A=Aop, C=Cop, L=Label, V=var definition, D=Data definition (const), K=Our new special operations.
#
# line = (line_number, line) tuple.

def operation(line: Line) -> Operation:

    o = line[1]

    # Handle each of the possible statement types.

    if o[0] == '@':             # @-op
        o = o[1:]
        if is_symbol(o):
            return {'cType': 'A', 'symbol': o, 'line': line}
        elif is_constant(o):
            return {'cType': 'A', 'constant': o, 'line': line}
        elif is_expression(o):
            return {'cType': 'A', 'expression': o, 'line': line}
        else:
            return {'cType': 'A', 'line': line, 'error': '@ Values is not a symbol, constant or expression'}
    elif o.startswith('('):     # (LABEL)
        if o.endswith(')'):
            return {'cType': 'L', 'symbol': o[1:-1], 'line': line}
        else:
            return {'cType': 'E', 'line': line, 'error': 'Label definition does not end in '')'''}
    elif o.startswith('$'):     # Variable declaration
        o = o[1:]
        if '(' in o:
            vname, vsize = o.split('(', 1)
            if vname == '_':
                vname = f'__Anon__{line[0]}'
            if ')' not in vsize:
                return {'cType': 'E', 'line': line, 'error': 'Variable definition is missing closing '')'''}
            vsize, vinit = vsize.split(')', 1)
            if vsize == '*':
                try:
                    _, vinit = vinit.split('=')
                    im = Image.open(vinit)
                except:
                    return {'cType': 'E', 'line': line, 'error': f'File [{vinit}] not found, or not image'}
                vsize, vlist = import_image(im)
                return {'cType': 'V', 'symbol': vname, 'expression': vsize, 'init': vlist, 'line': line}
            elif '=' in vinit:
                _, vinit = vinit.split('=')
                vlist = vinit.split(',')
                evsize = evaluate(vsize)
                if len(vlist) != evsize:
                    return {'cType': 'E', 'line': line, 'error': f'Variable size ({evsize}) does not match number of Values provided ({len(vlist)})'}
            else:
                vlist = []
            return {'cType': 'V', 'symbol': vname, 'expression': vsize, 'init': vlist, 'line': line}
        elif '=' in o:
            vname, vinit = o.split('=', 1)
            vlist = vinit.split(',')
            if len(vlist) != 1:
                return {'cType': 'E', 'line': line, 'error': f'Variable size (1) does not match number of Values provided ({len(vlist)})'}
            else:
                return {'cType': 'V', 'symbol': vname, 'expression': '1', 'init': vlist, 'line': line}	    
        elif '@' in o:
            vname, vinit = o.split('@', 1)
            vlist = vinit.split(',')
            if len(vlist) != 1:
                return {'cType': 'E', 'line': line, 'error': f'Variable alias can only one initializer value'}
            else:
                return {'cType': 'V', 'symbol': vname, 'expression': vlist[0], 'alias': True, 'line': line}	    

        else:
            return {'cType': 'V', 'symbol': o, 'expression': '1', 'line': line}
    elif o.startswith('#'):     # Constant declaration
        o = o[1:]
        if '=' in o:
            vname, vinit = o.split('=', 1)
            return {'cType': 'D', 'symbol': vname, 'expression': vinit, 'line': line}
        else:
            return {'cType': 'E', 'line': line, 'error': 'Constant definition does contain a Values'}
    else:                       # C-operation (or our custom ops, which are K-operations)
        olist = o.split(';')
        if len(olist) > 2:
            return {'cType': 'E', 'line': line, 'error': 'Multiple ;''s in operation'}
        elif len(olist) == 2:
            jmp = olist[1].upper()
        else:
            jmp = 'NULL'

        if ':=' in olist[0]:
            olist = olist[0].upper().split(':=')
            if len(olist) == 2:
                return {'cType': 'K', 'dest': olist[0], 'comp': olist[1], 'jump': jmp, 'line': line}
            else:
                return {'cType': 'E', 'line': line, 'error': 'Multiple :=''s in operation'}
        else:
            olist = olist[0].upper().split('=')
            if len(olist) == 1:
                return {'cType': 'C', 'dest': 'NULL', 'comp': olist[0], 'jump': jmp, 'line': line}
            elif len(olist) == 2:
                return {'cType': 'C', 'dest': olist[0], 'comp': olist[1], 'jump': jmp, 'line': line}
            else:
                return {'cType': 'E', 'line': line, 'error': 'Multiple =''s in operation'}

# Generate the code for an Operation, add it to the operation, and return the modified object.
# If we actually get to this point, the code has no syntax errors.

def codegen(o: Operation) -> Operation:

    match o['cType']:

        case 'A':   # @-Instruction
            if 'constant' in o:
                av = constant(o['constant'])
            elif 'symbol' in o:
                av = symbols[o['symbol']]
            else:
                try:
                    av = evaluate(o['expression'])
                except ZeroDivisionError:
                    o['error'] = 'Divide by 0 error in expression'
                    av = 0
                except Exception as oops:
                    o['error'] = str(oops)
                    av = 0
                if (av < -16384) or (32767 < av):
                    o['warning'] = '@expression out of -16384..32767 range; lower 15 bits used'
            o['code'] = av & 0b0111111111111111

        case 'C': # C-Instruction
            c = CINSTR
            oc = o['comp']
            od = o['dest']
            oj = o['jump']
            if oc in COMPS:
                c += COMPS[oc]
            else:
                o['error'] = 'Unknown alu operation ' + oc
                return o
            if od in DESTS:
                c += DESTS[od]
            else:
                o['error'] = 'Unknown destination ' + od
                return o
            if oj in JMPS:
                c += JMPS[oj]
            else:
                o['error'] = 'Unknown jump ' + oj
                return o
            o['code'] = c
        
        case 'K': # Our new special format
            c = CINSTR
            oc = o['comp']
            od = o['dest']
            oj = o['jump']

            if oc.startswith('!(') or oc.startswith('~('):
                c += NOTALU
                if oc.endswith(')'):
                    oc = oc[2:-1]
                else:
                    o['error'] = 'No closing parenthesis on custom ALU operation'
                    return o
            else:
                c += ALU

            # The following code works because no valid operation symbol is a substring of the head
            # of another symbol, which is very convenient. Of course, if that changes...

            xop = [(XOPS[x], x) for x in XOPS if oc.startswith(x)]

            if len(xop) == 1:
                c += xop[0][0]
                oc = oc[len(xop[0][1]):]
            else:
                o['error'] = 'Unknown custom ALU operation X-operation'
                return o

            func = [(FUNCS[f], f) for f in FUNCS if oc.startswith(f)]

            if len(func) == 1:
                c += func[0][0]
                oc = oc[len(func[0][1]):]
            else:
                o['error'] = 'Unknown custom ALU operation function'
                return o

            yop = [(YOPS[y], y) for y in YOPS if oc.startswith(y)]

            if len(yop) == 1:
                c += yop[0][0]
                oc = oc[len(yop[0][1]):]
            else:
                o['error'] = 'Unknown custom ALU operation X-operation'
                return o

            if oc != '':
                o['error'] = 'Extra symbols in custom ALU operation'
                return o

            if od in DESTS:
                c += DESTS[od]
            else:
                o['error'] = 'Unknown destination ' + od
                return o

            if oj in JMPS:
                c += JMPS[oj]
            else:
                o['error'] = 'Unknown jump ' + oj
                return o

            o['code'] = c

    return o

# Print out a segment of the symbol table in a nicely formatted way.

def print_symbols(symbols: Values, valid: List[str], title: str, byname: bool):

    # .sort() helper functions, permits sorting by value or name (case-insensitive).

    def byValues(s: str):
        return symbols[s]

    def byNames(s: str):
        return s.upper()

    # Filter out the desired symbols.

    valid_symbols = [s for s in symbols.keys() if s in valid]

    if not valid_symbols:
        return

    # Sort the symbols.

    if byname:
        valid_symbols.sort(key=byNames)
    else:
        valid_symbols.sort(key=byValues)

    # How wide is a column of symbols and values?

    num_symbols = len(valid_symbols)
    max_width = max([len(s) for s in valid_symbols])

    # Create the ruler that goes at the top of a column,
    # and the separator the divides the columns.

    ruler = '-'*max_width + ' -----'
    separator = ' | '

    # How many columns can we fit in a line?

    num_cols = min([(os.get_terminal_size().columns - len(separator)) // (len(ruler) + len(separator)), num_symbols])
    
    # Paranoia - what happens if the screen isn't wide enough? Well, in that case, we do the best we can.

    if num_cols==0:
        num_cols = 1

    # Given that many columns, how many rows do we need?

    num_rows = (num_symbols + num_cols - 1) // num_cols

    # Now that we know the number of rows, the number of columns needed may be less than the maximum we can fit.

    num_cols = (num_symbols + num_rows - 1) // num_rows
  
    # Format the symbols nicely; could be done in the final print list comprehension
    # but is done ahead of time for clarity.

    formatted_symbols = [f'{s:{max_width}} {symbols[s]:5}' for s in valid_symbols]
 
    # Print the header

    print(title + (' (by name)' if byname else ' (by value)'))
    print(separator.join([ruler for i in range(0, num_cols)]))

    # This little bit of evilness prints all the symbols in a row, but orders the symbols column-first, which
    # is easier to read. It does it by computing the index for a particular row and column, but only including
    # the items that are in-bounds. The end result is that the final column has some empty entries.

    for row in range(0, num_rows):
        print(separator.join([formatted_symbols[num_rows * col + row] if num_rows * col + row < num_symbols else '' for col in range(0, num_cols)]))

    print()

# The actual assembler! It's a bit on the long side for a function,
# but it is a very linear process so I think that's acceptable.

def avengers_assemble(fname: str, print_symbol_table: bool):

    oname = fname[:-4] + '.hack'

    # Read in the file, get back (line number, line, original line) tuples.
    # We keep the original line around for use in errors and warnings.

    lines = [(i+1, l, l) for i, l in enumerate(open(fname))]

    # Kill all the whitespace (evil trick). This makes parsing MUCH easier.
    # However, there is one wrinkle. Since we have implemented character
    # constants, and since one of them is ' ', we have to get sneaky and
    # replace these with dunder placeholders so they don't get smashed,
    # and then fix them after smashing all the whitespace. It also handles
    # bad constants with a double-space, but gives up after that as they
    # are going to error out anyways later on.

    lines = [(l[0], l[1].replace('\' ', '\'__SS__').replace('" ', '"__SS__').replace('__SS__ ', '__SS____SS__'), l[2]) for l in lines]
    lines = [(l[0], ''.join(l[1].split()), l[2]) for l in lines]
    lines = [(l[0], l[1].replace('__SS__', ' '), l[2]) for l in lines]

    # Kill all the comments.

    lines = [(l[0], l[1].split('//')[0], l[2]) for l in lines]

    # Kill all the blank lines.

    lines = [l for l in lines if l[1] != '']

    # Combine extended lines (\ at end of line).

    cur_line = 0
    while cur_line < (len(lines) - 1):
        if lines[cur_line][1].endswith('\\'):
            line = lines[cur_line][1]
            line = line[:-1] + lines[cur_line+1][1]
            original_line = lines[cur_line][2]
            original_line = original_line[:-1] + lines[cur_line+1][2]
            lines[cur_line] = (lines[cur_line][0], line, original_line)
            del lines[cur_line+1]
        else:
            cur_line = cur_line + 1

    # Parse the lines into operations.

    ops = [operation(l) for l in lines]

    # Check for a particular edge-case.

    if lines[-1][1].endswith('\\'):
        ops[-1]['error'] = 'Last line in the file contains a line-continuation character (\\).'

    # Check for explicit reference to dunder symbols and include warning(s),
    # and also check to see if we have to insert initialization code.

    init_needed = False

    for i,op in enumerate(ops):
        if op['cType'] == 'A' and op.get('symbol','').startswith('__'):
            ops[i].update({'warning':'Use of __symbol in code; please be careful as these are reserved for internal assembler use.'})
        init_needed = init_needed or 'init' in op

    # If we do have initialization to do, we have to prepend the jump to the init code and set up a symbol for where
    # the init code will actually go. Because we add this code before we determine the address of each line of code,
    # the symbol table will be populated correctly. We can't add the actual initialization code until after the
    # symbol table is complete, because we need to know the values being stored in order to generate optimal code.

    if init_needed:
        ops = [{'cType': 'A', 'expression': '__INIT', 'line': (-1, '@__INIT // Jump to Initializer'),},
               {'cType': 'C', 'dest': 'NULL', 'comp': '0', 'jump': 'JMP', 'line': (-1, '0;JMP')},
               {'cType': 'L', 'symbol': '__INIT.Ret', 'line': (-1, '(__INIT.Ret)')}] + \
               ops + \
               [{'cType': 'L', 'symbol': '__INIT', 'line': (-2, '(__INIT)')}]

    if DEBUG:
        for o in ops:
            print(o)
        print()
        print('Pass 1')

    # Populate the symbol table. in pass 1, we handle the () instructions.

    pc = 0  # Program counter

    for o in ops:
        ct = o['cType']
        if ct == 'L':
            sym = o['symbol']
            if sym == '':
                o['error'] = 'Empty symbol'
            elif not is_symbol(sym):
                o['error'] = 'Badly formed symbol'
            elif sym in symbols:
                o['error'] = 'Symbol previously defined'
            elif sym.upper() in ucase_symbols:
                o['error'] = 'Symbol previously defined (case-insensitive)'
            else:
                symbols[sym] = pc
                address_labels.append(sym)
                ucase_symbols.append(sym.upper())

        elif (ct == 'A') or (ct == 'C'):
            pc += 1
    
    if DEBUG:
        for o in ops:
            print(o)
        print()
        print('Pass 2')
    
    # Symbol table pass 2, handle the # and $ defines.

    ram = 16    # Locations 0-15 are reserved, so 16 is the first available

    for o in ops:
        ct = o['cType']
        if (ct == 'V') or (ct == 'D'):
            if 'symbol' in o:
                sym = o['symbol']
                if sym == '':
                    o['error'] = 'Empty symbol'
                elif is_constant(sym):
                    o['error'] = 'Cannot define a constant as a symbol'
                elif not is_symbol(sym):
                    o['error'] = 'Badly formed symbol'
                elif sym in symbols:
                    o['error'] = 'Symbol previously defined'
                elif sym.upper() in ucase_symbols:
                    o['error'] = 'Symbol previously defined (case-insensitive)'
                else:
                    try:
                        cv = evaluate(o['expression'])
                    except ZeroDivisionError:
                        o['error'] = 'Divide by 0 error in expression'
                        cv = 1
                    except Exception as ex:
                        o['error'] = str(ex)
                        cv = 1
                    if ct == 'D':           # Constant
                        symbols[sym] = cv
                        declared_values.append(sym)
                    else:                   # Variable
                        if 'alias' in o:    # Alias to existing variable
                            symbols[sym] = cv
                        else:
                            symbols[sym] = ram
                            ram = ram + cv
                            if ram > MAXRAM:
                                o['error'] = 'Out of RAM (data) memory.'
                        declared_variables.append(sym)
                    ucase_symbols.append(sym.upper())

    if DEBUG:
        for o in ops:
            print(o)
        print()
        print('Pass 3')
    
    # Symbol table pass 3, handle the @-instructions.

    for o in ops:
        ct = o['cType']
        if ct == 'A':
            if 'symbol' in o:
                sym = o['symbol']
                if sym == '':
                    o['error'] = 'Empty symbol'
                elif is_constant(sym):
                    o['error'] = 'Cannot define a constant as a symbol'
                elif not is_symbol(sym):
                    o['error'] = 'Badly formed symbol'
                elif not(sym in symbols):
                    if sym.upper() in ucase_symbols:
                        o['error'] = 'Symbol previously defined (case-insensitive)'
                    else:
                        symbols[sym] = ram
                        ram = ram + 1
                        declared_variables.append(sym)
                        implicit_variables.append(sym)
                        ucase_symbols.append(sym.upper())
                        if ram > MAXRAM:
                            o['error'] = 'Out of memory.'

    if DEBUG:
        for o in ops:
            print(o)
        print()
    
    # If we have any errors at this point, don't bother to do any more work,
    # else generate the instructions that perform all our initializations.

    errors = [o for o in ops if 'error' in o]

    if not errors and init_needed:
        
        initops = []        # The operations needed to perform the initializations.
        initinfo = []       # List of things we need to initialize.

        # Pass 1 - gather the initialization information into a list of tuples.

        for o in ops:
            if 'init' in o:
                symbol = o['symbol']
                line_number = o['line'][0]
                for offset, expr in enumerate(o['init']):
                    try:
                        val = evaluate(expr)
                        val = val if val >= 0 else 65536+val    # convert to 16-bit unsigned Values
                        initinfo.append((val, symbol, offset, line_number))
                    except Exception as ex:
                        bad_var = symbol + ('' if len(o['init']) == 1 else f'[{offset}]')
                        initops.append({'cType': 'A', 'expression': f'{symbol}+{offset}', 'line': o['line'], 'error': f'Invalid constant initialization expression [{expr}] provided for {bad_var}'})

        # Sort the initialization information by value; this means that items with the same value will
        # be initialized in sequence, which permits optimization because the D register doesn't have
        # to be reset each time. Realized this while giving a lecture at Princeton about the Life
        # program!

        initinfo.sort()

        # Generate the initialization code

        lastval = -1        # All our initialization values are positive, so this will never match.

        for (val, symbol, offset, line_number) in initinfo:
            if val in [0, 1]:                       # Values is a HACK constant
                initops.append({'cType': 'A', 'expression': f'{symbol}+{offset}', 'line': (line_number, f'@{symbol}+{offset}')})
                initops.append({'cType': 'C', 'dest': 'M', 'comp': f'{val}', 'jump': 'NULL', 'line': (line_number, f'M={val} // INIT to HACK constant ({val})')})
            elif val == 65535:                      # Values is -1
                initops.append({'cType': 'A', 'expression': f'{symbol}+{offset}', 'line': (line_number, f'@{symbol}+{offset}')})
                initops.append({'cType': 'C', 'dest': 'M', 'comp': '-1', 'jump': 'NULL', 'line': (line_number, f'M=-1 // INIT to HACK constant ({val})')})
            else:
                if val != lastval:                          # Load val into D register
                    if val == (lastval + 1) and (val != 2): # Can we just increment D (note that we can't if val==2 because D never gets set in the 0 and 1 cases!)?
                        initops.append({'cType': 'C', 'dest': 'D', 'comp': 'D+1', 'jump': 'NULL', 'line': (line_number, f'D=D+1 // INIT to adjacent value ({val})')})
                    elif val < 32768:               # 15-bit Values
                        initops.append({'cType': 'A', 'expression': f'{val}', 'line': (line_number, f'@{val}')})
                        initops.append({'cType': 'C', 'dest': 'D', 'comp': 'A', 'jump': 'NULL', 'line': (line_number, f'D=A // INIT to 15-bit value ({val})')})
                    else:                           # 16-bit Values
                        initops.append({'cType': 'A', 'expression': f'{(~val) & 0xFFFF}', 'line': (line_number, f'@{(~val) & 0xFFFF}')})
                        initops.append({'cType': 'C', 'dest': 'D', 'comp': '!A', 'jump': 'NULL', 'line': (line_number, 'D=!A // INIT to 16-bit value ({val})')})

                # Store D into correct location

                initops.append({'cType': 'A', 'expression': f'{symbol}+{offset}', 'line': (line_number, f'@{symbol}+{offset}')})
                initops.append({'cType': 'C', 'dest': 'M', 'comp': 'D', 'jump': 'NULL', 'line': (line_number, 'M=D')})

            lastval = val   # Remember what's in D for next time around the loop

        # Return to caller code.

        initops.append({'cType': 'A', 'expression': '__INIT.Ret', 'line': (-3, '@__INIT.Ret')})
        initops.append({'cType': 'C', 'dest': 'NULL', 'comp': '0', 'jump': 'JMP', 'line': (-3, '0;JMP')})

        # Add the initialization code, update program counter.

        ops = ops + initops

        pc = pc + len(initops)

        if (pc >= MAXROM):
            ops[-1]['error'] = 'Program too large!'

    # If we have any errors at this point, don't bother to do any more work,
    # otherwise generate the code.

    errors = [o for o in ops if 'error' in o]

    if not errors:

        ops = [codegen(o) for o in ops]

        # Print out the various symbol tables.

        if print_symbol_table:
            print()
            print_symbols(symbols, predefined_symbols, 'Predefined Symbols', byname=True)
            print_symbols(symbols, address_labels, 'Branch Addresses', byname=True)
            print_symbols(symbols, address_labels, 'Branch Addresses', byname=False)
            print_symbols(symbols, declared_values, 'Constants', byname=True)
            print_symbols(symbols, declared_values, 'Constants', byname=False)
            print_symbols(symbols, declared_variables, 'Variables', byname=True)
            print_symbols(symbols, declared_variables, 'Variables', byname=False)
            print_symbols(symbols, implicit_variables, 'Implicitly defined variables (in @statements)', byname=True)

    # Extract any errors or warnings that have been generated.

    errors = [o for o in ops if 'error' in o]
    warnings = [o for o in ops if 'warning' in o]

    # Either print the errors, or print the warnings and generate the final binary textfile.

    if errors:
        for e in errors:
            print('Error in line ' + str(e['line'][0]) + ': ' + e['error'])
            print('\t' + e['line'][2].strip('\n'))
        for w in warnings:
            print('Warning in line ' + str(w['line'][0]) + ': ' + w['warning'])
            print('\t' + w['line'][2].strip('\n'))
        print(f'Assembly aborted -- {len(errors)} error(s) and {len(warnings)} detected.')
        exit(1)
    else:
        for w in warnings:
            print('Warning in line ' + str(w['line'][0]) + ': ' + w['warning'])
            print('\t' + w['line'][2].strip('\n'))
        prog = ['{:016b}'.format(o['code']) for o in ops if 'code' in o]
        
        if DEBUG:
            for p in prog:
                print(p + '\t' + str(int('0b'+p, 0)))
        
        with open(oname, 'w') as hackfile:
            for p in prog:
                hackfile.write(p + '\n')

        if DEBUG:
            for o in ops:
                print(o)

        print(f'Program length: {pc} (of {MAXROM}, {int(pc*100/MAXROM)}%), RAM usage: {ram} (of {MAXRAM}, {int(ram*100/MAXRAM)}%)')
        print('Assembly successful - results written to ' + oname)
        
        exit(0)

# Main level.

if __name__ == '__main__':

    parser = argparse.ArgumentParser(
                    prog = 'assembler.py',
                    description = 'Assembles HACK programs',
                    epilog = 'Results are stored in a .hack file with the same name as the .asm file')

    parser.add_argument('filename', help='The HACK .asm file to be assembled')
    parser.add_argument('-s', '--symbols', action='store_true', required=False, help='prints helpful symbol tables')

    args = parser.parse_args()

    fname = args.filename

    if not args.filename.endswith('.asm'):
        print('Error: Input filename must end in .asm')
        exit(1)

    if not os.path.isfile(args.filename):
        print(f'Error: Input file [{args.filename}] does not exist')
        exit(1)
        
    avengers_assemble(args.filename, args.symbols)