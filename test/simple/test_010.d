//T compiles:no
//T retval:42
// Ensure that const values can't be assigned to.
module test_010;

int main()
{
    const(int) i;
    i = 42;
    return i;
}
