#!/usr/bin/env rdmd

/** Sampe application that uses fcgid. */
import nfnitloop.fcgid.provider;

void main()
{
	import std.stdio;
	auto f = new FastCGI();
	f.run(&handleRequest);	
}

void handleRequest(Request request)
{
	request.write("Content-Type: text/plain\r\n");
	request.write("\r\n");
	request.write("Here's a simple (F)CGI response!");
}