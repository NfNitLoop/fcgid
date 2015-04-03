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
	request.write("Content-Type: text/html\r\n");
	request.write("\r\n");
	request.write("
<html>
<head>
<title>Test Page</title>
</head>
<body>
");
	foreach (k, v; request.params)
	{
		request.write("<br>%s = %s".format(k,v));
	}
	request.write("
</body>
</html>
");
}