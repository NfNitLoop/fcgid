/** Includes types defined in the FCGI specification. 
 * See: http://www.fastcgi.com/drupal/node/6?q=node/22
 */
module nfnitloop.fcgid.impl.types;
import std.string: format;

// An FCGI server will hand us a listening socket at this file handle:
enum FCGI_LISTENSOCK_FILENO = 0;

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

	@property RecordType recordType() const { return getEnum(type, RecordType.FCGI_UNKNOWN_TYPE); }
	
	
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
		
		
		FCGI_Record_Header header;
		header.requestId = requestId;
		header.ver = 1;
		header.type = cast(ubyte) type;
		
		assert(buf.length < 0x10000);
		header.contentLength = cast(ushort) buf.length;
		return header;
	}
}
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




private: // Convenience functions for FCGI types: 

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


E getEnum(E, V)(V value, E defaultEnum) if (is(E == enum))
{
	import std.traits: EnumMembers;
	
	foreach(e; EnumMembers!E)
	{
		if (e == value) return e;
	}
	return defaultEnum;
}
