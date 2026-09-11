"""The package version, in one place.

A leaf module so anything can read it — including the transports, which the
package's own ``__init__`` imports and therefore cannot be imported *from*
without a cycle. The MCP handshake reports this to the server, and it used to
be a separate hardcoded literal that had drifted six minor versions behind.
"""

__version__ = "0.8.1"
