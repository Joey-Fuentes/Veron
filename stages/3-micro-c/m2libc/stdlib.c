/* Copyright (C) 2016 Jeremiah Orians
 * This file is part of M2-Planet.
 *
 * M2-Planet is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * M2-Planet is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with M2-Planet.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <ctype.h>

#define EXIT_FAILURE 1
#define EXIT_SUCCESS 0

#define _IN_USE 1
#define _NOT_IN_USE 0

typedef char wchar_t;

void exit(int value);

struct _malloc_node
{
	struct _malloc_node *next;
	void* block;
	size_t size;
	int used;
};

struct _malloc_node* _allocated_list;
/* HOW MANY NODES HAVE EVER BEEN CREATED. A node is created exactly once, in
 * _malloc_add_new, and after that it only MOVES between the two lists -- so
 * reachable(_allocated_list) + reachable(_free_list) must always equal this.
 * When it does not, a `next` in one of the chains has been clobbered and every
 * node past it is invisible while its block stays live. That is the failure
 * behind "realloc: pointer was never returned by malloc", and this is the
 * cheapest thing that can catch it AT THE MOMENT IT HAPPENS rather than
 * whenever some later caller trips over a lost block. */
long _malloc_nodes_created;
/* OFF BY DEFAULT. The per-call walk is O(n^2) over a run and it changes the
 * TIMING AND THE HEAP of the program under test -- a "regression" was measured
 * against a tree still carrying it before that was noticed. Set this to 1 by
 * hand to arm the detector. The failure-path diagnostics below cost nothing
 * and stay on. */
long _malloc_check_armed;
void _malloc_check_lists(char* where);
void _malloc_write_num(char* label, long v);
struct _malloc_node* _free_list;

/********************************
 * The core POSIX malloc        *
 ********************************/
long _malloc_ptr;
long _brk_ptr;
void* _malloc_brk(unsigned size)
{
	if(NULL == _brk_ptr)
	{
		_brk_ptr = brk(0);
		_malloc_ptr = _brk_ptr;
	}

	if(_brk_ptr < _malloc_ptr + size)
	{
		long old_brk = _brk_ptr;
		_brk_ptr = brk(_malloc_ptr + size);
		if(-1 == _brk_ptr) return 0;
		if(_brk_ptr == old_brk) return 0;
		if(_brk_ptr < _malloc_ptr + size) return 0;
	}

	long old_malloc = _malloc_ptr;
	_malloc_ptr = _malloc_ptr + size;
	return old_malloc;
}

void __init_malloc()
{
	_free_list = NULL;
	_allocated_list = NULL;
	return;
}

/************************************************************************
 * Handle with the tricky insert behaviors for our nodes                *
 * As free lists must be sorted from smallest to biggest to enable      *
 * cheap first fit logic                                                *
 * The free function however is rarely called, so it can kick sand and  *
 * do things the hard way                                               *
 ************************************************************************/
/* SAY WHICH BAIL-OUT IT WAS, AND WITH WHAT.
 *
 * The allocator had three exit(EXIT_FAILURE) calls and not one of them printed
 * anything. A program that trips one dies with status 1 and NO output, which
 * is indistinguishable from a clean `return 1` -- and one of them had been
 * ending every run of the stage-3 tcc spike. It took a syscall trace to see
 * that the exit was even coming from here, and the comment above the free()
 * one already says a previous round lost time to exactly that:
 *
 *     "so the program dies with status 1 and NO message, which is a hard thing
 *      to trace back here"
 *
 * That note was written when free(NULL) was fixed and the silence was left in
 * place. This is the same argument M2libc patch 0002 makes for malloc: a
 * refusal that does not say what it refused cannot be told from exhaustion.
 *
 * write() and a local formatter, not fputs and int2str: in M2libc's own build
 * order stdlib.c is compiled BEFORE stdio.c and bootstrappable.c, so neither
 * of those exists yet. */
void _malloc_die(char* why, long value)
{
	char digits[24];
	int j;
	long x;
	int n;

	n = 0;
	while(why[n] != 0) n = n + 1;
	write(2, "M2libc: ", 8);
	write(2, why, n);
	write(2, " (", 2);

	x = value;
	if(x < 0)
	{
		write(2, "-", 1);
		x = 0 - x;
	}
	if(0 == x) write(2, "0", 1);
	else
	{
		j = 0;
		while(x != 0)
		{
			digits[j] = 48 + (x % 10);
			j = j + 1;
			x = x / 10;
		}
		while(j != 0)
		{
			j = j - 1;
			write(2, digits + j, 1);
		}
	}
	write(2, ")\n", 2);
	exit(EXIT_FAILURE);
}

