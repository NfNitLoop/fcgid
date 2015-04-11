/** The impl package contains the implementation of the FCGI protocol. 
 * You shouldn't need to import anything in here directly.
 */
module nfnitloop.fcgid.impl;

import nfnitloop.fcgid.application; // TODO: Avoid circular dependencies? 
import nfnitloop.fcgid.impl.types;
import std.socket;


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
	
	@property RecordType type() const { return _header.recordType; } 
	
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

