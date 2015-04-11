module nfnitloop.fcgid.application;

import nfnitloop.fcgid.impl.types;
import nfnitloop.fcgid.impl;
import std.socket;
import std.string: format;
import std.conv;


/** 
 * Implements the web-application side of the FastCGI protocol. 
 * The application will then provide a FastCGI interface for the 
 * web server to interact with.
 *
 * For protocol info, see: http://www.fastcgi.com/drupal/node/6?q=node/22
 */
class FastCGI
{
	this()
	{
		import std.process: environment;
		import std.regex: split, regex;

		string addrs = environment.get("FCGI_WEB_SERVER_ADDRS", "");
		if (addrs.length > 0) { 
			fcgi_web_server_addrs = addrs.split(regex(",")).idup;
		}

		try { debugLevel = environment.get("FCGI_DEBUG_LEVEL", "0").to!int; }
		catch (ConvException e) { debugLevel = 0; }
	}

	/// Call run() with a Callback to process reqeusts from the web server.
	void run(Callback callback)
	{
		Socket sock = new Socket(cast(socket_t) FCGI_LISTENSOCK_FILENO, AddressFamily.INET);
		if (!sock.isAlive) 
		{
			import std.stdio;
			writeln("FCGI expected a listening socket on file handle 0.");
			return;
		}

		import std.concurrency: spawn;
		while(sock.isAlive) 
		{
			Socket newSock = sock.accept();
 			if (!sourceOK(newSock)) { newSock.close(); continue; }
 			spawn(&SocketHandler.spawn, newSock.releaseOwnership(), callback, debugLevel);
		} 
	}

private:
	// A list of hosts from which we will accept connections:
	// See: 3.2: Accepting Transport Connections
	private immutable (string[]) fcgi_web_server_addrs;
	private int debugLevel = 0;

	// See: 3.2: Accepting Transport Connections
	// These must come from one of the hosts that were provided to us.
	bool sourceOK(Socket sock)
	{
		auto addr = sock.remoteAddress.toHostNameString;
		
		// Server has not limited connections!?
		if (fcgi_web_server_addrs.length == 0) return true;

		import std.algorithm: any;
		return fcgi_web_server_addrs.any!(x => x==addr);
	}
}

/** FastCGI applications must provide a callback to handle requests. */
alias Callback = void function(Request);


/** (F)CGI request interface! */
interface Request 
{ 
	/// (F)CGI web parameters like REQUEST_SCHEME, REQUEST_URI, etc.
	@property const(string[string]) fcgiParams() const;

	/// Parsed QUERY_STRING as key/value pairs:
	@property const(string[string]) queryParams() const;

	/// Parsed QUERY_STRING containing a list of values for each key.
	@property const(string[][string]) queryParamsMulti() const;

	/// Represents standard output to FCGI (and the web browser.)
	/// Write your web headers and data here.
	@property OutputStream stdout();

	/// FCGI STDERR. Write messages here to display them in the web server's error log.
	@property OutputStream stderr();

	/// Helper function to write HTTP headers. 
	/// This is the same as calling request.stdout.write("Header: value\r\nHeader2: value2\r\n\r\n") for yourself.
	/// Note: This assumes it writes all the headers and appends a blank \r\n, so that the
	/// next thing sent to stdout begins your response.
	void writeHeaders(in string[string] headers);
}

/// allows writing to FCGI stdout / stderr. 
interface OutputStream
{
	alias ConstString = const(char)[];
	/// out.write(some, values, like, so);
	void write(ConstString[] messages ...);

	/// Like write() but appends a newline ('\n')
	void writeln(ConstString[] messages ...);

	void write(const(ubyte)[] data);
}