void _malloc_insert_block(struct _malloc_node* n, int used)
{
	/* Allocated block doesn't care about order */
	if(_IN_USE == used)
	{
		/* Literally just be done as fast as possible */
		n->next = _allocated_list;
		_allocated_list = n;
		return;
	}

	/* sanity check garbage */
	if(_NOT_IN_USE != used) _malloc_die("_malloc_insert_block: used flag is not _NOT_IN_USE", used);
	if(_NOT_IN_USE != n->used) _malloc_die("_malloc_insert_block: node used flag is not _NOT_IN_USE", n->used);
	if(NULL != n->next) _malloc_die("_malloc_insert_block: node already has a next", (long)n->next);

	/* Free block really does care about order */
	struct _malloc_node* i = _free_list;
	struct _malloc_node* last = NULL;
	while(NULL != i)
	{
		/* sort smallest to largest */
		if(n->size <= i->size)
		{
			/* Connect */
			n->next = i;
			/* If smallest yet */
			if(NULL == last) _free_list = n;
			/* or just another average block */
			else last->next = n;
			return;
		}

		/* iterate */
		last = i;
		i = i->next;
	}

	/* looks like we are the only one */
	if(NULL == last) _free_list = n;
	/* or we are the biggest yet */
	else last->next = n;
}

/************************************************************************
 * We only mark a block as unused, we don't actually deallocate it here *
 * But rather shove it into our _free_list                              *
 ************************************************************************/
void free(void* ptr)
{
	_malloc_check_lists("free    ");
/* just in case someone needs to quickly turn it off */
#ifndef _MALLOC_DISABLE_FREE
	/* free(NULL) IS A NO-OP. C requires it, and real code relies on it:
	 *
	 *     static void tcc_set_str(char **pp, const char *str)
	 *     { tcc_free(*pp); *pp = str ? tcc_strdup(str) : NULL; }
	 *
	 * *pp is NULL the first time, straight out of a calloc'd struct. Without
	 * this, the search below finds no matching block and falls through to the
	 * exit(EXIT_FAILURE) at the end of the function -- so the program dies
	 * with status 1 and NO message, which is a hard thing to trace back here.
	 */
	if(NULL == ptr) return;

	struct _malloc_node* i = _allocated_list;
	struct _malloc_node* last = NULL;

	/* walk the whole freaking list if needed to do so */
	while(NULL != i)
	{
		/* did we find it? */
		if(i->block == ptr)
		{
			/* detach the block */
			if(NULL == last) _allocated_list = i->next;
			/* in a way that doesn't break the allocated list */
			else last->next = i->next;

			/* insert into free'd list */
			i->used = _NOT_IN_USE;
			i->next = NULL;
			_malloc_insert_block(i, _NOT_IN_USE);
			return;
		}

		/* iterate */
		last = i;
		i = i->next;
	}

	/* we received a pointer to a block that wasn't allocated */
	_malloc_die("free: pointer was never returned by malloc", (long)ptr);
#endif
	/* if free is disabled, there is nothing to do */
	return;
}

/************************************************************************
 * find if there is any "FREED" blocks big enough to sit on our memory  *
 * budget's face and ruin its life. Respectfully of course              *
 ************************************************************************/
void* _malloc_find_free(unsigned size)
{
	struct _malloc_node* i = _free_list;
	struct _malloc_node* last = NULL;
	/* Walk the whole list if need be */
	while(NULL != i)
	{
		/* see if anything in it is equal or bigger than what I need */
		if((_NOT_IN_USE == i->used) && (i->size >= size))
		{
			/* disconnect from list ensuring we don't break free doing so */
			if(NULL == last) _free_list = i->next;
			else last->next = i->next;

			/* insert into allocated list */
			i->used = _IN_USE;
			i->next = NULL;
			_malloc_insert_block(i, _IN_USE);
			return i->block;
		}

		/* iterate (will loop forever if you get this wrong) */
		last = i;
		i = i->next;
	}

	/* Couldn't find anything big enough */
	return NULL;
}

/************************************************************************
 * Well we couldn't find any memory good enough to satisfy our needs so *
 * we are going to have to go beg for some memory on the street corner  *
 ************************************************************************/
