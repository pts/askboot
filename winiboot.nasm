;
; winiboot.nasm: ShoeLace MBR bootloader (boot partition picker)
; by C. E. Chew 1988-04-25 -- 1990-04-24
; bytewise identical translation of winiboot.x to NASM by pts@fazekas.hu on 2026-03-25
;
; Compile with: nasm -O0 -w+orphan-labels -f bin -o winiboot.bin winiboot.nasm
; Minimum NASM version required: 0.98.39
;
; This program transfers a floppy based bootstrap into a minix based
; hard disk bootstrap. It scans the hard disk partition table for
; the first minix partition, then transfers the boot process onto that.
;
; Edit history:
;
; * 1988-04-25: Created source
; * 1988-08-19: Adapted to boot off Dos or Minix partition
; * 1989-10-06: Converted for Minix assembler
; * 1989-10-09: Add default boot partition
; * 1990-04-24: Part of Minix bootloader ShoeLace 1.0a
; * 2026-03-25: Translated to NASM; Added as an UKH kernel (by pts@fazekas.hu)
;

HARD_DISK       equ 0x80     ; hard disk code
BUFFER          equ 0x600    ; buffer area above vectors
BOOTCODE        equ 0x7c00   ; boot code entry
BOOTSEG         equ 0x7c0    ; boot segment
TOPOFSTACK      equ 0x7c00   ; top of stack
BOOTPART        equ 0x1bd    ; default boot partition
TABLE           equ 0x1be    ; partition table offset
ENTRIES         equ 0x4      ; table entries
ZERO            equ 0x30     ; ascii '0'
ONE             equ 0x31     ; ascii '1'
SPACE           equ 0x20     ; ascii ' '
ASTERISK        equ 0x2a     ; ascii '*'
HEXOFFSET       equ 39       ; offset to a-f
VECTOR          equ 0x00     ; vector segment
DISK_VECTOR     equ 0x13<<2  ; disk interrupt vector
TIMEOUT         equ 15*18    ; timeout for keyhit
TIMELO          equ 0x46c    ; timer count low
TIMEHI          equ 0x46e    ; timer count high

; --- Partition table structure

active          equ 0   ; partition is active
shead           equ 1   ; start head
ssector         equ 2   ; start sector
scylinder       equ 3   ; start cylinder
type            equ 4   ; partition type
ehead           equ 5   ; end head
esector         equ 6   ; end sector
ecylinder       equ 7   ; end cylinder
hidden          equ 8   ; hidden sectors
sectors         equ 12  ; size of partition
partition       equ 16  ; partition structure size

; --- Bootstrap Entrypoint
;
; The BIOS boot code will load this at location 0000:7c00. The hard
; disk partition table is loaded above the vectors and scanned for
; a minix partition.

_start:
	mov ax, VECTOR  ; vector segment
	mov es, ax
	mov ss, ax
	mov sp, TOPOFSTACK  ; set up a stack
	mov ax, BOOTSEG  ; boot segment
	mov ds, ax

	or dl, HARD_DISK  ; boot hard disk !! Not needed.
	mov [diskcode], dl  ; code for this hard disk

	mov si, _start  ; move table to low memory
	mov di, BUFFER  ; buffer address
	mov cx, 0x0100  ; one sector
	cld  ; direction is up
	repne  ; !! This should be rep.
	    movsw

; Print the partitions

	mov bx, m_logo  ; sign on
	call puts

	mov si, TABLE  ; partition table
	mov bl, 1  ; partition number

printpartitions:
	mov al, SPACE  ; look for default
	cmp bl, [bootpart]
	jne short notboot
	mov al, ASTERISK  ; this is the default
notboot:
	call putc

	mov di, 10  ; decimal
	mov cl, 1
	mov al, bl  ; which partition
	call putbyte

	push bx  ; remember for later

	mov di, 16  ; hex
	mov cl, 4  ; field width
	mov bl, 8  ; fields

firstfields:
	cld
	lodsb
	call putbyte
	dec bl
	jnz short firstfields

	mov di, 10  ; decimal
	mov cl, 10  ; field width
	mov bl, 2  ; fields

secondfields:
	les ax, [si]  ; load long
	lea si, [si+4]
	mov dx, es  ; high order
	call putlong
	dec bl
	jnz short secondfields

	mov bx, m_crlf  ; say newline
	call puts

	pop bx  ; partition number
	inc bl
	cmp bl, ENTRIES
	jbe short printpartitions

; Wait for indication of partition to boot

	mov bx, m_boot  ; say we're booting
	call puts

	mov ax, VECTOR  ; vector segment
	mov es, ax  ; address low memory
	mov bx, TIMEOUT  ; timeout

