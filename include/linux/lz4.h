/* SPDX-License-Identifier: BSD-2-Clause */
/* LZ4 1.10.0 compatibility wrapper for the Linux kernel tree. */
#ifndef __LINUX_LZ4_H__
#define __LINUX_LZ4_H__

/*
 * LZ4_DISTANCE_MAX, LZ4_DECOMPRESS_INPLACE_MARGIN and friends live inside
 * the LZ4_STATIC_LINKING_ONLY section of the upstream header, and the
 * deprecated decompression entry points have to stay silent because the
 * kernel is built with CONFIG_CC_WERROR=y.  Both switches have to be set
 * before lz4.h is pulled in.
 */
#define LZ4_STATIC_LINKING_ONLY
#define LZ4_DISABLE_DEPRECATE_WARNINGS

#include "../../lib/lz4/lz4.h"
#include "../../lib/lz4/lz4hc.h"

/* Names the rest of the kernel still uses from the pre-1.10 header. */
#define LZ4_MEM_COMPRESS LZ4_STREAM_MINSIZE
#define LZ4HC_MEM_COMPRESS LZ4_STREAMHC_MINSIZE
#define LZ4HC_MIN_CLEVEL LZ4HC_CLEVEL_MIN
#define LZ4HC_DEFAULT_CLEVEL LZ4HC_CLEVEL_DEFAULT
#define LZ4HC_MAX_CLEVEL LZ4HC_CLEVEL_MAX

#endif /* __LINUX_LZ4_H__ */
