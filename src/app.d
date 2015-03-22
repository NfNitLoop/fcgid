#!/usr/bin/env rdmd

/** Sampe application that uses fcgid. */
import nfnitloop.fcgid.provider;

void main()
{
	import std.stdio;
	auto f = new FastCGI();
	f.run();	
}
