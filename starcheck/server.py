import importlib
import json
import socketserver
import sys
import traceback

HOST = "localhost"
KEY = None


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
        # print(f"SERVER receive: {data.decode('utf-8')}")

        # Decode self.data from JSON
        cmd = json.loads(data)

        if cmd["key"] != KEY:
            print(f"SERVER: bad key {cmd['key']!r}")
            return

        # print(f"SERVER receive func: {cmd['func']}")
        # print(f"SERVER receive args: {cmd['args']}")
        # print(f"SERVER receive kwargs: {cmd['kwargs']}")

        # For security reasons, only allow functions in the public API of starcheck module
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
        else:
            exc = None

        resp = json.dumps({"result": result, "exception": exc})
        # print(f"SERVER send: {resp}")

        self.request.sendall(resp.encode("utf-8"))


def main():
    global KEY

    # Read a line from STDIN
    port = int(sys.stdin.readline().strip())
    KEY = sys.stdin.readline().strip()

    print("SERVER: starting on port", port)

    # Create the server, binding to localhost on supplied port
    with socketserver.TCPServer((HOST, port), MyTCPHandler) as server:
        # Activate the server; this will keep running until you
        # interrupt the program with Ctrl-C
        server.serve_forever()


if __name__ == "__main__":
    main()
