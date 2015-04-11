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
class Request 
{ 
	/// (F)CGI web parameters like REQUEST_SCHEME, REQUEST_URI, etc.
	@property const(string[string]) fcgiParams() const { return _fcgi_params; }

	/// Parsed QUERY_STRING as key/value pairs:
	@property const(string[string]) queryParams() const { return _query_params; }

	/// Parsed QUERY_STRING containing a list of values for each key.
	@property const(string[][string]) queryParamsMulti() const { return _query_params_multi; }

	/// Represents standard output to FCGI (and the web browser.)
	/// Write your web headers and data here.
	@property OutputStream stdout() { return _stdout; }

	/// FCGI STDERR. Write messages here to display them in the web server's error log.
	@property OutputStream stderr() { return _stderr; }

	/// Helper function to write HTTP headers. 
	/// This is the same as calling request.stdout.write("Header: value\r\nHeader2: value2\r\n\r\n") for yourself.
	/// Note: This assumes it writes all the headers and appends a blank \r\n, so that the
	/// next thing sent to stdout begins your response.
	void writeHeaders(in string[string] headers)
	{
		foreach (header, value; headers)
		{
			// TODO: Check that headers don't include newlines. Throw?
			_stdout.write("%s: %s\r\n".format(header, value));
		}
		_stdout.write("\r\n");
	}		

package: 
	ushort id;
	SocketHandler handler;
	const Record beginRecord;
	OutputStream _stdout;
	OutputStream _stderr;

	ubyte[] _params_data;
	string[string] _fcgi_params; // Parsed version of params.
	string[string] _query_params; // parsed QUERY_STRING params.
	string[][string] _query_params_multi; // same, with possible multiple values.

	this(int id, SocketHandler handler, const Record beginRecord) 
	{
		this.id = cast(ushort) id;
		this.handler = handler;
		this.beginRecord = beginRecord;
		_stdout = new OutImpl(this.id, RecordType.FCGI_STDOUT, handler);
		_stderr = new OutImpl(this.id, RecordType.FCGI_STDERR, handler);
	}

	void handle(const Record record)
	{
		final switch(record.type)
		{
			case RecordType.FCGI_PARAMS:
				if (!record.endOfStream) { _params_data ~= record.content; }
				else { calcParams(); }
			break;
			
			case RecordType.FCGI_STDIN:
				// TODO: Send & cache stdin somewhere.
			break;

			case RecordType.FCGI_END_REQUEST:
			case RecordType.FCGI_ABORT_REQUEST:
				// TODO: Move handling of closing to here.
			break;

			case RecordType.FCGI_DATA:
				// This might be used by other request roles in the future?
			case RecordType.FCGI_BEGIN_REQUEST:
			case RecordType.FCGI_STDOUT:
			case RecordType.FCGI_STDERR:
			case RecordType.FCGI_GET_VALUES:
			case RecordType.FCGI_GET_VALUES_RESULT:
			case RecordType.FCGI_UNKNOWN_TYPE:

				// TODO: These types shouldn't happen here.
				// Send an error message to the server.
			break;

		}

	}

	void calcParams()
	{
		import std.algorithm: findSplit;
		import std.algorithm: splitter;
		import std.uri: decodeComponent;
		import std.string: empty;

		// Parse the FCGI parameters:
		_fcgi_params = _params_data.fcgiParams;
		handler.writeDebug(1, "Got params: %s".format(_fcgi_params));

		// Parse QUERY_STRING parameters in 2 ways:
		// _query_params: key/value
		// _query_params_multi: key/value[]
		auto query = fcgiParams.get("QUERY_STRING", "");

		foreach(keyValue; query.splitter("&"))
		{
			auto split = keyValue.findSplit("=");
			if (split[0].empty) continue;
			auto key = split[0].decodeComponent;
			auto value = split[2].decodeComponent;
			_query_params[key] = value;
			if (key in _query_params_multi) { _query_params_multi[key] ~= value; }
			else { _query_params_multi[key] = [value]; }
		}
		
	}

	/// Should we close the socket after this request? 
	bool keepConnection() const
	{
		return beginRecord.beginRequestBody.keepConnection;
	}
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


