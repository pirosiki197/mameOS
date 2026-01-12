PHYS_LOAD_ADDR = 0x80200000;
KERNEL_OFFSET = 0xFFFFFFFF00000000;
KERNEL_VMA = PHYS_LOAD_ADDR + KERNEL_OFFSET;

SECTIONS {
    . = KERNEL_VMA;

    .text : AT(PHYS_LOAD_ADDR) {
        __kernel_base = .;
        __text_start = .;
        KEEP(*(.text.boot));
        *(.text .text.*);
        __text_end = .;
    }

    .rodata ALIGN(4096) : AT(ADDR(.rodata) - KERNEL_OFFSET) {
        __rodata_start = .;
        *(.rodata .rodata.*);
        __rodata_end = .;
    }

    .data ALIGN(4096) : AT(ADDR(.data) - KERNEL_OFFSET) {
        __data_start = .;
        *(.data .data.*);
    }

    .bss ALIGN(4096) : AT(ADDR(.bss) - KERNEL_OFFSET) {
        __bss = .;
        *(.bss .bss.* .sbss .sbss.*);
        __bss_end = .;
        __data_end = .;
    }

    . = ALIGN(4096);
    __stack_guard = .;
    . += 4096;

    __stack_start = .;
    . += 128 * 1024; /* 128KB */
    __stack_end = .;
    __stack_top = .;

    . = ALIGN(4096);
    __kernel_end = .;

    __free_ram_start = .;
}
