;
; askboot.nasm: interactive, single-sector PC BIOS HDD MBR bootloader (boot partition picker)
; extended and optimized by pts@fazekas.hu on 2026-03-25
; based on winiboot.x by C. E. Chew 1988-04-25 -- 1990-04-24
;
; Compile with: nasm -O0 -w+orphan-labels -f bin -o askboot.bin askboot.nasm
; Minimum NASM version required: 0.98.39
; Install to HDD image file hd.img on Linux: dd if=askboot.bin of=hd.img conv=notrunc
;
; A typical HDD MBR bootloader picks the first primary partition marked
; active, loads its boot sector (first 0x200 bytes of the partition) to
; 0:0x7c00, and jumps to it (in real mode). askboot displays details of all
; 4 primary partitions, and lets the user pick one to boot by pressing a key
; (<1> to <4>). If the user presses <Enter> instead, or a timeout of ~15
; seconds elapses, askboot boots the first primary partition marked as
; active, or the first partition if none are active.
;
; Additional features of askboot: it uses EBIOS LBA (if available), so it
; can boot from a partition starting after the the first ~7.87 GiB of the
; HDD; it ignores the CHS values (which are less reliable, especially if the
; HDD image is moved between emulators or the PC BIOS settings are changed)
; in the partition table entry, and it always uses the partition start
; sector index (LBA), even if EBIOS LBA is not available.
;
; askboot can boot on an IBM PC (or compatible) with a 8086 or newer CPU and
; BIOS boot. So it runs on most PCs before 2010. Newer PCs tend to use UEFI
; boot instead, some of them still retaining BIOS boot as a configuration
; option, sometimes called as *legacy BIOS* boot.
;
; See also
; https://en.wikipedia.org/wiki/Master_boot_record#MBR_to_VBR_interface for
; how this MBR code transfers control to the boot sector boot code (Volume
; Boot Record, VBR).
;
; Edit history:
;
; * 1988-04-25: C. E. Chew created the first implementation of WiniBoot for ShoeLace.
; * 1988-08-19: Adapted to boot off DOS or Minix partition
; * 1989-10-06: Converted yo Minix assembler (asld) syntax.
; * 1989-10-09: Add default boot partition.
; * 1990-04-24 v1.0a: Part of Minix bootloader ShoeLace 1.0a.
; * 2026-03-25 v1.1: Changes by Peter Szabo <pts@fazekas.hu>:
;   * Translated BCC as (and asld) syntax to NASM.
;   * Moved all variables to the stack.
;   * Made sure that the word at file offet MAGIC is 0. Some MBR parsers rely on it.
;   * Added detection of the first active partition, and made it default.
;   * Added handling <Enter> to boot default partition.
;   * Added boot using EBIOS LBA (if available), which fixes booting from a partition starting after the first ~7.87 GiB of the HDD.
;   * Added calculation of boot sector CHS from the LBA (hidden) field of the partition (rather than the shead, ssector and scyliner fields), the former is more reliable.
;   * Added preserving of the ES, DI and DH register values for plug-and-play (PnP) BIOS.
;   * Improved timeout accuracy.
;   * Made the display of fields Base (.hidden) and Size (.sectors) wider, so that there is always a space in-between.
;   * Heavily optimized the 8086 assembly implementation for size so that all the new functionality fits in.
;

; --- Configuration

%ifdef TIMEOUT_SEC  ; Timeout (number of seconds) waiting for a user keypress to select the partition to boot. Actualy timeout may be a bit larger. Specify 0 or negative to disable timeout (i.e. to make it infinite).
  %assign TIMEOUT_SEC TIMEOUT_SEC
%else
  %define TIMEOUT_SEC 15  ; Default.
%endif

%ifdef FALLBACK_PARTITION  ; Fallback default partition number if there is no active primary partition. Must be 1, 2, 3 or 4.
  %assign FALLBACK_PARTITION FALLBACK_PARTITION
%else
  %define FALLBACK_PARTITION 1  ; Default.
%endif
%if FALLBACK_PARTITION<1 || FALLBACK_PARTITION>4
  %error ERROR_BAD_FALLBACK_PARTITION FALLBACK_PARTITION
  times -1 nop
%endif

; ---

bits 16
cpu 8086

