module nfnitloop.fcgid.application;

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

private: 
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


private: /////////////////////////////////////////////////////////////////


/** When an FCGI socket is opened, this class will handle communication on that socket. */
class SocketHandler
{
	/** Call with spawn() to spin up a new thread.  This function will assume ownership of sharedSocket. */
	static void spawn(shared(Socket) sharedSocket, Callback callback, int debugLevel)
	{
		auto socket = sharedSocket.takeOwnership();
		auto handler = new SocketHandler(socket, callback, debugLevel);
		handler.run();
	}

	this(Socket sock, Callback cb, int debugLevel)
	{
		this.sock = sock;
		callback = cb;
		this.debugLevel = debugLevel;
	}

	Socket sock;
	Callback callback;
	int debugLevel;
	Request[int] requests;

	void run()
	{
		writeDebug(5, "Begin SocketHandler.handle()");
		scope(exit) sock.close();

		FCGI_Record_Header header;
		while (sock.isAlive)
		{
			sock.fill(header.memory);

			if (header.ver != 1) 
			{
				writeDebug(1, "Skipping record with version %s: %s".format(header.ver, header));
				continue;
				// TODO: Need to drain that record from the socket anyway.
			}

			auto record = Record.read(header, sock);
			writeDebug(2, "Got record: %s".format(record));
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
				// TODO: Send FCGI error.
				writeDebug(0, "ERROR: Request # %s is already started!?".format(requestId));
				return;
			}
			requests[requestId] = new Request(requestId, this, record);
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
				closeRequest(request, 0); // TODO: non-zero for errors?

				return;
			}

			request.handle(record);
		}
	}

	void write(RecordType rt, ushort requestId, const(char)[] data)
	{
		// Cast to ubytes. Sock is a binary stream. This will let us use range w/o weird string-y behavior. 
		write(rt, requestId, cast(const(ubyte)[]) data);
	}

	void write(RecordType rt, ushort requestId, const(ubyte)[] data)
	{
		import std.range: chunks;

		// Protect against writing too many or too few (0) bytes:
		foreach(chunk; data.chunks(0xffff))
		{
			auto header = FCGI_Record_Header.make(requestId, rt, chunk);
			sock.write(header.memory);
			sock.write(chunk);
		}
	}

	void writeDebug(int debugLevel, lazy const(char)[] data, int requestId = 0)
	{
		if (this.debugLevel < debugLevel) { return; }
		alias stderr = RecordType.FCGI_STDERR;
		ushort id = cast(ushort) requestId;
		write(stderr, id, "DEBUG: ");
		write(stderr, id, data); 
		write(stderr, id, "\n");
	}

	void closeStream(Request req, RecordType type)
	{
		// Send 0 bytes to close a stream.
		ubyte[] noData;
		auto header = FCGI_Record_Header.make(req.id, type, noData);
		sock.write(header.memory);
	}

	void closeRequest(Request req, uint appStatus)
	{

		// TODO: " When a role protocol calls for transmitting a stream other than FCGI_STDERR, at least one record of the stream type is always transmitted, even if the stream is empty. "

		// Send close request
		FCGI_EndRequestBody erb;
		erb.protocolStatus = EndRequestStatus.FCGI_REQUEST_COMPLETE;
		erb.appStatus = appStatus;


		auto header = FCGI_Record_Header.make(req.id, RecordType.FCGI_END_REQUEST, erb.memory);
		sock.write(header.memory);
		sock.write(erb.memory);

		requests.remove(req.id);
		if (!req.keepConnection)
		{
			sock.shutdown(SocketShutdown.BOTH);
			sock.close();
		}
	}
}

class OutImpl : OutputStream
{
	this(ushort requestId, RecordType recordType, SocketHandler socketHandler)
	{
		this.requestId = requestId;
		this.recordType = recordType;
		this.socketHandler = socketHandler;
	}

	ushort requestId;
	RecordType recordType;
	SocketHandler socketHandler;

	void write(const(char)[][] messages ...)
	{
		foreach(message; messages) { write(cast(const(ubyte)[]) message); }
	}

	void writeln(const(char)[][] messages ...)
	{
		foreach(message; messages) { write(message); }
		write("\n");
	}

	void write(const(ubyte)[] data)
	{
		socketHandler.write(recordType, requestId, data);
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
		auto typeEnum = getEnum(type, RecordType.FCGI_UNKNOWN_TYPE);

		return "FCGI_Record_Header(version: %s, type: %s, requestId: %s, contentLength: %s, paddingLength: %s)"
		.format(ver, typeEnum, requestId, contentLength, paddingLength);
	}

	/** Construct a record to send data for a given request, recordtype, and data. 
	  * Data length may not exceed 2^16 bytes. (64KiB)
	  */
	static FCGI_Record_Header make(T)(int requestId, RecordType type, const(T)[] data)
	{
		auto buf = cast(void[]) data;
		assert(buf.length < 0x10000);


		FCGI_Record_Header header;
		header.requestId = requestId;
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
		return getEnum(roleB0, RequestRole.UNKNOWN_);
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

	@property RecordType type() const { return getEnum(_header.type, RecordType.FCGI_UNKNOWN_TYPE); }

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


E getEnum(E, V)(V value, E defaultEnum) if (is(E == enum))
{
	import std.traits: EnumMembers;

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