void* _malloc_add_new(unsigned size)
{
	struct _malloc_node* n;
#ifdef __uefi__
	n = _malloc_uefi(sizeof(struct _malloc_node));
	/* Check if we were beaten */
	if(NULL == n) return NULL;
	n->block = _malloc_uefi(size);
#else
	n = _malloc_brk(sizeof(struct _malloc_node));
	/* Check if we were beaten */
	if(NULL == n) return NULL;
	n->block = _malloc_brk(size);
#endif
	/* check if we were robbed */
	if(NULL == n->block) return NULL;

	/* Looks like we made it home safely */
	_malloc_nodes_created = _malloc_nodes_created + 1;
	n->size = size;
	n->next = NULL;
	n->used = _IN_USE;
	/* lets pop the cork and party */
	_malloc_insert_block(n, _IN_USE);
	return n->block;
}

/************************************************************************
 * Safely iterates over all malloc nodes and frees them                 *
 ************************************************************************/
void __malloc_node_iter(struct _malloc_node* node, FUNCTION _free)
{
	struct _malloc_node* current;
	while(node != NULL)
	{
		current = node;
		node = node->next;
		_free(current->block);
		_free(current);
	}
}

/************************************************************************
 * Runs a callback with all previously allocated nodes.                 *
 * This can be useful if operating system does not do any clean up.     *
 ************************************************************************/
void* _malloc_release_all(FUNCTION _free)
{
	__malloc_node_iter(_allocated_list, _free);
	__malloc_node_iter(_free_list, _free);
}

/************************************************************************
 * Provide a POSIX standardish malloc function to keep things working   *
 ************************************************************************/
void* malloc(unsigned size)
{
	_malloc_check_lists("malloc  ");
	/* skip allocating nothing */
	if(0 == size) return NULL;

	/* use one of the standard block sizes */
	size_t max = 1 << 30;
	size_t used = 256;
	while(used < size)
	{
		used = used << 1;

		/* fail big allocations */
		if(used > max)
		{
			/* SAY WHAT WAS ASKED FOR. A caller that gets NULL back reports
			 * "memory full", which cannot distinguish genuine exhaustion from
			 * ONE absurd request -- and those need opposite fixes: a bigger heap,
			 * or a bug in whatever computed the size.
			 *
			 * It matters here because micro-c makes `int` eight bytes, so a size
			 * derived from a sizeof or a shift can come out enormous with nothing
			 * looking wrong at the call site.
			 *
			 * WRITTEN WITH write() AND A LOCAL FORMATTER, not fputs and int2str:
			 * in M2libc's own build order stdlib.c is compiled BEFORE stdio.c and
			 * bootstrappable.c, so neither of those exists yet. */
			char digits[24];
			int at = 24;
			size_t left = size;
			write(2, "malloc: refusing ", 17);
			if(0 == left)
			{
				at = at - 1;
				digits[at] = '0';
			}
			while(0 != left)
			{
				at = at - 1;
				digits[at] = '0' + (left % 10);
				left = left / 10;
			}
			write(2, digits + at, 24 - at);
			write(2, " bytes\n", 7);
			return NULL;
		}
	}

	/* try the cabinets around the house */
	void* ptr = _malloc_find_free(used);

	/* looks like we need to get some more from the street corner */
	if(NULL == ptr)
	{
		ptr = _malloc_add_new(used);
	}

	/* hopefully you can handle NULL pointers, good luck */
	return ptr;
}

/* A LABELLED NUMBER, straight to fd 2. stdlib.c is compiled BEFORE stdio.c and
 * bootstrappable.c in M2libc's own build order, so fputs and int2str do not
 * exist yet -- the same constraint the big-allocation reporter works under. */
void _malloc_write_num(char* label, long v)
{
	char digits[24];
	int at = 24;
	int neg = 0;
	unsigned long u;
	int i = 0;
	while(0 != label[i]) i = i + 1;
	write(2, label, i);
	if(v < 0) { neg = 1; u = -v; } else u = v;
	if(0 == u) { at = at - 1; digits[at] = 48; }
	while(0 != u) { at = at - 1; digits[at] = 48 + (u % 10); u = u / 10; }
	if(neg) { at = at - 1; digits[at] = 45; }
	write(2, digits + at, 24 - at);
	write(2, "\n", 1);
}

