from fastapi import FastAPI

import auth_routes
import stats_routes
import game
import connect4
import connect4_stats_routes
import ludo
import ludo_stats_routes

app = FastAPI()

app.include_router(auth_routes.router)
app.include_router(stats_routes.router)
app.include_router(game.router)
app.include_router(connect4.router)
app.include_router(connect4_stats_routes.router)
app.include_router(ludo.router)
app.include_router(ludo_stats_routes.router)
