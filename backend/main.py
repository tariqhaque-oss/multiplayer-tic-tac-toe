from fastapi import FastAPI

import auth_routes
import stats_routes
import game

app = FastAPI()

app.include_router(auth_routes.router)
app.include_router(stats_routes.router)
app.include_router(game.router)