/* WALK BOTH LISTS AND COMPARE. Bounded, so a chain clobbered into a CYCLE
 * reports rather than hangs -- an infinite loop here would look like the
 * compiler wedging, which is the least informative failure available. */
void _malloc_check_lists(char* where)
{
	if(0 == _malloc_check_armed) return;

	long seen = 0;
	long guard = 0;
	struct _malloc_node* i = _allocated_list;
	while(NULL != i)
	{
		seen = seen + 1;
		guard = guard + 1;
		if(guard > 100000)
		{
			write(2, "MALLOC CHECK: allocated list is a CYCLE at ", 42);
			write(2, where, 8);
			write(2, "\n", 1);
			exit(9);
		}
		i = i->next;
	}
	i = _free_list;
	while(NULL != i)
	{
		seen = seen + 1;
		guard = guard + 1;
		if(guard > 100000)
		{
			write(2, "MALLOC CHECK: free list is a CYCLE at ", 37);
			write(2, where, 8);
			write(2, "\n", 1);
			exit(9);
		}
		i = i->next;
	}

	if(seen != _malloc_nodes_created)
	{
		/* WHICH NODE ENDS THE CHAIN. The last node the walk reaches is the one
		 * whose `next` was clobbered, and its block is the memory the wild
		 * store was aimed near. Print the node, its block, and the words
		 * around the break so the shape of the write is visible. */
		struct _malloc_node* lastok = NULL;
		struct _malloc_node* w = _allocated_list;
		long depth = 0;
		while(NULL != w) { lastok = w; depth = depth + 1; w = w->next; }
		write(2, "MALLOC CHECK: NODES LOST at ", 28);
		write(2, where, 8);
		write(2, "\n", 1);
		_malloc_write_num("  nodes created   = ", _malloc_nodes_created);
		_malloc_write_num("  nodes reachable = ", seen);
		_malloc_write_num("  lost            = ", _malloc_nodes_created - seen);
		_malloc_write_num("  allocated depth  = ", depth);
		if(NULL != lastok)
		{
			_malloc_write_num("  last node addr   = ", (long)lastok);
			_malloc_write_num("  its block        = ", (long)lastok->block);
			_malloc_write_num("  its size         = ", (long)lastok->size);
			_malloc_write_num("  its used         = ", (long)lastok->used);
			_malloc_write_num("  its next (BAD)   = ", (long)lastok->next);
			/* the first words of its block: what tcc put there names the user */
			long* bw = lastok->block;
			_malloc_write_num("  block word[0]    = ", bw[0]);
			_malloc_write_num("  block word[1]    = ", bw[1]);
			_malloc_write_num("  block word[2]    = ", bw[2]);
			/* WHO OWNS THE MEMORY THAT ENDS WHERE THE BROKEN next LIVES.
			 * lastok->next sits at (char*)lastok + 0, which is 32 bytes
			 * before its block -- exactly where the PREVIOUS allocation's
			 * data ends. An overrun of that block writes here. */
			struct _malloc_node* pv = _allocated_list;
			long found = 0;
			while(NULL != pv)
			{
				if((((char*)pv->block) + pv->size) == ((char*)lastok))
				{
					found = 1;
					_malloc_write_num("  OVERRUN SOURCE blk= ", (long)pv->block);
					_malloc_write_num("   its size         = ", (long)pv->size);
					long* ow = pv->block;
					_malloc_write_num("   word[0]          = ", ow[0]);
					_malloc_write_num("   word[1]          = ", ow[1]);
					long* tail = pv->block;
					tail = tail + ((pv->size / 8) - 2);
					_malloc_write_num("   tail[-2]         = ", tail[0]);
					_malloc_write_num("   tail[-1]         = ", tail[1]);
				}
				pv = pv->next;
			}
			if(0 == found) write(2, "  no live block ends there\n", 27);
		}
		exit(9);
	}
}

