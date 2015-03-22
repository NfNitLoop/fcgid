module nfnitloop.fcgid.provider;

import std.socket;
import std.process: environment;
import std.regex: split, regex;
import std.algorithm: any;

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
		enforce(sock.isAlive(), "Expected a listening socket on file handle 0.");
		while(true) 
		{
			handle(sock.accept());
		}
	}

	void handle(Socket sock)
	{
		if (!sourceOK(sock))
		{
			sock.close();
			return;
		}

		// TODO:
		sock.send("Hi there!\n");
		sock.close();
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

private: /////////////////////////////////////////////////////////////////

/** receive() from socket until buf is full. 
 * Returns true on success, false if the object could not be filled. 
 */
bool fill(Socket sock, void[] buf)
{
	size_t read = 0;
	while (read < buf.length) 
	{
		auto got = sock.receive(buf[read..$]);
		if (got == 0 || got == Socket.ERROR) {
			return false;
		}
		assert(got > 0);
		read += got;
	}

	return read == buf.length;
}

// See: 3.3: Records
struct FCGI_Record
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
}

// We depend on this for filling the struct directly from the socket:
static assert(FCGI_Record.sizeof == 8);


 enum FCGI_LISTENSOCK_FILENO = 0;