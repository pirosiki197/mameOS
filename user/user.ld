ENTRY(start)

SECTIONS {
    . = 0x1000;

    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    }

    . = ALIGN(0x1000);
    .rodata : {
        . = ALIGN(8);
        *(.rodata .rodata.*)
    }

    . = ALIGN(0x1000);
    .data : {
        *(.data)
    }

    .bss : {
        *(.bss)
    }
}