void* realloc(void* ptr, unsigned size)
{
	if(0 == size)
	{
		if(NULL != ptr) free(ptr);
		return NULL;
	}

	/* IF THE BLOCK WE ALREADY HAVE IS BIG ENOUGH, KEEP IT.
	 *
	 * Every allocation here is rounded up to a power of two at or above
	 * 256, so the block behind `ptr` is usually much larger than what was
	 * asked for and a growth within that headroom needs no move at all.
	 *
	 * BEFORE malloc(), NOT AFTER. Checking later would allocate the
	 * replacement block first and then leak it on every in-place realloc,
	 * which on tcc's doubling growth is most of them.
	 *
	 * `want` IS A size_t AND THAT IS NOT DECORATION. `size` is the
	 * `unsigned` parameter -- four bytes -- and `have->size` is a size_t.
	 * Comparing them directly is a mixed-width comparison, and this
	 * compiler has a documented history of getting exactly those wrong:
	 * EXPERIMENT-zzzc (a cast to a narrower integer truncates),
	 * EXPERIMENT-zzza (a global scalar loads at its own width) and
	 * EXPERIMENT-zzzw (int is four bytes) are all that class. If the
	 * comparison came out backwards the block would be handed back TOO
	 * SMALL and the caller would write past its end into the next node's
	 * `next` field -- which is the exact corruption shape patch 0011
	 * measured. One assignment removes the risk entirely.
	 */
	if(NULL != ptr)
	{
		size_t want = size;
		struct _malloc_node* have = _allocated_list;
		while(NULL != have)
		{
			if(have->block == ptr)
			{
				if(have->size >= want) return ptr;
				break;
			}

			have = have->next;
		}
	}

	void* new_alloc = malloc(size);

	if(ptr == NULL || new_alloc == NULL)
	{
		/* If ptr is NULL we act like normal malloc.
		 * If allocation failed return that NULL immediately. */
		return new_alloc;
	}

	size_t old_alloc_size = 0;
	size_t copy_size;
	struct _malloc_node* i = _allocated_list;
	while(NULL != i)
	{
		if(i->block == ptr)
		{
			old_alloc_size = i->size;
			break;
		}

		i = i->next;
	}

	if(old_alloc_size == 0)
	{
		/* WHICH KIND OF WRONG POINTER. "never returned by malloc" cannot
		 * distinguish a block that was FREED earlier -- a use-after-free,
		 * whose node is sitting on _free_list -- from an address that was
		 * never a block start at all, which is a corrupted or interior
		 * pointer. Those are opposite investigations, so ask before dying. */
		struct _malloc_node* f = _free_list;
		while(NULL != f)
		{
			if(f->block == ptr)
			{
				_malloc_die("realloc: USE AFTER FREE -- this block is on the free list", (long)ptr);
			}
			f = f->next;
		}
		/* Not a block start in either list. Is it INSIDE one? */
		struct _malloc_node* g = _allocated_list;
		while(NULL != g)
		{
			if((ptr > g->block) && (ptr < (void*)(((char*)g->block) + g->size)))
			{
				_malloc_die("realloc: INTERIOR pointer, offset into a live block", (long)(((char*)ptr) - ((char*)g->block)));
			}
			g = g->next;
		}
		/* HOW FAR FROM A REAL BLOCK. A pointer sitting a fixed small
		 * distance ABOVE a block start is a header skip -- tcc's own
		 * tal_realloc_impl computes `((tal_header_t *)p) - 1`, so the
		 * inverse shows up as a constant offset. A large distance means the
		 * address is not related to any block and was computed wrongly. */
		long best = 0x7FFFFFFF;
		struct _malloc_node* h = _allocated_list;
		while(NULL != h)
		{
			long d = ((char*)ptr) - ((char*)h->block);
			if(d < 0) d = -d;
			if(d < best) best = d;
			h = h->next;
		}
		struct _malloc_node* k = _free_list;
		while(NULL != k)
		{
			long d = ((char*)ptr) - ((char*)k->block);
			if(d < 0) d = -d;
			if(d < best) best = d;
			k = k->next;
		}
		/* WHICH SIDE, AND HOW FAR. A distance alone cannot tell "one
		 * allocation stride too far" from "unrelated address". The stride
		 * here is sizeof(struct _malloc_node) + the 256-byte minimum block,
		 * so a pointer exactly one stride ABOVE a real block is a computed
		 * address that ran off the end of the list, and one BELOW is a
		 * header the caller skipped. */
		long signed_best = 0;
		long nblocks = 0;
		long abs_best = 0x7FFFFFFF;
		struct _malloc_node* q = _allocated_list;
		while(NULL != q)
		{
			long d = ((char*)ptr) - ((char*)q->block);
			long ad = d;
			if(ad < 0) ad = -ad;
			if(ad < abs_best) { abs_best = ad; signed_best = d; }
			nblocks = nblocks + 1;
			q = q->next;
		}
		_malloc_write_num("realloc: bad ptr        = ", (long)ptr);
		_malloc_write_num("realloc: nearest block  = ", (long)ptr - signed_best);
		_malloc_write_num("realloc: ptr - nearest  = ", signed_best);
		_malloc_write_num("realloc: live blocks    = ", nblocks);
		/* IS ptr PAST THE END OF THE NEAREST BLOCK? An overrun and a stale
		 * pointer look identical as a distance and need opposite fixes. */
		long nsize = 0;
		struct _malloc_node* z = _allocated_list;
		while(NULL != z)
		{
			if(((char*)z->block) == (((char*)ptr) - signed_best)) nsize = z->size;
			z = z->next;
		}
		_malloc_write_num("realloc: nearest size   = ", nsize);
		_malloc_write_num("realloc: past its end by= ", signed_best - nsize);
		_malloc_write_num("realloc: requested size = ", (long)size);
		/* THE WHOLE LIST. If the address is a plausible block boundary but no
		 * node claims it, the question is whether the LIST is missing an
		 * entry -- and only the list itself can answer that. */
		/* WHAT IS ACTUALLY THERE. The earlier table_ident hunt identified an
		 * object by reading its first words -- token numbers meant a token
		 * string, not a Sym. Same question here: an address that is not a
		 * block still points at SOMETHING, and what it points at names who
		 * computed it. */
		long* pw = ptr;
		_malloc_write_num("realloc: word[0] at ptr = ", pw[0]);
		_malloc_write_num("realloc: word[1] at ptr = ", pw[1]);
		_malloc_write_num("realloc: word[2] at ptr = ", pw[2]);
		/* and the four words BELOW it -- a node header is next/block/size/used */
		long* pb = ptr;
		pb = pb - 4;
		_malloc_write_num("realloc: ptr[-4] (next?)= ", pb[0]);
		_malloc_write_num("realloc: ptr[-3] (blk?) = ", pb[1]);
		_malloc_write_num("realloc: ptr[-2] (size?)= ", pb[2]);
		_malloc_write_num("realloc: ptr[-1] (used?)= ", pb[3]);
		write(2, "realloc: --- allocated ---\n", 27);
		struct _malloc_node* w = _allocated_list;
		while(NULL != w)
		{
			_malloc_write_num("  block = ", (long)w->block);
			_malloc_write_num("   size = ", (long)w->size);
			w = w->next;
		}
		write(2, "realloc: --- free ---\n", 22);
		struct _malloc_node* y = _free_list;
		while(NULL != y)
		{
			_malloc_write_num("  block = ", (long)y->block);
			_malloc_write_num("   size = ", (long)y->size);
			y = y->next;
		}
		_malloc_die("realloc: pointer is not a block", best);
	}

	copy_size = old_alloc_size;
	if(size < copy_size) copy_size = size;
	/* memcpy(new_alloc, ptr, copy_size); */
	int i;
	char* new_alloc_char = (char*)new_alloc;
	char* ptr_char = (char*)ptr;
	for (i = 0; i < copy_size; ++i)
	{
		new_alloc_char[i] = ptr_char[i];
	}

	/* Free the old alloc */
	free(ptr);

	return new_alloc;
}