BOOTCODE        equ 0x7c00   ; Boot code entry. 0x200 bytes of MBR of boot sector starts here.
MBRCODE         equ 0x7a00   ; MBR code entry. 0x200 bytes of MBR starts here, copied from BOOTCODE.
MAGIC           equ 0x1bc    ; magic value offset
TABLE           equ 0x1be    ; partition table offset
ENTRIES         equ 0x4      ; table entries
ZERO            equ '0'      ; ascii '0'
ONE             equ '1'      ; ascii '1'
SPACE           equ ' '      ; ascii ' '
ASTERISK        equ '*'      ; ascii '*'
HEXOFFSET       equ 'a'-'0'-10  ; offset to a-f
DISK_VECTOR     equ 0x13<<2  ; disk interrupt vector
%if (TIMEOUT_SEC)>0
  TIMEOUT       equ ((TIMEOUT_SEC)*1193182+(1<<15))>>16  ; Timeout for keyhit in PIT ticks.
%else
  TIMEOUT       equ 0
%endif
TIMELO          equ 0x46c    ; BIOS timer count low  word.
TIMEHI          equ 0x46e    ; BIOS timer count high word.

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
	xor cx, cx
	mov ds, cx
	cli  ; Work around bug in early 8086 for changing SS:SP unlocked.
	mov ss, cx
	mov sp, MBRCODE  ; set up to of stack.
	sti

	push dx  ; Save DH for plug-and-play (PnP) BIOS, and as a side effect, save DL (BIOS drive number). Will be restored (popped) by jump_to_partition_boot_sector.
	push di  ; Save ES for plug-and-play (PnP) BIOS. Will be restored (popped) by jump_to_partition_boot_sector.
	push es  ; Save ES for plug-and-play (PnP) BIOS. Will be restored (popped) by jump_to_partition_boot_sector.

	mov es, cx
	mov si, BOOTCODE
	mov di, MBRCODE
	mov ch, 0x200>>1>>8  ; 1 sector (0x200 bytes). Sets CX := 0x200>>1, because CL is already 0.
	cld  ; direction is up
	rep movsw  ; This also uses ES.
	jmp 0:MBRCODE+print_logo-_start  ; Jump to print_logo in the copy.
	; Not reached.

; Prints a string onto the console. The string will be pointed to
; by DS:BL+BOOTCODE. Ruins BX, AL := 0.
puts:
%if BOOTCODE&0xff
  %error ERROR_BOOTCODE_NOT_DIVISIBLE_BY_0x100
  times -1 nop
%endif
	mov bh, BOOTCODE>>8
.next:
	mov al, [bx]  ; pick up next character
	inc bx  ; advance
	test al, al  ; check for terminating null
	jz short putc.ret
	call putc
	jmp short .next

; Prints the byte in AL, in base DI, padded with spaces to field width CL
; (must be <=0x7f), onto the console. Ruins AX, BX, CX, DX.
putbyte:
	mov ah, 0
%if 1
	cwd  ; DX := 0. This only works if AH <= 0x7f.
	; Fall through to putdword.
%else
	; Fall through to putword.

; Prints the word in AX, in base DI, padded with spaces to field width
; CL (must be <=0x7f), onto the console. Ruins AX, BX, CX, DX.
putword:
	xor dx, dx  ; DX := 0.
%endif
	; Fall through to putdword.

; Prints the dword in DX:AX, in base DI, padded with spaces to field
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
	;push ax  ; Save.
	push bx
	xor bx, bx  ; Page and color.
	mov ah, 0xe  ; Write text in teletype mode to console. This ruins BP when scrolling in some buggy BIOS.
	int 0x10  ; BIOS video syscall: print character to console.
	pop bx
	;pop ax  ; Restore.
	;pop bp  ; Restore.
.ret:
	ret

m_boot:
	db 10, 'Boot: ', 0
m_logo:
	db 'AskBoot v1.1 Mar 2026', 13, 10, 10
	db '   Boot Hd Sec Cyl Type Hd Sec Cyl       Base       Size'
m_crlf:
	db 13, 10, 0

print_logo:
	mov bl, m_logo-_start  ; logo banner
	call puts

get_hdd_geometry:
	xor di, di  ; Workaround for buggy BIOS: ES:DI must be 0:0 for int 13h AH==8.
	;mov es, di  ; Already set.
	mov ah, 8  ; Read drive parameters.
	;mov dl, ...  ; BIOS drive number. Already set.
	push dx  ; Save. Will be restored (popped) right below.
	int 0x13  ; BIOS disk syscall. This call changes ES and DI only if DL is a floppy drive. But it isn't here, because we are running an MBR.
	; If the HDD is larger than ~7.87 GiB, now DH == 0xfe, CX == 0xffff, which indicates the BIOS maximum.
