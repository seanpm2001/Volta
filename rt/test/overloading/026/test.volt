//T macro:expect-failure
//T check:2 overloaded functions match call
module test;

fn foo(a: i32, b: i32 = 2) i32
{
	return a + b;
}

fn foo(a: i32) i32
{
	return a;
}

fn main() i32
{
	return foo(12);
}