loadtime:
	mov cx, [es:TIMELO]  ; load the current time

waitkey:
	mov ah, 1  ; check for keystroke
	int 0x16
	jnz short keyhit  ; key was struck

	test bx, bx  ; no timeout desired
	jz short waitkey

	cmp cx, [es:TIMELO]  ; check for new time
	je short waitkey
	dec bx  ; wait for timeout to elapse
	jnz short loadtime

timedout:
	mov al, [bootpart]  ; get default boot partition
	dec al
	jmp short boot

keyhit:
	mov ah, 0  ; read key
	int 0x16
	mov bx, 0  ; disable timeout
	sub al, ONE  ; convert partition number
	cmp al, ENTRIES
	jae short waitkey

boot:
	push ax  ; remember partition
	add al, ONE  ; say which one
	call putc
	mov bx, m_crlf
	call puts
	pop ax

	mov ah, partition  ; size of each partition
	mul ah  ; offset
	mov si, BUFFER+TABLE  ; point at partition table
	add si, ax  ; point at partition entry

	pushf  ; fake an int 0x13
	push cs
	mov bx, BOOTCODE
	push bx
	mov ax, VECTOR  ; vector segment
	mov es, ax

	mov ax, 0x201  ; read one sector
	mov dh, [es:si+shead]  ; head
	mov cl, [es:si+ssector]  ; sector
	mov ch, [es:si+scylinder]  ; cylinder
	mov dl, [diskcode]  ; disk

	jmp far [es:DISK_VECTOR]  ; read and boot

m_boot:
	db 10, 'Boot: ', 0
m_logo:
	db 'WiniBoot v1.0 Nov 1989', 13, 10, 10
	db '   Boot Hd Sec Cyl Type Hd Sec Cyl      Base      Size'
m_crlf:
	db 13, 10, 0
diskcode:
	db 0

; --- Print a String
;
; Print a string on to the console. The string will be pointed to
; by bx on entry and be assumed to lie in the segment indicated
; by ds.

puts:
	mov al, [bx]  ; pick up next character
	inc bx  ; advance
	test al, al  ; check for terminating null
	je putsret
	call putc
	jmp short puts
putsret:
	ret

; --- Print a Character.
;
; Print a character on the console. The character is assumed
; to be in al.

putc:
	push si
	push di
	push bx
	mov bx, 1  ; page zero and foreground colour
	mov ah, 0x0e  ; write text in teletype mode
	int 0x10
	pop bx
	pop di
	pop si
	ret

; --- Print a long.
;
; Print the unsigned long in ax, dx on the console. Call
; at the alternate entry points to print out shorts or
; bytes. Load the radix in di _before_ the call and
; the field width in cx.

putbyte:
	xor ah, ah  ; kill high order

putshort:
	xor dx, dx  ; kill high order

putlong:
	push si  ; save
	push bx
	push cx
	call putnum
	pop cx  ; recover
	pop bx
	pop si
	ret

putnum:
	push ax  ; least significant word
	mov ax, dx  ; most significant part first
	xor dx, dx
	div di
	mov si, ax  ; most significant part of quotient
	pop ax  ; combine remainder
	div di
	push dx  ; modulo radix
	mov dx, si  ; most significant part of quotient
	mov si, ax  ; check for zero
	or si, dx
	jz pad
	dec cl  ; another digit done
	call putnum  ; convert high order first
	jmp short nopad

pad:
	dec cl  ; count down
	jle nopad
	mov al, SPACE  ; pad with spaces
	call putc
	jmp short pad

nopad:
	pop ax  ; print digit
	cmp al, 9
	jbe nothex
	add al, HEXOFFSET  ; a-f
nothex:
	add al, ZERO
	call putc
	ret

	times BOOTPART-($-$$) db 0 ; !! Shouldn't be needed.
bootpart:
	db 1  ; Default partition to boot. !! Look for active.

; --- This is a copy of C. E. Chew's HDD partition table. !!

%ifdef PARTITIONS
	times TABLE-($-$$) db 0
partitions:
	db 0x080, 0x001, 0x001, 0x000, 0x004, 0x005, 0x051, 0x097
	dd 0x00000011, 0x0000a27f
	db 0x000, 0x000, 0x041, 0x098, 0x040, 0x005, 0x0d1, 0x027
	dd 0x0000a290, 0x00009f60
	db 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000
	dd 0x00000000, 0x00000000
	db 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000
	dd 0x00000000, 0x00000000
boot_signature:
	dw 0xaa55
%endif

; __END__
