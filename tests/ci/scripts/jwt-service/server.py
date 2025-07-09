#!/usr/bin/env python3
from datetime import datetime, timedelta
from urllib.parse import urlparse
from jose import jwt
from tornado.httpserver import HTTPServer
from tornado.ioloop import IOLoop
from tornado.web import Application, RequestHandler


JWT_EXPIRATION_MINUTES = 5


class JWTServiceHandler(RequestHandler):

    def get(self, username):
        token = self.create_token(username)
        self.write(token)

    def create_token(self, username):
        claims_set = {
            'sub': username,
            'exp': datetime.now() + timedelta(minutes=JWT_EXPIRATION_MINUTES),
        }
        with open('/run/secrets/daf-private', 'r') as rsa_private_key_file:
            return jwt.encode(
                claims_set,
                rsa_private_key_file.read(),
                algorithm='RS256',
            )


def main():

    application = Application(
        [(r'/([a-z]+)', JWTServiceHandler)],
    )

    http_server = HTTPServer(application)
    url = urlparse('http://0.0.0.0:7777')

    http_server.listen(url.port, url.hostname)
    IOLoop.current().start()


if __name__ == '__main__':
    main()