/************************************************************************
 * Provide a POSIX standardish memset function to keep things working   *
 ************************************************************************/
void* memset(void* ptr, int value, int num)
{
	char* s;
	/* basically walk the block 1 byte at a time and set it to any value you want */
	for(s = ptr; 0 < num; num = num - 1)
	{
		s[0] = value;
		s = s + 1;
	}

	return ptr;
}

/************************************************************************
 * Provide a POSIX standardish calloc function to keep things working   *
 ************************************************************************/
void* calloc(int count, int size)
{
	/* if things get allocated, we are good*/
	void* ret = malloc(count * size);
	/* otherwise good luck */
	if(NULL == ret) return NULL;
	memset(ret, 0, (count * size));
	return ret;
}


/* USED EXCLUSIVELY BY MKSTEMP */
void __set_name(char* s, int i)
{
	s[5] = '0' + (i % 10);
	i = i / 10;
	s[4] = '0' + (i % 10);
	i = i / 10;
	s[3] = '0' + (i % 10);
	i = i / 10;
	s[2] = '0' + (i % 10);
	i = i / 10;
	s[1] = '0' + (i % 10);
	i = i / 10;
	s[0] = '0' + i;
}

/************************************************************************
 * Provide a POSIX standardish mkstemp function to keep things working  *
 ************************************************************************/
