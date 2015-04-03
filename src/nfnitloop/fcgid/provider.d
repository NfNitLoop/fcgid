module nfnitloop.fcgid.provider;

import std.algorithm: any;
import std.concurrency: spawn;
import std.conv: to;
import std.process: environment;
import std.range: chunks;
import std.regex: split, regex;
import std.socket;
import std.string: format;
import std.traits: EnumMembers;

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

	/**
	 * Call run() with a Callback to process reqeusts from the web server.
	 */
	void run(Callback callback)
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
			Socket newSock = sock.accept();
 			if (!sourceOK(newSock)) { newSock.close(); continue; }
 			// TODO: Check thread limit?
 			spawn(&SocketHandler.spawn, newSock.releaseOwnership(), callback);
		}
	}

	

	// See: 3.2: Accepting Transport Connections
	// These must come from one of the hosts that were provided to us.
	private bool sourceOK(Socket sock)
	{
		auto addr = sock.remoteAddress.toHostNameString;
		
		// Server has not limited connections!?
		if (fcgi_web_server_addrs.length == 0) return true;
		// 
		return fcgi_web_server_addrs.any!(x => x==addr);
	}
}

/** FastCGI applications must provide a callback to handle requests. */
alias Callback = void function(Request);


/** (F)CGI request interface! */
class Request 
{

	/** (F)CGI web parameters like REQUEST_SCHEME, REQUEST_URI, etc. */
	@property const(string[string]) params() const { return _params; }

	void write(const(char)[] data) // TODO: Char? ubyte? Both?
	{
		handler.stdout(this, cast(ubyte[]) data);
	}

private: 
	int id;
	SocketHandler handler;

	ubyte[] _params_data;
	string[string] _params; // Parsed version of params.

	this(int id, SocketHandler handler) 
	{
		this.id = id;
		this.handler = handler;
	}

	void handle(const Record record)
	{
		if (record.type == RecordType.FCGI_PARAMS)
		{
			if (!record.endOfStream) {
				_params_data ~= record.content;
			} else {
				_params = _params_data.fcgiParams;
				debugMsg("Got params: %s".format(_params));
			}
		}
	}
}


private: /////////////////////////////////////////////////////////////////


/** When an FCGI socket is opened, this class will handle communication on that socket. */
class SocketHandler
{
	/** Call with spawn() to spin up a new thread.  This function will assume ownership of sharedSocket. */
	static void spawn(shared(Socket) sharedSocket, Callback callback)
	{
		auto socket = sharedSocket.takeOwnership();
		auto handler = new SocketHandler(socket, callback);
		handler.run();
	}

	Socket sock;
	Callback callback;

	this(Socket sock, Callback cb)
	{
		this.sock = sock;
		callback = cb;
	}

	Request[int] requests;

