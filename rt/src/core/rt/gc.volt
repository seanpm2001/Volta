// Copyright © 2016, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module core.rt.gc;

static import __volta;


alias AllocDg = __volta.AllocDg;
alias allocDg = __volta.allocDg;

struct Stats
{
	ulong count;
}

extern(C):

void vrt_gc_init();
AllocDg vrt_gc_get_alloc_dg();
void vrt_gc_shutdown();
Stats* vrt_gc_get_stats(out Stats stats);
