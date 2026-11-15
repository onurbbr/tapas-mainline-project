// SPDX-License-Identifier: BSD-3-Clause
/*
 * Minimal replacement for ar_osal_log.c so that acdbdump can be built on a
 * host without Android's liblog. Keeps the same three entry points and the
 * same ar_log_lvl global the library expects.
 */
#include "ar_osal_log.h"
#include "ar_osal_types.h"
#include <stdio.h>
#include <stdarg.h>

uint32_t ar_log_lvl = (AR_CRITICAL | AR_ERROR | AR_INFO);

void ar_log_init(void)
{
}

void ar_log(uint32_t level, const char_t *log_tag, const char_t *file,
	    const char_t *func, int32_t line, const char_t *msg, ...)
{
	va_list ap;

	if (!(level & ar_log_lvl))
		return;

	fprintf(stderr, "%s: %s:%d %s: ", log_tag, file, line, func);
	va_start(ap, msg);
	vfprintf(stderr, msg, ap);
	va_end(ap);
	fprintf(stderr, "\n");
}

void ar_log_deinit(void)
{
}
