async function postJSON(url, body) {
    const res = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    return res.json();
}

const params = new URLSearchParams(location.search);
const messageDiv = document.getElementById("message");
const loginForm = document.getElementById("loginForm");
const resendForm = document.getElementById("resendForm");
const emailInput = document.getElementById("email");

function showMessage(text, isError) {
    messageDiv.innerText = text;
    messageDiv.classList.toggle("error", !!isError);
}

const redirectMessages = {
    invalid_token: ["That verification link is invalid or has expired.", true],
};

const error = params.get("error");

if (error && redirectMessages[error]) {
    showMessage(...redirectMessages[error]);
} else if (params.get("created") === "1") {
    showMessage("Account created. Check your email for a verification link.");
} else if (params.get("verified") === "1") {
    showMessage("Email verified. You can log in now.");
} else if (params.get("reset_done") === "1") {
    showMessage("Password updated. You can log in now.");
} else if (params.get("logged_out") === "1") {
    showMessage("You have been logged out.");
}

loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const data = await postJSON("/api/auth/login", {
        email: emailInput.value,
        password: document.getElementById("password").value,
    });

    if (data.ok) {
        location.href = "/games.html";
        return;
    }

    if (data.error === "unverified") {
        showMessage("Please verify your email before logging in.", true);
        resendForm.style.display = "block";
    } else {
        showMessage("Invalid email or password.", true);
    }
});

resendForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await postJSON("/api/auth/resend-verification", { email: emailInput.value });
    showMessage("If that account needs verifying, a new email was sent.");
});
