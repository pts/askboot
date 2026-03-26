# askboot: interactive, single-sector PC BIOS HDD MBR bootloader (boot partition picker)

A typical HDD MBR bootloader picks the first primary partition marked
active, loads its boot sector (first 0x200 bytes of the partition) to
0:0x7c00, and jumps to it (in real mode). askboot displays details of all
4 primary partitions, and lets the user pick one to boot by pressing a key
(<1> to <4>). If the user presses <Enter> instead, or a timeout of ~15
seconds elapses, askboot boots the first primary partition marked as
active, or the first partition if none are active.

Additional features of askboot: it uses EBIOS LBA (if available), so it
can boot from a partition starting after the the first ~7.87 GiB of the
HDD; it ignores the CHS values (which are less reliable, especially if the
HDD image is moved between emulators or the PC BIOS settings are changed)
in the partition table entry, and it always uses the partition start
sector index (LBA), even if EBIOS LBA is not available.

askboot can boot on an IBM PC (or compatible) with a 8086 or newer CPU and
BIOS boot. So it runs on most PCs before 2010. Newer PCs tend to use UEFI
boot instead, some of them still retaining BIOS boot as a configuration
option, sometimes called as *legacy BIOS* boot.

The askboot implementation [askboot.nasm] is based on WiniBoot by C. E.
Chew, part of the Minix bootloader ShoeLace 1.0a, released on 1990-04-24.

See also
https://en.wikipedia.org/wiki/Master_boot_record#MBR_to_VBR_interface for
how this MBR code transfers control to the boot sector boot code (Volume
Boot Record, VBR).

To compile askboot, run: `nasm -O0 -w+orphan-labels -f bin -o askboot.bin
askboot.nasm`. Minimum NASM version required: 0.98.39. askboot can be
configured at compile time e.g. with the command-line flage
`-DTIMEOUT_SEC=3`. See more configuration details in [askboot.nasm].

To install the compiled *askboot.bin* to a HDD image file hd.img (which
already contains a valid partition table) on Linux, run `dd if=askboot.bin
of=hd.img conv=notrunc`.