int mkstemp(char *template)
{
	/* get length of template */
	int i = 0;
	while(0 != template[i]) i = i + 1;
	i = i - 1;

	/* String MUST be more than 6 characters in length */
	if(i < 6) return -1;

	/* Sanity check the string matches the template requirements */
	int count = 6;
	int c;
	while(count > 0)
	{
		c = template[i];
		/* last 6 chars must be X */
		if('X' != c) return -1;
		template[i] = '0';
		i = i - 1;
		count = count - 1;
	}

	int fd = -1;
	count = -1;
	/* open will return -17 or other values */
	while(0 > fd)
	{
		/* Just give up after the planet has blown up */
		if(9000 < count) return -1;

		/* Try up to 9000 unique filenames before stopping */
		count = count + 1;
		__set_name(template+i+1, count);

		/* Pray we can */
		fd = open(template, O_RDWR | O_CREAT | O_EXCL, 00600);
	}

	/* well that only took count many tries */
	return fd;
}

/************************************************************************
 * wcstombs - convert a wide-character string to a multibyte string     *
 * because seriously UEFI??? UTF-16 is a bad design choice but I guess  *
 * they were drinking pretty hard when they designed UEFI; it is DOS    *
 * but somehow they magically found ways of making it worse             *
 ************************************************************************/
size_t wcstombs(char* dest, char* src, size_t n)
{
	int i = 0;

	do
	{
		/* UTF-16 is 2bytes per char and that first byte maps good enough to ASCII */
		dest[i] = src[2 * i];
		if(dest[i] == 0)
		{
			break;
		}
		i = i + 1;
		n = n - 1;
	} while (n != 0);

	return i;
}

/************************************************************************
 * getenv - get an environmental variable                               *
 ************************************************************************/
size_t _strlen(char const* str)
{
	size_t i = 0;
	while(0 != str[i]) i = i + 1;
	return i;
}
int _strncmp(char const* lhs, char const* rhs, size_t count)
{
	size_t i = 0;
	while(count > i)
	{
		if(0 == lhs[i]) break;
		if(lhs[i] != rhs[i]) return lhs[i] - rhs[i];
		i = i + 1;
	}

	return 0;
}
char** _envp;
char* getenv (char const* name)
{
	char** p = _envp;
	char* q;
	int length = _strlen(name);

	while (p[0] != 0)
	{
		if(_strncmp(name, p[0], length) == 0)
		{
			q = p[0] + length;
			if(q[0] == '=')
				return q + 1;
		}
		p += 1;
	}

	return 0;
}

/************************************************************************
 * setenv - set an environmental variable                               *
 ************************************************************************/
char* _strcpy(char* dest, char const* src)
{
	int i = 0;

	while (0 != src[i])
	{
		dest[i] = src[i];
		i = i + 1;
	}
	dest[i] = 0;

	return dest;
}

int setenv(char const *s, char const *v, int overwrite_p)
{
	char** p = _envp;
	int length = _strlen(s);
	int value_length = _strlen(v);
	char* q;

	while (p[0] != 0)
	{
		if (_strncmp (s, p[0], length) == 0)
		{
			q = p[0] + length;
			if (q[0] == '=')
			{
				if(0 == overwrite_p) return 0;
				break;
			}
		}
		p += 1;
	}
	char *entry = malloc (length + value_length + 2);
	if(NULL == entry) return -1;
	int end_p = p[0] == 0;
	p[0] = entry;
	_strcpy(entry, s);
	_strcpy(entry + length, "=");
	_strcpy(entry + length + 1, v);
	entry[length + value_length + 1] = 0;
	if (end_p != 0)
		p[1] = 0;

	return 0;
}

/************************************************************************
 * atoi - Ascii TO Integer                                              *
 ************************************************************************/
int atoi(const char* str)
{
	int value = 0;
	int negative = 0;

	while(isspace(*str))
	{
		str = str + 1;
	}

	switch(*str) {
		case '-': negative = 1;
		/* FALLTHROUGH */
		case '+': str = str + 1;
		/* FALLTHROUGH */
	}

	while(isdigit(*str))
	{
		value = 10 * value - (*str - '0');
		str = str + 1;
	}

	if(negative)
	{
		return value;
	}
	else
	{
		return -value;
	}
}
