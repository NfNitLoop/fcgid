#!/usr/bin/env rdmd

/** Sampe application that uses fcgid. */
import nfnitloop.fcgid.provider;

void main()
{
	auto f = new FastCGI();
	f.run(&handleRequest);	
}

void handleRequest(Request request)
{
	maybeSleep(request);
	request.write("Content-Type: text/html\r\n");
	request.write("\r\n");
	request.write("
<html>
<head>
<title>Test Page</title>
</head>
<body>
");

	request.write("<p>This is request #%s.</p>".format(getCount()));

	foreach (k, v; request.queryParams)
	{
		request.write("\n<br>Query param: %s = %s".format(k,v));
	}
	foreach (k, v; request.fcgiParams)
	{
		request.write("\n<br>%s = %s".format(k,v));
	}
	request.write("
</body>
</html>
");
}



// Example: Use message passing to access application state:

import std.concurrency;

void counter()
{
	uint count = 0;
	void handleRequests(Tid requester) { requester.send(++count); }
	while (true) { receive(&handleRequests); }
}

immutable string countThread = "counter";
shared static this()
{
	auto tid = spawn(&counter); 
	import std.exception: enforce;
	enforce(register(countThread, tid), "Error registering counter thread.");
}


uint getCount()
{
	uint count;
	locate(countThread).send(thisTid);
	receive((uint x) { count = x; });
	return count;
}

// Simulate a slow query.
void maybeSleep(Request req)
{
	import std.conv;
	import core.thread;
	try 
	{ 
		int sleep = req.queryParams.get("sleep", "").to!int;
		Thread.sleep(dur!"seconds"(sleep));
	}
	catch (ConvException) { /* That wasn't an int. */ }
}

