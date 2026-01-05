SECTIONS {
    . = 0x80200000;
    __kernel_base = .;

    .text :{
        __text_start = .;
        KEEP(*(.text.boot));
        *(.text .text.*);
        __text_end = .;
    }

    .rodata : ALIGN(4096) {
        __rodata_start = .;
        *(.rodata .rodata.*);
        __rodata_end = .;
    }

    .data : ALIGN(4096) {
        __data_start = .;
        *(.data .data.*);
    }

    .bss : ALIGN(4096) {
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
    __free_ram = .;
    . += 32 * 1024 * 1024; /* 32MB */
    __free_ram_end = .;
}
