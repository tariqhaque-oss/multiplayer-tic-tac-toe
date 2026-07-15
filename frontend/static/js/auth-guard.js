async function requireAuth() {
    const res = await fetch("/api/auth/me", { credentials: "same-origin" });
    const data = await res.json();

    if (!data.authenticated) {
        location.href = "/login.html";
        return null;
    }

    return data;
}

async function logout() {
    await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" });
    location.href = "/login.html";
}

requireAuth();