.disk_error_infinite_loop:
	jc short .disk_error_infinite_loop
	mov al, dh
	mov ah, 0
	inc ax
	pop dx  ; Restore DL := BIOS drive number; DH := junk.
	push dx  ; Save DL == BIOS drive number (boot unit). Will be restored (popped) by read_partition_boot_sector_ebios_lba.
	push ax  ; Save HDD head count (1..256, most BIOSes never return 256, because early MS-DOS doesn't support it). Will be restored (popped) by read_partition_boot_sector_ebios_lba.
	and cx, byte 0x3f  ; Also sets CH := 0.
	push cx  ; Save HDD sectors-per-track (0..63, 0 is invalid). Will be restored (popped) by read_partition_boot_sector_ebios_lba.
	mov ah, 1  ; Get status of last drive operation. Needed after the AH == 8 call. Uses the BIOS drive number in DL.
	int 0x13  ; BIOS disk syscall.

find_active:
	mov si, BOOTCODE+TABLE+partition_entry.size*4
	mov bx, FALLBACK_PARTITION<<8|4  ; BH := 1 (fallback default partition); BL := first partition to try.
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
	inc bx  ; BL := 1 (partition number to print first); BH := junk.
.next:
	mov al, SPACE  ; look for default
	cmp bl, bh  ; BH == default partition.
	jne short .not_default
	mov al, ASTERISK  ; this is the default
.not_default:
	call putc

	lea ax, [bx+ZERO]  ; AL := BL+ZERO; AH := junk.
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
	mov cx, 0x20b  ; CL (field width) := 11; CH (field count) := 2 (start sector (LBA) and sector count).

.secondfields:
	lodsw
	xchg ax, dx
	lodsw
	xchg ax, dx  ; DX:AX := dword to print.
	push cx  ; Save.
	call putdword
	pop cx  ; Restore.
	dec ch
	jnz short .secondfields

	mov bl, m_crlf-_start  ; say newline
	call puts

	pop bx  ; Restore BL (current partition) and BH (default partition).
	inc bx
	cmp bl, ENTRIES
	jbe short .next
	; Fall through to display_boot_prompt.

display_boot_prompt:
	mov dl, bh
	dec dx  ; DL+1 := default partition.

	mov bl, m_boot-_start  ; say we're booting
	call puts

%if TIMEOUT>0  ; Timeout desired.
	mov cx, TIMEOUT  ; timeout
%else
	jmp short keyhit  ; It will wait for the next keypress.
	nop  ; Not reached. This nop is to match the size of the other `%if' branch.
%endif
	mov si, TIMELO

loadtime:
	mov bx, [si]  ; load the current time at word [TIMELO].

waitkey:
	mov ah, 1  ; check for keystroke
	int 0x16  ; BIOS keyboard syscall.
	jnz short keyhit  ; key was struck
	cmp bx, [si]  ; check for new time
	je short waitkey  ; This is a CPU-spinning wait. A `hlt' to wait for a keyboard or timer interrupt would introduce a race condition.
	loop loadtime  ; Wait for timeout to elapse. Also does CX -= 1.
	; Timed out. Fall through to boot_default_partition.

boot_default_partition:
	xchg ax, dx  ; AL+1 := default partition; AH := junk; DX := junk.
	jmp short boot

keyhit:
	mov ah, 0  ; read key
	int 0x16  ; BIOS keyboard syscall.
	cmp al, ENTER_ASCII
	je short boot_default_partition
	sub al, ONE  ; convert partition number
	cmp al, ENTRIES
	jae short keyhit  ; No more timeout processing after the first keypress.
	; Fall through to boot.

boot:  ; Boot the primary partition specified in AL+1 (AL == 0 meaning the first partition).
	add al, ONE  ; say which one
	call putc
	mov ah, partition_entry.size  ; size of each partition
	mul ah  ; offset
	add ax, strict word MBRCODE+TABLE-ONE*partition_entry.size  ; point at partition table
	xchg si, ax  ; SI := AX (offset of partition entry); AX := junk.
	mov bl, m_crlf-_start
	call puts

	mov cx, [si+partition_entry.hidden  ]  ; CX := low  word of partition start sector index (LBA).
	mov ax, [si+partition_entry.hidden+2]  ; AX := high word of partition start sector index (LBA).
	; Fall through to read_partition_boot_sector_ebios_lba.

; Here we try to read the partition boot sector using EBIOS LBA first,
; because that is able to read it beyod the first >~7.87 GiB. The CHS (int
; 13 AH==2) method can't do that.
read_partition_boot_sector_ebios_lba:
	pop di  ; Restore DI := HDD sectors-per-track.
	pop bp  ; Restore BP := HDD head count.
	pop dx  ; Restore DL := BIOS drive number; DH := junk.
	push si  ; Save.
	mov si, BOOTCODE
	push si  ; Save BOOTCODE.
	xor bx, bx
	;mov ds, bx  ; DS == 0 is already correct.
	times 2 push bx  ; High dword of partition start sector index (LBA).
	push ax  ; High word of partition start sector index (LBA).
	push cx  ; Low  word of partition start sector index (LBA).
	push es  ; CS == DS == ES == SS == BX == 0.
	push si
	inc bx
	push bx  ; Number of sectors to read == 1.
	mov bl, 0x10
	push bx  ; Size of Disk Address Packet (DAP) == 0x10.
	mov si, sp
	push ax  ; Save high word of partition start sector index (LBA).
	mov ah, 0x42  ; Extended read sectors from drive.
	int 0x13  ; BIOS disk syscall to read a sector (0x200 bytes) to 0x7c00:0. It will keep the data unchanged on read error.
	pop ax  ; Restore AX := high word of partition start sector index (LBA).
	lea sp, [si+bx]  ; BX == size of Disk Address Packet (DAP) == 0x10. It doesn't change the FLAGS, needed by `jnc' below.
	pop bx  ; BX := BOOTCODE.
	pop si  ; Restore. DS:SI will be used by the boot sector boot code.
	jnc short jump_to_partition_boot_sector  ; Jump iff sector successfully read using EBIOS LBA.
	; Fall back to CHS (int 13h AH==2).
	push dx  ; Save DL == BIOS drive number.
	; Fall through to convert_lba_to_chs.

; Converts sector offset (LBA) value in AX:CX to BIOS-style CHS value in CX
; and DL (instead of DH). Expects DI == HDD sectors-per-track; BP == HDD
; head count. Ruins DH, AX and FLAGS.
convert_lba_to_chs:
	xor dx, dx
	div di  ; DI == HDD sectors-per-track. We expect it to be in 1..63.
	xchg cx, ax
	div di   ; DI == HDD sectors-per-track. We expect it to be in 1..63.
	inc dx  ; Like `inc dl`, but 1 byte shorter. Sector numbers start with 1.
	xchg cx, dx  ; CX := sec value (1..63); CL := sec value (1..63); CH := 0; DX := high word of dividend.
	div bp  ; BP == HDD head count. We expect it to be 1..256 (never 256 in most BIOSes). AX := cyl value (BIOS allows 0..1023); DX := head value (0..255); DL := head value (0..255); DH := 0; Sets the high 6 bits of AH (and AX) to 0.
	; BIOS int 13h AH == 2 wants the head value in DH, the low 8
	; bits of the cyl value in CH, and it wants CL ==
	; (cyl>>8<<6)|head. Thus we copy DL to DH (cyl value), AL to
	; CH (low 8 bits of the cyl value), AH to CL (sec value),
	; and or the 2 bits of AH (high 8 bits of the cyl value)
	; shifted to CL.
	mov ch, al
	times 2 ror ah, 1  ; This works because the high 6 bits of AH were 0.
	or cl, ah
	; Fall through to read_partition_boot_sector_chs.

read_partition_boot_sector_chs:
	pop ax  ; Restore AL := BIOS drive number; AH := junk.
	mov ah, dl  ; AH := head value.
	xchg dx, ax  ; DH := head value; DL := BIOS drive number; AH := 2 (read sectors; AL := 1 (read 1 sector).
	mov ax, 0x201  ; AH := 2 (read sectors); AL := 1 (read 1 sector).
	;mov bx, BOOTCODE  ; BX is already BOOTCODE, set by `pop bx' in read_partition_boot_sector_ebios_lba above.
	;mov di, 0
	;mov es, di  ; ES := 0. Not needed, it's already set. We make ES:BX == 0:BOOTCODE point to the read destination buffer.
	int 0x13  ; BIOS disk syscall to read a sector (0x200 bytes) to 0x7c00:0. It will keep the data unchanged on read error.
	; Fall through to jump_to_partition_boot_sector.

jump_to_partition_boot_sector:
	pop es  ; Restore ES saved for plug-and-play (PnP) BIOS.
	pop di  ; Restore DI saved for plug-and-play (PnP) BIOS.
	pop dx  ; Restore DH saved for plug-and-play (PnP) BIOS and DL (BIOS drive number). DL is already correct, the restore keeps it unchanged.`
	jmp short _start+BOOTCODE-MBRCODE  ; Jump to 0:BOOTCODE. On disk read error, the MBR code (us) is run again.
	;jmp bx  ; Jump to 0:BOOTCODE. On disk read error, the MBR code (us) is run again.

	times MAGIC-($-$$) db '-'
magic:
	dw 0  ; Indicate valid partition table. https://github.com/pts/pts-pc-rescuekit kernels check it.

; __END__
