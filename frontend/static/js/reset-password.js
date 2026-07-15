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
const resetPasswordForm = document.getElementById("resetPasswordForm");

const errors = {
    mismatch: "Passwords do not match.",
    weak: "Password must be 8-72 characters.",
    reused: "You've already used that password before. Choose a different one.",
    invalid_reset_link: "That password reset link is invalid or has expired."
};

const token = params.get("token") || "";
document.getElementById("token").value = token;

if (!token) {
    messageDiv.innerText = "Missing or invalid reset link.";
    messageDiv.classList.add("error");
}

resetPasswordForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const data = await postJSON("/api/auth/reset-password", {
        token: token,
        new_password: document.getElementById("new_password").value,
        confirm_new_password: document.getElementById("confirm_new_password").value,
    });

    if (data.ok) {
        location.href = "/login.html?reset_done=1";
        return;
    }

    messageDiv.innerText = errors[data.error] || "Something went wrong. Please try again.";
    messageDiv.classList.add("error");
});
