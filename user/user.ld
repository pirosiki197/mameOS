ENTRY(start)

SECTIONS {
    . = 0x1000;

    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    }

    .rodata : {
        . = ALIGN(8);
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data)
    }

    .bss : {
        *(.bss)
    }
}
