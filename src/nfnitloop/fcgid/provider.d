module nfnitloop.fcgid.provider;

import std.algorithm: any;
import std.concurrency: spawn;
import std.conv: to;
import std.process: environment;
import std.regex: split, regex;
import std.socket;
import std.string: format;
import std.traits: EnumMembers;


alias CallbackFunc = void function(Request);

/** 
 * Implements the web-application side of the FastCGI protocol. 
 * The application will then provide a FastCGI interface for the 
 * web server to interact with.
 *
 * For protocol info, see: http://www.fastcgi.com/drupal/node/6?q=node/22
 */
class FastCGI
{

	// A list of hosts from which we will accept connections:
	// See: 3.2: Accepting Transport Connections
	private immutable (string[]) fcgi_web_server_addrs;

	this()
	{
		string addrs = environment.get("FCGI_WEB_SERVER_ADDRS", "");
		if (addrs.length > 0) { 
			fcgi_web_server_addrs = addrs.split(regex(",")).idup;
		}
	}

	void run()
	{
		Socket sock = new Socket(cast(socket_t) FCGI_LISTENSOCK_FILENO, AddressFamily.INET);
		if (!sock.isAlive()) 
		{
			auto msg = "Expected a listening socket on file handle 0.";
			debugMsg(msg);
			enforce(false, msg);
		} 
		while(true) 
		{
			// Shared, but we're just going to pass ownership to the other thread:
			Socket newSock = sock.accept();
 			if (!sourceOK(newSock)) { newSock.close(); continue; }
 			// TODO: Check thread limit?
 			spawn(&SocketHandler.spawn, newSock.releaseOwnership());
		}
	}

	

	// See: 3.2: Accepting Transport Connections
	private bool sourceOK(Socket sock)
	{
		auto addr = sock.remoteAddress.toHostNameString;
		
		// Server has not limited connections!?
		if (fcgi_web_server_addrs.length == 0) return true;
		// 
		return fcgi_web_server_addrs.any!(x => x==addr);

	}
}



/** (F)CGI request interface! */
class Request 
{

	/** (F)CGI web parameters like REQUEST_SCHEME, REQUEST_URI, etc. */
	@property const(string[string]) params() const { return _params; }

private: 
	string[string] _params;
	Response _response;

	this(Response r) 
	{
		_response = r;
	}

}

class Response
{
	void writeln(string msg)
	{
		// TODO: fcgi.writeln(this, msg);
	}

private:

	uint id;
	FastCGI fcgi;

	this(uint id, FastCGI fcgi)
	{
		this.id = id;
		this.fcgi = fcgi;
	}
}

private: /////////////////////////////////////////////////////////////////


/** When an FCGI socket is opened, this class will handle communication on that socket. */
class SocketHandler
{
	/** Call with spawn() to spin up a new thread.  This function will assume ownership of sharedSocket. */
	static void spawn(shared(Socket) sharedSocket)
	{
		auto socket = sharedSocket.takeOwnership();
		auto handler = new SocketHandler();
		handler.handle(socket);
	}

	this()
	{
	}

	void handle(Socket sock)
	{

		debugMsg("SocketHandler.handle()");
		scope(exit) debugMsg("/SocketHandler.handle()");
		scope(exit) sock.close();

		FCGI_Record_Header header;
		while (true)
		{
			sock.fill(header.memory);

			if (header.ver != 1) 
			{
				debugMsg("Skipping record with version %s: %s".format(header.ver, header));
				continue;
			}

			auto record = Record.read(header, sock);
			debugMsg("Got record: %s".format(record));
			routeRecord(record);
		}
	}

	void routeRecord(const Record record)
	{
		if (record.type == RecordType.FCGI_BEGIN_REQUEST)
		{

		}
	}
}

/** receive() from socket until buf is full. 
 * Throws: SocketFillException if buf couldn't be filled.
 */
void fill(Socket sock, void[] buf)
{
	size_t read = 0;
	while (read < buf.length) 
	{
		auto got = sock.receive(buf[read..$]);
		if (got == 0) { throw new SocketFillException("Got 0 bytes. Connection closed?"); }
		if (got == Socket.ERROR) { throw new SocketFillException("Received Socket.ERROR"); }
		assert(got > 0);
		read += got;
	}

	if (read != buf.length) { throw new SocketFillException("Read too many bytes!?"); }
}

/** Thrown if fill() couldn't fill the given data structure. */
class SocketFillException : Exception
{
	this(string msg) { super(msg); }
}

// Cast a thing to void[] so that sock can read into it.
void[] memory(T)(ref T thing)
{
	return cast(void[]) (&thing)[0..1];
}

void debugMsg(string msg)
{
	import std.stdio;
	auto f = new File("/tmp/app.d.log", "a");
	scope(exit) f.close();

	f.writeln(msg);
}

// See: 3.3: Records
struct FCGI_Record_Header
{
	// FCGI protocol version. Should always be 1.
	ubyte ver; 

