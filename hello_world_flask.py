import os
import socket
from flask import Flask

app = Flask(__name__)

@app.route('/')
def hello():
    return 'Hello World from cf app 1 @ {host}!\n'.format(host=socket.gethostname())

port = os.getenv('VCAP_APP_PORT', '80')

if __name__ == "__main__":
#    app.debug=True
    app.run(host='0.0.0.0', port=int(port))
