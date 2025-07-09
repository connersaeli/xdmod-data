FROM cimg/python:3.8

RUN python -m pip install python-jose tornado

COPY --chmod=777 ./server.py /usr/local/bin/server.py

USER root

CMD ["/usr/local/bin/server.py"]
