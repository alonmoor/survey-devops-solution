# FastAPI health endpoints used by the probes (illustrative)
import socket
from contextlib import asynccontextmanager
from fastapi import FastAPI, Response

state = {"ready": False}

@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup: open DB pool, load config ...
    state["ready"] = True
    yield
    # shutdown (after SIGTERM): stop taking new traffic, close pool
    state["ready"] = False

app = FastAPI(lifespan=lifespan)

@app.get("/healthz/live")
def live():
    return {"status": "alive"}          # process only, never checks the DB

@app.get("/healthz/ready")
def ready(response: Response):
    if not state["ready"]:
        response.status_code = 503
        return {"status": "starting or stopping"}
    # pod name lets the availability test tell which replica answered slowly
    return {"status": "ready", "pod": socket.gethostname()}
