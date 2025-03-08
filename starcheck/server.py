import collections
import importlib
import json
import logging
import socketserver
import sys
import traceback

from ska_helpers.logging import basic_logger

logger = basic_logger(__name__, level="INFO")

HOST = "localhost"
KEY = None

func_calls = collections.Counter()


class PythonServer(socketserver.TCPServer):
    timeout = 180

    def handle_timeout(self) -> None:
        print(
            f"SERVER: starcheck python server timeout after {self.timeout}s idle",
            file=sys.stderr,
        )
        # self.shutdown()  # DOES NOT WORK, just hangs
        sys.exit(1)


class MyTCPHandler(socketserver.StreamRequestHandler):
    """
    The request handler class for our server.

    It is instantiated once per connection to the server, and must
    override the handle() method to implement communication to the
    client.
    """

    def handle(self):
        # self.request is the TCP socket connected to the client
        data = self.rfile.readline()
        logger.debug(f"SERVER receive: {data.decode('utf-8')}")

        # Decode self.data from JSON
        cmd = json.loads(data)

        if cmd["key"] != KEY:
            logger.ERROR(f"SERVER: bad key {cmd['key']!r}")
            return

        logger.debug(f"SERVER receive func: {cmd['func']}")
        logger.debug(f"SERVER receive args: {cmd['args']}")
        logger.debug(f"SERVER receive kwargs: {cmd['kwargs']}")

        exc = None

        # For security reasons, only allow functions in the public API of starcheck module
        if cmd["func"] == "get_server_calls":
            # Sort func calls by the items in the counter
            result = dict(func_calls)
        else:
            func_calls[cmd["func"]] += 1
            parts = cmd["func"].split(".")
            package = ".".join(["starcheck"] + parts[:-1])
            func = parts[-1]
            module = importlib.import_module(package)
            func = getattr(module, func)
            args = cmd["args"]
            kwargs = cmd["kwargs"]

            try:
                result = func(*args, **kwargs)
            except Exception:
                result = None
                exc = traceback.format_exc()

        resp = json.dumps({"result": result, "exception": exc})
        logger.debug(f"SERVER send: {resp}")

        self.request.sendall(resp.encode("utf-8"))


def main():
    global KEY

    # Read a line from STDIN
    port = int(sys.stdin.readline().strip())
    KEY = sys.stdin.readline().strip()
    loglevel = sys.stdin.readline().strip()

    logmap = {"0": logging.CRITICAL, "1": logging.WARNING, "2": logging.INFO}
    if loglevel in logmap:
        logger.setLevel(logmap[loglevel])
    if int(loglevel) > 2:
        logger.setLevel(logging.DEBUG)

    logger.info(f"SERVER: starting on port {port}")

    # Create the server, binding to localhost on supplied port
    with PythonServer((HOST, port), MyTCPHandler) as server:
        # Activate the server; this will keep running until you
        # interrupt the program with Ctrl-C
        while True:
            server.handle_request()


if __name__ == "__main__":
    main()
