|			Minix Hard Disk Boot
|
|			Author:	C. E. Chew
|
| This program transfers a floppy based bootstrap into a minix based
| hard disk bootstrap. It scans the hard disk partition table for
| the first minix partition, then transfers the boot process onto that.
|
| Edit History:
| 09-Nov-1989	Add default boot partition
| 06-Nov-1989	Converted for Minix assembler
| 19-Aug-1988	Adapted to boot off Dos or Minix partition.
| 25-Apr-1988	Created source

HARD_DISK	=	0x80		| hard disk code
BUFFER		=	0x600		| buffer area above vectors
BOOTCODE	=	0x7c00		| boot code entry
BOOTSEG		=	0x7c0		| boot segment
TOPOFSTACK	=	0x7c00		| top of stack
BOOTPART	=	0x1bd		| default boot partition
TABLE		=	0x1be		| partition table offset
ENTRIES		=	0x4		| table entries
ZERO		=	0x30		| ascii '0'
ONE		=	0x31		| ascii '1'
SPACE		=	0x20		| ascii ' '
ASTERISK	=	0x2a		| ascii '*'
HEXOFFSET	=	39		| offset to a-f
VECTOR		=	0x00		| vector segment
DISK_VECTOR	=	0x13 * 4	| disk interrupt vector
TIMEOUT		=	15*18		| timeout for keyhit
TIMELO		=	0x46c		| timer count low
TIMEHI		=	0x46e		| timer count high

|	Partition table structure

active		= 0			| partition is active
shead		= 1			| start head
ssector		= 2			| start sector
scylinder	= 3			| start cylinder
type		= 4			| partition type
ehead		= 5			| end head
esector		= 6			| end sector
ecylinder	= 7			| end cylinder
hidden		= 8			| hidden sectors
sectors		= 12			| size of partition
partition	= 16			| partition structure size

|		Bootstrap Entrypoint
|
| The BIOS boot code will load this at location 0000:7c00. The hard
| disk partition table is loaded above the vectors and scanned for
| a minix partition.

	.text
	.define	_main

_main:
	mov	ax,#VECTOR		| vector segment
	mov	es,ax
	mov	ss,ax
	mov	sp,#TOPOFSTACK		| set up a stack
	mov	ax,#BOOTSEG		| boot segment
	mov	ds,ax

	orb	dl,#HARD_DISK		| boot hard disk
	movb	diskcode,dl		| code for this hard disk

	mov	si,#_main		| move table to low memory
	mov	di,#BUFFER		| buffer address
	mov	cx,#0x0100		| one sector
	cld				| direction is up
	rep
	movw

| Print the partitions

	mov	bx,#m_winiboot		| sign on
	call	puts

	mov	si,#TABLE		| partition table
	movb	bl,#1			| partition number

printpartitions:
	movb	al,#SPACE		| look for default
	cmpb	bl,BOOTPART
	jne	notboot
	movb	al,#ASTERISK		| this is the default
notboot:
	call	putc

	mov	di,#10			| decimal
	movb	cl,#1
	movb	al,bl			| which partition
	call	putbyte

	push	bx			| remember for later

	mov	di,#16			| hex
	movb	cl,#4			| field width
	movb	bl,#8			| fields

firstfields:
	cld
	lodb
	call	putbyte
	decb	bl
	jnz	firstfields

	mov	di,#10			| decimal
	movb	cl,#10			| field width
	movb	bl,#2			| fields

secondfields:
	les	ax,(si)			| load long
	lea	si,4(si)
	mov	dx,es			| high order
	call	putlong
	decb	bl
	jnz	secondfields

	mov	bx,#m_crlf		| say newline
	call	puts

	pop	bx			| partition number
	incb	bl
	cmpb	bl,#ENTRIES
	jbe	printpartitions

| Wait for indication of partition to boot

	mov	bx,#m_boot		| say we're booting
	call	puts

	mov	ax,#VECTOR		| vector segment
	mov	es,ax			| address low memory
	mov	bx,#TIMEOUT		| timeout

loadtime:
	seg	es
	mov	cx,TIMELO		| load the current time

waitkey:
	movb	ah,#1			| check for keystroke
	int	0x16
	jnz	keyhit			| key was struck

	test	bx,bx			| no timeout desired
	jz	waitkey

	seg	es
	cmp	cx,TIMELO		| check for new time
	je	waitkey
	dec	bx			| wait for timeout to elapse
	jnz	loadtime

