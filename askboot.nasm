;
; askboot.nasm: improved ShoeLace MBR bootloader (boot partition picker)
; extended by pts@fazekas.hu on 2026-03-25
; based on winiboot.x by C. E. Chew 1988-04-25 -- 1990-04-24
;
; Compile with: nasm -O0 -w+orphan-labels -f bin -o askboot.bin askboot.nasm
; Minimum NASM version required: 0.98.39
;
; This program displays the partition table (only the 4 primary partition),
; waits for a user keypress with a timeout (~15 seconds), and boots the
; selected partition. On timeout and upon <Enter>, it boots the default
; partition, which is the first acive partition, or the first partition if
; none are active.
;
; This program loads the partition boot sector using CHS (not LBA), so the
; CHS numbers in the partition table must be correct. Also it can't boot
; from a partition far away from the start of a huge (>~7.87 GiB) HDD.
;
; Edit history:
;
; * 1988-04-25: Created source
; * 1988-08-19: Adapted to boot off Dos or Minix partition
; * 1989-10-06: Converted for Minix assembler
; * 1989-10-09: Add default boot partition
; * 1990-04-24 v1.0: Part of Minix bootloader ShoeLace 1.0a
; * 2026-03-25: Translated to NASM; Added as an UKH kernel (by pts@fazekas.hu)
; * 2026-03-25 v1.1: Moved bootpart earlier, to make room for magic_number; Added detection of the first active partition; <Enter> to boot default
;
; !! Boot using LBA (this would increase the code size sigificantly, we'd have to call int 13h with AH==8).
;

bits 16
cpu 8086

HARD_DISK       equ 0x80     ; hard disk code
BUFFER          equ 0x600    ; buffer area above vectors
BOOTCODE        equ 0x7c00   ; boot code entry
BOOTSEG         equ 0x7c0    ; boot segment
TOPOFSTACK      equ 0x7c00   ; top of stack
TABLE           equ 0x1be    ; partition table offset
ENTRIES         equ 0x4      ; table entries
ZERO            equ 0x30     ; ascii '0'
ONE             equ 0x31     ; ascii '1'
SPACE           equ 0x20     ; ascii ' '
ASTERISK        equ 0x2a     ; ascii '*'
HEXOFFSET       equ 39       ; offset to a-f
VECTOR          equ 0x00     ; vector segment
DISK_VECTOR     equ 0x13<<2  ; disk interrupt vector
TIMEOUT         equ 15*18    ; timeout for keyhit: ~15 seconds
TIMELO          equ 0x46c    ; timer count low
TIMEHI          equ 0x46e    ; timer count high

DEFAULT_PARTITION equ 1  ; Only if no partition is active.
ENTER_ASCII equ 13  ; The ASCII code for the <Enter> key. The scancode is 28.

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

; --- Boot entry point
;
; The BIOS boot code will load this at location 0000:7c00. The hard
; disk partition table is loaded above the vectors.

_start:
	mov ax, VECTOR  ; vector segment
	mov es, ax
	cli  ; Work around bug in early 8086 for changing SS:SP unlocked.
	mov ss, ax
	mov sp, TOPOFSTACK  ; set up a stack
	sti
	mov ax, BOOTSEG  ; boot segment
	mov ds, ax

	or dl, HARD_DISK  ; boot hard disk !! Not needed.
	mov [diskcode], dl  ; code for this hard disk

	mov si, _start  ; move table to low memory
	mov di, BUFFER  ; buffer address
	mov cx, 0x100  ; one sector
	cld  ; direction is up
	rep movsw

print_logo:
	mov bx, m_logo  ; logo banner
	call puts

find_active:
	mov si, TABLE+partition*4  ; +active
	mov bx, DEFAULT_PARTITION<<8|4  ; BH := 1 (fallback default partition); BL := first partition to try.
.next:
	sub si, byte partition
	cmp byte [si+active], 0  ; !! Do we have a 0 somewhere?
	jnl short .maybe_next
	mov bh, bl  ; BH := first active partition.
.maybe_next:
	dec bl
	jnz short .next

print_partitions:
	;mov si, TABLE  ; partition table  . Already set.
	inc bx  ; BL := 1 (partition number to print first); BH := junk.
.next:
	mov al, SPACE  ; look for default
	cmp bl, bh  ; BH == default partition.
	jne short .not_default
	mov al, ASTERISK  ; this is the default
.not_default:
	call putc

	mov di, 10  ; decimal
	mov cl, 1
	mov al, bl  ; which partition
	call putbyte

	push bx  ; remember for later

	mov di, 16  ; hex
	mov cl, 4  ; field width
	mov bl, 8  ; fields

.firstfields:
	lodsb
	call putbyte  ; !! Print CX not as 8+8, but as 10+6(sector) bits.
	dec bl
	jnz short .firstfields

	mov di, 10  ; decimal
	mov cl, 10  ; field width
	mov bl, 2  ; fields: start sector (LBA) and sector count.

.secondfields:
	lodsw
	xchg ax, dx
	lodsw
	xchg ax, dx  ; DX:AX := uint32 to print.
	call putdword
	dec bl
	jnz short .secondfields

	mov bx, m_crlf  ; say newline
	call puts

	pop bx  ; partition number
	inc bx
	cmp bl, ENTRIES
	jbe short .next
	; Fall through to display_boot_prompt.

display_boot_prompt:
	mov bl, bh
	dec bx
	push bx  ; Save default partition in BL+1.

	mov bx, m_boot  ; say we're booting
	call puts

	mov ax, VECTOR  ; vector segment
	mov es, ax  ; address low memory
	mov bx, TIMEOUT  ; timeout

loadtime:
	mov cx, [es:TIMELO]  ; load the current time

waitkey:
	mov ah, 1  ; check for keystroke
	int 0x16  ; BIOS keyboard syscall.
	jnz short keyhit  ; key was struck

	test bx, bx  ; no timeout desired?
	jz short waitkey  ; This is a CPU-spinning wait. A `hlt' to wait for a keyboard or timer interrupt would introduce a race condition.

	cmp cx, [es:TIMELO]  ; check for new time
	je short waitkey
	dec bx  ; wait for timeout to elapse
	jnz short loadtime
	; Timed out. Fall through to boot_default_partition.

boot_default_partition:
	pop ax  ; Restore AL+1 := default partition.
	jmp short boot

keyhit:
	mov ah, 0  ; read key
	int 0x16  ; BIOS keyboard syscall.
	xor bx, bx  ; disable timeout
	cmp al, ENTER_ASCII
	je short boot_default_partition
	sub al, ONE  ; convert partition number
	cmp al, ENTRIES
	jae short waitkey
	;pop bx  ; Discard default partition. Not needed.
	; Fall through to boot.

boot:  ; Boot the primary partition specified in AL+1 (AL == 0 meaning the first partition).
	push ax  ; remember partition
	add al, ONE  ; say which one
	call putc
	mov bx, m_crlf
	call puts
	pop ax

	mov ah, partition  ; size of each partition
	mul ah  ; offset
	add ax, strict word BUFFER+TABLE  ; point at partition table
	xchg si, ax  ; SI := AX (offset of partition entry); AX := junk.

	pushf  ; Fake stack entry for an iret in `int 0x13'.
	push cs  ; 0.
	mov bx, BOOTCODE
	push bx
	mov dl, 0  ; Self-modifying code: the immediate value has been set above (as [diskcode]).
diskcode: equ $-1
	push cs
	pop ds ; DS := 0. At boot sector boot code (VBR) entry, DS:SI should point to the partition entry, which it now does.
	mov ax, 0x201  ; read one sector
	mov dh, [si+shead]  ; head
	mov cx, [si+ssector]  ; CL := sector; CH := cylinder ([si+scylinder])
	jmp far [DISK_VECTOR]  ; read and boot
	; Not reached. On disk read error, the MBR code (us) is run again.
	; !! Preserve DH and ES:DI for full plug-and-play support. https://en.wikipedia.org/wiki/Master_boot_record#MBR_to_VBR_interface

; Prints a string onto the console. The string will be pointed to
; by DS:BX. Ruins BX, AL.
puts:
.next:
	mov al, [bx]  ; pick up next character
	inc bx  ; advance
	test al, al  ; check for terminating null
	jz short putdword.ret
	call putc
	jmp short .next

; Prints the uint8_t in AL, in base DI, padded with spaces to field width CL
; (must be <=0x7f), onto the console. Ruins AX, DX.
putbyte:
	mov ah, 0
%if 1
	cwd  ; DX := 0. This only works if AH <= 0x7f.
	; Fall through to putdword.
%else
	; Fall through to putword.

; Prints the uint16_t in AX, in base DI, padded with spaces to field width
; CL (must be <=0x7f), onto the console. Ruins AX, DX.
putword:
	xor dx, dx  ; DX := 0.
%endif
	; Fall through to putdword.

; Prints the uint32_t in DX:AX, in base DI, padded with spaces to field
; width CL (must be <=0x7f), onto the console. Ruins AX, DX.
putdword:
	push bx  ; Save.
	push cx  ; Save.
	call .putnum
	pop cx  ; Restore.
	pop bx  ; Restore.
.ret:
	ret
.putnum:  ; Prints remaining digits of DX:AX. Recursive.
	xchg bx, ax  ; Save AX (low word of dividend) to BX; AX := junk.
	xchg ax, dx  ; AX := high word; DX := junk.
	xor dx, dx  ; DX := 0.
	div di  ; Divide DX:AX by DI, put quotient to AX, put remainder to DX.
	xchg ax, bx  ; Restore AX from BX; BX := high dword of quotient.
	div di  ; Divide DX:AX by DI, put quotient to AX, put remainder to DX.
	push dx  ; Save digit in DL.
	mov dx, bx  ; DX := high word of quotient.
	or bx, ax  ; check for zero
	jnz short .skippad
.pad:
	dec cl  ; count down
	jle short .nopad
	mov al, SPACE  ; pad with spaces
	call putc
	jmp short .pad
.skippad:
	dec cl  ; Another digit done, one less to pad.
	call .putnum  ; convert high order first
.nopad:
	pop ax  ; Restore AL := digit.
	cmp al, 9
	jbe short .nothex
	add al, HEXOFFSET  ; a-f
.nothex:
	add al, ZERO
	; Fall through to putc.

; Prints a character in AL onto the console. Ruins AH.
putc:
	push bp  ; Save for some buggy BIOS when scrolling.
	;push ax
	push bx
	xor bx, bx  ; Page and color.
	mov ah, 0xe  ; write text in teletype mode
	int 0x10  ; BIOS video syscall: print character to console.
	pop bx
	;pop ax
	pop bp  ; Restore.
	ret

m_boot:
	db 10, 'Boot: ', 0
m_logo:
	db 'AskBoot v1.1 Mar 2026', 13, 10, 10
	db '   Boot Hd Sec Cyl Type Hd Sec Cyl      Base      Size'
m_crlf:
	db 13, 10, 0

	times TABLE-2-($-$$) db 0
magic:
	dw 0  ; Indicate valid partition table. https://github.com/pts/pts-pc-rescuekit kernels check it.

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
