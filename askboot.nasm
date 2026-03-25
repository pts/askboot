;
; askboot.nasm: improved ShoeLace MBR bootloader (boot partition picker)
; extended and optimized by pts@fazekas.hu on 2026-03-25
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
; !! feature: Boot using LBA (this would increase the code size sigificantly, we'd have to call int 13h with AH==8).
;

bits 16
cpu 8086

HARD_DISK       equ 0x80     ; hard disk code
BUFFER          equ 0x600    ; buffer area above vectors
BOOTCODE        equ 0x7c00   ; boot code entry
TABLE           equ 0x1be    ; partition table offset
ENTRIES         equ 0x4      ; table entries
ZERO            equ '0'      ; ascii '0'
ONE             equ '1'      ; ascii '1'
SPACE           equ ' '      ; ascii ' '
ASTERISK        equ '*'      ; ascii '*'
HEXOFFSET       equ 'a'-'0'-10  ; offset to a-f
DISK_VECTOR     equ 0x13<<2  ; disk interrupt vector
TIMEOUT         equ 15*18    ; timeout for keyhit: ~15 seconds
TIMELO          equ 0x46c    ; BIOS timer count low  word.
TIMEHI          equ 0x46e    ; BIOS timer count high word.

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
	; !! feature: Preserved ES, DI, DX (DH) for PnP (plug-and-play) BIOS. Restoring ES and DH would make our `jmp far [DISK_VECTOR]' trick fail.
	;    Preserve DH and ES:DI for full plug-and-play support. https://en.wikipedia.org/wiki/Master_boot_record#MBR_to_VBR_interface
	;mov bx, es  ; Save original ES.
	xor ax, ax
	mov es, ax
	mov ds, ax
	cli  ; Work around bug in early 8086 for changing SS:SP unlocked.
	mov ss, ax
	mov sp, BOOTCODE  ; set up to of stack.
	sti

	;or dl, HARD_DISK  ; boot hard disk. Not needed, DL is already >= 0x80.
	mov si, sp  ; == BOOTCODE  ; move table to low memory
	mov di, BUFFER  ; buffer address
	mov cx, 0x200>>1  ; one sector
	cld  ; direction is up
	rep movsw  ; This also uses ES == 0.

print_logo:
	mov bx, m_logo-_start+BOOTCODE  ; logo banner
	call puts

get_hdd_geometry:
	xor di, di  ; Workaround for buggy BIOS. Also the 0 value will be used later.
	;mov es, di  ; Already set.
	mov ah, 8  ; Read drive parameters.
	;mov dl, ...  ; BIOS drive number. Already set.
	push dx  ; Save DL == BIOS drive number (boot unit). Will be restored (popped) by read_and_jump_to_partition_boot_sector.
	push dx  ; Save.
	int 0x13  ; BIOS disk syscall. This call changes ES and DI only if DL is a floppy drive. But it isn't here, because we are running an MBR.
.disk_error_infinite_loop:
	jc .disk_error_infinite_loop
	mov al, dh
	mov ah, 0
	inc ax
	pop dx  ; Restore DL := BIOS drive number; AH := junk.
	push ax  ; Save HDD head count (1..256).
	and cx, byte 0x3f  ; Also sets CH := 0.
	push cx  ; Save HDD sectors-per-track (0..63, 0 is invalid).
	mov ah, 1  ; Get status of last drive operation. Needed after the AH == 8 call. Takes the drive number in DL.
	int 0x13  ; BIOS syscall.

find_active:
	mov si, BOOTCODE+TABLE+partition*4  ; +active
	mov bx, DEFAULT_PARTITION<<8|4  ; BH := 1 (fallback default partition); BL := first partition to try.
.next:
	sub si, byte partition
	cmp [si+active], ch  ; CH == 0.
	jnl short .maybe_next  ; Jump iff the 1<<7 == 0x80 bit in byte [si+active] is not set, i.e. the partition is not active.
	mov bh, bl  ; BH := first active partition.
.maybe_next:
	dec bl
	jnz short .next

print_partitions:
	;mov si, BOOTCODE+TABLE  ; partition table  . Already set.
	mov bl, ONE  ; BL := '1' (partition number to print first); BH := junk.
.next:
	mov al, SPACE  ; look for default
	cmp bl, bh  ; BH == default partition.
	jne short .not_default
	mov al, ASTERISK  ; this is the default
.not_default:
	call putc

	mov al, bl  ; which partition
	call putc

	push bx  ; remember for later

	mov di, 16  ; hex
	mov cx, 0x804  ; CL (field width) := 4; CH (field count) := 8.

.firstfields:
	lodsb
	call putbyte  ; !! feature: Print CX not as 8+8, but as 10(cyl)+6(sec) bits.
	dec ch
	jnz short .firstfields

	mov di, 10  ; decimal
	mov cx, 0x20a  ; CL (field width) := 10; CH (field count) := 2 (start sector (LBA) and sector count).

.secondfields:
	lodsw
	xchg ax, dx
	lodsw
	xchg ax, dx  ; DX:AX := uint32 to print.
	call putdword
	dec ch
	jnz short .secondfields  ; !! size optimization: Try to do `loop' in CL is 0, swap. Save up to 2 bytes.

	mov bx, m_crlf-_start+BOOTCODE  ; say newline
	call puts

	pop bx  ; partition number
	inc bx
	cmp bl, ZERO+ENTRIES
	jbe short .next
	; Fall through to display_boot_prompt.

display_boot_prompt:
	mov bl, bh
	dec bx
	push bx  ; Save default partition in BL+1.

	mov bx, m_boot-_start+BOOTCODE  ; say we're booting
	call puts

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
	pop bx  ; Discard default partition. Not needed.
	; Fall through to boot.

boot:  ; Boot the primary partition specified in AL+1 (AL == 0 meaning the first partition).
	add al, ONE  ; say which one
	call putc
	mov ah, partition  ; size of each partition
	mul ah  ; offset
	add ax, strict word BUFFER+TABLE-ONE*partition  ; point at partition table
	xchg si, ax  ; SI := AX (offset of partition entry); AX := junk.
	mov bx, m_crlf-_start+BOOTCODE
	call puts

	mov cx, [si+hidden  ]  ; CX := low  word of partition start sector.
	mov ax, [si+hidden+2]  ; AX := high word of partition start sector.
	; Fall through to convert_lba_to_chs.

; Converts sector offset (LBA) value in AX:CX to BIOS-style CHS value in CX
; and DL (instead of DH). Ruins DH, BX, AX and FLAGS. This is heavily
; optimized for code size.
convert_lba_to_chs:
	xor dx, dx
	pop bx  ; Restore BX := HDD sectors-per-track.
	div bx  ; BX == HDD sectors-per-track. We expect it to be in 1..63.
	xchg cx, ax
	div bx   ; BX == HDD sectors-per-track. We expect it to be in 1..63.
	inc dx  ; Like `inc dl`, but 1 byte shorter. Sector numbers start with 1.
	xchg cx, dx  ; CX := sec value (1..63); CL := sec value (1..63); CH := 0; DX := high word of dividend.
	pop bx  ; Restore BX := HDD head count.
	div bx  ; BX == HDD had count. We expect it to be 1..256. AX := cyl value (BIOS allows 0..1023); DX := head value (0..255); DL := head value (0..255); DH := 0; Sets the high 6 bits of AH (and AX) to 0.
	; BIOS int 13h AH == 2 wants the head value in DH, the low 8
	; bits of the cyl value in CH, and it wants CL ==
	; (cyl>>8<<6)|head. Thus we copy DL to DH (cyl value), AL to
	; CH (low 8 bits of the cyl value), AH to CL (sec value),
	; and or the 2 bits of AH (high 8 bits of the cyl value)
	; shifted to CL.
	mov ch, al
	times 2 ror ah, 1  ; This works because the high 6 bits of AH were 0.
	or cl, ah
	; Fall through to read_and_jump_to_partition_boot_sector.

read_and_jump_to_partition_boot_sector:
	pop ax  ; Restore AL := BIOS drive number; AH := junk.
	mov ah, dl  ; AH := head value.
	xchg dx, ax  ; DH := head value; DL := BIOS drive number; AX := junk.
	mov ax, 0x201  ; read one sector
	mov bx, sp  ; BX := BOOTCODE.
	;push ds  ; 0
	;pop es  ; ES := 0. Not needed, it's already 0. We make ES:BX == 0:BOOTCODE point to the read destination buffer.
	pushf  ; Fake stack entry for an iret in `int 0x13'.
	push ds  ; 0.
	push bx
	jmp far [DISK_VECTOR]  ; read and boot
	; Not reached. On disk read error, the MBR code (us) is run again.


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
; (must be <=0x7f), onto the console. Ruins AX, CL, DX.
putbyte:
	mov ah, 0
%if 1
	cwd  ; DX := 0. This only works if AH <= 0x7f.
	; Fall through to putdword.
%else
	; Fall through to putword.

; Prints the uint16_t in AX, in base DI, padded with spaces to field width
; CL (must be <=0x7f), onto the console. Ruins AX, CL, DX.
putword:
	xor dx, dx  ; DX := 0.
%endif
	; Fall through to putdword.

; Prints the uint32_t in DX:AX, in base DI, padded with spaces to field
; width CL (must be <=0x7f), onto the console. Ruins AX, CL, DX.
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

; Prints a character in AL onto the console. Ruins AH, BP.
putc:
	;push bp  ; Save for some buggy BIOS when scrolling. No need to save BP.
	;push ax
	push bx
	xor bx, bx  ; Page and color.
	mov ah, 0xe  ; Write text in teletype mode to console. This ruins BP when scrolling in some buggy BIOS.
	int 0x10  ; BIOS video syscall: print character to console.
	pop bx
	;pop ax
	;pop bp  ; Restore.
	ret

m_boot:
	db 10, 'Boot: ', 0
m_logo:
	db 'AskBoot v1.1 Mar 2026', 13, 10, 10
	db '   Boot Hd Sec Cyl Type Hd Sec Cyl      Base      Size'
m_crlf:
	db 13, 10, 0

	times TABLE-2-($-$$) db '-'
magic:
	dw 0  ; Indicate valid partition table. https://github.com/pts/pts-pc-rescuekit kernels check it.

; __END__
