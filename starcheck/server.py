import importlib
import json
import socketserver
import traceback


PORT = 44123
HOST = "localhost"


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
        # print(f"SERVER receive func: {cmd['func']}")
        # print(f"SERVER receive args: {cmd['args']}")
        # print(f"SERVER receive kwargs: {cmd['kwargs']}")

        # For security reasons, only allow functions in the public API of starcheck module
        parts = cmd["func"].split(".")
        package = '.'.join(['starcheck'] + parts[:-1])
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
    # Create the server, binding to localhost on port 9999
    with socketserver.TCPServer((HOST, PORT), MyTCPHandler) as server:
        # Activate the server; this will keep running until you
        # interrupt the program with Ctrl-C
        server.serve_forever()


if __name__ == "__main__":
    print("SERVER: starting on port", PORT)
    main()
