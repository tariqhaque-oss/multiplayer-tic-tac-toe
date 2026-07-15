import os

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, RedirectResponse

from config import PAGES_DIR
from security import get_session

router = APIRouter()


@router.get("/")
def home(request: Request):
    session = get_session(request)
    if not session:
        return RedirectResponse("/login")
    return RedirectResponse("/games")


@router.get("/games")
def games_hub(request: Request):
    session = get_session(request)
    if not session:
        return RedirectResponse("/login")
    return FileResponse(os.path.join(PAGES_DIR, "games.html"))


@router.get("/games/tic-tac-toe")
def tic_tac_toe_page(request: Request):
    session = get_session(request)
    if not session:
        return RedirectResponse("/login")
    return FileResponse(os.path.join(PAGES_DIR, "index.html"))
