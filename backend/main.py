from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from config import STATIC_DIR
import auth_routes
import page_routes
import stats_routes
import game

app = FastAPI()
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

app.include_router(auth_routes.router)
app.include_router(page_routes.router)
app.include_router(stats_routes.router)
app.include_router(game.router)