timedout:
	movb	al,BOOTPART		| get default boot partition
	decb	al
	j	boot

keyhit:
	movb	ah,#0			| read key
	int	0x16
	mov	bx,#0			| disable timeout
	subb	al,#ONE			| convert partition number
	cmpb	al,#ENTRIES
	jae	waitkey

boot:
	push	ax			| remember partition
	addb	al,#ONE			| say which one
	call	putc
	mov	bx,#m_crlf
	call	puts
	pop	ax

	movb	ah,#partition		| size of each partition
	mulb	ah			| offset
	mov	si,#BUFFER+TABLE	| point at partition table
	add	si,ax			| point at partition entry

	pushf				| fake an int 0x13
	push	cs
	mov	bx,#BOOTCODE
	push	bx
	mov	ax,#VECTOR		| vector segment
	mov	es,ax

	mov	ax,#0x201		| read one sector
	seg	es
	movb	dh,shead(si)		| head
	seg	es
	movb	cl,ssector(si)		| sector
	seg	es
	movb	ch,scylinder(si)	| cylinder
	movb	dl,diskcode		| disk

	seg	es
	jmpi	@DISK_VECTOR		| read boot

m_boot:	.byte	0x0a
	.ascii	"Boot: "
	.byte	0
m_winiboot:
	.ascii	"WiniBoot v1.0 Nov 1989"
	.byte	0x0d,0x0a,0x0a
	.ascii	"   Boot Hd Sec Cyl Type Hd Sec Cyl      Base      Size"
m_crlf:	.byte	0x0d,0x0a,0x00

diskcode:
	.byte	0

|		Print a String
|
| Print a string on to the console. The string will be pointed to
| by bx on entry and be assumed to lie in the segment indicated
| by ds.

puts:
	movb	al,(bx)			| pick up next character
	inc	bx			| advance
	testb	al,al			| check for terminating null
	je	putsret
	call	putc
	j	puts
putsret:
	ret

|		Print a Character
|
| Print a character on the console. The character is assumed
| to be in al.

putc:
	push	si
	push	di
	push	bx
	mov	bx,#1			| page zero and foreground colour
	movb	ah,#0x0e		| write text in teletype mode
	int	0x10
	pop	bx
	pop	di
	pop	si
	ret

|		Print a Long
|
| Print the unsigned long in ax,dx on the console. Call
| at the alternate entry points to print out shorts or
| bytes. Load the radix in di _before_ the call and
| the field width in cx.

putbyte:
	xorb	ah,ah			| kill high order

putshort:
	xor	dx,dx			| kill high order

putlong:
	push	si			| save
	push	bx
	push	cx
	call	putnum
	pop	cx			| recover
	pop	bx
	pop	si
	ret

putnum:
	push	ax			| least significant word
	mov	ax,dx			| most significant part first
	xor	dx,dx
	div	di
	mov	si,ax			| most significant part of quotient
	pop	ax			| combine remainder
	div	di
	push	dx			| modulo radix
	mov	dx,si			| most significant part of quotient
	mov	si,ax			| check for zero
	or	si,dx
	jz	pad
	decb	cl			| another digit done
	call	putnum			| convert high order first
	j	nopad

pad:	decb	cl			| count down
	jle	nopad
	movb	al,#SPACE		| pad with spaces
	call	putc
	j	pad

nopad:	pop	ax			| print digit
	cmpb	al,#9
	jbe	nothex
	addb	al,#HEXOFFSET		| a-f
nothex:	addb	al,#ZERO
	call	putc
	ret

|		Disk Partition Table
|
| This is a copy of my disk partition table.
|
|	.org	BOOTPART
|	.byte	1
|
|	.org	TABLE
|	.byte	0x080,0x001,0x001,0x000,0x004,0x005,0x051,0x097
|	.long	0x00000011,0x0000A27F
|	.byte	0x000,0x000,0x041,0x098,0x040,0x005,0x0D1,0x027
|	.long	0x0000A290,0x00009F60
|	.byte	0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000
|	.long	0x00000000,0x00000000
|	.byte	0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000
|	.long	0x00000000,0x00000000
|	.byte	0x055,0x0AA
