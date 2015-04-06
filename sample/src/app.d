#!/usr/bin/env rdmd

/** Sampe application that uses fcgid. */
import nfnitloop.fcgid.application;
import std.string;

void main()
{
	auto f = new FastCGI();
	f.run(&handleRequest);	
}

void handleRequest(Request request)
{
	maybeSleep(request);
	request.writeHeaders([
		"Content-Type": "text/html; charset=utf-8",
		"X-Served-By": "nfnitloop.fcgid.application"
	]);
	auto stdout = request.stdout;
	stdout.write("
<html>
<head>
<title>Test Page</title>
</head>
<body>
");

	stdout.writeln("<p>This is request #%s.</p>".format(getCount()));

	foreach (param, values; request.queryParamsMulti)
	{
		if (values.length == 1) { stdout.writeln("<br>Query param: %s = %s".format(param,values[0])); }
		else { stdout.writeln("<br>Query param: %s = %s".format(param, values)); }
	}

	stdout.write("<pre>");
	foreach (k, v; request.fcgiParams)
	{
		stdout.writeln("%s = %s".format(k.rightJustify(22),v.quote()));
	}
	stdout.writeln("</pre>");
	stdout.write("
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
	bool running = true;
	void shutdown(OwnerTerminated ot) { running = false; }
	while (running) { receive(&handleRequests, &shutdown); }
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

// Hacky. Quote for HTML.
string quote(string s)
{
	import std.array: replace;
	return s.replace("<", "&lt;");
}