	// Record type.
	ubyte type; 

	// 16 bit request ID: 
	ubyte requestIdB1; 
	ubyte requestIdB0;

	// 16-bit content length:
	ubyte contentLengthB1;
	ubyte contentLengthB0;


	ubyte paddingLength;
	ubyte reserved;

	@property ushort requestId() const 
	{
		ushort x = requestIdB1;
		x = cast(ushort) (x << 8); 
		x += requestIdB0;
		return x;
	}

	@property ushort contentLength() const 
	{
		ushort x = contentLengthB1;
		x = cast(ushort) (x << 8); 
		x += contentLengthB0;
		return x;
	}
	
	string toString() const
	{
		auto typeEnum = get(type, RecordType.FCGI_UNKNOWN_TYPE);

		return "FCGI_Record_Header(version: %s, type: %s, requestId: %s, contentLength: %s, paddingLength: %s)"
		.format(ver, typeEnum, requestId, contentLength, paddingLength);
	}

}

class Record
{
	/** Using a record header, read a record from a socket and return it. */
	static immutable(Record) read(FCGI_Record_Header header, Socket socket)
	{
		auto content = new ubyte[header.contentLength];
		socket.fill(content);

		// TODO: How can I throw away this stuff w/o allocating all the time? 
		auto padding = new ubyte[header.paddingLength];
		socket.fill(padding);

		return cast(immutable(Record)) new Record(header, content);
	}

	private immutable FCGI_Record_Header _header;
	private immutable(ubyte)[] _content;

	this(FCGI_Record_Header header, ubyte[] content) 
	{
		// TODO: Avoid dups?
		_header = header;
		_content = content.idup;
	}

	@property immutable(FCGI_Record_Header) header() const { return _header; } 
	@property immutable(ubyte)[] content() const { return _content; }

	override string toString() const
	{
		auto s = "Record(\n%s".format(header);
		if (_header.type == RecordType.FCGI_PARAMS)
		{
			s ~= "Params: " ~ to!string(getParams());
		}

		s ~= "\n)";
		return s;
	}

	auto getParams() const
	{
		assert(_header.type == RecordType.FCGI_PARAMS);
		string[string] params;
		const(ubyte)[] data = _content;
		while (data.length > 0)
		{
			uint keyLength = getParamLength(data);
			uint valueLength = getParamLength(data);
			string key = getParamString(data, keyLength);
			string value = getParamString(data, valueLength);
			params[key] = value;
		}

		return params;

	}

	uint getParamLength(ref const(ubyte)[] content) const
	{
		enforce(content.length >= 1, new NameValueDecodeException);
		uint length = content[0];
		content = content[1..$];
		if (length < 128) return length;

		// Else, the high bit is set, meaning we expect 3 more bytes of size:
		enforce(content.length >= 3, new NameValueDecodeException);
		length = length | 0x7f;
		foreach (x; 0 .. 3)
		{
			length = length << 8;
			length += content[0];
			content = content[1..$];
		}
		return length;
	}

	string getParamString(ref const(ubyte)[] content, uint length) const
	{
		enforce(content.length >= length, new NameValueDecodeException);
		string value = cast(string) content[0..length];
		content = content[length..$];
		return value;
	}

	@property bool endOfStream() const
	{
		// TODO: Check that this is a stream type. 
		// Streams are ended w/ a 0-length block.
		// See: 3.3: Types of Record Types
		return content.length == 0;
	}

	@property RecordType type() const { return get(_header.type, RecordType.FCGI_UNKNOWN_TYPE); }
}

class NameValueDecodeException : Exception
{
	this() { super("Error decoding FastCGI Name-value pair."); }
}

enum RecordType
{
	FCGI_BEGIN_REQUEST = 1,
	FCGI_ABORT_REQUEST,
	FCGI_END_REQUEST,
	FCGI_PARAMS,
	FCGI_STDIN,
	FCGI_STDOUT,
	FCGI_STDERR,
	FCGI_DATA,
	FCGI_GET_VALUES,
	FCGI_GET_VALUES_RESULT,
	FCGI_UNKNOWN_TYPE
}

enum OutStream
{
	STDIN,
	STDOUT
}

E get(E, V)(V value, E defaultEnum) if (is(E == enum))
{
	foreach(e; EnumMembers!E)
	{
		if (e == value) return e;
	}
	return defaultEnum;
}

/** Mark that an object is to be shared with another thread by releasing ownership from the current thread. */
shared(T) releaseOwnership(T)(T t)
{
	return cast(shared(T)) t;
}

/** Mark that the local thread is taking ownership of an object. */
T takeOwnership(T)(shared(T) t)
{
	return cast(T) t;
}

// We depend on this for filling the struct directly from the socket:
static assert(FCGI_Record_Header.sizeof == 8);


 enum FCGI_LISTENSOCK_FILENO = 0;