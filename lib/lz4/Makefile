ccflags-y += -O3 \
    -DLZ4_FREESTANDING=1 \
    -DLZ4_FAST_DEC_LOOP=1

# LZ4 1.10.0 uses some C99-style declarations; the tree is built with
# -std=gnu89 and CONFIG_CC_WERROR=y, so both warnings have to be relaxed
# here or every block that declares after a statement fails the build.
CFLAGS_lz4.o := -Wno-declaration-after-statement
CFLAGS_lz4hc.o := -Wno-declaration-after-statement

obj-y += lz4.o lz4hc.o

obj-$(CONFIG_ARM64) += $(addprefix lz4armv8/, lz4accel.o lz4armv8.o)