	void run()
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
				// TODO: Need to drain that record from the socket anyway.
			}

			auto record = Record.read(header, sock);
			debugMsg("Got record: %s".format(record));
			routeRecord(record);
		}
	}

	void routeRecord(const Record record)
	{
		auto requestId = record.header.requestId;

		if (record.type == RecordType.FCGI_BEGIN_REQUEST)
		{
			if (requestId in requests)
			{
				debugMsg("ERROR: Request # %s is already started!?".format(requestId));
				return;
			}
			requests[requestId] = new Request(requestId, this);
			return;
		}


		if (requestId == 0)
		{
			// TODO
			return;
		}

		if (requestId in requests)
		{
			auto request = requests[requestId];
			if (record.type == RecordType.FCGI_STDIN && record.endOfStream)
			{
				callback(request);  // todo: try/catch.
				// TODO: Are these necessary if we close the request? 
				// closeStream(request, RecordType.FCGI_STDOUT);
				// closeStream(request, RecordType.FCGI_STDERR);
				closeRequest(request, 0); // TODO: non-zero for errors.

				return;
			}

			request.handle(record);
		}
	}

	void stdout(Request request, const(ubyte)[] chars)
	{
		// Protect against writing too many or too few (0) bytes:
		foreach(chunk; chars.chunks(0xffff))
		{
			auto header = FCGI_Record_Header.make(request, RecordType.FCGI_STDOUT, chunk);
			sock.write(header.memory);
			sock.write(chunk);
			debugMsg("Writing request: " ~ cast(const(char)[]) chars);
		}

	}

	void closeStream(Request req, RecordType type)
	{
		// Send 0 bytes to close a stream.
		ubyte[] none;
		auto header = FCGI_Record_Header.make(req, type, none);
		sock.write(header.memory);
	}

	void closeRequest(Request req, uint appStatus)
	{
		// TODO: Send close request
		FCGI_EndRequestBody erb;
		erb.protocolStatus = EndRequestStatus.FCGI_REQUEST_COMPLETE;
		erb.appStatus = appStatus;


		auto header = FCGI_Record_Header.make(req, RecordType.FCGI_END_REQUEST, erb.memory);
		sock.write(header.memory);
		sock.write(erb.memory);

		// TODO: Close the connection if we're supposed to. 
		requests.remove(req.id);
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

/** Write all data to the socket. */
void write(T)(Socket sock, T[] data)
{
	auto buf = cast(void[]) data;
	while (buf.length > 0)
	{
		auto sent = sock.send(buf);
		if (sent == Socket.ERROR) { throw new Exception("Error sending to socket."); }
		buf = buf[sent..$];
	}
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

void debugMsg(lazy const(char)[] msg)
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

	@property ushort requestId() const { return fromBytes(requestIdB0, requestIdB1); }
	@property void requestId(uint newValue) { newValue.putInto(requestIdB0, requestIdB1); }

	@property ushort contentLength() const { return fromBytes(contentLengthB0, contentLengthB1); }
	@property void contentLength(uint newValue) { newValue.putInto(contentLengthB0, contentLengthB1); }

	
	string toString() const
	{
		auto typeEnum = get(type, RecordType.FCGI_UNKNOWN_TYPE);

		return "FCGI_Record_Header(version: %s, type: %s, requestId: %s, contentLength: %s, paddingLength: %s)"
		.format(ver, typeEnum, requestId, contentLength, paddingLength);
	}

	/** Construct a record to send data for a given request, recordtype, and data. 
	  * Data length may not exceed 2^16 bytes. (64KiB)
	  */
	static FCGI_Record_Header make(T)(Request request, RecordType type, const(T)[] data)
	{
		auto buf = cast(void[]) data;
		assert(buf.length < 0x10000);


		FCGI_Record_Header header;
		header.requestId = request.id;
		header.ver = 1;
		header.type = cast(ubyte) type;

		header.contentLength = cast(ushort) buf.length;
		return header;
	}

}

// We depend on this for filling the struct directly from the socket:
static assert(FCGI_Record_Header.sizeof == 8);


struct FCGI_BeginRequestBody
{
	ubyte roleB1;
	ubyte roleB0;
	ubyte flags;
	ubyte[5] reserved;

	@property RequestRole role()
	{
		return get(roleB0, RequestRole.UNKNOWN_);
	} 

	@property bool keepConnection()
	{
		return flags & FCGI_KEEP_CONN;
	}
}

static assert(FCGI_BeginRequestBody.sizeof == 8);

// Bitmask for BeginRequestBody flags.
enum FCGI_KEEP_CONN = 1;


struct FCGI_EndRequestBody
{
	ubyte appStatusB3;
	ubyte appStatusB2;
	ubyte appStatusB1;
	ubyte appStatusB0;
	ubyte protocolStatus;
	ubyte[3] reserved;

	@property void status(EndRequestStatus status)
	{
		protocolStatus = cast(ubyte) status;
	}
	@property void appStatus(uint status)
	{
		appStatusB0 = cast(ubyte) status;
		appStatusB1 = cast(ubyte) (status >> 8);
		appStatusB2 = cast(ubyte) (status >> 16);
		appStatusB3 = cast(ubyte) (status >> 24);
	}
}
static assert(FCGI_EndRequestBody.sizeof == 8);

void putInto(uint value, out ubyte b0, out ubyte b1)
{
	b0 = cast(ubyte) value;
	b1 = cast(ubyte) (value >> 8);
}

ushort fromBytes(in ubyte b0, in ubyte b1)
{
	ushort x = b1;
	x = cast(ushort) (x << 8); 
	x += b0;
	return x;
}

class Record
{
	/** Using a record header, read a record from a socket and return it. */
	static immutable(Record) read(FCGI_Record_Header header, Socket socket)
	{
		auto content = new ubyte[header.contentLength + header.paddingLength];
		socket.fill(content);
		content.length -= header.paddingLength;

		return cast(immutable(Record)) new Record(header, content);
	}

	private FCGI_Record_Header _header;
	private ubyte[] _content;

	this(FCGI_Record_Header header, ubyte[] content) 
	{
		// TODO: Avoid dups?
		_header = header;
		_content = content;
	}

	this(RecordType type)
	{
		_header.type = cast(ubyte) type;
	}

	@property const(FCGI_Record_Header) header() const { return _header; } 
	@property const(ubyte)[] content() const { return _content; }

	override string toString() const
	{
		auto s = "Record(\n  %s".format(header);
		if (type == RecordType.FCGI_BEGIN_REQUEST)
		{
			auto brb = beginRequestBody;
			s ~= "\n  Role: %s".format(brb.role);
			s ~= "\n  keepConnection: %s".format(brb.keepConnection());
		}

		s ~= "\n)";
		return s;
	}

	@property bool endOfStream() const
	{
		// TODO: Check that this is a stream type. 
		// Streams are ended w/ a 0-length block.
		// See: 3.3: Types of Record Types
		return content.length == 0;
	}

	@property RecordType type() const { return get(_header.type, RecordType.FCGI_UNKNOWN_TYPE); }

	@property FCGI_BeginRequestBody beginRequestBody() const
	{
		assert(type == RecordType.FCGI_BEGIN_REQUEST);
		assert(_content.length == FCGI_BeginRequestBody.sizeof);

		FCGI_BeginRequestBody brb;
		brb.memory()[0..$] = cast(void[]) _content[0..$];

		return brb;
	}
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

enum RequestRole
{
    FCGI_RESPONDER = 1,
    FCGI_AUTHORIZER,
    FCGI_FILTER,
    UNKNOWN_
}

enum EndRequestStatus
{
	FCGI_REQUEST_COMPLETE = 0,
	FCGI_CANT_MPX_CONN,
	FCGI_OVERLOADED,
	FCGI_UNKNOWN_ROLE,
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


// Get key/value pairs encoded in fcgi parameters:
string[string] fcgiParams(const(ubyte)[] data)
{
	string[string] params;
	while (data.length > 0)
	{
		uint keyLength = data.popParamLength();
		uint valueLength = data.popParamLength();
		string key = data.popParamString(keyLength);
		string value = data.popParamString(valueLength);
		params[key] = value;
	}

	return params;
}

uint popParamLength(ref const(ubyte)[] content)
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

string popParamString(ref const(ubyte)[] content, uint length)
{
	enforce(content.length >= length, new NameValueDecodeException);
	string value = cast(string) content[0..length];
	content = content[length..$];
	return value;
}

// The socket we expect to be open for us to receive connections on:
 enum FCGI_LISTENSOCK_FILENO = 0;