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
; See also
; https://en.wikipedia.org/wiki/Master_boot_record#MBR_to_VBR_interface for
; how this MBR code transfers control to the boot sector boot code (Volume
; Boot Record, VBR).
;
; This program loads the partition boot sector using CHS (not LBA), but it
; calculates the CHS values from the LBA sector index, so it ignores the CHS
; numbers in the partition table, but it still can't boot from a partition
; starting at >~7.87 GiB from the start of the HDD. To overcome that, the
; EBIOS syscall call (int 13h with AH==0x42) would have to be used to read
; the partition boot sector, but that code (with autodetection) doesn't fit.
;
; Edit history:
;
; * 1988-04-25: Created source
; * 1988-08-19: Adapted to boot off Dos or Minix partition
; * 1989-10-06: Converted for Minix assembler
; * 1989-10-09: Add default boot partition
; * 1990-04-24 v1.0a: Part of Minix bootloader ShoeLace 1.0a
; * 2026-03-25 v1.1: Changes by Peter Szabo <pts@fazekas.hu>
;   * Translated BCC as (and asld) syntax to NASM.
;   * Moved all variables to the stack.
;   * Made sure that the word at file offet MAGIC is 0. Some MBR parsers rely on it.
;   * Added detection of the first active partition, and made it default.
;   * Added handling <Enter> to boot default partition.
;   * Added calculation of boot sector CHS from the LBA (hidden) field of the partition (rather than the shead, ssector and scyliner fields), the former is more reliable.
;   * Added preserving of the ES, DI and DH register values for plug-and-play (PnP) BIOS.
;
; !! feature: Boot using LBA (this would increase the code size sigificantly, we'd have to call int 13h with AH==8).
;

bits 16
cpu 8086

HARD_DISK       equ 0x80     ; hard disk code
BUFFER          equ 0x1000   ; buffer area above vectors, 0x200 bytes
BOOTCODE        equ 0x7c00   ; boot code entry
BSCODE          equ 0x7bfa   ; entry just before reading the boot sector, see BSCODE below.
MAGIC           equ 0x1bc    ; magic value offset
TABLE           equ 0x1be    ; partition table offset
ENTRIES         equ 0x4      ; table entries
ZERO            equ '0'      ; ascii '0'
ONE             equ '1'      ; ascii '1'
SPACE           equ ' '      ; ascii ' '
ASTERISK        equ '*'      ; ascii '*'
HEXOFFSET       equ 'a'-'0'-10  ; offset to a-f
DISK_VECTOR     equ 0x13<<2  ; disk interrupt vector
TIMEOUT_SEC     equ 15       ; Timeout waiting for a user keypress to select the partition to boot.
TIMEOUT         equ ((TIMEOUT_SEC)*1193182+(1<<15))>>16  ; Timeout for keyhit in PIT ticks.
TIMELO          equ 0x46c    ; BIOS timer count low  word.
TIMEHI          equ 0x46e    ; BIOS timer count high word.

DEFAULT_PARTITION equ 1  ; Only if no partition is active.
ENTER_ASCII equ 13  ; The ASCII code for the <Enter> key. The scancode is 28.

; --- Partition table structure

struc partition_entry
.active:         resb 1  ; equ 0   ; partition is active
.shead:          resb 1  ; equ 1   ; start head
.ssector:        resb 1  ; equ 2   ; start sector
.scylinder:      resb 1  ; equ 3   ; start cylinder
.type:           resb 1  ; equ 4   ; partition type
.ehead:          resb 1  ; equ 5   ; end head
.esector:        resb 1  ; equ 6   ; end sector
.ecylinder:      resb 1  ; equ 7   ; end cylinder
.hidden:         resd 1  ; equ 8   ; hidden sectors, i.e. partition start sector index (LBA)
.sectors:        resd 1  ; equ 12  ; size of partition
.size:                   ; equ 16  ; partition_entry structure size
endstruc

; --- Boot entry point
;
; The BIOS boot code will load this at location 0000:7c00. The hard
; disk partition table is loaded above the vectors.

_start:
	; This is typically loaded to CS:IP == 0:0x7c00, but some BIOSes load it to CS:IP == 0x7c0:0. So we can't be sure about the value of CS.
	xor ax, ax
	mov ds, ax
	cli  ; Work around bug in early 8086 for changing SS:SP unlocked.
	mov ss, ax
	mov sp, BOOTCODE  ; set up to of stack.
	sti
	mov si, sp  ; == BOOTCODE  ; move table to low memory

	db 0xb8  ; Opcode byte of `mov ax, ...'.
	    pop di  ; Restore DI used by plug-and-play (PnP) BIOS.
	    pop dx  ; Restore DH used by plug-and-play (PnP) BIOS. As a side effect, restore DL (BIOS drive number).
	push ax
	db 0xb8  ; Opcode byte of `mov ax, ...'.
	    db 0x13  ; Immediate byte of `int 0x13', BIOS disk syscall.
	    pop es  ; Restore ES used by plug-and-play (PnP) BIOS.
	push ax
	db 0xb8  ; Opcode byte of `mov ax, ...'.
	    xchg dx, ax  ; DH := head value; DL := BIOS drive number; AH := 2 (read sectors; AL := 1 (read 1 sector).
	    db 0xcd  ; Opcode byte of `int 0x13', BIOS disk syscall.
	push ax
	push dx
	push di
	push es
	; Now the stack looks like this:
	; word [ss:sp    ] == word [0:0x7bf4] == ES saved for plug-and-play (PnP) BIOS.
	; word [ss:sp+2  ] == word [0:0x7bf6] == DI saved for plug-and-play (PnP) BIOS.
	; byte [ss:sp+4  ] == byte [0:0x7bf8] == BIOS drive number, will be restored to DL.
	; byte [ss:sp+5  ] == byte [0:0x7bf9] == DH saved for plug-and-play (PnP) BIOS.
	; word [ss:sp+6  ] == word [0:0x7bfa] == word [0:BSCODE] == `xchg dx, ax'  ; DH := head value; DL := BIOS drive number; AH := 2 (read sectors; AL := 1 (read 1 sector).
	; byte [ss:sp+8  ] == byte [0:0x7bfc] == `int 0x13'  ; BIOS disk syscall to read a sector (0x200 bytes) to 0x7c00:0. It will keep the data unchanged on error.
	; byte [ss:sp+9  ] == byte [0:0x7bfd] == `pop es'  ; Restore ES saved for plug-and-play (PnP) BIOS.
	; byte [ss:sp+0xa] == byte [0:0x7bfe] == `pop di'  ; Restore DI saved for plug-and-play (PnP) BIOS.
	; byte [ss:sp+0xb] == byte [0:0x7bff] == `pop dx'  ; Restore DH saved for plug-and-play (PnP) BIOS and DL (BIOS drive number). DL is already correct, the restore keeps it unchanged.`
	; Top (end) of stack is SS:BOOTCODE == 0:0x7c00.  ; And then fall through to 0:BOOTCODE == 0x7c00, the entry point of the boot sector, or (on read error) the entry point of the MBR code again.

	;or dl, HARD_DISK  ; boot hard disk. Not needed, DL is already >= 0x80.
	xor di, di
%if (BUFFER>>4)<(0x200>>1)
  %error ERROR_BAD_BUFFER
  times -1 nop
%endif
	mov cx, BUFFER>>4  ; At least 1 sector (0x200 bytes).
	mov es, cx
	cld  ; direction is up
	rep movsw  ; This also uses ES.

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
	mov si, BOOTCODE+TABLE+partition_entry.size*4  ; +active
	mov bx, DEFAULT_PARTITION<<8|4  ; BH := 1 (fallback default partition); BL := first partition to try.
.next:
	sub si, byte partition_entry.size
	cmp [si+partition_entry.active], ch  ; CH == 0.
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

	push bx  ; Save BL (current partition) and BH (default partition).

	mov di, 16  ; hex
	mov cx, 0x804  ; CL (field width) := 4; CH (field count) := 8.

.firstfields:
	lodsb
	push cx  ; Save.
	call putbyte  ; !! feature: Print CX not as 8+8, but as 10(cyl)+6(sec) bits.
	pop cx  ; Restore.
	dec ch
	jnz short .firstfields

	mov di, 10  ; decimal
	mov cx, 0x20a  ; CL (field width) := 10; CH (field count) := 2 (start sector (LBA) and sector count).

.secondfields:
	lodsw
	xchg ax, dx
	lodsw
	xchg ax, dx  ; DX:AX := uint32 to print.
	push cx  ; Save.
	call putdword
	pop cx  ; Restore.
	dec ch
	jnz short .secondfields

	mov bx, m_crlf-_start+BOOTCODE  ; say newline
	call puts

	pop bx  ; Restore BL (current partition) and BH (default partition).
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
	mov cx, [TIMELO]  ; load the current time

waitkey:
	mov ah, 1  ; check for keystroke
	int 0x16  ; BIOS keyboard syscall.
	jnz short keyhit  ; key was struck

	test bx, bx  ; no timeout desired?
	jz short waitkey  ; This is a CPU-spinning wait. A `hlt' to wait for a keyboard or timer interrupt would introduce a race condition.

	cmp cx, [TIMELO]  ; check for new time
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
	mov ah, partition_entry.size  ; size of each partition
	mul ah  ; offset
	add ax, strict word BUFFER+TABLE-ONE*partition_entry.size  ; point at partition table
	xchg si, ax  ; SI := AX (offset of partition entry); AX := junk.
	mov bx, m_crlf-_start+BOOTCODE
	call puts

	mov cx, [si+partition_entry.hidden  ]  ; CX := low  word of partition start sector.
	mov ax, [si+partition_entry.hidden+2]  ; AX := high word of partition start sector.
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
	div bx  ; BX == HDD head count. We expect it to be 1..256. AX := cyl value (BIOS allows 0..1023); DX := head value (0..255); DL := head value (0..255); DH := 0; Sets the high 6 bits of AH (and AX) to 0.
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
	mov dx, 0x201  ; read one sector. Will be copied to AX by `xchg dx, ax' at 0:BSCODE.
	mov bx, BOOTCODE-BUFFER
	;mov di, BUFFER>>4
	;mov es, di  ; ES := BUFFER>>4. Not needed, it's already set. We make ES:BX == (BUFFER>>4):(BOOTCODE-BUFFER) =~= 0:BOOTCODE point to the read destination buffer.
	jmp 0:BSCODE  ; Finally we set CS to 0.
	; Not reached. On disk read error, the MBR code (us) is run again.


; Prints a string onto the console. The string will be pointed to
; by DS:BX. Ruins BX, AL.
puts:
.next:
	mov al, [bx]  ; pick up next character
	inc bx  ; advance
	test al, al  ; check for terminating null
	jz short putc.ret
	call putc
	jmp short .next

; Prints the uint8_t in AL, in base DI, padded with spaces to field width CL
; (must be <=0x7f), onto the console. Ruins AX, BX, CX, DX.
putbyte:
	mov ah, 0
%if 1
	cwd  ; DX := 0. This only works if AH <= 0x7f.
	; Fall through to putdword.
%else
	; Fall through to putword.

; Prints the uint16_t in AX, in base DI, padded with spaces to field width
; CL (must be <=0x7f), onto the console. Ruins AX, BX, CX, DX.
putword:
	xor dx, dx  ; DX := 0.
%endif
	; Fall through to putdword.

; Prints the uint32_t in DX:AX, in base DI, padded with spaces to field
; width CL (must be <=0x7f), onto the console. Ruins AX, BX, CX, DX.
putdword:
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
.ret:
	ret

m_boot:
	db 10, 'Boot: ', 0
m_logo:
	db 'AskBoot v1.1 Mar 2026', 13, 10, 10
	db '   Boot Hd Sec Cyl Type Hd Sec Cyl      Base      Size'
m_crlf:
	db 13, 10, 0

	times MAGIC-($-$$) db '-'
magic:
	dw 0  ; Indicate valid partition table. https://github.com/pts/pts-pc-rescuekit kernels check it.

; __END__
