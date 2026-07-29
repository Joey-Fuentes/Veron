/* An array whose ELEMENT is `char*`. CLOSED -- it was a name comparison.
 *
 * `char* a[2]; a[1]=x; p=a[1]; p[0]` segfaults. The identical program with
 * `long*` in place of `char*` passes, and that is the whole diagnosis: the
 * element load takes its width from the POINTED-AT type rather than from the
 * element type, so it reads one byte of an eight-byte pointer.
 *
 * MICRO-C.md already names this blind spot and says case 31 closed it:
 * "Every array-of-pointers probe used `long*`, where the element width and the
 * pointed-at width are both 8 -- so no case could detect a wrong choice
 * between them." Case 31 made the two numbers differ by six for a STRUCT
 * element. It did not for a pointer-to-char element, and the suite has been
 * green over this for every round since.
 *
 * NINE ROWS of stage 2's conformance corpus fail on it -- 394, 396, 397, 398,
 * 400, 401, 402, 403, 404 -- which is what a corpus written by someone not
 * looking for this compiler's bugs is for. */
int main(void)
{
	char* a[2];
	char x[2];
	char y[2];
	char* p;
	char* q;

	x[0] = 1;
	y[0] = 41;
	a[0] = x;
	a[1] = y;
	p = a[0];
	q = a[1];
	if(p[0] + q[0] != 42) return 1;
	return 0;
}
